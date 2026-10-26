// lang: Rust, file: ytcvt.rs, runs on: Windows 11, target: YouTube audio sourcing
// playlist converter (Musi-style): walks the synced Spotify catalog, searches
// YouTube per track, scores candidates against the real metadata, pulls the
// audio-only stream, tags it, and drops it into the local library scan path.
// The whole existing player (queue, EQ, visuals, lyrics) just works on the
// result - it is a local file like any other.

use crate::library::Library;
use std::path::PathBuf;
use std::process::Command;

// Every external process is started windowless. Without CREATE_NO_WINDOW a
// GUI app inherits a brand new console for each child, which is the black
// rectangle that used to flash every time a song was pulled or converted.
pub fn ytdlp() -> Command {
    let mut c = Command::new(YTDLP);
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        c.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    // yt-dlp is a Python program, and Python picks its stdout encoding from the
    // console code page. On a Windows box that is cp1252, so a UTF-8 title
    // arrives re-encoded ("–" becomes "â€“") and the playlist ends up called
    // something nobody typed. Both variables force UTF-8 regardless of the
    // console the app was started from.
    c.env("PYTHONUTF8", "1");
    c.env("PYTHONIOENCODING", "utf-8");
    // a stalled connection must not pin a worker thread forever: yt-dlp's own
    // socket timeout is the backstop behind run_capped.
    c.args(["--socket-timeout", "15"]);
    // the active account's session travels with every call: search, download
    // and probe all see the same youtube the browser sees
    for a in crate::accounts::cookie_args() {
        c.arg(a);
    }
    c
}

/// Undo one round of cp1252-as-UTF-8 mangling. A UTF-8 title read through the
/// Windows console code page turns "–" (e2 80 93) into "â€“", which is *valid*
/// UTF-8 and therefore parses without complaint - the bytes are simply
/// describing the wrong characters. Mapping every char back to its cp1252 byte
/// and decoding again is exact when, and only when, the result is real UTF-8.
/// "Café" fails that test (e9 is not a lead byte) and is returned untouched.
pub fn repair_mojibake(s: &str) -> String {
    // the tell-tale lead characters: a 2/3/4-byte UTF-8 sequence read as cp1252
    // always starts with one of these, so a string without one cannot be this
    let suspect = s.contains('Ã') || s.contains('â') || s.contains('ð') || s.contains('Â');
    if !suspect {
        return s.to_string();
    }
    let mut bytes = Vec::with_capacity(s.len());
    for ch in s.chars() {
        match cp1252_byte(ch) {
            Some(b) => bytes.push(b),
            None => return s.to_string(),
        }
    }
    match String::from_utf8(bytes) {
        Ok(fixed) if fixed != s && !fixed.contains('\u{fffd}') => fixed,
        _ => s.to_string(),
    }
}

fn cp1252_byte(c: char) -> Option<u8> {
    let n = c as u32;
    if n < 0x80 || (0xA0..=0xFF).contains(&n) {
        return Some(n as u8);
    }
    // the only codepoints where cp1252 disagrees with latin-1
    Some(match c {
        '€' => 0x80, '‚' => 0x82, 'ƒ' => 0x83, '„' => 0x84, '…' => 0x85,
        '†' => 0x86, '‡' => 0x87, 'ˆ' => 0x88, '‰' => 0x89, 'Š' => 0x8a,
        '‹' => 0x8b, 'Œ' => 0x8c, 'Ž' => 0x8e, '‘' => 0x91, '’' => 0x92,
        '“' => 0x93, '”' => 0x94, '•' => 0x95, '–' => 0x96, '—' => 0x97,
        '˜' => 0x98, '™' => 0x99, 'š' => 0x9a, '›' => 0x9b, 'œ' => 0x9c,
        'ž' => 0x9e, 'Ÿ' => 0x9f,
        _ => return None,
    })
}

/// Parse the json yt-dlp printed, repaired if the console mangled it.
fn ytdlp_json(bytes: &[u8]) -> Option<serde_json::Value> {
    let raw = String::from_utf8_lossy(bytes).to_string();
    let fixed = repair_mojibake(&raw);
    serde_json::from_str(&fixed).ok()
}

// spawn yt-dlp and never wait longer than `secs`: a DNS hiccup or a throttled
// extractor used to leave a search hanging for the rest of the session.
fn run_capped(cmd: &mut std::process::Command, secs: u64) -> Option<std::process::Output> {
    use std::io::Read;
    cmd.stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    let mut child = cmd.spawn().ok()?;
    let mut so = child.stdout.take()?;
    let mut se = child.stderr.take()?;
    let t_out = std::thread::spawn(move || {
        let mut b = Vec::new();
        let _ = so.read_to_end(&mut b);
        b
    });
    let t_err = std::thread::spawn(move || {
        let mut b = Vec::new();
        let _ = se.read_to_end(&mut b);
        b
    });
    let start = std::time::Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let stdout = t_out.join().unwrap_or_default();
                let stderr = t_err.join().unwrap_or_default();
                return Some(std::process::Output { status, stdout, stderr });
            }
            Ok(None) => {
                if start.elapsed().as_secs() >= secs {
                    let _ = child.kill();
                    let _ = child.wait();
                    let _ = t_out.join();
                    let _ = t_err.join();
                    return None;
                }
                std::thread::sleep(Duration::from_millis(60));
            }
            Err(_) => return None,
        }
    }
}
use std::sync::Mutex;
use std::time::Duration;

const YTDLP: &str = concat!(env!("AETHER_ROOT"), "/bin/yt-dlp.exe");
const FFMPEG: &str = concat!(env!("AETHER_ROOT"), "/bin/ffmpeg.exe");
/// Where a downloaded song lands: the user's own Music folder, created on first
/// download. `AETHER_MUSIC` moves it (the first entry wins).
fn out_dir() -> String {
    if let Ok(v) = std::env::var("AETHER_MUSIC") {
        if let Some(first) = v.split(';').map(|s| s.trim()).find(|s| !s.is_empty()) {
            return first.replace('\\', "/");
        }
    }
    match std::env::var("USERPROFILE") {
        Ok(home) => format!("{}/Music/AetherMix", home.replace('\\', "/")),
        Err(_) => "aethermix-downloads".to_string(),
    }
}
const COVERS_DIR: &str = concat!(env!("AETHER_ROOT"), "/cache/covers");

// ffmpeg is what turns youtube's aac/opus stream into a plain .mp3. it also
// rescues the occasional source the decoder cannot read. optional: without it
// every add still lands as aac (m4a), which the engine decodes natively.
fn ffmpeg() -> Option<&'static str> {
    if std::path::Path::new(FFMPEG).is_file() {
        Some(FFMPEG)
    } else {
        None
    }
}

fn run_ffmpeg(args: &[&str]) -> Result<(), String> {
    let mut c = Command::new(FFMPEG);
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        c.creation_flags(0x0800_0000);
    }
    let out = c.args(args).output().map_err(|e| format!("spawn ffmpeg: {e}"))?;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        let msg = err
            .lines()
            .filter(|l| !l.trim().is_empty())
            .last()
            .unwrap_or("?")
            .to_string();
        return Err(format!("convert failed: {msg}"));
    }
    Ok(())
}

// the audio files an add can legitimately leave behind, best first
const AUDIO_EXTS: [&str; 6] = ["mp3", "m4a", "ogg", "opus", "webm", "mp4"];

fn staged_file(base: &str, stem: &str) -> Option<PathBuf> {
    AUDIO_EXTS
        .iter()
        .map(|e| PathBuf::from(format!("{base}.{e}")))
        .find(|p| p.file_stem().and_then(|s| s.to_str()) == Some(stem) && p.is_file())
        .or_else(|| {
            // extension casing can vary; fall back to a directory scan by stem
            std::fs::read_dir(out_dir()).ok().and_then(|rd| {
                rd.filter_map(|e| e.ok())
                    .map(|e| e.path())
                    .find(|p| {
                        p.file_stem().and_then(|s| s.to_str()) == Some(stem)
                            && p.extension()
                                .and_then(|e| e.to_str())
                                .map(|e| AUDIO_EXTS.contains(&e.to_lowercase().as_str()))
                                .unwrap_or(false)
                    })
            })
        })
}

#[derive(Default, Clone)]
pub struct ConvertStatus {
    pub running: bool,
    pub total: usize,
    pub done: usize,
    pub failed: usize,
    pub skipped: usize,
    pub current: String,
    pub last_error: String,
}

impl ConvertStatus {
    pub fn to_json(&self) -> String {
        serde_json::json!({
            "running": self.running,
            "total": self.total,
            "done": self.done,
            "failed": self.failed,
            "skipped": self.skipped,
            "current": self.current,
            "last_error": self.last_error,
        })
        .to_string()
    }
}

static STATUS: Mutex<Option<ConvertStatus>> = Mutex::new(None);

#[derive(Default, Clone)]
pub struct AddStatus {
    pub running: bool,
    pub current: String,
    pub current_title: String,
    pub last_title: String,
    pub last_error: String,
    pub last_id: i64,
    pub done: usize,
    pub queued: usize,
    pub failed: usize,
}

static ADD_STATUS: Mutex<Option<AddStatus>> = Mutex::new(None);

pub fn add_status_json() -> String {
    let g = ADD_STATUS.lock().unwrap();
    let st = g.clone().unwrap_or_default();
    let queued = ADDQ.lock().unwrap().jobs.len();
    serde_json::json!({
        "running": st.running,
        "current": st.current,
        "current_title": st.current_title,
        "last_title": st.last_title,
        "last_error": st.last_error,
        "last_id": st.last_id,
        "done": st.done,
        "failed": st.failed,
        "queued": queued,
    })
    .to_string()
}

fn add_state(f: impl FnOnce(&mut AddStatus)) {
    let mut g = ADD_STATUS.lock().unwrap();
    let st = g.get_or_insert_with(AddStatus::default);
    f(st);
}

pub fn status_snapshot() -> ConvertStatus {
    STATUS
        .lock()
        .unwrap()
        .clone()
        .unwrap_or_default()
}

fn set_current(title: &str) {
    let mut g = STATUS.lock().unwrap();
    let st = g.get_or_insert_with(ConvertStatus::default);
    st.current = title.into();
}

fn bump(field: fn(&mut ConvertStatus)) {
    let mut g = STATUS.lock().unwrap();
    if let Some(st) = g.as_mut() {
        field(st);
    }
}

fn err(msg: &str) {
    let mut g = STATUS.lock().unwrap();
    if let Some(st) = g.as_mut() {
        st.last_error = msg.into();
    }
}

fn safe_name(s: &str) -> String {
    let mut out = String::new();
    for c in s.chars() {
        if c.is_ascii_alphanumeric() || " -_()[]".contains(c) {
            out.push(c);
        } else {
            out.push('_');
        }
    }
    let out = out.trim().trim_matches('_').to_string();
    if out.is_empty() {
        "track".into()
    } else {
        out.chars().take(90).collect()
    }
}

struct Candidate {
    id: String,
    title: String,
    duration_s: f64,
    thumb: String,
}

fn search(query: &str) -> Result<Vec<Candidate>, String> {
    let mut cmd = ytdlp();
    cmd.args([
        "--dump-single-json",
        "--flat-playlist",
        "--no-warnings",
        &format!("ytsearch5:{query}"),
    ]);
    let out = run_capped(&mut cmd, 25).ok_or_else(|| "yt-dlp search timed out".to_string())?;
    if !out.status.success() {
        return Err(format!(
            "yt-dlp search failed: {}",
            String::from_utf8_lossy(&out.stderr).chars().take(200).collect::<String>()
        ));
    }
    let body = String::from_utf8_lossy(&out.stdout);
    let v: serde_json::Value =
        serde_json::from_str(&body).map_err(|e| format!("parse search json: {e}"))?;
    let mut out = Vec::new();
    if let Some(entries) = v.get("entries").and_then(|e| e.as_array()) {
        for e in entries {
            let Some(id) = e.get("id").and_then(|x| x.as_str()) else { continue };
            let title = e.get("title").and_then(|x| x.as_str()).unwrap_or("").to_string();
            let duration_s = e.get("duration").and_then(|x| x.as_f64()).unwrap_or(0.0);
            let thumb = e
                .get("thumbnail")
                .and_then(|x| x.as_str())
                .map(|x| x.to_string())
                .or_else(|| {
                    e.get("thumbnails")
                        .and_then(|t| t.as_array())
                        .and_then(|a| a.last())
                        .and_then(|t| t.get("url"))
                        .and_then(|x| x.as_str())
                        .map(|x| x.to_string())
                })
                .unwrap_or_else(|| format!("https://i.ytimg.com/vi/{id}/hqdefault.jpg"));
            if duration_s > 0.0 {
                out.push(Candidate {
                    id: id.into(),
                    title,
                    duration_s,
                    thumb,
                });
            }
        }
    }
    Ok(out)
}

fn score(cand: &Candidate, title: &str, artist: &str, want_ms: u32) -> f64 {
    let ct = cand.title.to_lowercase();
    let mut s = 0.0;
    // token overlap on title
    for tok in title.to_lowercase().split_whitespace() {
        if ct.contains(tok) {
            s += 3.0;
        }
    }
    // artist token overlap
    for tok in artist.to_lowercase().split_whitespace() {
        if tok.len() > 2 && ct.contains(tok) {
            s += 2.5;
        }
    }
    // duration proximity: |delta| within 8s = near-perfect match
    let delta = (cand.duration_s * 1000.0 - want_ms as f64).abs();
    if delta < 3000.0 {
        s += 6.0;
    } else if delta < 8000.0 {
        s += 3.0;
    } else if delta < 15000.0 {
        s += 1.0;
    } else {
        s -= (delta / 1000.0 - 15.0).min(20.0);
    }
    // traps: live performances, remixes, 8-hour loops
    let t = ct.as_str();
    if t.contains("live") {
        s -= 4.0;
    }
    if t.contains("remix") && !title.to_lowercase().contains("remix") {
        s -= 5.0;
    }
    if t.contains("1 hour") || t.contains("10 hours") || t.contains("24 hours") {
        s -= 20.0;
    }
    if t.contains("official audio") || t.contains("lyric") || t.contains("official video") {
        s += 1.5;
    }
    // topic/auto channels host the real audio
    if t.contains("topic") {
        s += 2.0;
    }
    s
}

fn pick(cands: Vec<Candidate>, title: &str, artist: &str, want_ms: u32) -> Option<Candidate> {
    cands
        .into_iter()
        .map(|c| {
            let s = score(&c, title, artist, want_ms);
            (c, s)
        })
        .max_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal))
        .filter(|(_, s)| *s > 4.0)
        .map(|(c, _)| c)
}

fn tag_file(path: &PathBuf, title: &str, artist: &str, cover: &[u8]) {
    // best-effort tagging: real title/artist + embedded cover so the library
    // extracts real art for every converted track
    use lofty::prelude::*;
    use lofty::probe::Probe;
    use lofty::tag::Tag;
    let Ok(mut tf) = Probe::open(path).and_then(|p| p.read()) else {
        eprintln!("[ytcvt] tag_file: probe failed on {path:?}");
        return;
    };
    if tf.primary_tag().is_none() {
        let tag_type = tf.primary_tag_type();
        tf.insert_tag(Tag::new(tag_type));
    }
    let Some(tag) = tf.primary_tag_mut() else {
        eprintln!("[ytcvt] tag_file: no mutable tag on {path:?}");
        return;
    };
    tag.set_title(title.to_string());
    tag.set_artist(artist.to_string());
    if cover.len() > 8 {
        use std::io::Cursor;
        match lofty::picture::Picture::from_reader(&mut Cursor::new(cover.to_vec())) {
            Ok(mut pic) => {
                pic.set_pic_type(lofty::picture::PictureType::CoverFront);
                tag.push_picture(pic);
                eprintln!("[ytcvt] tag_file: pushed {} byte cover", cover.len());
            }
            Err(e) => eprintln!("[ytcvt] tag_file: picture parse failed: {e}"),
        }
    }
    use lofty::config::WriteOptions;
    if let Err(e) = tf.save_to_path(path, WriteOptions::default()) {
        eprintln!("[ytcvt] tag save failed for {:?}: {e}", path.file_name().unwrap_or_default());
    }
}

// a clean, human search result list for the add-music sheet
pub fn search_json(query: &str, limit: usize) -> String {
    search_source_json(query, "youtube", limit)
}

/// Search one source. youtube and soundcloud go through yt-dlp (no api key,
/// no extra account); spotify is answered by the server, which owns the
/// session, and local is filtered in the ui.
pub fn search_source_json(query: &str, source: &str, limit: usize) -> String {
    let q = query.trim();
    if q.is_empty() {
        return "{\"results\":[]}".into();
    }
    let n = limit.clamp(1, 20);
    let target = match source {
        "soundcloud" => format!("scsearch{n}:{q}"),
        _ => format!("ytsearch{n}:{q}"),
    };
    let mut cmd = ytdlp();
    cmd.args(["--dump-single-json", "--flat-playlist", "--no-warnings", &target]);
    let Some(out) = run_capped(&mut cmd, 25) else {
        return "{\"results\":[],\"error\":\"yt-dlp search timed out\"}".into();
    };
    if !out.status.success() {
        let hint = String::from_utf8_lossy(&out.stderr)
            .lines()
            .filter(|l| !l.trim().is_empty())
            .last()
            .unwrap_or("")
            .to_string();
        return serde_json::json!({"results": [], "error": format!("search failed: {hint}")})
            .to_string();
    }
    let v: serde_json::Value = ytdlp_json(&out.stdout).unwrap_or_default();
    let mut rows = Vec::new();
    if let Some(entries) = v.get("entries").and_then(|e| e.as_array()) {
        for e in entries {
            let Some(id) = e.get("id").and_then(|x| x.as_str()) else { continue };
            let title = e.get("title").and_then(|x| x.as_str()).unwrap_or("");
            let mut artist = e
                .get("uploader")
                .or_else(|| e.get("channel"))
                .or_else(|| e.get("creator"))
                .and_then(|x| x.as_str())
                .unwrap_or("")
                .to_string();
            if artist.to_lowercase().ends_with(" - topic") {
                artist.truncate(artist.len() - 8);
            }
            let dur = e.get("duration").and_then(|x| x.as_f64()).unwrap_or(0.0);
            // zero-length entries are channels/live shells, not songs
            if dur <= 1.0 {
                continue;
            }
            // soundcloud's flat entries carry their art in a size list, not a
            // single thumbnail; the largest one is the right one
            let thumb = e
                .get("thumbnail")
                .and_then(|x| x.as_str())
                .map(|x| x.to_string())
                .or_else(|| {
                    e.get("thumbnails")
                        .and_then(|t| t.as_array())
                        .and_then(|a| a.last())
                        .and_then(|t| t.get("url"))
                        .and_then(|x| x.as_str())
                        .map(|x| x.to_string())
                })
                .unwrap_or_else(|| {
                    if source == "soundcloud" {
                        String::new()
                    } else {
                        format!("https://i.ytimg.com/vi/{id}/hqdefault.jpg")
                    }
                });
            // webpage_url is the human page yt-dlp can actually fetch;
            // soundcloud's flat "url" is an api endpoint with encoded colons
            let url = e
                .get("webpage_url")
                .or_else(|| e.get("url"))
                .and_then(|x| x.as_str())
                .map(|x| x.to_string())
                .unwrap_or_else(|| format!("https://www.youtube.com/watch?v={id}"));
            rows.push(serde_json::json!({
                "id": id,
                "source": source,
                "url": url,
                "title": clean_title(title),
                "artist": artist,
                "duration_ms": (dur * 1000.0) as u64,
                "thumb": thumb,
            }));
        }
    }
    serde_json::json!({"results": rows}).to_string()
}

fn clean_title(t: &str) -> String {
    let mut s = t.to_string();
    for junk in [
        "(Official Video)",
        "[Official Video]",
        "(Official Music Video)",
        "[Official Music Video]",
        "(Official Audio)",
        "[Official Audio]",
        "(Lyric Video)",
        "[Lyric Video]",
        "(Visualizer)",
        "[Visualizer]",
        "(Audio)",
        "[Audio]",
    ] {
        s = s.replace(junk, "");
    }
    s.trim().trim_matches('-').trim().to_string()
}

/// Is the configured session readable? Run one cheap search and hand back the
/// first real line of stderr when it is not - cookie import failures are the
/// only thing this can honestly diagnose.
pub fn probe_session() -> (bool, String) {
    let mut cmd = ytdlp();
    cmd.args([
        "--dump-single-json",
        "--flat-playlist",
        "--no-warnings",
        "ytsearch1:aethermix session probe",
    ]);
    match run_capped(&mut cmd, 25) {
        Some(o) if o.status.success() => (true, "session loaded, youtube answered".into()),
        Some(o) => {
            let err = String::from_utf8_lossy(&o.stderr);
            let line = err
                .lines()
                .find(|l| l.to_lowercase().contains("cookie") || l.to_lowercase().contains("error"))
                .or_else(|| err.lines().last())
                .unwrap_or("unknown failure")
                .trim()
                .to_string();
            (false, line)
        }
        None => (false, "youtube did not answer in time".into()),
    }
}

// One worker, one queue: pressing "+" on several results used to spawn
// competing threads that overwrote each other's status, so the sheet looked
// frozen. Now every request is a job and the worker reports the real one.
#[derive(Clone)]
struct AddJob {
    url: String,
    stream: bool,
    play: bool,
}

struct AddQueue {
    jobs: std::collections::VecDeque<AddJob>,
    worker: bool,
}

static ADDQ: Mutex<AddQueue> = Mutex::new(AddQueue {
    jobs: std::collections::VecDeque::new(),
    worker: false,
});

// download one youtube song straight into the library, tag it, and pin it to
// the active playlist. runs off the UI thread; progress is exposed by status.
pub fn add_url(
    lib: std::sync::Arc<Mutex<Library>>,
    app: std::sync::Arc<Mutex<crate::state::AppState>>,
    url: String,
) {
    add_url_playing(lib, app, url, false)
}

fn enqueue(
    lib: std::sync::Arc<Mutex<Library>>,
    app: std::sync::Arc<Mutex<crate::state::AppState>>,
    job: AddJob,
) {
    let start_worker = {
        let mut q = ADDQ.lock().unwrap();
        if q.jobs
            .iter()
            .any(|j| j.url == job.url && j.stream == job.stream)
        {
            return;
        }
        q.jobs.push_back(job.clone());
        if q.worker {
            false
        } else {
            q.worker = true;
            true
        }
    };
    {
        let mut g = ADD_STATUS.lock().unwrap();
        let st = g.get_or_insert_with(AddStatus::default);
        if !st.running {
            st.running = true;
            st.last_error.clear();
        }
    }
    add_state(|s| {
        s.current = job.url;
    });
    if !start_worker {
        return;
    }
    std::thread::Builder::new()
        .name("yt-add".into())
        .spawn(move || loop {
            let job = {
                let mut q = ADDQ.lock().unwrap();
                match q.jobs.pop_front() {
                    Some(j) => j,
                    None => {
                        q.worker = false;
                        add_state(|s| {
                            s.running = false;
                            s.current.clear();
                            s.current_title.clear();
                        });
                        return;
                    }
                }
            };
            add_state(|s| {
                s.running = true;
                s.current = job.url.clone();
                s.current_title.clear();
                s.last_error.clear();
            });
            let got = if job.stream {
                add_stream_inner(&lib, &app, &job.url)
            } else {
                add_url_inner(&lib, &app, &job.url)
            };
            match got {
                Ok((id, title)) => {
                    add_state(|s| {
                        s.last_id = id as i64;
                        s.last_title = title;
                        s.done += 1;
                    });
                    if job.play {
                        crate::server::request_play(id);
                    }
                }
                Err(e) => {
                    eprintln!("[yt-add] {e}");
                    add_state(|s| {
                        s.failed += 1;
                        s.last_error = e;
                    });
                }
            }
        })
        .expect("spawn yt add");
}

/// `play` = start the song the moment the file lands, so a search result can
/// be used with one press instead of add-then-hunt-for-it.
pub fn add_url_playing(
    lib: std::sync::Arc<Mutex<Library>>,
    app: std::sync::Arc<Mutex<crate::state::AppState>>,
    url: String,
    play: bool,
) {
    enqueue(
        lib,
        app,
        AddJob {
            url,
            stream: false,
            play,
        },
    );
}

/// Add a song that plays straight from the web: metadata and sleeve are
/// fetched now, the audio only when it plays. No waiting for a download, no
/// disk cost - and the row can be saved offline later from its menu.
pub fn add_stream_playing(
    lib: std::sync::Arc<Mutex<Library>>,
    app: std::sync::Arc<Mutex<crate::state::AppState>>,
    url: String,
    play: bool,
) {
    enqueue(
        lib,
        app,
        AddJob {
            url,
            stream: true,
            play,
        },
    );
}

// metadata for one page, shared by the stream add and the offline save
pub(crate) struct WebMeta {
    pub(crate) vid: String,
    pub(crate) title: String,
    pub(crate) artist: String,
    pub(crate) album: String,
    pub(crate) duration_ms: u32,
    pub(crate) thumb: String,
}

pub(crate) fn web_meta(url: &str) -> Result<WebMeta, String> {
    let mut meta_cmd = ytdlp();
    meta_cmd.args(["--dump-single-json", "--no-playlist", "--no-warnings", url]);
    let meta_out = run_capped(&mut meta_cmd, 45)
        .ok_or_else(|| "could not read that page (timed out)".to_string())?;
    if !meta_out.status.success() {
        let msg = String::from_utf8_lossy(&meta_out.stderr)
            .lines()
            .filter(|l| !l.trim().is_empty())
            .last()
            .unwrap_or("?")
            .to_string();
        return Err(format!("could not read that page: {msg}"));
    }
    let v: serde_json::Value =
        ytdlp_json(&meta_out.stdout).ok_or_else(|| "bad page metadata".to_string())?;
    let vid = v.get("id").and_then(|x| x.as_str()).unwrap_or("").to_string();
    let mut title = v
        .get("track")
        .and_then(|x| x.as_str())
        .or_else(|| v.get("title").and_then(|x| x.as_str()))
        .unwrap_or("untitled")
        .to_string();
    title = clean_title(&title);
    let mut artist = v
        .get("artist")
        .or_else(|| v.get("creator"))
        .or_else(|| v.get("uploader"))
        .or_else(|| v.get("channel"))
        .and_then(|x| x.as_str())
        .unwrap_or("the web")
        .to_string();
    if artist.to_lowercase().ends_with(" - topic") {
        artist.truncate(artist.len() - 8);
    }
    if title.len() > artist.len() + 3 {
        let head_ok = title
            .get(..artist.len())
            .map(|h| h.eq_ignore_ascii_case(&artist))
            .unwrap_or(false);
        if head_ok {
            if let Some(tail) = title.get(artist.len()..).map(|r| r.trim_start()) {
                let cut = tail
                    .strip_prefix('-')
                    .or_else(|| tail.strip_prefix('\u{2013}'))
                    .or_else(|| tail.strip_prefix('\u{2014}'))
                    .map(|r| r.trim());
                if let Some(c) = cut {
                    if c.len() >= 3 {
                        title = c.to_string();
                    }
                }
            }
        }
    }
    let album = v
        .get("album")
        .and_then(|x| x.as_str())
        .unwrap_or(if url.contains("soundcloud.com") {
            "SoundCloud"
        } else {
            "YouTube"
        })
        .to_string();
    let duration_ms = (v.get("duration").and_then(|x| x.as_f64()).unwrap_or(0.0) * 1000.0) as u32;
    let thumb = v
        .get("thumbnail")
        .and_then(|x| x.as_str())
        .map(|x| x.to_string())
        .or_else(|| {
            v.get("thumbnails")
                .and_then(|t| t.as_array())
                .and_then(|a| a.last())
                .and_then(|t| t.get("url"))
                .and_then(|x| x.as_str())
                .map(|x| x.to_string())
        })
        .unwrap_or_default();
    Ok(WebMeta {
        vid,
        title,
        artist,
        album,
        duration_ms,
        thumb,
    })
}

// keep the sleeve on disk so a playlist survives an expired thumbnail url
pub(crate) fn cache_cover(vid: &str, thumb: &str) -> String {
    if vid.is_empty() && thumb.is_empty() {
        return String::new();
    }
    let bytes = cover_for_video(vid, thumb);
    if bytes.is_empty() {
        return thumb.to_string();
    }
    let dir = COVERS_DIR;
    let _ = std::fs::create_dir_all(dir);
    let name = format!("{dir}/yt_{}.jpg", if vid.is_empty() { "web" } else { vid });
    let _ = std::fs::write(&name, &bytes);
    if std::path::Path::new(&name).is_file() {
        format!("file:///{name}")
    } else {
        String::new()
    }
}

fn add_stream_inner(
    lib: &std::sync::Arc<Mutex<Library>>,
    app: &std::sync::Arc<Mutex<crate::state::AppState>>,
    url: &str,
) -> Result<(usize, String), String> {
    let meta = web_meta(url)?;
    add_state(|s| s.current_title = format!("{} - {}", meta.artist, meta.title));
    let cover = cache_cover(&meta.vid, &meta.thumb);
    let id = {
        let mut l = lib.lock().unwrap();
        let id = l.add_track(
            &meta.title,
            &meta.artist,
            &meta.album,
            meta.duration_ms,
            "",
            "",
            url,
            &cover,
        );
        l.save_playlist();
        id
    };
    let label = if url.contains("soundcloud.com") {
        "soundcloud"
    } else if url.contains("bandcamp.com") {
        "bandcamp"
    } else {
        "youtube"
    };
    {
        let mut a = app.lock().unwrap();
        a.status = format!("queued \"{}\" from {label} (streams, no download)", meta.title);
        a.library_version = lib.lock().unwrap().version;
    }
    warm_lyrics_web(
        meta.title.clone(),
        meta.artist.clone(),
        meta.album.clone(),
        meta.duration_ms,
    );
    Ok((id, meta.title))
}

/// Save a streamed row to disk in the background, then point the same row at
/// the file. The stream keeps playing while it lands.
pub fn save_web_row(
    lib: std::sync::Arc<Mutex<Library>>,
    app: std::sync::Arc<Mutex<crate::state::AppState>>,
    id: usize,
) {
    let (web, title) = {
        let l = lib.lock().unwrap();
        match l.tracks.iter().find(|t| t.id == id) {
            Some(t) => (t.web.clone(), t.title.clone()),
            None => return,
        }
    };
    if web.is_empty() {
        return;
    }
    {
        let mut a = app.lock().unwrap();
        a.status = format!("saving \"{title}\" for offline play");
    }
    std::thread::Builder::new()
        .name("yt-save".into())
        .spawn(move || match ingest_url(&web) {
            Ok(got) => {
                {
                    let mut l = lib.lock().unwrap();
                    if let Some(t) = l.tracks.iter_mut().find(|t| t.id == id) {
                        t.path = got.path.clone();
                        if !got.cover_url.is_empty() {
                            t.cover_file = got.cover_url.clone();
                        }
                        if t.duration_ms == 0 {
                            t.duration_ms = got.duration_ms;
                        }
                    }
                    l.version += 1;
                    l.save_playlist();
                }
                {
                    let mut a = app.lock().unwrap();
                    a.status = format!("saved \"{title}\" - plays offline now");
                    a.library_version = lib.lock().unwrap().version;
                }
                warm_lyrics(got.title, got.artist, got.album, got.duration_ms, got.path);
            }
            Err(e) => {
                app.lock().unwrap().status = format!("could not save \"{title}\": {e}");
            }
        })
        .ok();
}

/// Lyrics for a row that has no file yet: only the shared cache is written,
/// since there is no folder to put an .lrc beside.
fn warm_lyrics_web(title: String, artist: String, album: String, duration_ms: u32) {
    if title.trim().is_empty() {
        return;
    }
    let _ = std::thread::Builder::new()
        .name("lyr-web".into())
        .spawn(move || {
            let Some((ly, sy)) = crate::catalog::fetch_lrclib(&title, &artist, &album, duration_ms)
            else {
                return;
            };
            if ly.trim().is_empty() {
                return;
            }
            let dir = concat!(env!("AETHER_ROOT"), "/cache/lyrics");
            let _ = std::fs::create_dir_all(dir);
            let key = crate::state::song_key(&title, &artist);
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);
            let _ = std::fs::write(
                format!("{dir}/{key}.json"),
                serde_json::json!({ "lyrics": ly, "synced": sy, "t": now }).to_string(),
            );
        });
}

pub struct Ingested {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration_ms: u32,
    pub path: String,
    pub cover_url: String,
    pub vid: String,
}

/// Download one url into the library folder and return what the playlist
/// writer needs. The library is not touched: the importer owns that step.
pub fn ingest_url(url: &str) -> Result<Ingested, String> {
    let mut meta_cmd = ytdlp();
    meta_cmd.args(["--dump-single-json", "--no-playlist", "--no-warnings", url]);
    let meta_out = run_capped(&mut meta_cmd, 45)
        .ok_or_else(|| "could not read that video (timed out)".to_string())?;
    if !meta_out.status.success() {
        let msg = String::from_utf8_lossy(&meta_out.stderr)
            .lines()
            .filter(|l| !l.trim().is_empty())
            .last()
            .unwrap_or("?")
            .to_string();
        return Err(format!("could not read that video: {msg}"));
    }
    let v: serde_json::Value = ytdlp_json(&meta_out.stdout)
        .ok_or_else(|| "bad video metadata".to_string())?;
    let vid = v.get("id").and_then(|x| x.as_str()).unwrap_or("");
    if vid.is_empty() {
        return Err("no video id".into());
    }
    let mut title = v
        .get("track")
        .and_then(|x| x.as_str())
        .or_else(|| v.get("title").and_then(|x| x.as_str()))
        .unwrap_or("untitled")
        .to_string();
    title = clean_title(&title);
    let mut artist = v
        .get("artist")
        .or_else(|| v.get("creator"))
        .or_else(|| v.get("uploader"))
        .or_else(|| v.get("channel"))
        .and_then(|x| x.as_str())
        .unwrap_or("youtube")
        .to_string();
    if artist.to_lowercase().ends_with(" - topic") {
        artist.truncate(artist.len() - 8);
    }
    // youtube's flat/track field often repeats the uploader as a prefix:
    // "Billie Eilish, Khalid - lovely" uploaded by "Billie Eilish" used to be
    // stored as "Billie Eilish - Billie Eilish, Khalid - lovely", which reads
    // badly in the room and makes the lyric lookup score against noise.
    // only a real separator is stripped - "Queen" + "Queen of the Night"
    // must keep its title.
    if title.len() > artist.len() + 3 {
        let head_ok = title
            .get(..artist.len())
            .map(|h| h.eq_ignore_ascii_case(&artist))
            .unwrap_or(false);
        if head_ok {
            if let Some(rest) = title.get(artist.len()..) {
                let tail = rest.trim_start();
                let cut = tail
                    .strip_prefix('-')
                    .or_else(|| tail.strip_prefix(':'))
                    .or_else(|| tail.strip_prefix('\u{2013}'))
                    .or_else(|| tail.strip_prefix('\u{2014}'))
                    .map(|r| r.trim());
                if let Some(c) = cut {
                    if c.len() >= 3 && !c.eq_ignore_ascii_case(&title) {
                        title = c.to_string();
                    }
                }
            }
        }
    }
    // the sheet shows the song while it is still downloading, not a raw url
    let shown = format!("{artist} - {title}");
    add_state(|s| s.current_title = shown.clone());
    let album = v
        .get("album")
        .and_then(|x| x.as_str())
        .unwrap_or("YouTube")
        .to_string();
    let dur_ms = (v.get("duration").and_then(|x| x.as_f64()).unwrap_or(0.0) * 1000.0) as u32;
    let thumb = v
        .get("thumbnail")
        .and_then(|x| x.as_str())
        .map(|x| x.to_string())
        .or_else(|| {
            v.get("thumbnails")
                .and_then(|t| t.as_array())
                .and_then(|a| a.last())
                .and_then(|t| t.get("url"))
                .and_then(|x| x.as_str())
                .map(|x| x.to_string())
        })
        .unwrap_or_default();

    let _ = std::fs::create_dir_all(out_dir());
    let stem = safe_name(&format!("{artist} - {title}"));
    let base = format!("{}/{stem}", out_dir());
    let mut produced = staged_file(&base, &stem);

    if produced.is_none() {
        // with ffmpeg present this is a real mp3 on disk, converted as it lands;
        // without it we ask for aac first, which the engine already decodes.
        let want_mp3 = ffmpeg().is_some();
        let mut dl = ytdlp();
        if want_mp3 {
            dl.args([
                "-x",
                "--audio-format",
                "mp3",
                "--audio-quality",
                "0",
            ]);
        } else {
            dl.args([
                "-f",
                "bestaudio[ext=m4a]/bestaudio[ext=mp4]/bestaudio[ext=webm]/bestaudio",
            ]);
        }
        let out = dl
            .args([
                "-o",
                &format!("{base}.%(ext)s"),
                "--no-playlist",
                "--no-warnings",
                url,
            ])
            .output()
            .map_err(|e| format!("spawn download: {e}"))?;
        if !out.status.success() {
            let err = String::from_utf8_lossy(&out.stderr).to_string();
            let msg = err
                .lines()
                .filter(|l| l.contains("ERROR") || l.contains("error"))
                .last()
                .or_else(|| err.lines().last())
                .unwrap_or("?")
                .to_string();
            return Err(format!("download failed: {msg}"));
        }
        produced = staged_file(&base, &stem);
    }

    let mut produced =
        produced.ok_or_else(|| "download produced no playable file".to_string())?;

    // never hand a row to the library that the engine cannot open: a silent
    // "won't play" entry is worse than an honest error in the add sheet.
    if crate::library::open_decoder(&produced.to_string_lossy()).is_none() {
        if ffmpeg().is_some() {
            let mp3 = PathBuf::from(format!("{base}.mp3"));
            let src = produced.to_string_lossy().to_string();
            let dst = mp3.to_string_lossy().to_string();
            run_ffmpeg(&[
                "-y",
                "-i",
                &src,
                "-vn",
                "-codec:a",
                "libmp3lame",
                "-q:a",
                "4",
                &dst,
            ])?;
            let _ = std::fs::remove_file(&produced);
            produced = mp3;
        } else {
            let _ = std::fs::remove_file(&produced);
            return Err(
                "that source only came in a format this player cannot decode - rebuild bin/ffmpeg.exe to convert it"
                    .into(),
            );
        }
    }
    let path = produced.to_string_lossy().replace('\\', "/");
    let cover_bytes = cover_for_video(&vid, &thumb);
    if !cover_bytes.is_empty() {
        let _ = tag_file(&produced, &title, &artist, &cover_bytes);
    }
    let cover_dir = COVERS_DIR;
    let _ = std::fs::create_dir_all(cover_dir);
    let cover_name = format!("{cover_dir}/yt_{vid}.jpg");
    if !cover_bytes.is_empty() {
        let _ = std::fs::write(&cover_name, &cover_bytes);
    }
    let cover_url = if std::path::Path::new(&cover_name).is_file() {
        format!("file:///{cover_name}")
    } else {
        String::new()
    };

    Ok(Ingested {
        title,
        artist,
        album,
        duration_ms: dur_ms,
        path,
        cover_url,
        vid: vid.to_string(),
    })
}

/// Lyrics travel with the song.
///
/// A freshly downloaded row used to be lyric-less until the vibe page asked
/// for it, and if lrclib was cold at that exact moment the miss was cached for
/// a week. Now the lookup happens once, right after the file lands: the answer
/// is written both into the shared lyrics cache and as the song's own `.lrc`
/// beside the audio (which `Library::lyrics_for` reads before anything else and
/// which survives a wiped cache). It runs off-thread by design - the add queue
/// must never wait on a network round trip, and a late write still lands
/// before the song is first played.
fn warm_lyrics(title: String, artist: String, album: String, duration_ms: u32, path: String) {
    if title.trim().is_empty() || path.trim().is_empty() {
        return;
    }
    let _ = std::thread::Builder::new()
        .name("lyr-warm".into())
        .spawn(move || {
            let audio = std::path::Path::new(&path);
            if !audio.is_file() {
                return;
            }
            let lrc = audio.with_extension("lrc");
            // a lyric file that came with the download (or one we already
            // wrote) wins: never overwrite what the file itself carries
            if lrc.is_file() {
                return;
            }
            let Some((ly, sy)) = crate::catalog::fetch_lrclib(&title, &artist, &album, duration_ms)
            else {
                return;
            };
            if ly.trim().is_empty() {
                return;
            }
            let dir = concat!(env!("AETHER_ROOT"), "/cache/lyrics");
            let _ = std::fs::create_dir_all(dir);
            let key = crate::state::song_key(&title, &artist);
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);
            let _ = std::fs::write(
                format!("{dir}/{key}.json"),
                serde_json::json!({ "lyrics": ly, "synced": sy, "t": now }).to_string(),
            );
            let _ = std::fs::write(&lrc, &ly);
            eprintln!(
                "[lyrics] {} - {}: {} lines (synced={sy})",
                artist,
                title,
                ly.lines().count()
            );
        });
}

/// A soundcloud track that cannot be downloaded (its licensed catalogue is
/// DRM protected, and yt-dlp refuses it outright) is usually the same
/// recording on youtube. Ask soundcloud what the track is, ask youtube for
/// it, and hand back the first match - the row still lands, from the twin.
fn soundcloud_twin(url: &str) -> Option<(String, String)> {
    let body = ureq::get(&format!(
        "https://soundcloud.com/oembed?format=json&url={url}"
    ))
    .timeout(Duration::from_secs(10))
    .set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AetherMix/0.5")
    .call()
    .ok()?
    .into_string()
    .ok()?;
    let v: serde_json::Value = serde_json::from_str(&body).ok()?;
    let title = v.get("title").and_then(|x| x.as_str()).unwrap_or("").trim();
    let author = v
        .get("author_name")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .trim();
    if title.is_empty() {
        return None;
    }
    let q = format!("{author} {title}").trim().to_string();
    let found = search_source_json(&q, "youtube", 3);
    let v: serde_json::Value = serde_json::from_str(&found).ok()?;
    let first = v.get("results")?.as_array()?.first()?.clone();
    let u = first.get("url").and_then(|x| x.as_str())?.to_string();
    let t = first
        .get("title")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    if u.is_empty() {
        return None;
    }
    Some((u, t))
}

fn add_url_inner(
    lib: &std::sync::Arc<Mutex<Library>>,
    app: &std::sync::Arc<Mutex<crate::state::AppState>>,
    url: &str,
) -> Result<(usize, String), String> {
    let got = match ingest_url(url) {
        Ok(g) => g,
        Err(e) => {
            if url.contains("soundcloud.com") {
                match soundcloud_twin(url) {
                    Some((twin, shown)) => {
                        eprintln!("[add] soundcloud refused ({e}) - taking the youtube twin: {shown}");
                        add_state(|s| s.current_title = shown);
                        ingest_url(&twin)?
                    }
                    None => return Err(e),
                }
            } else {
                return Err(e);
            }
        }
    };
    let source_label = if url.contains("soundcloud.com") { "soundcloud" } else { "youtube" };
    let id = {
        let mut l = lib.lock().unwrap();
        let id = l.add_track(&got.title, &got.artist, &got.album, got.duration_ms, &got.path, "", &url, &got.cover_url);
        l.save_playlist();
        id
    };
    {
        let mut a = app.lock().unwrap();
        a.status = format!("added \"{}\" from {source_label}", got.title);
        a.library_version = lib.lock().unwrap().version;
    }
    // the row is in the library; the lyrics follow in the background so the
    // song is never played into an empty lyric column
    warm_lyrics(
        got.title.clone(),
        got.artist.clone(),
        got.album.clone(),
        got.duration_ms,
        got.path.clone(),
    );
    Ok((id, got.title))
}

fn download_audio(video_id: &str, out_path: &str) -> Result<(), String> {
    let url = format!("https://www.youtube.com/watch?v={video_id}");
    let out = ytdlp()
        .args([
            "-f",
            "bestaudio[ext=m4a]/bestaudio[ext=opus]/bestaudio",
            "-o",
            out_path,
            "--no-playlist",
            "--no-warnings",
            &url,
        ])
        .output()
        .map_err(|e| format!("spawn yt-dlp: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "download failed: {}",
            String::from_utf8_lossy(&out.stderr).lines().last().unwrap_or("?").to_string()
        ));
    }
    Ok(())
}

fn oembed_cover_uri(track_uri: &str) -> String {
    if track_uri.is_empty() {
        return String::new();
    }
    let url = format!(
        "https://open.spotify.com/oembed?url={}",
        track_uri.replace(':', "%3A")
    );
    let body = match ureq::get(&url)
        .timeout(Duration::from_secs(10))
        .set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AetherMix/0.5")
        .call()
    {
        Ok(r) => r.into_string().unwrap_or_default(),
        Err(_) => return String::new(),
    };
    serde_json::from_str::<serde_json::Value>(&body)
        .ok()
        .and_then(|v| {
            v.get("thumbnail_url")
                .and_then(|x| x.as_str())
                .map(|x| x.to_string())
        })
        .unwrap_or_default()
}

fn fetch_cover(url: &str) -> Vec<u8> {
    if url.len() < 8 {
        return Vec::new();
    }
    match ureq::get(url)
        .timeout(Duration::from_secs(12))
        .set("Accept", "image/jpeg,image/png,image/webp,image/avif;q=0.9,*/*;q=0.5")
        .set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AetherMix/0.5")
        .call()
    {
        Ok(r) => {
            // binary-safe read: into_string mangles non-UTF8 image bytes
            let mut buf = Vec::new();
            use std::io::Read;
            let _ = r.into_reader().read_to_end(&mut buf);
            // a throttled or redirecting host answers with html; that is not art.
            // webp/avif is transcoded here, so every caller only ever sees jpeg.
            crate::library::renderable_image(buf).unwrap_or_default()
        }
        Err(e) => {
            eprintln!("[ytcvt] cover fetch failed ({url}): {e}");
            Vec::new()
        }
    }
}

fn push_unique(out: &mut Vec<String>, u: String) {
    let u = u.trim().to_string();
    if u.len() > 8 && !out.iter().any(|x| *x == u) {
        out.push(u);
    }
}

// YouTube answers best-quality art as jpg, but lyric/auto-generated uploads
// only have the `vi_webp` twin, and maxresdefault is a grey placeholder for
// videos without an HD frame. Try the jpeg twin, the real max-res frame and
// then the two always-present sizes until one is actual artwork.
fn cover_for_video(vid: &str, thumb: &str) -> Vec<u8> {
    let mut urls: Vec<String> = Vec::new();
    if thumb.contains("/vi_webp/") {
        push_unique(
            &mut urls,
            thumb.replace("/vi_webp/", "/vi/").replace(".webp", ".jpg"),
        );
    }
    push_unique(&mut urls, thumb.to_string());
    if !vid.is_empty() {
        push_unique(&mut urls, format!("https://i.ytimg.com/vi/{vid}/maxresdefault.jpg"));
        push_unique(&mut urls, format!("https://i.ytimg.com/vi/{vid}/hqdefault.jpg"));
        push_unique(&mut urls, format!("https://i.ytimg.com/vi/{vid}/mqdefault.jpg"));
    }
    for u in urls {
        let body = fetch_cover(&u);
        // the "no image" placeholder is a ~1KB 120x90 frame: not a cover
        if body.len() > 2000 {
            return body;
        }
    }
    Vec::new()
}

// Rows added before the cover pass (or whose thumbnail host answered webp) sit
// in the list with no face. This walks the bare playlist rows once in the
// background, matches each to its YouTube video and writes real art beside the
// audio, then embeds it so the library keeps the same cover after a rescan.
// Only rows that are already downloaded are touched: streaming rows get their
// art from the catalog sync.
pub fn repair_covers(
    lib: std::sync::Arc<Mutex<Library>>,
    app: std::sync::Arc<Mutex<crate::state::AppState>>,
) {
    std::thread::Builder::new()
        .name("cover-repair".into())
        .spawn(move || {
            // let the shell and the first library paint finish first
            std::thread::sleep(Duration::from_secs(5));
            // local files that were ripped without art sit bare forever:
            // they are searched too, not just playlist rows with a link.
            let work: Vec<(String, String, u32, String, String)> = {
                let l = lib.lock().unwrap();
                l.tracks
                    .iter()
                    .filter(|t| {
                        (t.origin == "playlist" || t.origin == "local")
                            && !t.path.is_empty()
                            && t.cover_file.is_empty()
                    })
                    // a handful per boot: a slow extractor must not own the
                    // whole session, and each launch heals a few more
                    .take(12)
                    .map(|t| {
                        (
                            t.title.clone(),
                            t.artist.clone(),
                            t.duration_ms,
                            t.path.clone(),
                            t.uri.clone(),
                        )
                    })
                    .collect()
            };
            if work.is_empty() {
                return;
            }
            eprintln!("[ytcvt] cover repair: {} bare rows", work.len());
            for (title, artist, dur_ms, path, uri) in work {
                // a youtube-sourced row already knows its video: no search
                // needed. a bare row is matched by title + artist.
                let (vid, thumb) = if let Some(id) = video_id(&uri) {
                    (id.clone(), format!("https://i.ytimg.com/vi/{id}/hqdefault.jpg"))
                } else if uri.is_empty() || uri.starts_with("http") {
                    // "Unknown Artist" is noise to the search engine
                    let q = if artist.eq_ignore_ascii_case("unknown artist") {
                        title.clone()
                    } else {
                        format!("{title} {artist}")
                    };
                    let cands = match search(&q) {
                        Ok(c) => c,
                        Err(_) => continue,
                    };
                    let Some(best) = pick(cands, &title, &artist, dur_ms) else {
                        continue;
                    };
                    (best.id, best.thumb)
                } else {
                    // spotify rows have their own backfill (oEmbed)
                    continue;
                };
                let cover = cover_for_video(&vid, &thumb);
                if cover.len() < 2000 {
                    continue;
                }
                let cover_dir = COVERS_DIR.to_string();
                let _ = std::fs::create_dir_all(&cover_dir);
                let file = format!("{cover_dir}/yt_{vid}.jpg");
                if std::fs::write(&file, &cover).is_err() {
                    continue;
                }
                // the scanner keys cached art by the audio path: writing that
                // name means the face is still there after a restart even if
                // the mp3 itself refuses the new tag.
                let key = crate::library::cover_key_for_path(&path);
                let keyed = format!("{cover_dir}/{key}.jpg");
                let _ = std::fs::write(&keyed, &cover);
                let url = format!("file:///{file}");
                tag_file(&PathBuf::from(&path), &title, &artist, &cover);
                let version = {
                    let mut l = lib.lock().unwrap();
                    if let Some(t) = l
                        .tracks
                        .iter_mut()
                        .find(|t| t.title == title && t.artist == artist && t.path == path)
                    {
                        t.cover_file = url;
                    }
                    l.version += 1;
                    l.save_playlist();
                    l.version
                };
                app.lock().unwrap().library_version = version;
                eprintln!("[ytcvt] cover repair: {title} <- {vid}");
                // direct-link rows cost no search; title matches do. leave the
                // network a breath so a repair never starves playback.
                std::thread::sleep(Duration::from_millis(if uri.is_empty() { 900 } else { 250 }));
            }
        })
        .expect("spawn cover-repair");
}

pub fn backfill_covers(lib: std::sync::Arc<Mutex<Library>>) {
    std::thread::Builder::new()
        .name("ytcvt-covers".into())
        .spawn(move || {
            let work: Vec<(String, String, String, String)> = {
                let l = lib.lock().unwrap();
                l.tracks
                    .iter()
                    .filter(|t| t.origin == "playlist" && !t.path.is_empty() && !t.uri.is_empty())
                    .map(|t| {
                        (
                            t.path.clone(),
                            t.title.clone(),
                            t.artist.clone(),
                            t.uri.clone(),
                        )
                    })
                    .collect()
            };
            eprintln!("[ytcvt] backfill worklist: {} candidates", work.len());
            let mut done = 0;
            for (path, title, artist, track_uri) in work {

                let Ok(data) = std::fs::read(&path) else { continue };
                if data.windows(4).any(|w| w == b"covr") {
                    continue; // already has art
                }
                let cover_url = oembed_cover_uri(&track_uri);
                if cover_url.is_empty() {
                    continue;
                }
                let cover = fetch_cover(&cover_url);
                if cover.len() < 100 {
                    continue;
                }
                tag_file(&PathBuf::from(&path), &title, &artist, &cover);
                done += 1;
                std::thread::sleep(Duration::from_millis(150));
            }
            eprintln!("[ytcvt] cover backfill: {done} files got embedded art");
        })
        .expect("spawn backfill");
}

pub fn convert_one(lib: std::sync::Arc<Mutex<Library>>, id: usize) {
    std::thread::Builder::new()
        .name("ytcvt-one".into())
        .spawn(move || {
            let info = {
                let l = lib.lock().unwrap();
                let Some(t) = l.tracks.get(id) else { return };
                (
                    t.id,
                    t.title.clone(),
                    t.artist.clone(),
                    t.duration_ms,
                    t.cover_file.clone(),
                )
            };
            let (id, title, artist, dur_ms, cover_url) = info;
            let stem = safe_name(&format!("{artist} - {title}"));
            let target = format!("{}/{stem}.m4a", out_dir());
            if !std::path::Path::new(&target).exists() {
                let cands = match search(&format!("{title} {artist}")) {
                    Ok(c) => c,
                    Err(_) => return,
                };
                if let Some(best) = pick(cands, &title, &artist, dur_ms) {
                    let tmp = format!("{}/.tmp_{id}.%(ext)s", out_dir());
                    if download_audio(&best.id, &tmp).is_ok() {
                        if let Some(produced) = std::fs::read_dir(out_dir()).ok().and_then(|rd| {
                            rd.filter_map(|e| e.ok()).find(|e| {
                                e.file_name().to_string_lossy().to_string().starts_with(&format!(".tmp_{id}."))
                            }).map(|e| e.path())
                        }) {
                            let final_path = produced.with_file_name(format!("{stem}{}", produced.extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default()));
                            let _ = std::fs::rename(&produced, &final_path);
                            let cover = fetch_cover(&cover_url);
                            tag_file(&final_path, &title, &artist, &cover);
                        }
                    }
                }
            }
            eprintln!("[ytcvt] single-track conversion finished (check folder): {title}");
        })
        .expect("spawn one-shot converter");
}

pub fn start_convert(lib: std::sync::Arc<Mutex<Library>>, app: std::sync::Arc<Mutex<crate::state::AppState>>) {
    {
        let mut g = STATUS.lock().unwrap();
        if let Some(st) = g.as_ref() {
            if st.running {
                return;
            }
        }
        let total = {
            let l = lib.lock().unwrap();
            l.tracks
                .iter()
                .filter(|t| t.origin == "playlist" && t.path.is_empty() && !t.uri.is_empty())
                .count()
        };
        *g = Some(ConvertStatus {
            running: true,
            total,
            ..Default::default()
        });
    }
    std::thread::Builder::new()
        .name("ytcvt".into())
        .spawn(move || {
            // snapshot the worklist (id, title, artist, duration, cover)
            let mut work: Vec<(usize, String, String, u32, String)> = Vec::new();
            {
                let l = lib.lock().unwrap();
                for t in l.tracks.iter() {
                    if t.origin == "playlist" && !t.uri.is_empty() && t.path.is_empty() {
                        work.push((
                            t.id,
                            t.title.clone(),
                            t.artist.clone(),
                            t.duration_ms,
                            t.cover_file.clone(),
                        ));
                    }
                }
            }
            let _ = app;
            for (id, title, artist, dur_ms, cover_url) in work {
                let stem = safe_name(&format!("{artist} - {title}"));
                set_current(&format!("{artist} - {title}"));
                let target = format!("{}/{stem}.m4a", out_dir());
                let target_p = PathBuf::from(&target);
                if target_p.exists() {
                    bump(|s| s.skipped += 1);
                    continue;
                }
                // search + score
                let query = format!("{title} {artist}");
                let cands = match search(&query) {
                    Ok(c) => c,
                    Err(e) => {
                        err(&format!("{title}: {e}"));
                        bump(|s| s.failed += 1);
                        continue;
                    }
                };
                let Some(best) = pick(cands, &title, &artist, dur_ms) else {
                    err(&format!("{title}: no confident YouTube match"));
                    bump(|s| s.failed += 1);
                    continue;
                };
                // download to a tmp name then promote
                let tmp = format!("{}/.tmp_{id}.%(ext)s", out_dir());
                if let Err(e) = download_audio(&best.id, &tmp) {
                    err(&format!("{title}: {e}"));
                    bump(|s| s.failed += 1);
                    continue;
                }
                // find what yt-dlp actually produced
                let produced = std::fs::read_dir(out_dir())
                    .ok()
                    .and_then(|rd| {
                        rd.filter_map(|e| e.ok())
                            .find(|e| {
                                let n = e.file_name().to_string_lossy().to_string();
                                n.starts_with(&format!(".tmp_{id}."))
                            })
                            .map(|e| e.path())
                    });
                let Some(produced) = produced else {
                    err(&format!("{title}: download produced no file"));
                    bump(|s| s.failed += 1);
                    continue;
                };
                let final_path = produced.with_file_name(format!("{stem}{}", produced.extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default()));
                if std::fs::rename(&produced, &final_path).is_err() {
                    let _ = std::fs::copy(&produced, &final_path);
                    let _ = std::fs::remove_file(&produced);
                }
                // tag it with the REAL metadata + cover
                let cover = fetch_cover(&cover_url);
                tag_file(&final_path, &title, &artist, &cover);
                bump(|s| s.done += 1);
                // pacing: be a polite client
                std::thread::sleep(Duration::from_secs(3));
            }
            let mut g = STATUS.lock().unwrap();
            if let Some(st) = g.as_mut() {
                st.running = false;
                st.current = String::new();
            }
            eprintln!("[ytcvt] conversion pass complete");
        })
        .expect("spawn converter");
}

// ---------------- moving backdrops ----------------
// A youtube link as the room's wallpaper. Qt cannot play a googlevideo url
// (it needs a session and expiring headers), so the clip is fetched once at a
// small size, kept in the cache, and looped from disk like any other film.

#[derive(Default, Clone)]
struct BgJob {
    running: bool,
    url: String,
    path: String,
    error: String,
    // 0..100 while yt-dlp is reporting progress; 100 once the film is on disk
    pct: u32,
    note: String,
}

static BG: Mutex<Option<BgJob>> = Mutex::new(None);

fn bg_dir() -> String {
    concat!(env!("AETHER_ROOT"), "/cache/backdrops").to_string()
}

fn bg_stem(key: &str) -> String {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut h = DefaultHasher::new();
    key.hash(&mut h);
    format!("bg_{:016x}", h.finish())
}

// A video has one identity even though it has many links: youtu.be, watch?v=,
// shorts, an embed. Hashing the raw url made each spelling a fresh 30MB
// download, so key the cache on the id instead.
fn video_key(url: &str) -> String {
    if let Some(id) = video_id(url) {
        return format!("yt-{id}");
    }
    url.trim().to_string()
}

fn video_id(url: &str) -> Option<String> {
    let u = url.trim();
    let mut rest = "";
    if let Some(p) = u.find("youtu.be/") {
        rest = &u[p + 9..];
    } else if let Some(p) = u.find("/shorts/") {
        rest = &u[p + 8..];
    } else if let Some(p) = u.find("/embed/") {
        rest = &u[p + 7..];
    } else if let Some(p) = u.find("/live/") {
        rest = &u[p + 6..];
    } else if let Some(p) = u.find("v=") {
        rest = &u[p + 2..];
    }
    if rest.is_empty() {
        return None;
    }
    let id: String = rest
        .chars()
        .take_while(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .collect();
    if id.len() >= 6 {
        Some(id)
    } else {
        None
    }
}

fn bg_json(j: &BgJob) -> String {
    serde_json::json!({
        "running": j.running,
        "url": j.url,
        "path": j.path,
        "error": j.error,
        "pct": j.pct,
        "note": j.note,
    })
    .to_string()
}

pub fn backdrop_status() -> String {
    let g = BG.lock().unwrap();
    match g.as_ref() {
        Some(j) => bg_json(j),
        None => serde_json::json!({"running": false, "path": "", "error": ""}).to_string(),
    }
}

fn bg_note(note: &str, pct: u32) {
    let mut g = BG.lock().unwrap();
    if let Some(j) = g.as_mut() {
        if j.running {
            j.note = note.to_string();
            j.pct = pct.min(99);
        }
    }
}

// raw yt-dlp stderr is a wall of python tracebacks; say what actually went
// wrong and what the person can do about it
fn friendly_video_error(raw: &str) -> String {
    let l = raw.to_lowercase();
    if l.contains("sign in to confirm") || l.contains("not a bot") || l.contains("cookies") {
        return "youtube wants a signed-in session for this video - link a browser in Studio > Accounts, then try again".into();
    }
    if l.contains("requested format is not available") {
        return "this video has no 720p stream the player can decode".into();
    }
    if l.contains("video unavailable") || l.contains("private video") {
        return "that video is private, region-locked or was removed".into();
    }
    let line = raw
        .lines()
        .filter(|x| !x.trim().is_empty())
        .last()
        .unwrap_or("video fetch failed");
    line.trim().chars().take(240).collect()
}

fn download_video(url: &str, target: &str, fmt: &str) -> Result<(), String> {
    use std::io::{BufRead, BufReader};
    use std::process::Stdio;
    let mut c = ytdlp();
    c.args([
        "-f",
        fmt,
        "--merge-output-format",
        "mp4",
        "--newline",
        "--no-playlist",
        "--no-warnings",
        "-o",
        target,
        url,
    ])
    .stdout(Stdio::piped())
    .stderr(Stdio::piped());
    let mut child = c.spawn().map_err(|e| format!("yt-dlp could not start: {e}"))?;
    let stderr = child.stderr.take();
    let tail_thread = std::thread::spawn(move || {
        let mut tail: Vec<String> = Vec::new();
        if let Some(se) = stderr {
            for line in BufReader::new(se).lines().flatten() {
                if line.trim().is_empty() {
                    continue;
                }
                tail.push(line);
                if tail.len() > 40 {
                    tail.remove(0);
                }
            }
        }
        tail.join("\n")
    });
    if let Some(out) = child.stdout.take() {
        for line in BufReader::new(out).lines().flatten() {
            if !line.contains("[download]") || !line.contains('%') {
                continue;
            }
            if let Some(p) = line.find('%') {
                let num: String = line[..p]
                    .chars()
                    .rev()
                    .take_while(|ch| ch.is_ascii_digit() || *ch == '.')
                    .collect::<String>()
                    .chars()
                    .rev()
                    .collect();
                if let Ok(v) = num.parse::<f32>() {
                    bg_note("pulling the film", v.clamp(0.0, 99.0) as u32);
                }
            }
        }
    }
    let status = child.wait().map_err(|e| format!("yt-dlp wait: {e}"))?;
    let err = tail_thread.join().unwrap_or_default();
    if status.success() {
        Ok(())
    } else {
        Err(friendly_video_error(&err))
    }
}

// h264+aac so the Qt ffmpeg backend can paint it without a codec pack
fn transcode_video(src: &str, dst: &str) -> Result<(), String> {
    if ffmpeg().is_none() {
        return Err("this video needs converting, but bin/ffmpeg.exe is missing".into());
    }
    run_ffmpeg(&[
        "-y",
        "-i",
        src,
        "-c:v",
        "libx264",
        "-preset",
        "veryfast",
        "-crf",
        "23",
        "-pix_fmt",
        "yuv420p",
        "-c:a",
        "aac",
        "-b:a",
        "160k",
        "-movflags",
        "+faststart",
        dst,
    ])
}

/// Fetch a video once and answer with its local path. Direct media urls are
/// passed straight through: they are already playable.
pub fn prepare_backdrop(url: &str) -> String {
    let url = url.trim();
    if url.is_empty() {
        return serde_json::json!({"running": false, "path": "", "error": "no link"}).to_string();
    }
    let lower = url.to_lowercase();
    if lower.ends_with(".mp4") && (lower.starts_with("http") || lower.starts_with("file:")) {
        return serde_json::json!({"running": false, "path": url, "error": ""}).to_string();
    }
    let dir = bg_dir();
    let _ = std::fs::create_dir_all(&dir);
    let key = video_key(url);
    let stem = bg_stem(&key);
    let target = format!("{dir}/{stem}.mp4");
    let meta = format!("{dir}/{stem}.json");
    if std::path::Path::new(&target).is_file() {
        let j = BgJob {
            running: false,
            url: url.into(),
            path: target,
            error: String::new(),
            pct: 100,
            note: String::new(),
        };
        *BG.lock().unwrap() = Some(j.clone());
        return bg_json(&j);
    }
    {
        let mut g = BG.lock().unwrap();
        *g = Some(BgJob {
            running: true,
            url: url.into(),
            path: String::new(),
            error: String::new(),
            pct: 0,
            note: "reading the link".into(),
        });
    }
    let u = url.to_string();
    let t = target.clone();
    let m = meta.clone();
    std::thread::Builder::new()
        .name("bg-fetch".into())
        .spawn(move || {
            let mut j = BgJob {
                running: false,
                url: u.clone(),
                path: String::new(),
                error: String::new(),
                pct: 0,
                note: String::new(),
            };
            // h.264 first: this Qt's ffmpeg backend has no AV1 decoder, and an
            // ad-free film with a black screen is not a film.
            let avc = "bv*[height<=720][vcodec^=avc1]+ba[ext=m4a]/b[height<=720][vcodec^=avc1]/bv*[height<=720][ext=mp4]+ba[ext=m4a]";
            bg_note("pulling 720p h.264", 0);
            let first = download_video(&u, &t, avc);
            match first {
                Ok(()) if std::path::Path::new(&t).is_file() => {
                    j.path = t.clone();
                    j.pct = 100;
                }
                Ok(()) => j.error = "the download finished without a video file".into(),
                Err(e) => {
                    // second chance: any codec up to 720p, then one local
                    // transcode so the film is still h264/aac on disk
                    let recoverable = !e.contains("signed-in") && !e.contains("private");
                    if !recoverable {
                        j.error = e;
                    } else {
                        let tmp = format!("{}/{}.src.mp4", bg_dir(), stem);
                        let _ = std::fs::remove_file(&t);
                        bg_note("second source", 0);
                        match download_video(&u, &tmp, "bv*[height<=720]+ba/b[height<=720]/b") {
                            Ok(()) => {
                                bg_note("converting for playback", 0);
                                let r = transcode_video(&tmp, &t);
                                let _ = std::fs::remove_file(&tmp);
                                match r {
                                    Ok(()) => {
                                        j.path = t.clone();
                                        j.pct = 100;
                                    }
                                    Err(x) => j.error = x,
                                }
                            }
                            Err(x) => j.error = if x.len() > 4 { x } else { e },
                        }
                    }
                }
            }
            if !j.path.is_empty() {
                let meta = serde_json::json!({ "url": u, "key": j.path, "path": j.path, "at": chrono_like_now() });
                let _ = std::fs::write(&m, meta.to_string());
            }
            eprintln!("[backdrop] {} -> {:?}", j.error, j.path);
            // a second video may have been asked for while this one was
            // downloading: never overwrite the newer request's live state
            let mut g = BG.lock().unwrap();
            let current = g.as_ref().map(|x| x.url == j.url).unwrap_or(true);
            if current {
                *g = Some(j);
            }
        })
        .expect("spawn bg-fetch");
    bg_status_now()
}

fn bg_status_now() -> String {
    backdrop_status()
}

fn chrono_like_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Cached clips that can be offered as recent backdrops.
pub fn backdrop_library() -> String {
    let dir = bg_dir();
    let mut rows: Vec<serde_json::Value> = Vec::new();
    if let Ok(rd) = std::fs::read_dir(&dir) {
        for e in rd.flatten() {
            let p = e.path();
            if p.extension().and_then(|x| x.to_str()) != Some("json") {
                continue;
            }
            let Ok(body) = std::fs::read_to_string(&p) else { continue };
            let Ok(v) = serde_json::from_str::<serde_json::Value>(&body) else { continue };
            let path = v.get("path").and_then(|x| x.as_str()).unwrap_or("");
            if path.is_empty() || !std::path::Path::new(path).is_file() {
                continue;
            }
            rows.push(serde_json::json!({
                "url": v.get("url").and_then(|x| x.as_str()).unwrap_or(""),
                "path": path,
                "at": v.get("at").and_then(|x| x.as_u64()).unwrap_or(0),
            }));
        }
    }
    rows.sort_by(|a, b| {
        b.get("at").and_then(|x| x.as_u64()).unwrap_or(0)
            .cmp(&a.get("at").and_then(|x| x.as_u64()).unwrap_or(0))
    });
    serde_json::json!({ "clips": rows }).to_string()
}

/// One link, described for the browser: what kind of page it is, what it is
/// called, and - for a playlist or a channel - how many songs are behind it.
/// Uses a flat playlist probe so a 500-song set answers in one request
/// instead of resolving every entry.
pub fn resolve_page_json(url: &str) -> String {
    let u = url.trim();
    if !u.starts_with("http") {
        return serde_json::json!({ "ok": false, "error": "not a link" }).to_string();
    }
    if u.contains("spotify.com") || u.starts_with("spotify:") {
        return serde_json::json!({
            "ok": true,
            "kind": "spotify",
            "url": u,
            "title": "Spotify link",
            "artist": "spotify",
            "duration_ms": 0,
            "thumb": "",
            "count": 0
        })
        .to_string();
    }
    let mut cmd = ytdlp();
    cmd.args([
        "--dump-single-json",
        "--flat-playlist",
        "--no-warnings",
        "--no-progress",
        u,
    ]);
    let out = match run_capped(&mut cmd, 35) {
        Some(o) => o,
        None => {
            return serde_json::json!({ "ok": false, "error": "that page did not answer in time" })
                .to_string()
        }
    };
    if !out.status.success() {
        let msg = String::from_utf8_lossy(&out.stderr)
            .lines()
            .filter(|l| !l.trim().is_empty())
            .last()
            .unwrap_or("could not read that page")
            .to_string();
        return serde_json::json!({ "ok": false, "error": msg }).to_string();
    }
    let v: serde_json::Value = match ytdlp_json(&out.stdout) {
        Some(v) => v,
        None => {
            return serde_json::json!({ "ok": false, "error": "bad page data" }).to_string()
        }
    };
    let entries = v.get("entries").and_then(|e| e.as_array()).cloned().unwrap_or_default();
    let is_playlist = v.get("_type").and_then(|t| t.as_str()) == Some("playlist")
        || entries.len() > 1;
    let title = v
        .get("title")
        .and_then(|x| x.as_str())
        .unwrap_or("untitled page")
        .to_string();
    let artist = v
        .get("uploader")
        .or_else(|| v.get("channel"))
        .or_else(|| v.get("creator"))
        .and_then(|x| x.as_str())
        .unwrap_or(if u.contains("soundcloud.com") { "soundcloud" } else { "youtube" })
        .to_string();
    let thumb = v
        .get("thumbnail")
        .and_then(|x| x.as_str())
        .map(|x| x.to_string())
        .or_else(|| {
            v.get("thumbnails")
                .and_then(|t| t.as_array())
                .and_then(|a| a.last())
                .and_then(|t| t.get("url"))
                .and_then(|x| x.as_str())
                .map(|x| x.to_string())
        })
        .unwrap_or_default();
    let duration = v.get("duration").and_then(|x| x.as_f64()).unwrap_or(0.0);
    let preview: Vec<serde_json::Value> = entries
        .iter()
        .take(14)
        .map(|e| {
            serde_json::json!({
                "title": e.get("title").and_then(|x| x.as_str()).unwrap_or("?"),
                "url": e.get("url").and_then(|x| x.as_str()).unwrap_or(""),
                "duration_ms": (e.get("duration").and_then(|x| x.as_f64()).unwrap_or(0.0) * 1000.0) as u32,
            })
        })
        .collect();
    serde_json::json!({
        "ok": true,
        "kind": if is_playlist { "playlist" } else { "video" },
        "url": u,
        "title": title,
        "artist": artist,
        "duration_ms": (duration * 1000.0) as u32,
        "thumb": thumb,
        "count": entries.len(),
        "entries": preview,
        "source": if u.contains("soundcloud.com") { "soundcloud" } else { "youtube" }
    })
    .to_string()
}
