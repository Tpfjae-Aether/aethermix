// lang: Rust, file: live.rs
// Live web streaming - play a youtube / soundcloud / bandcamp page without
// writing a file first.
//
// The engine has two moving parts:
//   1. yt-dlp resolves the page into a direct media URL (`-g`). Those URLs are
//      signed and short-lived, so the answer is cached for three hours and
//      resolved again if ffmpeg dies on a stale one.
//   2. ffmpeg turns that URL into raw PCM on stdout, which is pushed straight
//      into the same ring buffer the file decoder feeds. Seeking restarts
//      ffmpeg at the new offset (HTTP range request), which is why a stream
//      can jump around without downloading the whole song.
//
// Pause is backpressure: the reader stops draining ffmpeg's stdout, ffmpeg
// blocks on its pipe, and no samples reach the ring. That costs no CPU.

use crate::audio::Core;
use std::io::Read;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

const RATE: u32 = 44100;
const CHANNELS: u32 = 2;
// keep roughly three seconds buffered: enough to ride a network hiccup, small
// enough that pausing is felt immediately and seeking is not stuck behind a
// long queue of already-decoded audio
const HIGH_WATER: usize = (RATE * CHANNELS * 3) as usize;
const NO_SEEK: u32 = u32::MAX;

const YTDLP: &str = concat!(env!("AETHER_ROOT"), "/bin/yt-dlp.exe");
const FFMPEG: &str = concat!(env!("AETHER_ROOT"), "/bin/ffmpeg.exe");

fn hidden(cmd: &mut Command) -> &mut Command {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    cmd
}

pub struct Live {
    gen: AtomicU64,
    id: AtomicU64,
    playing: AtomicBool,
    ended: AtomicBool,
    pos: AtomicU32,
    dur: AtomicU32,
    seek_to: AtomicU32,
    child: Mutex<Option<Child>>,
    title: Mutex<String>,
    artist: Mutex<String>,
    web: Mutex<String>,
}

static LIVE: OnceLock<Arc<Live>> = OnceLock::new();

pub fn handle() -> &'static Arc<Live> {
    LIVE.get_or_init(|| {
        Arc::new(Live {
            gen: AtomicU64::new(0),
            id: AtomicU64::new(0),
            playing: AtomicBool::new(false),
            ended: AtomicBool::new(false),
            pos: AtomicU32::new(0),
            dur: AtomicU32::new(0),
            seek_to: AtomicU32::new(NO_SEEK),
            child: Mutex::new(None),
            title: Mutex::new(String::new()),
            artist: Mutex::new(String::new()),
            web: Mutex::new(String::new()),
        })
    })
}

pub fn active() -> bool {
    handle().id.load(Ordering::Relaxed) != 0
}

pub fn ended() -> bool {
    handle().ended.load(Ordering::Relaxed)
}

pub fn position_ms() -> u32 {
    handle().pos.load(Ordering::Relaxed)
}

pub fn duration_ms() -> u32 {
    handle().dur.load(Ordering::Relaxed)
}

pub fn is_playing() -> bool {
    handle().playing.load(Ordering::Relaxed)
}

/// What is on the wire right now ("Artist - Title"), for the status line.
pub fn now_label() -> String {
    let t = handle().title.lock().map(|s| s.clone()).unwrap_or_default();
    let a = handle().artist.lock().map(|s| s.clone()).unwrap_or_default();
    if a.is_empty() {
        t
    } else if t.is_empty() {
        a
    } else {
        format!("{a} - {t}")
    }
}

pub fn pause() {
    handle().playing.store(false, Ordering::Relaxed);
}

pub fn play() {
    handle().playing.store(true, Ordering::Relaxed);
}

pub fn seek(ms: u32) {
    let h = handle();
    if h.id.load(Ordering::Relaxed) == 0 {
        return;
    }
    h.seek_to.store(ms.min(h.dur.load(Ordering::Relaxed).max(1)), Ordering::Relaxed);
    h.ended.store(false, Ordering::Relaxed);
}

pub fn stop() {
    let h = handle();
    h.gen.fetch_add(1, Ordering::Relaxed);
    h.id.store(0, Ordering::Relaxed);
    h.playing.store(false, Ordering::Relaxed);
    h.ended.store(false, Ordering::Relaxed);
    h.seek_to.store(NO_SEEK, Ordering::Relaxed);
    h.pos.store(0, Ordering::Relaxed);
    if let Ok(mut slot) = h.child.lock() {
        if let Some(mut c) = slot.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }
}

/// Start streaming a web page. Returns false when the row cannot be streamed,
/// so the caller can fall back to a saved file or the Spotify session.
pub fn start(
    core: &Arc<Core>,
    page_url: &str,
    title: &str,
    artist: &str,
    duration_hint: u32,
    track_id: usize,
) -> bool {
    if page_url.trim().is_empty() {
        return false;
    }
    stop();
    let h = handle();
    h.gen.fetch_add(1, Ordering::Relaxed);
    let gen = h.gen.load(Ordering::Relaxed);
    h.id.store(track_id as u64 + 1, Ordering::Relaxed);
    h.playing.store(true, Ordering::Relaxed);
    h.ended.store(false, Ordering::Relaxed);
    h.dur.store(duration_hint, Ordering::Relaxed);
    h.pos.store(0, Ordering::Relaxed);
    h.seek_to.store(NO_SEEK, Ordering::Relaxed);
    if let Ok(mut t) = h.title.lock() {
        *t = title.to_string();
    }
    if let Ok(mut a) = h.artist.lock() {
        *a = artist.to_string();
    }
    if let Ok(mut w) = h.web.lock() {
        *w = page_url.to_string();
    }

    core.ring.clear();
    core.src_rate.store(RATE, Ordering::Relaxed);
    core.position_ms.store(0, Ordering::Relaxed);
    core.duration_ms.store(duration_hint, Ordering::Relaxed);
    core.playing.store(true, Ordering::Relaxed);

    let h2 = h.clone();
    let core2 = core.clone();
    let page = page_url.to_string();
    std::thread::Builder::new()
        .name("live-stream".into())
        .spawn(move || run(h2, core2, page, gen))
        .ok();
    true
}

// ---------------------------------------------------------------- resolution
struct Resolved {
    page: String,
    direct: String,
    at: std::time::Instant,
}

static RESOLVED: Mutex<Vec<Resolved>> = Mutex::new(Vec::new());
static RESOLVE_LOCK: Mutex<()> = Mutex::new(());

fn resolve_direct(page: &str, force: bool) -> Result<String, String> {
    resolve_with(page, false, force)
}

/// The direct media URL as a *client* can play it - the phone's <audio>
/// element, not ffmpeg. iOS decodes AAC everywhere and Opus only on newer
/// builds, so the phone asks for an m4a rendition. Its answer is cached under
/// a different key from the engine's opus pick, so neither tuning can quietly
/// change what the other one plays.
pub fn direct_audio_url(page: &str) -> Result<String, String> {
    resolve_with(page, true, false)
}

/// Drop every cached link for one page. A signed media URL can expire between
/// resolving it and the first byte, and the honest answer to that is to ask
/// again rather than to serve the client a 403.
pub fn forget_direct(page: &str) {
    if let Ok(mut cache) = RESOLVED.lock() {
        cache.retain(|r| !r.page.starts_with(page));
    }
}

fn resolve_with(page: &str, mp4: bool, force: bool) -> Result<String, String> {
    let key = if mp4 {
        format!("{page}|mp4")
    } else {
        page.to_string()
    };
    if !force {
        if let Ok(cache) = RESOLVED.lock() {
            if let Some(hit) = cache.iter().find(|r| r.page == key) {
                if hit.at.elapsed().as_secs() < 3 * 3600 {
                    return Ok(hit.direct.clone());
                }
            }
        }
    }
    let _guard = RESOLVE_LOCK.lock().map_err(|_| "resolver poisoned".to_string())?;
    let mut cmd = Command::new(YTDLP);
    hidden(&mut cmd);
    cmd.args([
        "-g",
        "-f",
        if mp4 {
            "bestaudio[ext=m4a]/bestaudio[acodec=mp4a]/bestaudio/best"
        } else {
            "bestaudio[acodec=opus]/bestaudio/best"
        },
        "--no-playlist",
        "--no-warnings",
        "--no-progress",
        page,
    ]);
    cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
    let mut child = cmd.spawn().map_err(|e| format!("yt-dlp could not start: {e}"))?;
    // a dead network must not pin the resolver forever
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(45);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) => {
                if std::time::Instant::now() > deadline {
                    let _ = child.kill();
                    return Err("resolving that link timed out".into());
                }
                std::thread::sleep(std::time::Duration::from_millis(60));
            }
            Err(e) => return Err(format!("resolver wait: {e}")),
        }
    }
    let out = child.wait_with_output().map_err(|e| format!("resolver output: {e}"))?;
    let text = String::from_utf8_lossy(&out.stdout);
    let direct = text
        .lines()
        .map(|l| l.trim())
        .find(|l| l.starts_with("http://") || l.starts_with("https://"))
        .map(|s| s.to_string());
    let direct = match direct {
        Some(d) => d,
        None => {
            let err = String::from_utf8_lossy(&out.stderr);
            let msg = err
                .lines()
                .filter(|l| l.contains("ERROR") || l.contains("error"))
                .last()
                .or_else(|| err.lines().last())
                .unwrap_or("no stream url returned")
                .trim()
                .to_string();
            return Err(msg);
        }
    };
    if let Ok(mut cache) = RESOLVED.lock() {
        cache.retain(|r| r.page != key && r.at.elapsed().as_secs() < 3 * 3600);
        cache.push(Resolved { page: key, direct: direct.clone(), at: std::time::Instant::now() });
        if cache.len() > 32 {
            cache.remove(0);
        }
    }
    Ok(direct)
}

fn spawn_ffmpeg(direct: &str, from_ms: u32) -> Result<Child, String> {
    let mut cmd = Command::new(FFMPEG);
    hidden(&mut cmd);
    // -ss before -i is a fast input seek (HTTP range), not a decode-and-drop
    cmd.args(["-hide_banner", "-loglevel", "error", "-nostdin"]);
    if from_ms > 0 {
        cmd.args(["-ss", &format!("{:.3}", from_ms as f64 / 1000.0)]);
    }
    cmd.args([
        "-i",
        direct,
        "-vn",
        "-ac",
        "2",
        "-ar",
        &RATE.to_string(),
        "-f",
        "s16le",
        "pipe:1",
    ]);
    // stderr must never share a pipe with the audio: ffmpeg writes decode
    // warnings there, and a full 64 KiB pipe buffer stalls the encoder mid-song
    cmd.stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("ffmpeg could not start: {e}"))
}

fn same(h: &Live, gen: u64) -> bool {
    h.gen.load(Ordering::Relaxed) == gen
}

fn take_seek(h: &Live) -> Option<u32> {
    let v = h.seek_to.swap(NO_SEEK, Ordering::Relaxed);
    if v == NO_SEEK {
        None
    } else {
        Some(v)
    }
}

fn kill_child(h: &Live) {
    if let Ok(mut slot) = h.child.lock() {
        if let Some(mut c) = slot.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
    }
}

fn run(h: Arc<Live>, core: Arc<Core>, page: String, gen: u64) {
    let mut start_ms: u32 = 0;
    let mut miss = 0u32;
    while same(&h, gen) {
        if let Some(ms) = take_seek(&h) {
            start_ms = ms;
            h.pos.store(ms, Ordering::Relaxed);
            core.ring.clear();
            core.position_ms.store(ms, Ordering::Relaxed);
        }
        if !h.playing.load(Ordering::Relaxed) {
            std::thread::sleep(std::time::Duration::from_millis(50));
            continue;
        }

        let direct = match resolve_direct(&page, miss > 0) {
            Ok(d) => d,
            Err(e) => {
                eprintln!("[live] resolve failed: {e}");
                h.ended.store(true, Ordering::Relaxed);
                h.playing.store(false, Ordering::Relaxed);
                return;
            }
        };
        if !same(&h, gen) {
            return;
        }
        let mut child = match spawn_ffmpeg(&direct, start_ms) {
            Ok(c) => c,
            Err(e) => {
                eprintln!("[live] {e}");
                h.ended.store(true, Ordering::Relaxed);
                return;
            }
        };
        let mut out = match child.stdout.take() {
            Some(o) => o,
            None => {
                let _ = child.kill();
                h.ended.store(true, Ordering::Relaxed);
                return;
            }
        };
        if let Ok(mut slot) = h.child.lock() {
            *slot = Some(child);
        }

        let mut bytes_read: u64 = 0;
        // frames decoded since this pipe started: the position is this plus the
        // seek offset, so the clock climbs instead of resetting on every read
        let mut played: u64 = 0;
        let mut carry: Option<u8> = None;
        let mut buf = vec![0u8; 32 * 1024];
        let mut seeked = false;
        loop {
            if !same(&h, gen) {
                kill_child(&h);
                return;
            }
            if let Some(ms) = take_seek(&h) {
                start_ms = ms;
                h.pos.store(ms, Ordering::Relaxed);
                core.position_ms.store(ms, Ordering::Relaxed);
                core.ring.clear();
                seeked = true;
                kill_child(&h);
                break;
            }
            if !h.playing.load(Ordering::Relaxed) {
                std::thread::sleep(std::time::Duration::from_millis(50));
                continue;
            }
            // backpressure: never race the device by more than a few seconds
            let mut waited = 0;
            while core.ring.len() > HIGH_WATER && waited < 4000 && same(&h, gen) {
                std::thread::sleep(std::time::Duration::from_millis(20));
                waited += 20;
            }
            let n = out.read(&mut buf).unwrap_or(0);
            if n == 0 {
                break;
            }
            bytes_read += n as u64;
            miss = 0;
            let mut pcm: Vec<u8> = Vec::with_capacity(n + 1);
            if let Some(b) = carry.take() {
                pcm.push(b);
            }
            pcm.extend_from_slice(&buf[..n]);
            let even = pcm.len() - (pcm.len() % 2);
            if even < pcm.len() {
                carry = Some(pcm[even]);
            }
            let mut samples: Vec<f32> = Vec::with_capacity(even / 2);
            for c in pcm[..even].chunks_exact(2) {
                let s = i16::from_le_bytes([c[0], c[1]]);
                samples.push(s as f32 / 32768.0);
            }
            let frames = samples.len() as u64 / CHANNELS as u64;
            played += frames;
            core.ring.push(&samples);
            core.last_feed.store(
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_millis() as u64,
                Ordering::Relaxed,
            );
            let pos = start_ms as u64 + played * 1000 / RATE as u64;
            h.pos.store(pos.min(u32::MAX as u64) as u32, Ordering::Relaxed);
            core.position_ms.store(h.pos.load(Ordering::Relaxed), Ordering::Relaxed);
            let dur = h.dur.load(Ordering::Relaxed);
            if dur == 0 || pos > dur as u64 {
                h.dur.store(pos as u32, Ordering::Relaxed);
                core.duration_ms.store(pos as u32, Ordering::Relaxed);
            }
        }

        // reap the child; a mid-song death usually means the signed url aged out
        let child_ok = {
            let mut slot = match h.child.lock() {
                Ok(g) => g,
                Err(_) => return,
            };
            match slot.take() {
                Some(mut c) => {
                    let ok = c.wait().map(|s| s.success()).unwrap_or(false);
                    if !ok {
                        if let Some(mut err) = c.stderr.take() {
                            let mut s = String::new();
                            let _ = err.read_to_string(&mut s);
                            if !s.trim().is_empty() {
                                eprintln!("[live] ffmpeg: {}", s.lines().last().unwrap_or(""));
                            }
                        }
                    }
                    ok
                }
                None => false,
            }
        };
        if !same(&h, gen) {
            return;
        }
        if seeked {
            continue;
        }
        if bytes_read > RATE as u64 * 3 && !child_ok && miss < 1 {
            // it died mid-song: re-resolve from where the ear already is
            miss += 1;
            start_ms = h.pos.load(Ordering::Relaxed);
            eprintln!("[live] stream interrupted at {start_ms}ms - re-resolving url");
            std::thread::sleep(std::time::Duration::from_millis(300));
            continue;
        }
        if bytes_read == 0 && miss < 2 {
            miss += 1;
            continue;
        }
        core.last_feed.store(0, Ordering::Relaxed);
        h.ended.store(true, Ordering::Relaxed);
        return;
    }
}
