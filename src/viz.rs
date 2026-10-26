// lang: Rust, file: viz.rs
// FFT + 32-band spectrum levels + waveform tap, fed from the live audio path
use crate::audio::Core;
use crate::state::AppState;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::time::Duration;

const N: usize = 2048;
const F_LO: f64 = 40.0;
const F_HI: f64 = 16000.0;

// in-place iterative radix-2 FFT, complex input split into re/im
pub fn fft(re: &mut [f64], im: &mut [f64]) {
    let n = re.len();
    debug_assert!(n.is_power_of_two());
    let mut j: usize = 0;
    for i in 0..n {
        if i < j {
            re.swap(i, j);
            im.swap(i, j);
        }
        let mut m = n >> 1;
        while m >= 1 && j & m != 0 {
            j ^= m;
            m >>= 1;
        }
        if m >= 1 {
            j |= m;
        }
    }
    let mut len = 2usize;
    while len <= n {
        let ang = -std::f64::consts::TAU / len as f64;
        let (wr, wi) = (ang.cos(), ang.sin());
        for i in (0..n).step_by(len) {
            let (mut cr, mut ci) = (1.0f64, 0.0f64);
            for k in 0..len / 2 {
                let a = i + k;
                let b = a + len / 2;
                let tr = re[b] * cr - im[b] * ci;
                let ti = re[b] * ci + im[b] * cr;
                re[b] = re[a] - tr;
                im[b] = im[a] - ti;
                re[a] += tr;
                im[a] += ti;
                let ncr = cr * wr - ci * wi;
                ci = cr * wi + ci * wr;
                cr = ncr;
            }
        }
        len <<= 1;
    }
}

fn band_edges(b: usize) -> (f64, f64) {
    let ratio = (F_HI / F_LO).powf(b as f64 / 32.0);
    let lo = F_LO * ratio;
    let hi = F_LO * (F_HI / F_LO).powf((b + 1) as f64 / 32.0);
    (lo, hi)
}

pub fn compute(core: &Core, prev: &mut [f32; 32], peak: &mut [f32; 32]) -> ([f32; 32], [f32; 64]) {
    let raw = core.viz.snapshot_last(N);

    // waveform: 64 points, block-average of what we have
    let mut wave = [0.0f32; 64];
    if !raw.is_empty() {
        let per = (raw.len() as f64 / 64.0).max(1.0) as usize;
        for p in 0..64 {
            let start = p * per;
            let end = ((start + per).min(raw.len())).max(start);
            let mut acc = 0.0f32;
            let mut cnt = 0;
            for i in start..end {
                acc += raw[i];
                cnt += 1;
            }
            wave[p] = if cnt > 0 { (acc / cnt as f32) * 3.0 } else { 0.0 };
            if wave[p] > 1.0 {
                wave[p] = 1.0;
            }
            if wave[p] < -1.0 {
                wave[p] = -1.0;
            }
        }
    }

    if raw.len() < N {
        // not enough audio yet: decay toward silence
        for p in prev.iter_mut() {
            *p *= 0.86;
        }
        return (*prev, wave);
    }

    let mut re = [0.0f64; N];
    let mut im = [0.0f64; N];
    for i in 0..N {
        let w = 0.5 - 0.5 * (std::f64::consts::TAU * i as f64 / N as f64).cos();
        re[i] = raw[i] as f64 * w;
    }
    fft(&mut re, &mut im);

    let bin_hz = 44100.0 / N as f64;
    let mut bands = [0.0f32; 32];
    for b in 0..32 {
        let (lo, hi) = band_edges(b);
        let k_lo = (lo / bin_hz).ceil() as usize;
        let k_hi = ((hi / bin_hz).floor() as usize).clamp(k_lo + 1, N / 2);
        let mut acc = 0.0f64;
        let mut cnt = 0usize;
        for k in k_lo..k_hi {
            let mag = ((re[k] * re[k] + im[k] * im[k]) as f64).sqrt();
            acc += mag;
            cnt += 1;
        }
        let avg = if cnt > 0 { acc / cnt as f64 } else { 0.0 };
        // adaptive normalization: running peak with slow decay
        let a = avg as f32;
        if a > peak[b] {
            peak[b] = a;
        } else {
            peak[b] *= 0.9995;
        }
        let norm = (a / peak[b].max(1e-6)).sqrt();
        bands[b] = norm.clamp(0.0, 1.0);
        // peak-hold fall smoothing
        prev[b] = bands[b].max(prev[b] * 0.82);
    }

    (*prev, wave)
}

pub fn start(app: Arc<Mutex<AppState>>, core: Arc<Core>) {
    std::thread::Builder::new()
        .name("viz".into())
        .spawn(move || {
            let mut prev = [0.0f32; 32];
            let mut peak = [1e-3f32; 32];
            loop {
                std::thread::sleep(Duration::from_millis(45));
                let (levels, wave) = compute(&core, &mut prev, &mut peak);
                if let Ok(mut s) = app.lock() {
                    s.levels = levels.to_vec();
                    s.wave = wave.to_vec();
                }
                let _ = Ordering::Relaxed;
            }
        })
        .expect("spawn viz thread");
}
