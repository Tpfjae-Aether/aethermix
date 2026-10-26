// lang: Rust, file: audio.rs
// cpal output engine + ring buffers; single playback path, dynamic source rate
use crate::state::AppState;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

// ---------------------------------------------------------------------------
// 5-band graphic EQ: RBJ biquads, applied post-volume in the device callback
// bands: 60Hz low shelf | 250Hz | 1kHz | 4kHz peaking | 12kHz high shelf
// ---------------------------------------------------------------------------
#[derive(Clone, Copy, Default)]
pub struct Biquad {
    b0: f32, b1: f32, b2: f32, a1: f32, a2: f32,
}

impl Biquad {
    fn peaking(f0: f32, q: f32, gain_db: f32, rate: f32) -> Self {
        let a = 10f32.powf(gain_db / 40.0);
        let w0 = 2.0 * std::f32::consts::PI * f0 / rate;
        let (cw, sw) = (w0.cos(), w0.sin());
        let al = sw / (2.0 * q);
        let b0 = 1.0 + al * a;
        let b1 = -2.0 * cw;
        let b2 = 1.0 - al * a;
        let a0 = 1.0 + al / a;
        let a1 = -2.0 * cw;
        let a2 = 1.0 - al / a;
        Self { b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0 }
    }
    fn low_shelf(f0: f32, gain_db: f32, rate: f32) -> Self {
        let a = 10f32.powf(gain_db / 40.0);
        let w0 = 2.0 * std::f32::consts::PI * f0 / rate;
        let (cw, sw) = (w0.cos(), w0.sin());
        let sq = a.sqrt();
        let al = sw / 2.0 * ((a + 1.0 / a) * 0.0 + 2.0).sqrt() * 0.70710678118;
        let b0 = a * ((a + 1.0) - (a - 1.0) * cw + 2.0 * sq * al);
        let b1 = 2.0 * a * ((a - 1.0) - (a + 1.0) * cw);
        let b2 = a * ((a + 1.0) - (a - 1.0) * cw - 2.0 * sq * al);
        let a0 = (a + 1.0) + (a - 1.0) * cw + 2.0 * sq * al;
        let a1 = -2.0 * ((a - 1.0) + (a + 1.0) * cw);
        let a2 = (a + 1.0) + (a - 1.0) * cw - 2.0 * sq * al;
        Self { b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0 }
    }
    fn high_shelf(f0: f32, gain_db: f32, rate: f32) -> Self {
        let a = 10f32.powf(gain_db / 40.0);
        let w0 = 2.0 * std::f32::consts::PI * f0 / rate;
        let (cw, sw) = (w0.cos(), w0.sin());
        let sq = a.sqrt();
        let al = sw / 2.0 * ((a + 1.0 / a) * 0.0 + 2.0).sqrt() * 0.70710678118;
        let b0 = a * ((a + 1.0) + (a - 1.0) * cw + 2.0 * sq * al);
        let b1 = -2.0 * a * ((a - 1.0) + (a + 1.0) * cw);
        let b2 = a * ((a + 1.0) + (a - 1.0) * cw - 2.0 * sq * al);
        let a0 = (a + 1.0) - (a - 1.0) * cw + 2.0 * sq * al;
        let a1 = 2.0 * ((a - 1.0) - (a + 1.0) * cw);
        let a2 = (a + 1.0) - (a - 1.0) * cw - 2.0 * sq * al;
        Self { b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0 }
    }
    #[inline]
    fn process(&self, z: &mut [f32; 2], x: f32) -> f32 {
        let y = self.b0 * x + z[0];
        z[0] = self.b1 * x - self.a1 * y + z[1];
        z[1] = self.b2 * x - self.a2 * y;
        y
    }
}

fn compute_eq(gains: [f32; 5], rate: f32) -> [Biquad; 5] {
    [
        Biquad::low_shelf(60.0, gains[0], rate),
        Biquad::peaking(250.0, 1.1, gains[1], rate),
        Biquad::peaking(1000.0, 1.0, gains[2], rate),
        Biquad::peaking(4000.0, 1.0, gains[3], rate),
        Biquad::high_shelf(12000.0, gains[4], rate),
    ]
}

// ---------------------------------------------------------------------------
// Ring buffer: decoded stereo f32 @ source rate in, device callback drains
// ---------------------------------------------------------------------------
pub struct RingBuffer {
    q: Mutex<VecDeque<f32>>,
    cap: usize,
}

impl RingBuffer {
    pub fn new(cap: usize) -> Self {
        Self {
            q: Mutex::new(VecDeque::with_capacity(cap)),
            cap,
        }
    }

    pub fn push(&self, data: &[f32]) {
        if data.is_empty() {
            return;
        }
        let mut q = self.q.lock().unwrap();
        for s in data {
            q.push_back(*s);
        }
        let overflow = q.len().saturating_sub(self.cap);
        if overflow > 0 {
            q.drain(0..overflow);
        }
    }

    pub fn pop(&self, out: &mut [f32]) -> usize {
        let mut q = self.q.lock().unwrap();
        let n = q.len().min(out.len());
        for i in 0..n {
            out[i] = q.pop_front().unwrap_or(0.0);
        }
        n
    }

    pub fn clear(&self) {
        self.q.lock().unwrap().clear();
    }

    pub fn len(&self) -> usize {
        self.q.lock().unwrap().len()
    }

    pub fn snapshot_last(&self, n: usize) -> Vec<f32> {
        let q = self.q.lock().unwrap();
        let start = q.len().saturating_sub(n);
        q.iter().skip(start).copied().collect()
    }
}

// ---------------------------------------------------------------------------
// Shared audio core
// ---------------------------------------------------------------------------
pub struct Core {
    pub ring: RingBuffer,          // decoded stereo f32 interleaved @ src_rate
    pub viz: RingBuffer,           // mono post-volume tap @ device rate
    pub volume: AtomicU32,         // 0..100 percent
    pub playing: AtomicBool,
    pub src_rate: AtomicU32,       // current file sample rate
    pub position_ms: AtomicU32,
    pub duration_ms: AtomicU32,
    pub underruns: AtomicU64,
    pub last_feed: AtomicU64,
    pub resample_carry: Mutex<f64>,
    // graphic EQ (f32 gains bit-packed into AtomicU32 - portable)
    pub eq_enabled: AtomicBool,
    pub eq_gains: [AtomicU32; 5],          // f32::to_bits, dB -12..+12
    eq_coeffs: Mutex<[Biquad; 5]>,
    eq_state: Mutex<[[[f32; 2]; 5]; 2]>,   // [ch][band] DF1 memory
    eq_dirty: AtomicBool,
    eq_rate: AtomicU32,
}

impl Core {
    pub fn new() -> Self {
        Self {
            ring: RingBuffer::new(44100 * 2 * 12), // ~12s ring - theme-switch CPU spike headroom
            viz: RingBuffer::new(32768),
            volume: AtomicU32::new(70),
            playing: AtomicBool::new(false),
            src_rate: AtomicU32::new(44100),
            position_ms: AtomicU32::new(0),
            duration_ms: AtomicU32::new(0),
            underruns: AtomicU64::new(0),
            last_feed: AtomicU64::new(0),
            resample_carry: Mutex::new(0.0),
            eq_enabled: AtomicBool::new(false),
            eq_gains: std::array::from_fn(|_| AtomicU32::new(0)),
            eq_coeffs: Mutex::new([Biquad::default(); 5]),
            eq_state: Mutex::new([[[0.0, 0.0]; 5]; 2]),
            eq_dirty: AtomicBool::new(true),
            eq_rate: AtomicU32::new(0),
        }
    }

    pub fn set_eq(&self, enabled: bool, gains: [f32; 5]) {
        self.eq_enabled.store(enabled, Ordering::Relaxed);
        for (i, g) in gains.iter().enumerate() {
            self.eq_gains[i].store(g.to_bits(), Ordering::Relaxed);
        }
        self.eq_dirty.store(true, Ordering::Relaxed);
        let mut st = self.eq_state.lock().unwrap();
        for ch in 0..2 {
            for b in 0..5 {
                st[ch][b] = [0.0, 0.0];
            }
        }
    }

    pub fn volume_factor(&self) -> f32 {
        let v = self.volume.load(Ordering::Relaxed) as f32 / 100.0;
        v * v // perceptual curve
    }
}

// ---------------------------------------------------------------------------
// librespot Sink: streamed decoder output lands here, pushed into the ring
// ---------------------------------------------------------------------------
use librespot_playback::audio_backend::{Sink, SinkError, SinkResult};
use librespot_playback::convert::Converter;
use librespot_playback::decoder::AudioPacket;

pub struct EngineSink(pub Arc<Core>);

impl Sink for EngineSink {
    fn write(&mut self, packet: AudioPacket, converter: &mut Converter) -> SinkResult<()> {
        let samples = packet
            .samples()
            .map_err(|e| SinkError::OnWrite(e.to_string()))?;
        let f32s = converter.f64_to_f32(samples);

        // BACKPRESSURE - this is load-bearing. librespot paces playback by the
        // sink's write() call: a sink that accepts everything instantly lets the
        // decoder race through a whole track in seconds, fire EndOfTrack, and
        // trigger a skip storm. Block while the ring is above the high-water
        // mark (~2s of stereo @44.1k). Bounded wait so a stalled consumer can
        // never deadlock the decoder thread; overflow drain is the fallback.
        const HIGH_WATER: usize = 44100 * 2 * 6;
        let mut waited_ms = 0u32;
        while self.0.ring.len() > HIGH_WATER && waited_ms < 5000 {
            std::thread::sleep(std::time::Duration::from_millis(10));
            waited_ms += 10;
        }
        self.0.ring.push(&f32s);
        self.0.last_feed.store(
            (std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap_or_default()
                .as_millis()) as u64,
            Ordering::Relaxed,
        );
        Ok(())
    }

    fn start(&mut self) -> SinkResult<()> {
        self.0.ring.clear();
        Ok(())
    }

    fn stop(&mut self) -> SinkResult<()> {
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Device callback: pop from ring, linear-resample to device rate, map channels
// ---------------------------------------------------------------------------
fn fill_callback(core: &Core, data: &mut [f32], dev_rate: f64, dev_ch: usize) {
    let ch = dev_ch.max(1);
    let frames = data.len() / ch;
    let vol = core.volume_factor();
    let playing = core.playing.load(Ordering::Relaxed);
    let src_rate = core.src_rate.load(Ordering::Relaxed) as f64;

    if !playing || src_rate <= 0.0 {
        for v in data.iter_mut() {
            *v = 0.0;
        }
        return;
    }

    let ratio = src_rate / dev_rate; // source frames per device frame
    let carry_prev = *core.resample_carry.lock().unwrap();
    let total_src = frames as f64 * ratio + carry_prev;
    let whole = total_src.floor() as usize;
    {
        let mut carry = core.resample_carry.lock().unwrap();
        *carry = total_src - whole as f64;
    }

    let mut src = vec![0.0f32; (whole + 2) * 2];
    let got = core.ring.pop(&mut src);
    let got_frames = got / 2;
    // only a REAL underrun counts: track loaded AND the ring held data within
    // the last 2s (recent feed). A paused/ended track leaving the callback
    // silent is idle, not a pipeline failure.
    let last_feed_ms = core.last_feed.load(Ordering::Relaxed);
    let now_ms = (std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()) as u64;
    if got == 0 && last_feed_ms != 0 && now_ms.saturating_sub(last_feed_ms) < 2000 {
        core.underruns.fetch_add(1, Ordering::Relaxed);
    }

    // EQ: refresh coefficients on gain change or device-rate change
    let eq_on = core.eq_enabled.load(Ordering::Relaxed);
    if eq_on
        && (core.eq_dirty.load(Ordering::Relaxed)
            || core.eq_rate.load(Ordering::Relaxed) != dev_rate as u32)
    {
        let gains = [
            f32::from_bits(core.eq_gains[0].load(Ordering::Relaxed)),
            f32::from_bits(core.eq_gains[1].load(Ordering::Relaxed)),
            f32::from_bits(core.eq_gains[2].load(Ordering::Relaxed)),
            f32::from_bits(core.eq_gains[3].load(Ordering::Relaxed)),
            f32::from_bits(core.eq_gains[4].load(Ordering::Relaxed)),
        ];
        let c = compute_eq(gains, dev_rate as f32);
        *core.eq_coeffs.lock().unwrap() = c;
        core.eq_rate.store(dev_rate as u32, Ordering::Relaxed);
        core.eq_dirty.store(false, Ordering::Relaxed);
    }
    let mut eq_z = core.eq_state.lock().unwrap();
    let eq_c = *core.eq_coeffs.lock().unwrap();

    let mut viz = Vec::with_capacity(frames);
    for fi in 0..frames {
        let pos = fi as f64 * ratio + carry_prev;
        let i = pos as usize;
        let frac = (pos - i as f64) as f32;
        let (l, r) = if i + 1 < got_frames {
            let l = src[i * 2] * (1.0 - frac) + src[(i + 1) * 2] * frac;
            let r = src[i * 2 + 1] * (1.0 - frac) + src[(i + 1) * 2 + 1] * frac;
            (l, r)
        } else if i < got_frames {
            (src[i * 2], src[i * 2 + 1])
        } else {
            (0.0, 0.0)
        };
        let mut s_l = l * vol;
        let mut s_r = r * vol;
        if eq_on {
            for b in 0..5 {
                s_l = eq_c[b].process(&mut eq_z[0][b], s_l);
                s_r = eq_c[b].process(&mut eq_z[1][b], s_r);
            }
        }
        if ch == 1 {
            data[fi] = (s_l + s_r) * 0.5;
            viz.push(data[fi]);
        } else {
            for c in 0..ch {
                data[fi * ch + c] = if c % 2 == 0 { s_l } else { s_r };
            }
            viz.push(s_l);
        }
    }
    drop(eq_z);
    core.viz.push(&viz);
}

// ---------------------------------------------------------------------------
// Output stream bootstrap
// ---------------------------------------------------------------------------
pub fn start_output(core: Arc<Core>, _app: Arc<Mutex<AppState>>) {
    use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
    std::thread::Builder::new()
        .name("audio-out".into())
        .spawn(move || {
            let host = cpal::default_host();
            let device = match host.default_output_device() {
                Some(d) => d,
                None => {
                    eprintln!("[audio] no output device found");
                    return;
                }
            };
            let default_cfg = match device.default_output_config() {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("[audio] default config failed: {e}");
                    return;
                }
            };

            // prefer native stereo 44.1k; fall back to device default
            let cfg = device
                .supported_output_configs()
                .ok()
                .and_then(|mut cs| {
                    cs.find(|c| {
                        c.channels() == 2 && c.try_with_sample_rate(44100).is_some()
                    })
                })
                .and_then(|c| c.try_with_sample_rate(44100));

            let config = match cfg {
                Some(c) => c.config(),
                None => default_cfg.config(),
            };
            let dev_rate = config.sample_rate as f64;
            let dev_ch = config.channels as usize;
            eprintln!("[audio] output stream: {} Hz, {} ch", dev_rate, dev_ch);

            let core2 = core.clone();
            let err_cb = |e: cpal::Error| eprintln!("[audio] stream error: {e}");
            let data_cb = move |data: &mut [f32], _info: &cpal::OutputCallbackInfo| {
                fill_callback(&core2, data, dev_rate, dev_ch);
            };

            let stream = match device.build_output_stream(config, data_cb, err_cb, None) {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("[audio] build_output_stream failed: {e}");
                    return;
                }
            };
            if let Err(e) = stream.play() {
                eprintln!("[audio] stream.play failed: {e}");
                return;
            }
            eprintln!("[audio] stream live");
            // park forever: keeps the cpal Stream alive
            loop {
                std::thread::park();
            }
        })
        .expect("spawn audio thread");
}
