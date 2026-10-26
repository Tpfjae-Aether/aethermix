// lang: Rust, file: server.rs
// localhost bridge: QML polls state/library, commands flow back via GET routes
use crate::audio::Core;
use crate::library::Library;
use crate::player::{PlayerCmd, PlayerState};
use crate::state::{self, AppState};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

const PORT: u16 = 3690;

// A phone opens several sockets at once for artwork and at most a handful for
// audio. This ceiling stops a stuck or hostile LAN peer from holding hundreds
// of handler threads (and their stacks) open.
static LIVE_CONNS: AtomicUsize = AtomicUsize::new(0);
const MAX_CONNS: usize = 96;

// The phone is a second window: it reads the shelf, streams a file and edits
// rooms. This used to be an allow-list of what the LAN *could* reach, and the
// list kept falling behind the app: the home-screen icon, the web-app manifest
// and the room-add routes were all written after it and were answered with
// "that route is local only". It is now the other way round - everything is
// reachable unless it is named here - because the safe default for a read or a
// room edit is yes, while the routes below are the ones a shared Wi-Fi must
// never reach: they spawn an extractor, take a filesystem path from the caller,
// import an arbitrary file, swap a signed-in account, open a window on the PC,
// or rewrite the desktop's own look.
const LOCAL_ONLY: &[&str] = &[
    // the gateway switch, the diag channel, and the Windows shell harness
    "/phone",
    "/frame",
    "/page",
    "/shell/on",
    "/shell/off",
    "/shell/state",
    "/shell/devices",
    // credentials: a stranger on the Wi-Fi must never see or change an account
    "/oauth/grant",
    "/oauth/start",
    "/accounts",
    "/accounts/save",
    "/accounts/signin",
    "/accounts/test",
    "/spotify/library",
    "/spotify/search",
    "/spotify/add",
    "/spotify/suggest",
    "/extensions",
    "/engine",
    // the desktop's own look and feel
    "/appearance",
    "/appearance/set",
    "/lyricstyle",
    "/lyricstyle/set",
    "/eq",
    "/eq/set",
    "/theme/save",
    "/theme/delete",
    "/config",
    "/backdrop/prepare",
    "/backdrop/status",
    "/backdrop/library",
    // routes that take a path from the caller, or rewrite the library wholesale
    "/playlist/add_local",
    "/playlist/add_spotify",
    "/playlist/rename",
    "/playlist/retire",
    "/playlist/import/preview",
    "/playlist/import/start",
    "/playlist/import/status",
    "/playlist/import/m3u",
    "/playlist/export",
    "/track/info",
    "/track/reveal",
    "/thumb",
    "/live",
    "/youtube/add",
    "/youtube/search",
    "/youtube/status",
    "/sources/search",
    "/web/resolve",
    "/rescan",
    "/catalog/sync",
    "/sleep",
    // queue surgery, which reorders the deck the desktop is playing
    "/queue",
    "/queue/add",
    "/queue/clear",
    "/queue/remove",
    "/queue/playnext",
    "/mode",
    "/shuffle",
    "/repeat",
    "/playlist/set",
    "/stats",
    "/favorite",
    "/favorites",
    "/convert/covers",
    "/convert/one",
];

// The phone page travels inside the binary: nothing to deploy, nothing to
// fetch at runtime, so it renders on a network with no internet at all.
const MOBILE_HTML: &str = include_str!("../web/mobile.html");

// Whether the phone may reach this machine. The desktop's own UI talks to the
// bridge over loopback on the same port, so closing the gateway is a decision
// about remote callers, not about unbinding the socket the app itself uses.
static PHONE_OPEN: AtomicBool = AtomicBool::new(true);
static PHONE_LOADED: AtomicBool = AtomicBool::new(false);

fn phone_open() -> bool {
    // first caller reads the saved choice: opening a launch with the gateway
    // closed must not quietly reopen it
    if !PHONE_LOADED.swap(true, Ordering::Relaxed) {
        let on = crate::state::config_str("phone_site")
            .map(|v| v != "0")
            .unwrap_or(true);
        PHONE_OPEN.store(on, Ordering::Relaxed);
    }
    PHONE_OPEN.load(Ordering::Relaxed)
}

fn lan_enabled() -> bool {
    match std::env::var("AETHER_LAN") {
        Ok(v) => {
            let v = v.trim().to_ascii_lowercase();
            !(v == "0" || v == "off" || v == "false" || v == "no")
        }
        Err(_) => true,
    }
}

// The machine's outbound-facing IPv4, without sending a packet. The phone has
// to type this into Studio, so the desktop prints it at boot too.
pub fn lan_ip() -> Option<String> {
    let s = std::net::UdpSocket::bind("0.0.0.0:0").ok()?;
    s.connect("8.8.8.8:80").ok()?;
    let a = s.local_addr().ok()?;
    Some(a.ip().to_string())
}
const THEMES_DIR: &str = concat!(env!("AETHER_ROOT"), "/themes");

// last frame-pacing report from the shell: [fps, worst frame ms, quality %,
// frames over 20ms, frames over 40ms] over the reporting window
static FRAME_LOCK: Mutex<[f64; 5]> = Mutex::new([60.0, 0.0, 100.0, 0.0, 0.0]);
static FRAME_DIAG: Mutex<String> = Mutex::new(String::new());

// ---- stale-instance eviction (self-healing port bind) ----
fn stale_aethermix_pids(exclude: u32) -> Vec<u32> {
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W, TH32CS_SNAPPROCESS,
    };
    let mut out = Vec::new();
    unsafe {
        let snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snap.is_null() {
            return out;
        }
        let mut entry: PROCESSENTRY32W = std::mem::zeroed();
        entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;
        if Process32FirstW(snap, &mut entry) != 0 {
            loop {
                let name: String = entry
                    .szExeFile
                    .iter()
                    .take_while(|&c| *c != 0)
                    .map(|&c| char::from_u32(c as u32).unwrap_or('?'))
                    .collect::<String>()
                    .to_lowercase();
                if (name.starts_with("aethermix") || name.starts_with("custom_spotify"))
                    && entry.th32ProcessID != exclude
                {
                    out.push(entry.th32ProcessID);
                }
                if Process32NextW(snap, &mut entry) == 0 {
                    break;
                }
            }
        }
        let _ = windows_sys::Win32::Foundation::CloseHandle(snap);
    }
    out
}

fn open_process_for_kill(pid: u32) -> windows_sys::Win32::Foundation::HANDLE {
    use windows_sys::Win32::System::Threading::{OpenProcess, PROCESS_TERMINATE};
    unsafe { OpenProcess(PROCESS_TERMINATE, 0, pid) }
}

pub static PLAYER_TX: OnceLock<Sender<PlayerCmd>> = OnceLock::new();

fn send(cmd: PlayerCmd) -> bool {
    PLAYER_TX
        .get()
        .map(|tx| tx.send(cmd).is_ok())
        .unwrap_or(false)
}

/// Let the downloader start the song the moment it lands. One lazy add should
/// feel like pressing play, not like filing something for later.
pub fn request_play(id: usize) {
    let _ = send(PlayerCmd::PlayId(id));
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' if i + 2 < bytes.len() + 1 && i + 2 <= bytes.len() - 1 => {
                if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                    out.push(v);
                    i += 3;
                } else {
                    out.push(bytes[i]);
                    i += 1;
                }
            }
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn query_param(query: &str, key: &str) -> Option<String> {
    for pair in query.split('&') {
        let mut it = pair.splitn(2, '=');
        if it.next() == Some(key) {
            let v = it.next().unwrap_or("");
            return Some(percent_decode(v));
        }
    }
    None
}

fn respond(stream: &mut TcpStream, body: &str) {
    let resp = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    );
    let _ = stream.write_all(resp.as_bytes());
    let _ = stream.flush();
}

fn respond_bytes(stream: &mut TcpStream, mime: &str, body: &[u8]) {
    // CRLF here, like every other responder: a bare LF header block is legal to
    // be lenient about, but Apple's own fetchers are the ones that download the
    // home-screen icon and the artwork, and there is no reason to hand them a
    // malformed response to argue with.
    let head = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: {mime}\r\nAccess-Control-Allow-Origin: *\r\nCache-Control: max-age=86400\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    let _ = stream.write_all(head.as_bytes());
    let _ = stream.write_all(body);
    let _ = stream.flush();
}

fn respond_html(stream: &mut TcpStream, body: &str) {
    // no-cache on purpose: the page is edited far more often than the binary
    // is rebuilt, and a stale copy on a phone is very hard to spot
    let head = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n",
        body.len()
    );
    let _ = stream.write_all(head.as_bytes());
    let _ = stream.write_all(body.as_bytes());
    let _ = stream.flush();
}

fn image_mime(b: &[u8]) -> &'static str {
    if b.starts_with(&[0x89, b'P', b'N', b'G']) {
        "image/png"
    } else if b.starts_with(b"GIF8") {
        "image/gif"
    } else if b.len() > 12 && &b[0..4] == b"RIFF" && &b[8..12] == b"WEBP" {
        "image/webp"
    } else {
        "image/jpeg"
    }
}

// Remote art is proxied through the engine: Qt's network stack cannot always
// negotiate TLS on a stripped deployment, and every cover would silently fall
// back to a gradient. One disk cache, one fetch, served over loopback.
fn cached_thumb(url: &str) -> Option<Vec<u8>> {
    if !(url.starts_with("http://") || url.starts_with("https://")) {
        return None;
    }
    // youtube serves webp to thumbnail clients that accept it, and this Qt
    // build has no webp decoder. the bare /vi/<id>/hq720.jpg path always
    // answers jpeg, so drop the signing query before fetching.
    let url = if (url.contains("ytimg.com") || url.contains("img.youtube.com"))
        && url.contains('?')
    {
        url.split('?').next().unwrap_or(url).to_string()
    } else {
        url.to_string()
    };
    let url = url.as_str();
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut h = DefaultHasher::new();
    url.hash(&mut h);
    let dir = concat!(env!("AETHER_ROOT"), "/cache/thumbs");
    let _ = std::fs::create_dir_all(dir);
    let path = format!("{dir}/{:016x}.img", h.finish());
    if let Ok(b) = std::fs::read(&path) {
        if crate::library::looks_like_image(&b) {
            return Some(b);
        }
    }
    let body = ureq::get(url)
        .timeout(Duration::from_secs(10))
        .set("Accept", "image/jpeg,image/png,image/gif;q=0.9,*/*;q=0.5")
        .set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AetherMix/0.5")
        .call()
        .ok()
        .and_then(|r| {
            let mut buf = Vec::new();
            use std::io::Read;
            r.into_reader().read_to_end(&mut buf).ok().map(|_| buf)
        })?;
    let body = renderable_image(body)?;
    let _ = std::fs::write(&path, &body);
    Some(body)
}

// a webp/avif (anything this Qt build has no plugin for) is re-encoded once
// through the bundled ffmpeg, then cached as jpeg like every other thumb.
fn renderable_image(body: Vec<u8>) -> Option<Vec<u8>> {
    crate::library::renderable_image(body)
}

fn theme_file(name: &str) -> Option<String> {
    if name.is_empty()
        || !name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
    {
        return None;
    }
    let path = format!("{THEMES_DIR}/{name}.json");
    std::fs::read_to_string(path).ok()
}

// the theme's display name is not the file id: a tab override stores `ink`
// while the json says `"name": "Ink"`. QML needs the id to switch back, so
// every theme answer carries it explicitly.
fn theme_file_named(name: &str) -> Option<String> {
    let body = theme_file(name)?;
    let mut v: serde_json::Value = serde_json::from_str(&body).ok()?;
    if let Some(o) = v.as_object_mut() {
        o.insert("id".into(), serde_json::json!(name));
    }
    Some(v.to_string())
}

fn slugify(name: &str) -> String {
    let mut out = String::new();
    let mut dash = false;
    for c in name.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
            dash = false;
        } else if !dash && !out.is_empty() {
            out.push('-');
            dash = true;
        }
    }
    out.trim_matches('-').to_string()
}

fn theme_names() -> Vec<String> {
    let mut out = Vec::new();
    if let Ok(entries) = std::fs::read_dir(THEMES_DIR) {
        for e in entries.flatten() {
            let p = e.path();
            if p.extension().and_then(|x| x.to_str()) == Some("json") {
                if let Some(stem) = p.file_stem().and_then(|s| s.to_str()) {
                    out.push(stem.to_string());
                }
            }
        }
    }
    out.sort();
    out
}

// One byte-range server for every audio the phone can ask for: a library
// row and a room row differ only in how the path was found.
fn serve_media(out: &mut TcpStream, path: &str, title: &str, range: Option<&str>, head_only: bool) {
            let p = std::path::Path::new(path);
            let Ok(meta) = std::fs::metadata(p) else {
                respond(out, "{\"ok\":false,\"error\":\"this row has no file on disk\"}");
                return;
            };
            let total = meta.len();
            let ext = p.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase();
            let mime = match ext.as_str() {
                "mp3" => "audio/mpeg",
                "flac" => "audio/flac",
                "wav" => "audio/wav",
                "ogg" | "opus" => "audio/ogg",
                "m4a" | "aac" => "audio/mp4",
                _ => "application/octet-stream",
            };
            // bytes=start-end | bytes=start- | bytes=-suffix. A player can ask
            // for several ranges at once; serving the first is legal and keeps
            // the reply a single part.
            let mut start = 0u64;
            let mut end = total.saturating_sub(1);
            let mut partial = false;
            let mut unsatisfiable = false;
            if let Some(h) = range {
                if let Some(spec) = h.strip_prefix("bytes=") {
                    let spec = spec.split(',').next().unwrap_or("").trim();
                    let (a, b) = spec.split_once('-').unwrap_or(("", ""));
                    if a.is_empty() {
                        if let Ok(n) = b.trim().parse::<u64>() {
                            start = total.saturating_sub(n);
                            partial = true;
                        }
                    } else if let Ok(v) = a.trim().parse::<u64>() {
                        // remember the ask before clamping: a request that
                        // starts at or past EOF is 416, not a one-byte reply
                        unsatisfiable = v >= total;
                        start = v.min(total.saturating_sub(1));
                        partial = true;
                        if let Ok(e) = b.trim().parse::<u64>() {
                            end = e.min(total.saturating_sub(1));
                        }
                    }
                }
            }
            if end < start {
                end = total.saturating_sub(1);
            }
            // an empty file or a range that starts past the end is not a
            // satisfiable request; answering 200 with zero bytes makes AVPlayer
            // retry forever
            if total == 0 || unsatisfiable {
                let head = format!(
                    "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{total}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                );
                let _ = out.write_all(head.as_bytes());
                let _ = out.flush();
                return;
            }
            let len = end.saturating_sub(start) + 1;
            let head = if partial {
                format!(
                    "HTTP/1.1 206 Partial Content\r\nContent-Type: {mime}\r\nAccept-Ranges: bytes\r\nContent-Range: bytes {start}-{end}/{total}\r\nContent-Length: {len}\r\nConnection: close\r\n\r\n"
                )
            } else {
                format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: {mime}\r\nAccept-Ranges: bytes\r\nContent-Length: {total}\r\nConnection: close\r\n\r\n"
                )
            };
            if out.write_all(head.as_bytes()).is_err() {
                return;
            }
            if head_only {
                let _ = out.flush();
                return;
            }
            // stream it in windows: a lossless file can be hundreds of MB and
            // loading it whole to answer one Range request would spike the RAM
            if let Ok(mut f) = std::fs::File::open(p) {
                use std::io::{Seek, SeekFrom};
                if f.seek(SeekFrom::Start(start)).is_ok() {
                    let mut left = len;
                    let mut buf = vec![0u8; 64 * 1024];
                    while left > 0 {
                        let want = buf.len().min(left as usize);
                        match f.read(&mut buf[..want]) {
                            Ok(0) => break,
                            Ok(n) => {
                                if out.write_all(&buf[..n]).is_err() {
                                    break;
                                }
                                left -= n as u64;
                            }
                            Err(_) => break,
                        }
                    }
                }
            }
            let _ = out.flush();
            eprintln!("[audio] {title} bytes {start}-{end}/{total}");
}

// A streamed row has no file to range over, so the bridge resolves the page
// into a signed media URL and relays the bytes. The phone asks one origin
// (this one) for everything, so there is no CORS step, no cookie jar on the
// handset and no expiry in the middle of a song: if the link dies, this asks
// for a new one and carries on from there.
const MEDIA_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

// A phone plays one thing at a time, so a handful of proxied streams is already
// generous; the ceiling stops a stuck client holding a thread per retry.
static LIVE_STREAMS: AtomicUsize = AtomicUsize::new(0);
const MAX_STREAMS: usize = 6;

fn serve_stream(out: &mut TcpStream, page: &str, title: &str, range: Option<&str>, head_only: bool) {
    if !(page.starts_with("http://") || page.starts_with("https://")) {
        respond(out, "{\"ok\":false,\"error\":\"this row has no web source\"}");
        return;
    }
    if LIVE_STREAMS.fetch_add(1, Ordering::Relaxed) >= MAX_STREAMS {
        LIVE_STREAMS.fetch_sub(1, Ordering::Relaxed);
        respond(out, "{\"ok\":false,\"error\":\"too many streams open\"}");
        return;
    }
    struct Guard;
    impl Drop for Guard {
        fn drop(&mut self) {
            LIVE_STREAMS.fetch_sub(1, Ordering::Relaxed);
        }
    }
    let _guard = Guard;

    let mut attempt = 0;
    loop {
        attempt += 1;
        let direct = match crate::live::direct_audio_url(page) {
            Ok(u) => u,
            Err(e) => {
                let body = serde_json::json!({"ok": false, "error": e}).to_string();
                respond(out, &body);
                return;
            }
        };
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(10))
            .timeout_read(Duration::from_secs(30))
            .build();
        let mut req = agent
            .get(&direct)
            .set("User-Agent", MEDIA_UA)
            .set("Accept", "*/*");
        if let Some(r) = range {
            req = req.set("Range", r);
        }
        match req.call() {
            Ok(resp) => {
                let status = resp.status();
                let ctype = resp
                    .header("content-type")
                    .unwrap_or("application/octet-stream")
                    .to_string();
                let len = resp.header("content-length").map(|s| s.to_string());
                let crange = resp.header("content-range").map(|s| s.to_string());
                let mut head = format!(
                    "HTTP/1.1 {status} {}\r\nContent-Type: {ctype}\r\nAccept-Ranges: bytes\r\n",
                    if status == 206 { "Partial Content" } else { "OK" }
                );
                if let Some(c) = crange {
                    head.push_str(&format!("Content-Range: {c}\r\n"));
                }
                if let Some(l) = len {
                    head.push_str(&format!("Content-Length: {l}\r\n"));
                }
                head.push_str("Cache-Control: no-store\r\nConnection: close\r\n\r\n");
                if out.write_all(head.as_bytes()).is_err() {
                    return;
                }
                if head_only {
                    let _ = out.flush();
                    return;
                }
                let mut reader = resp.into_reader();
                let mut buf = vec![0u8; 64 * 1024];
                loop {
                    match reader.read(&mut buf) {
                        Ok(0) => break,
                        Ok(n) => {
                            if out.write_all(&buf[..n]).is_err() {
                                break;
                            }
                        }
                        Err(_) => break,
                    }
                }
                let _ = out.flush();
                eprintln!("[stream] {title} relayed");
                return;
            }
            // a signed link that answered a second ago can already be gone;
            // ask the resolver once more before telling the phone anything
            Err(ureq::Error::Status(code, _)) if (code == 403 || code == 410) && attempt == 1 => {
                eprintln!("[stream] {code} on the resolved link, resolving again");
                crate::live::forget_direct(page);
                continue;
            }
            Err(e) => {
                let body = serde_json::json!({"ok": false, "error": format!("upstream: {e}")})
                    .to_string();
                respond(out, &body);
                return;
            }
        }
    }
}

// Only rooms the shelf itself advertises may be read, so a crafted id cannot
// walk the disk. Read-only on purpose: opening a room here must leave the
// desktop's open playlist exactly where it was.
fn room_file(id: &str, lib: &Arc<Mutex<Library>>) -> Option<std::path::PathBuf> {
    let p = std::path::Path::new(id);
    if p.extension().and_then(|e| e.to_str()) != Some("json") {
        return None;
    }
    let known = lib.lock().unwrap().playlist_rows();
    let hit = known
        .iter()
        .any(|r| r.get("id").and_then(|x| x.as_str()) == Some(id));
    if !hit {
        return None;
    }
    Some(p.to_path_buf())
}

fn room_json(path: &std::path::Path) -> Result<String, String> {
    let raw = std::fs::read_to_string(path).map_err(|e| e.to_string())?;
    let v: serde_json::Value = serde_json::from_str(&raw).map_err(|e| e.to_string())?;
    let name = v.get("name").and_then(|x| x.as_str()).unwrap_or("Room").to_string();
    let cover = v.get("cover").and_then(|x| x.as_str()).unwrap_or("").to_string();
    let empty: Vec<serde_json::Value> = Vec::new();
    let rows = v.get("tracks").and_then(|x| x.as_array()).unwrap_or(&empty);
    // the path never leaves the server: the phone only learns whether a row can
    // play, and asks /room/audio for the bytes by row number
    let tracks: Vec<serde_json::Value> = rows
        .iter()
        .enumerate()
        .map(|(i, t)| {
            let p = t.get("path").and_then(|x| x.as_str()).unwrap_or("");
            // a row can be a page (streamed) instead of a file. The phone only
            // needs to know that something will answer, never where it lives.
            let web = t
                .get("web")
                .or_else(|| t.get("uri"))
                .and_then(|x| x.as_str())
                .filter(|s| s.starts_with("http"))
                .unwrap_or("");
            serde_json::json!({
                "row": i,
                "title": t.get("title").and_then(|x| x.as_str()).unwrap_or(""),
                "artist": t.get("artist").and_then(|x| x.as_str()).unwrap_or(""),
                "album": t.get("album").and_then(|x| x.as_str()).unwrap_or(""),
                "duration_ms": t.get("duration_ms").and_then(|x| x.as_u64()).unwrap_or(0),
                "cover": t.get("cover").and_then(|x| x.as_str()).unwrap_or(""),
                "playable": (!p.is_empty() && std::path::Path::new(p).is_file()) || !web.is_empty(),
                "stream": !web.is_empty() && (p.is_empty() || !std::path::Path::new(p).is_file()),
            })
        })
        .collect();
    Ok(serde_json::json!({
        "ok": true,
        "playlist_name": name,
        "playlist_cover": cover,
        "tracks": tracks,
    })
    .to_string())
}

fn handle(
    mut stream: TcpStream,
    app: &Arc<Mutex<AppState>>,
    core: &Arc<Core>,
    lib: &Arc<Mutex<Library>>,
    pst: &Arc<Mutex<PlayerState>>,
) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    // a client that stops reading a 64 KB window must not pin this thread
    let _ = stream.set_write_timeout(Some(Duration::from_secs(30)));
    // closed gateway: drop the connection before a byte is read, so a phone
    // sees a dead port rather than a page confirming something is listening
    if !phone_open()
        && stream
            .peer_addr()
            .map(|a| !a.ip().is_loopback())
            .unwrap_or(false)
    {
        return;
    }
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut request_line = String::new();
    if reader.read_line(&mut request_line).is_err() {
        return;
    }
    let mut drain = String::new();
    // AVPlayer asks for a byte range before it plays anything; keep the header
    // instead of throwing it away with the rest of the request
    let mut range_header: Option<String> = None;
    while reader.read_line(&mut drain).is_ok() {
        if drain.trim().is_empty() {
            break;
        }
        let low = drain.to_ascii_lowercase();
        if let Some(rest) = low.strip_prefix("range:") {
            range_header = Some(rest.trim().to_string());
        }
        drain.clear();
    }

    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or("");
    let target = parts.next().unwrap_or("");
    let head_only = method == "HEAD";
    if method != "GET" && !head_only {
        respond(&mut stream, "{\"ok\":false,\"error\":\"GET only\"}");
        return;
    }
    let (path, query) = match target.split_once('?') {
        Some((p, q)) => (p, q),
        None => (target, ""),
    };

    let from_lan = stream
        .peer_addr()
        .map(|a| !a.ip().is_loopback())
        .unwrap_or(false);
    if from_lan && LOCAL_ONLY.contains(&path) {
        respond(&mut stream, "{\"ok\":false,\"error\":\"that route is local only\"}");
        return;
    }

    let mut out = stream;
    match path {
        // local only: the switch that decides whether the phone can reach this
        // machine. Reading it tells the Studio what to draw; ?on=0|1 flips it
        // and remembers the choice across launches.
        "/phone" => {
            if let Some(v) = query_param(query, "on") {
                let on = v != "0" && v != "false";
                PHONE_OPEN.store(on, Ordering::Relaxed);
                PHONE_LOADED.store(true, Ordering::Relaxed);
                state::set_config_str("phone_site", if on { "1" } else { "0" });
            }
            let body = serde_json::json!({
                "open": phone_open(),
                "url": lan_ip().map(|ip| format!("http://{ip}:{PORT}/m")),
            })
            .to_string();
            respond(&mut out, &body);
        }
        // The phone's home-screen icon and web-app manifest. Served from the
        // same assets the exe wears, so the two can never drift apart.
        // iOS also probes the -precomposed spelling and the per-size suffixes
        // before it gives up and draws the page's first letter instead.
        "/icon-180.png" | "/icon-192.png" | "/icon-512.png" | "/icon-1024.png"
        | "/apple-touch-icon.png" | "/apple-touch-icon-precomposed.png"
        | "/apple-touch-icon-180x180.png" | "/apple-touch-icon-180x180-precomposed.png" => {
            let name = match path {
                "/apple-touch-icon.png"
                | "/apple-touch-icon-precomposed.png"
                | "/apple-touch-icon-180x180.png"
                | "/apple-touch-icon-180x180-precomposed.png" => "icon-180",
                other => other,
            };
            let name = name.trim_start_matches('/').trim_end_matches(".png");
            let file = format!(
                concat!(env!("AETHER_ROOT"), "/assets/icons/{}.png"),
                name
            );
            match std::fs::read(&file) {
                Ok(bytes) => respond_bytes(&mut out, "image/png", &bytes),
                Err(_) => respond(&mut out, "{\"ok\":false}"),
            }
        }
        "/manifest.webmanifest" => {
            let body = concat!(
                "{\"name\":\"AetherMix\",\"short_name\":\"AetherMix\",",
                "\"start_url\":\"/m\",\"scope\":\"/\",\"display\":\"standalone\",",
                "\"background_color\":\"#04070f\",\"theme_color\":\"#07060f\",",
                "\"icons\":[{\"src\":\"/icon-192.png\",\"sizes\":\"192x192\",\"type\":\"image/png\"},",
                "{\"src\":\"/icon-512.png\",\"sizes\":\"512x512\",\"type\":\"image/png\",\"purpose\":\"any maskable\"}]}"
            );
            respond_bytes(&mut out, "application/manifest+json", body.as_bytes());
        }
        "/" | "/m" => {
            // no install, no signing, no seven-day clock: the phone opens
            // this address in Safari and is a second window onto the bridge
            respond_html(&mut out, MOBILE_HTML);
        }
        "/state" => {
            let body = {
                let s = app.lock().unwrap();
                let (qlen, qpos, shuffle, repeat, cid) = {
                    let p = pst.lock().unwrap();
                    (
                        p.queue.len(),
                        p.pos,
                        p.shuffle,
                        p.repeat,
                        p.current_id,
                    )
                };
                // the offset the words actually use: a per-song nudge wins
                // over the global setting, so one bad LRC never breaks the rest
                let eff_offset = match cid {
                    Some(id) => {
                        let l = lib.lock().unwrap();
                        match l.tracks.get(id) {
                            Some(t) => crate::state::lyric_offset_for(&crate::state::song_key(&t.title, &t.artist))
                                .unwrap_or(s.lyric_offset_ms),
                            None => s.lyric_offset_ms,
                        }
                    }
                    None => s.lyric_offset_ms,
                };
                serde_json::json!({
                    "status": s.status,
                    "title": s.title,
                    "artist": s.artist,
                    "album": s.album,
                    "origin": s.origin,
                    "track_id": cid,
                    "playing": core.playing.load(Ordering::Relaxed),
                    "position_ms": core.position_ms.load(Ordering::Relaxed),
                    "duration_ms": core.duration_ms.load(Ordering::Relaxed),
                    "volume": s.volume,
                    "viz_mode": s.viz_mode,
                    "theme": s.theme,
                    "levels": s.levels,
                    "wave": s.wave,
                    "library_version": s.library_version,
                    "queue_len": qlen,
                    "queue_pos": qpos,
                    "shuffle": shuffle,
                    "repeat": repeat,
                    "underruns": core.underruns.load(Ordering::Relaxed),
                    "streaming": crate::stream::available(),
                    "cover_url": s.cover_url,
                    "lyric_offset_ms": eff_offset,
                    "lyric_offset_song": eff_offset != s.lyric_offset_ms,
                    "page": s.page,
                    // sleep timer, resume point and the liked set ride the same
                    // poll the ui already runs - no extra request per feature
                    "sleep_ms": crate::state::sleep_remaining_ms(),
                    "resume": resume_json(),
                    "liked_count": crate::state::favorites().len(),
                    "hotkeys": crate::state::config_str("hotkeys").map(|v| v == "1").unwrap_or(false),
                })
                .to_string()
            };
            respond(&mut out, &body);
        }
        "/library" => {
            // ?scope=playlist is the phone opening one room: rows of that room
            // only, no local vault. Everything else keeps the desktop shape.
            let playlist_only = query_param(query, "scope")
                .map(|v| v == "playlist")
                .unwrap_or(false);
            let body = lib.lock().unwrap().json_scope(!playlist_only);
            respond(&mut out, &body);
        }
        "/queue" => {
            let body = {
                let p = pst.lock().unwrap();
                let l = lib.lock().unwrap();
                let up: Vec<serde_json::Value> = p
                    .queue
                    .iter()
                    .enumerate()
                    .skip(p.pos + 1)
                    .take(24)
                    .filter_map(|(i, id)| l.tracks.get(*id).map(|t| (i, t)))
                    .map(|(i, t)| {
                        serde_json::json!({
                            "pos": i,
                            "id": t.id,
                            "title": t.title,
                            "artist": t.artist,
                            "cover": t.cover_file,
                            "playable": !t.path.is_empty() || !t.web.is_empty(),
                        })
                    })
                    .collect();
                let cur: Option<serde_json::Value> = p
                    .queue
                    .get(p.pos)
                    .and_then(|id| l.tracks.get(*id))
                    .map(|t| {
                        serde_json::json!({
                            "id": t.id,
                            "title": t.title,
                            "artist": t.artist,
                        })
                    });
                serde_json::json!({"current": cur, "up": up, "smart": p.smart_mode, "shuffle": p.shuffle}).to_string()
            };
            respond(&mut out, &body);
        }
        "/play" => {
            let id: Option<usize> = query_param(query, "id")
                .and_then(|v| v.parse().ok());
            match id {
                Some(id) => {
                    // a stale row id (a list drawn before a rescan, a link left
                    // over from a removed song) must say so instead of echoing
                    // ok:true and leaving the deck silent
                    let hit = {
                        let l = lib.lock().unwrap();
                        l.tracks.get(id).map(|t| (t.uri.clone(), !t.path.is_empty()))
                    };
                    let Some((uri, has_file)) = hit else {
                        respond(&mut out, "{\"ok\":false,\"error\":\"no such track\"}");
                        return;
                    };
                    // shell mode: rows that only exist as a spotify uri go to the
                    // official client. a row with a downloaded file plays here.
                    let shell_on = app.lock().unwrap().shell_mode;
                    if shell_on && !uri.is_empty() && !has_file {
                        match crate::shell::play_track_uri(&uri) {
                            Ok(()) => {
                                let mut a = app.lock().unwrap();
                                a.track_id = Some(id);
                                a.origin = "shell".into();
                                a.status = "shell: playing on the official client".into();
                            }
                            Err(e) => {
                                let mut a = app.lock().unwrap();
                                a.status = format!("shell error: {e}");
                            }
                        }
                        respond(&mut out, "{\"ok\":true}");
                        return;
                    }
                    let ok = send(PlayerCmd::PlayId(id));
                    if !ok {
                        respond(&mut out, "{\"ok\":false,\"error\":\"the player is not running\"}");
                        return;
                    }
                    // a resume point, or a "play from here" from a menu: the
                    // deck needs a beat to open the decoder before the seek
                    if let Some(ms) = query_param(query, "pos").and_then(|v| v.parse::<u32>().ok()) {
                        if ms > 0 {
                            std::thread::spawn(move || {
                                std::thread::sleep(std::time::Duration::from_millis(900));
                                send(PlayerCmd::Seek(ms));
                            });
                        }
                    }
                    respond(&mut out, "{\"ok\":true}");
                    let _ = ok;
                }
                None => respond(&mut out, "{\"ok\":false,\"error\":\"missing id\"}"),
            }
        }
        "/toggle" => {
            // one guard, one decision: two lock() calls inside one condition
            // can keep the first guard alive while the second waits for it
            let shell = {
                let a = app.lock().unwrap();
                a.shell_mode && a.origin == "shell"
            };
            if shell {
                let _ = crate::shell::toggle();
                respond(&mut out, "{\"ok\":true}");
                return;
            }
            send(PlayerCmd::Toggle);
            respond(&mut out, "{\"ok\":true}");
        }
        "/pause" => {
            send(PlayerCmd::Pause);
            respond(&mut out, "{\"ok\":true}");
        }
        "/resume" => {
            send(PlayerCmd::Resume);
            respond(&mut out, "{\"ok\":true}");
        }
        "/stop" => {
            send(PlayerCmd::Stop);
            respond(&mut out, "{\"ok\":true}");
        }
        "/next" => {
            let shell = {
                let a = app.lock().unwrap();
                a.shell_mode && a.origin == "shell"
            };
            if shell {
                let _ = crate::shell::next();
                respond(&mut out, "{\"ok\":true}");
                return;
            }
            send(PlayerCmd::Next);
            respond(&mut out, "{\"ok\":true}");
        }
        "/prev" => {
            let shell = {
                let a = app.lock().unwrap();
                a.shell_mode && a.origin == "shell"
            };
            if shell {
                let _ = crate::shell::prev();
                respond(&mut out, "{\"ok\":true}");
                return;
            }
            send(PlayerCmd::Prev);
            respond(&mut out, "{\"ok\":true}");
        }
        "/seek" => {
            let ms: u32 = query_param(query, "ms")
                .and_then(|v| v.parse().ok())
                .unwrap_or(0);
            send(PlayerCmd::Seek(ms));
            respond(&mut out, "{\"ok\":true}");
        }
        "/volume" => {
            let v: u32 = query_param(query, "v")
                .and_then(|x| x.parse().ok())
                .unwrap_or(70)
                .clamp(0, 100);
            core.volume.store(v, Ordering::Relaxed);
            app.lock().unwrap().volume = v;
            state::save_config(app, core, pst);
            respond(&mut out, "{\"ok\":true}");
        }
        "/mode" => {
            let m: u32 = query_param(query, "m")
                .and_then(|x| x.parse().ok())
                .unwrap_or(0)
                .min(2);
            app.lock().unwrap().viz_mode = m;
            state::save_config(app, core, pst);
            respond(&mut out, "{\"ok\":true}");
        }
        "/queue/remove" => {
            let mut i = query_param(query, "i").and_then(|v| v.parse::<usize>().ok()).unwrap_or(usize::MAX);
            if i == usize::MAX {
                if let Some(id) = query_param(query, "id").and_then(|v| v.parse::<usize>().ok()) {
                    let st0 = pst.lock().unwrap();
                    i = st0.queue.iter().position(|&x| x == id).unwrap_or(usize::MAX);
                }
            }
            let mut next_up: Option<usize> = None;
            {
                let mut st = pst.lock().unwrap();
                if i < st.queue.len() {
                    let was_current = Some(st.queue[i]) == st.current_id;
                    st.queue.remove(i);
                    if i < st.pos {
                        st.pos = st.pos.saturating_sub(1);
                    }
                    let keep: Vec<usize> = st.queue.clone();
                    st.smart_remaining.retain(|&x| keep.contains(&x));
                    if was_current {
                        next_up = st.queue.get(i.min(st.queue.len().saturating_sub(1))).copied();
                        st.pos = i.min(st.queue.len().saturating_sub(1));
                    }
                    respond(&mut out, "{\"ok\":true}");
                } else {
                    respond(&mut out, "{\"ok\":false,\"error\":\"that row is not in the queue\"}");
                }
            }
            if let Some(id) = next_up {
                send(PlayerCmd::PlayId(id));
            }
        }
        "/playlist/remove" => {
            let Some(id) = query_param(query, "id").and_then(|v| v.parse::<usize>().ok()) else {
                respond(&mut out, "{\"ok\":false,\"error\":\"missing id\"}");
                return;
            };
            let (gone, version, title) = {
                let mut l = lib.lock().unwrap();
                let title = l.tracks.get(id).map(|t| t.title.clone()).unwrap_or_default();
                let gone = l.remove_track(id);
                (gone, l.version, title)
            };
            if !gone {
                respond(&mut out, "{\"ok\":false,\"error\":\"no such track\"}");
                return;
            }
            // ids shift down by one: keep the live queue pointing at real rows
            let was_current = {
                let mut p = pst.lock().unwrap();
                p.queue.retain(|&x| x != id);
                for q in p.queue.iter_mut() {
                    if *q > id {
                        *q -= 1;
                    }
                }
                p.smart_remaining.retain(|&x| x != id);
                for q in p.smart_remaining.iter_mut() {
                    if *q > id {
                        *q -= 1;
                    }
                }
                let was = p.current_id == Some(id);
                match p.current_id {
                    Some(c) if c == id => {
                        p.current_id = None;
                        p.cur_path.clear();
                    }
                    Some(c) if c > id => p.current_id = Some(c - 1),
                    _ => {}
                }
                was
            };
            if was_current {
                send(PlayerCmd::Stop);
            }
            app.lock().unwrap().library_version = version;
            let body = serde_json::json!({"ok": true, "title": title}).to_string();
            respond(&mut out, &body);
        }
        "/playlist/append" => {
            // add one song to a playlist that is not the active one. the sheet
            // used to require switching lists first, which lost your place.
            let pl = query_param(query, "pl").unwrap_or_default();
            let Some(target) = crate::library::resolve_playlist_file(&pl) else {
                respond(&mut out, "{\"ok\":false,\"error\":\"playlist not found\"}");
                return;
            };
            let id = query_param(query, "id").and_then(|v| v.parse::<usize>().ok());
            let row = match id {
                Some(id) => {
                    let l = lib.lock().unwrap();
                    l.tracks.get(id).map(|t| serde_json::json!({
                        "title": t.title, "artist": t.artist, "album": t.album,
                        "duration_ms": t.duration_ms, "uri": t.uri, "cover": t.cover_file,
                        "path": t.path,
                    }))
                }
                None => None,
            };
            let Some(row) = row else {
                respond(&mut out, "{\"ok\":false,\"error\":\"no such track\"}");
                return;
            };
            let mut doc = std::fs::read_to_string(&target)
                .ok()
                .and_then(|b| serde_json::from_str::<serde_json::Value>(&b).ok())
                .unwrap_or_else(|| serde_json::json!({ "tracks": [] }));
            let mut arr = doc
                .get("tracks")
                .and_then(|x| x.as_array())
                .cloned()
                .unwrap_or_default();
            let key_uri = row.get("uri").and_then(|x| x.as_str()).unwrap_or("");
            let key_path = row.get("path").and_then(|x| x.as_str()).unwrap_or("");
            let key_title = row.get("title").and_then(|x| x.as_str()).unwrap_or("").to_lowercase();
            let dup = arr.iter().any(|t| {
                let u = t.get("uri").and_then(|x| x.as_str()).unwrap_or("");
                let p = t.get("path").and_then(|x| x.as_str()).unwrap_or("");
                let ti = t.get("title").and_then(|x| x.as_str()).unwrap_or("").to_lowercase();
                (!key_uri.is_empty() && u == key_uri)
                    || (!key_path.is_empty() && p == key_path)
                    || (key_uri.is_empty() && key_path.is_empty() && !key_title.is_empty() && ti == key_title)
            });
            if !dup {
                let mut copy = row.clone();
                if let Some(o) = copy.as_object_mut() {
                    o.insert("n".into(), serde_json::json!(arr.len() + 1));
                }
                arr.push(copy);
            }
            if let Some(o) = doc.as_object_mut() {
                o.insert("tracks".into(), serde_json::json!(arr));
                if !o.contains_key("name") {
                    o.insert("name".into(), serde_json::json!("Playlist"));
                }
            }
            let total = arr.len();
            // the write has to be confirmed before reporting success: an
            // unwritable path used to answer ok:true and leave the shelf
            // showing a song that was never saved
            let mut saved = false;
            if let Ok(body) = serde_json::to_string_pretty(&doc) {
                let tmp = format!("{target}.tmp");
                if std::fs::write(&tmp, body).is_ok() && std::fs::rename(&tmp, &target).is_ok() {
                    saved = true;
                }
            }
            if !saved {
                respond(&mut out, "{\"ok\":false,\"error\":\"could not write that playlist\"}");
                return;
            }
            // the guard must be scoped: comparing inside `if` kept the mutex
            // locked for the whole statement and the second lock deadlocked
            let is_active = {
                let l = lib.lock().unwrap();
                target == l.playlist_file
            };
            if is_active {
                let mut l = lib.lock().unwrap();
                l.load_all();
                let v = l.version;
                drop(l);
                app.lock().unwrap().library_version = v;
            }
            let body = serde_json::json!({"ok": true, "total": total, "duplicate": dup}).to_string();
            respond(&mut out, &body);
        }
        // ---- editing a room from the phone ---------------------------------
        // One song, added to the room the phone is looking at. `mode=stream`
        // keeps the row on the web; `mode=file` lands the row now and upgrades
        // it to a local file when the download finishes, so it is listenable
        // either way. Nothing here touches the desktop's deck.
        "/playlist/add_web" => {
            let pl = query_param(query, "pl").unwrap_or_default();
            let url = query_param(query, "url").unwrap_or_default();
            let mode = query_param(query, "mode").unwrap_or_else(|| "stream".into());
            if pl.is_empty() || !url.starts_with("http") {
                respond(&mut out, "{\"ok\":false,\"error\":\"need a room and a link\"}");
                return;
            }
            let body = crate::room_edit::add_web(&pl, &url, &mode);
            let ok = serde_json::from_str::<serde_json::Value>(&body)
                .ok()
                .and_then(|v| v.get("ok").and_then(|x| x.as_bool()))
                .unwrap_or(false);
            if ok {
                // if the room is the one on screen, let the shell notice
                let active = lib.lock().unwrap().playlist_file.clone();
                if crate::library::same_path(&active, &pl) {
                    let mut l = lib.lock().unwrap();
                    l.load_all();
                    let v = l.version;
                    drop(l);
                    app.lock().unwrap().library_version = v;
                }
            }
            respond(&mut out, &body);
        }
        "/playlist/covers" => {
            let pl = query_param(query, "pl").unwrap_or_default();
            respond(&mut out, &crate::room_edit::cover_choices(&pl));
        }
        "/playlist/cover" => {
            let pl = query_param(query, "pl").unwrap_or_default();
            let cover = query_param(query, "cover").unwrap_or_default();
            if pl.is_empty() {
                respond(&mut out, "{\"ok\":false,\"error\":\"need a room\"}");
                return;
            }
            let ok = crate::room_edit::set_cover(&pl, &cover);
            if ok {
                let mut l = lib.lock().unwrap();
                if crate::library::same_path(&l.playlist_file, &pl) {
                    l.playlist_cover = cover.clone();
                    l.version += 1;
                    let v = l.version;
                    drop(l);
                    app.lock().unwrap().library_version = v;
                }
            }
            let body = serde_json::json!({"ok": ok, "cover": cover}).to_string();
            respond(&mut out, &body);
        }
        "/queue/add" => {
            // keep the song for after everything already lined up
            let id = query_param(query, "id").and_then(|v| v.parse::<usize>().ok()).unwrap_or(usize::MAX);
            let valid = { lib.lock().unwrap().tracks.get(id).is_some() };
            if !valid {
                respond(&mut out, "{\"ok\":false}");
            } else {
                let mut st = pst.lock().unwrap();
                st.queue.push(id);
                if !st.smart_remaining.contains(&id) {
                    st.smart_remaining.push(id);
                }
                let len = st.queue.len();
                respond(&mut out, &format!("{{\"ok\":true,\"queue_len\":{len}}}"));
            }
        }
        "/queue/clear" => {
            let mut st = pst.lock().unwrap();
            let keep = st.current_id;
            st.queue.retain(|&x| Some(x) == keep);
            st.pos = st.queue.len().saturating_sub(1).min(st.pos);
            st.smart_remaining.clear();
            respond(&mut out, "{\"ok\":true}");
        }
        "/queue/playnext" => {
            let id = query_param(query, "id").and_then(|v| v.parse::<usize>().ok()).unwrap_or(usize::MAX);
            let mut st = pst.lock().unwrap();
            if st.queue.contains(&id) || id != usize::MAX {
                let at = (st.pos + 1).min(st.queue.len());
                st.queue.insert(at, id);
                if !st.smart_remaining.contains(&id) {
                    st.smart_remaining.push(id);
                }
                respond(&mut out, "{\"ok\":true}");
            } else {
                respond(&mut out, "{\"ok\":false}");
            }
        }
        "/shuffle" => {
            let s = query_param(query, "s")
                .map(|x| x == "1" || x == "true")
                .unwrap_or(false);
            // mode=smart turns on play-count weighted picking; mode=random is
            // the classic reshuffle; absent = just toggle shuffle on/off
            let mode = query_param(query, "mode").unwrap_or_default();
            {
                let mut st = pst.lock().unwrap();
                if mode == "smart" {
                    st.smart_mode = true;
                } else if mode == "random" {
                    st.smart_mode = false;
                }
                st.smart_remaining.clear(); // refill picks up the new policy
            }
            send(PlayerCmd::SetShuffle(s));
            respond(&mut out, "{\"ok\":true}");
        }
        "/repeat" => {
            let r: u32 = query_param(query, "r")
                .and_then(|x| x.parse().ok())
                .unwrap_or(0)
                .min(2);
            send(PlayerCmd::SetRepeat(r));
            respond(&mut out, "{\"ok\":true}");
        }
        "/themes" => {
            let names = theme_names();
            let body = serde_json::json!({"themes": names}).to_string();
            respond(&mut out, &body);
        }
        "/theme/current" => {
            // a fresh profile has no theme parked in the state yet (the shell
            // assigns it after the first paint), so fall back to the default
            // world instead of answering an error the phone cannot use
            let name = app.lock().unwrap().theme.clone();
            let body = theme_file_named(&name)
                .or_else(|| theme_file_named("frutiger"))
                .or_else(|| theme_file_named("aurora"));
            match body {
                Some(body) => respond(&mut out, &body),
                None => respond(&mut out, "{\"error\":\"theme missing\"}"),
            }
        }
        "/theme" => {
            let name = query_param(query, "name").unwrap_or_default();
            let preview = query_param(query, "preview")
                .map(|v| v == "1")
                .unwrap_or(false);
            match theme_file_named(&name) {
                Some(body) => {
                    if !preview {
                        app.lock().unwrap().theme = name;
                        state::save_config(app, core, pst);
                    }
                    respond(&mut out, &body);
                }
                None => respond(&mut out, "{\"ok\":false,\"error\":\"unknown theme\"}"),
            }
        }
        "/oauth/grant" => {
            let tx = PLAYER_TX.get().cloned();
            match tx {
                Some(tx) => {
                    crate::stream::start_oauth_flow_force(app.clone(), core.clone(), tx);
                    respond(&mut out, "{\"ok\":true,\"status\":\"browser opened - re-authorize with full access, then restart the app\"}");
                }
                None => respond(&mut out, "{\"ok\":false}"),
            }
        }
        "/oauth/start" => {
            let tx = PLAYER_TX.get().cloned();
            match tx {
                Some(tx) => {
                    crate::stream::start_oauth_flow(app.clone(), core.clone(), tx);
                    respond(&mut out, "{\"ok\":true,\"status\":\"browser opened - complete the login\"}");
                }
                None => respond(&mut out, "{\"ok\":false,\"error\":\"player not ready\"}"),
            }
        }
        "/extensions" => {
            let mut exts: Vec<serde_json::Value> = Vec::new();
            if let Ok(entries) = std::fs::read_dir(concat!(env!("AETHER_ROOT"), "/extensions")) {
                for e in entries.flatten() {
                    let p = e.path();
                    if p.extension().and_then(|x| x.to_str()) == Some("qml") {
                        if let Some(stem) = p.file_stem().and_then(|s| s.to_str()) {
                            exts.push(serde_json::json!({
                                "id": stem,
                                "path": p.to_string_lossy(),
                            }));
                        }
                    }
                }
            }
            let body = serde_json::json!({ "extensions": exts }).to_string();
            respond(&mut out, &body);
        }
        "/lyrics" => {
            let id: usize = query_param(query, "id")
                .and_then(|v| v.parse().ok())
                .unwrap_or(usize::MAX);
            let refresh = query_param(query, "refresh").map(|v| v == "1").unwrap_or(false);
            // a room row has no library id of its own, and a freshly streamed
            // row may still be landing. Naming the song is enough: the library
            // is keyed by title+artist anyway.
            let mut wanted = (String::new(), String::new());
            let id = if id == usize::MAX {
                let title = query_param(query, "title").unwrap_or_default();
                let artist = query_param(query, "artist").unwrap_or_default();
                let key = crate::state::song_key(&title, &artist);
                let hit = {
                    let l = lib.lock().unwrap();
                    l.tracks
                        .iter()
                        .find(|t| crate::state::song_key(&t.title, &t.artist) == key)
                        .map(|t| t.id)
                };
                wanted = (title, artist);
                hit.unwrap_or(usize::MAX)
            } else {
                id
            };
            // not in the shelf (a search result, a row still landing): the
            // words are still findable by name, and that is all the cache needs
            let (lyrics, synced) = if id == usize::MAX {
                lyrics_named(&wanted.0, &wanted.1, "", 0, refresh)
            } else {
                lyrics_for_track(&lib, id, refresh)
            };
            let body = serde_json::json!({
                "lyrics": lyrics,
                "synced": synced,
            })
            .to_string();
            respond(&mut out, &body);
        }
        "/eq" => {
            let gains: Vec<f32> = (0..5)
                .map(|i| f32::from_bits(core.eq_gains[i].load(Ordering::Relaxed)))
                .collect();
            let body = serde_json::json!({
                "enabled": core.eq_enabled.load(Ordering::Relaxed),
                "gains": gains,
            })
            .to_string();
            respond(&mut out, &body);
        }
        "/eq/set" => {
            let mut g = [0f32; 5];
            for (i, slot) in g.iter_mut().enumerate() {
                *slot = query_param(query, &format!("g{i}"))
                    .and_then(|x| x.parse::<f32>().ok())
                    .unwrap_or(0.0)
                    .clamp(-12.0, 12.0);
            }
            let en = query_param(query, "enabled")
                .map(|x| x == "1" || x == "true")
                .unwrap_or(false);
            core.set_eq(en, g);
            crate::state::save_config(&app, &core, &pst);
            respond(&mut out, "{\"ok\":true}");
        }
        // frame pacing, reported by the shell every few seconds: the smoothed
        // rate plus the worst frame seen in that window, because an average of
        // 60fps can still hide the 40ms hitch the eye reads as stutter. the UI
        // shows it on the themes page; this endpoint makes it readable from a
        // script while the room's cost is being tuned.
        "/frame" => {
            // `d` carries a one-line diagnostic string from the shell while a
            // surface is being debugged: QML runtime errors never reach the
            // log, so this is the only channel back out
            if let Some(d) = query_param(query, "d") {
                if let Ok(mut slot) = FRAME_DIAG.lock() {
                    // an ordered trail, not a last value: the watcher bug is a
                    // question of which signal ran before which
                    slot.push_str(&d);
                    slot.push('|');
                    let len = slot.len();
                    if len > 900 { slot.drain(0..len - 900); }
                }
            }
            if let Some(f) = query_param(query, "f").and_then(|v| v.parse::<u32>().ok()) {
                let worst: u32 = query_param(query, "worst")
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(0);
                let q: u32 = query_param(query, "q").and_then(|v| v.parse().ok()).unwrap_or(100);
                let slow: u32 = query_param(query, "slow").and_then(|v| v.parse().ok()).unwrap_or(0);
                let vslow: u32 = query_param(query, "vslow").and_then(|v| v.parse().ok()).unwrap_or(0);
                if let Ok(mut slot) = FRAME_LOCK.lock() {
                    *slot = [f as f64, worst as f64, q as f64, slow as f64, vslow as f64];
                }
            }
            let (f, worst, q, slow, vslow) = FRAME_LOCK
                .lock()
                .map(|s| (s[0], s[1], s[2], s[3], s[4]))
                .unwrap_or((0.0, 0.0, 100.0, 0.0, 0.0));
            let diag = FRAME_DIAG.lock().map(|s| s.clone()).unwrap_or_default();
            respond(
                &mut out,
                &format!(
                    "{{\"fps\":{},\"worst\":{},\"q\":{},\"slow\":{},\"vslow\":{},\"diag\":\"{}\"}}",
                    f.round() as i64,
                    worst.round() as i64,
                    q.round() as i64,
                    slow.round() as i64,
                    vslow.round() as i64,
                    diag.replace('"', "'")
                ),
            );
        }
        "/lyricstyle" => {
            let id: usize = query_param(query, "id")
                .and_then(|v| v.parse().ok())
                .unwrap_or(usize::MAX);
            match crate::state::lyric_style(id) {
                Some(b) => respond(&mut out, &b),
                None => respond(&mut out, "{}"),
            }
        }
        "/lyricstyle/set" => {
            let id: usize = query_param(query, "id")
                .and_then(|v| v.parse().ok())
                .unwrap_or(usize::MAX);
            let pattern = query_param(query, "pattern").unwrap_or_else(|| "accent".into());
            let anim = query_param(query, "anim").unwrap_or_else(|| "rise".into());
            let emphasis = query_param(query, "emphasis").unwrap_or_else(|| "glow".into());
            let global = query_param(query, "global").map(|x| x == "1").unwrap_or(false);
            crate::state::set_lyric_style(id, &pattern, &anim, &emphasis, global);
            respond(&mut out, "{\"ok\":true}");
        }
        "/playlist/set" => {
            let raw = query_param(query, "url").unwrap_or_default();
            match crate::catalog::playlist_id(&raw) {
                Some(pid) => {
                    let url = format!("https://open.spotify.com/embed/playlist/{pid}");
                    crate::state::set_config_str("playlist_url", &url);
                    println!("[catalog] playlist switched to {pid}");
                    let lib2 = lib.clone();
                    let app2 = app.clone();
                    std::thread::spawn(move || {
                        crate::catalog::sync_once(&lib2, &app2);
                    });
                    let body = serde_json::json!({ "ok": true, "playlist": pid }).to_string();
                    respond(&mut out, &body);
                }
                None => {
                    respond(&mut out, "{\"ok\":false,\"error\":\"bad playlist url\"}");
                }
            }
        }
        "/playlists" => {
            let rows = lib.lock().unwrap().playlist_rows();
            let active = lib.lock().unwrap().playlist_file.clone();
            let body = serde_json::json!({
                "playlists": rows,
                "active": active,
            })
            .to_string();
            respond(&mut out, &body);
        }
        "/playlist/new" => {
            let name = query_param(query, "name")
                .unwrap_or_default()
                .trim()
                .to_string();
            if name.is_empty() {
                respond(&mut out, "{\"ok\":false,\"error\":\"name required\"}");
            } else {
                let mut l = lib.lock().unwrap();
                let file = l.create_playlist(&name);
                let version = l.version;
                drop(l);
                reset_playback(app, pst);
                app.lock().unwrap().library_version = version;
                let body = serde_json::json!({
                    "ok": true,
                    "file": file,
                    "name": name,
                })
                .to_string();
                respond(&mut out, &body);
            }
        }
        // paste a playlist link, get a room: youtube, soundcloud or spotify
        "/playlist/import/preview" => {
            let url = query_param(query, "url").unwrap_or_default();
            let limit = query_param(query, "limit").and_then(|x| x.parse().ok()).unwrap_or(0);
            let body = crate::playlist_import::preview_json(&url, limit);
            respond(&mut out, &body);
        }
        "/playlist/import/start" => {
            let url = query_param(query, "url").unwrap_or_default();
            let name = query_param(query, "name").unwrap_or_default();
            let limit = query_param(query, "limit").and_then(|x| x.parse().ok()).unwrap_or(0);
            let body = crate::playlist_import::start(&url, &name, limit, lib.clone(), app.clone());
            respond(&mut out, &body);
        }
        "/playlist/import/status" => {
            let body = crate::playlist_import::status_json();
            respond(&mut out, &body);
        }
        // A room is a file, and until now the only way to love it or leave it
        // was to make another one: the shelf filled up with rooms that shared a
        // name or held nothing. Rename rewrites the name and nothing else;
        // retire moves the file into library/backups, so a wrong press is a
        // move back, not a lost playlist.
        "/playlist/rename" => {
            let id = query_param(query, "id").unwrap_or_default();
            let name = query_param(query, "name").unwrap_or_default().trim().to_string();
            if name.is_empty() {
                respond(&mut out, "{\"ok\":false,\"error\":\"a room needs a name\"}");
                return;
            }
            let Some(path) = room_file(&id, lib) else {
                respond(&mut out, "{\"ok\":false,\"error\":\"no such room\"}");
                return;
            };
            let mut v = match std::fs::read_to_string(&path)
                .ok()
                .and_then(|b| serde_json::from_str::<serde_json::Value>(&b).ok())
            {
                Some(v) => v,
                None => {
                    respond(&mut out, "{\"ok\":false,\"error\":\"that room is not readable\"}");
                    return;
                }
            };
            if let Some(o) = v.as_object_mut() {
                o.insert("name".into(), serde_json::json!(name));
            }
            let tmp = format!("{}.tmp", path.display());
            let wrote = std::fs::write(&tmp, serde_json::to_string_pretty(&v).unwrap_or_default())
                .is_ok()
                && std::fs::rename(&tmp, &path).is_ok();
            if !wrote {
                respond(&mut out, "{\"ok\":false,\"error\":\"could not write that room\"}");
                return;
            }
            // the open room's name lives in memory; the bar and the shelf read
            // it from there, so it has to change here too
            let active = lib.lock().unwrap().playlist_file.clone();
            if crate::library::same_path(&active, &id) {
                lib.lock().unwrap().playlist_name = name.clone();
            }
            let body = serde_json::json!({"ok": true, "name": name}).to_string();
            respond(&mut out, &body);
        }
        "/playlist/retire" => {
            let id = query_param(query, "id").unwrap_or_default();
            let Some(path) = room_file(&id, lib) else {
                respond(&mut out, "{\"ok\":false,\"error\":\"no such room\"}");
                return;
            };
            {
                let l = lib.lock().unwrap();
                if crate::library::same_path(&l.playlist_file, &id) {
                    respond(
                        &mut out,
                        "{\"ok\":false,\"error\":\"that is the open room - open another one first\"}",
                    );
                    return;
                }
            }
            let stamp = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);
            let dir = concat!(env!("AETHER_ROOT"), "/library/backups");
            let _ = std::fs::create_dir_all(dir);
            let stem = path
                .file_stem()
                .and_then(|s| s.to_str())
                .unwrap_or("room");
            let dest = format!("{dir}/{stem}.retired-{stamp}.json");
            match std::fs::rename(&path, &dest) {
                Ok(_) => {
                    let body = serde_json::json!({"ok": true, "moved_to": dest}).to_string();
                    respond(&mut out, &body);
                }
                Err(e) => {
                    let body = serde_json::json!({"ok": false, "error": format!("could not move it: {e}")})
                        .to_string();
                    respond(&mut out, &body);
                }
            }
        }
        "/playlist/switch" => {
            let id = query_param(query, "id").unwrap_or_default();
            // Opening the room that is already open is a change of view, not of
            // deck. Switching used to reset playback unconditionally, so every
            // second click on the shelf silenced whatever was playing.
            let same = {
                let l = lib.lock().unwrap();
                crate::library::same_path(&l.playlist_file, &id)
            };
            if same {
                let name = lib.lock().unwrap().playlist_name.clone();
                let body = serde_json::json!({"ok": true, "name": name, "same": true}).to_string();
                respond(&mut out, &body);
                return;
            }
            let mut l = lib.lock().unwrap();
            let switched = l.switch_playlist(&id);
            let version = l.version;
            let name = l.playlist_name.clone();
            drop(l);
            if switched {
                reset_playback(app, pst);
                app.lock().unwrap().library_version = version;
                let body = serde_json::json!({"ok": true, "name": name}).to_string();
                respond(&mut out, &body);
            } else {
                respond(&mut out, "{\"ok\":false,\"error\":\"playlist not found\"}");
            }
        }
        "/youtube/search" => {
            let q = query_param(query, "q").unwrap_or_default();
            let src = query_param(query, "src").unwrap_or_else(|| "youtube".into());
            let body = crate::ytcvt::search_source_json(&q, &src, 12);
            respond(&mut out, &body);
        }
        // one search bar, every room it can reach. spotify uses the planted
        // session; youtube and soundcloud are yt-dlp searches, no key needed.
        "/sources/search" => {
            let q = query_param(query, "q").unwrap_or_default();
            let src = query_param(query, "src").unwrap_or_else(|| "youtube".into());
            let body = if src == "spotify" {
                if q.trim().is_empty() {
                    "{\"results\":[]}".to_string()
                } else {
                    let path = format!("/v1/search?type=track&limit=10&q={}", urlencode(&q));
                    let raw = crate::stream::api_get(&path, 8).unwrap_or_default();
                    spotify_results(&raw)
                }
            } else {
                crate::ytcvt::search_source_json(&q, &src, 10)
            };
            eprintln!("[search] {src} \"{q}\" -> {} bytes", body.len());
            respond(&mut out, &body);
        }
        "/web/resolve" => {
            let url = query_param(query, "url").unwrap_or_default();
            let body = crate::ytcvt::resolve_page_json(&url);
            respond(&mut out, &body);
        }
        "/youtube/add" => {
            let url = query_param(query, "url").unwrap_or_default();
            let play = query_param(query, "play").map(|v| v == "1").unwrap_or(false);
            // mode: stream (play from the web, nothing written to disk) or
            // file (download first). the default follows the global preference
            // so the plain "+" button behaves the way the listener chose.
            let mode = query_param(query, "mode").unwrap_or_else(|| {
                crate::state::config_str("add_mode").unwrap_or_else(|| "stream".into())
            });
            if !url.starts_with("http") {
                respond(&mut out, "{\"ok\":false,\"error\":\"need a video url\"}");
            } else {
                if mode == "file" {
                    crate::ytcvt::add_url_playing(lib.clone(), app.clone(), url.clone(), play);
                } else {
                    crate::ytcvt::add_stream_playing(lib.clone(), app.clone(), url.clone(), play);
                }
                let body = serde_json::json!({ "ok": true, "queued": true, "mode": mode }).to_string();
                respond(&mut out, &body);
            }
        }
        // a streamed row can be kept: download the same page and point the row
        // at the file. the stream keeps playing while it lands.
        "/track/save" => {
            let id: Option<usize> = query_param(query, "id").and_then(|v| v.parse().ok());
            match id {
                Some(id) => {
                    let row = {
                        let l = lib.lock().unwrap();
                        l.tracks.get(id).map(|t| (t.web.clone(), !t.path.is_empty()))
                    };
                    match row {
                        None => respond(&mut out, "{\"ok\":false,\"error\":\"no such track\"}"),
                        Some((_, true)) => respond(
                            &mut out,
                            "{\"ok\":false,\"error\":\"this song is already on disk\"}",
                        ),
                        Some((web, false)) if web.is_empty() => respond(
                            &mut out,
                            "{\"ok\":false,\"error\":\"this row has no web source to save\"}",
                        ),
                        Some(_) => {
                            crate::ytcvt::save_web_row(lib.clone(), app.clone(), id);
                            respond(&mut out, "{\"ok\":true,\"saving\":true}");
                        }
                    }
                }
                None => respond(&mut out, "{\"ok\":false,\"error\":\"need id\"}"),
            }
        }
        "/theme/save" => {
            let raw = query_param(query, "json").unwrap_or_default();
            match serde_json::from_str::<serde_json::Value>(&raw) {
                Ok(mut v) => {
                    let name = v
                        .get("name")
                        .and_then(|x| x.as_str())
                        .unwrap_or("")
                        .trim()
                        .to_string();
                    if name.is_empty() {
                        respond(&mut out, "{\"ok\":false,\"error\":\"the theme needs a name\"}");
                        return;
                    }
                    let slug = query_param(query, "id")
                        .map(|x| slugify(&x))
                        .filter(|x| !x.is_empty())
                        .unwrap_or_else(|| slugify(&name));
                    if slug.is_empty() {
                        respond(&mut out, "{\"ok\":false,\"error\":\"that name has no usable letters\"}");
                        return;
                    }
                    // a theme without a world is still a palette: fill the two
                    // sections the renderer reads so a hand-made file cannot
                    // open a room with nothing in it
                    if !v.get("bg3d").map(|x| x.is_object()).unwrap_or(false) {
                        v["bg3d"] = serde_json::json!({ "archetype": "veil" });
                    }
                    if !v.get("depth").map(|x| x.is_object()).unwrap_or(false) {
                        v["depth"] = serde_json::json!({
                            "shadow": 0.6, "rim": 0.3, "grain": 0.16,
                            "vignette": 0.3, "glass": 0.1, "blur": 0.95
                        });
                    }
                    if !v.get("palette").map(|x| x.is_array()).unwrap_or(false) {
                        let bg = v.get("bg").and_then(|x| x.as_str()).unwrap_or("#05070d");
                        let panel = v.get("panel").and_then(|x| x.as_str()).unwrap_or("#0b1220");
                        let accent = v.get("accent").and_then(|x| x.as_str()).unwrap_or("#00ffa3");
                        v["palette"] = serde_json::json!([bg, panel, accent, accent, accent]);
                    }
                    v["custom"] = serde_json::json!(true);
                    let body = match serde_json::to_string_pretty(&v) {
                        Ok(b) => b,
                        Err(e) => {
                            respond(&mut out, &serde_json::json!({"ok": false, "error": e.to_string()}).to_string());
                            return;
                        }
                    };
                    let path = format!("{THEMES_DIR}/{slug}.json");
                    let tmp = format!("{path}.tmp");
                    if std::fs::create_dir_all(THEMES_DIR).is_err()
                        || std::fs::write(&tmp, body).is_err()
                        || std::fs::rename(&tmp, &path).is_err()
                    {
                        respond(&mut out, "{\"ok\":false,\"error\":\"could not write that theme\"}");
                        return;
                    }
                    let out_body = serde_json::json!({ "ok": true, "id": slug, "name": name }).to_string();
                    respond(&mut out, &out_body);
                }
                Err(e) => {
                    respond(&mut out, &serde_json::json!({"ok": false, "error": e.to_string()}).to_string());
                }
            }
        }
        "/theme/delete" => {
            let name = query_param(query, "name").unwrap_or_default();
            let slug = slugify(&name);
            if slug.is_empty() {
                respond(&mut out, "{\"ok\":false,\"error\":\"need a theme\"}");
                return;
            }
            let wearing = {
                let a = app.lock().unwrap();
                name == a.theme
            };
            if wearing {
                respond(&mut out, "{\"ok\":false,\"error\":\"that theme is wearing right now - switch first\"}");
                return;
            }
            let path = format!("{THEMES_DIR}/{slug}.json");
            match std::fs::remove_file(&path) {
                Ok(()) => respond(&mut out, &serde_json::json!({"ok": true, "id": slug}).to_string()),
                Err(e) => respond(&mut out, &serde_json::json!({"ok": false, "error": e.to_string()}).to_string()),
            }
        }
        "/appearance" => {
            let body = crate::appearance::get_json();
            respond(&mut out, &body);
        }
        "/appearance/set" => {
            let raw = query_param(query, "json").unwrap_or_default();
            match serde_json::from_str::<serde_json::Value>(&raw) {
                Ok(v) => match crate::appearance::save(&v) {
                    Ok(()) => respond(&mut out, "{\"ok\":true}"),
                    Err(e) => {
                        let body = serde_json::json!({"ok": false, "error": e}).to_string();
                        respond(&mut out, &body);
                    }
                },
                Err(e) => {
                    let body = serde_json::json!({"ok": false, "error": e.to_string()}).to_string();
                    respond(&mut out, &body);
                }
            }
        }
        "/accounts" => {
            let body = crate::accounts::status_json(
                crate::stream::available(),
                if crate::stream::available() { "Spotify session linked" } else { "not linked" },
            );
            respond(&mut out, &body);
        }
        "/accounts/save" => {
            let raw = query_param(query, "json").unwrap_or_default();
            match serde_json::from_str::<serde_json::Value>(&raw) {
                Ok(v) => match crate::accounts::save(&v) {
                    Ok(()) => respond(&mut out, "{\"ok\":true}"),
                    Err(e) => {
                        let body = serde_json::json!({"ok": false, "error": e}).to_string();
                        respond(&mut out, &body);
                    }
                },
                Err(e) => {
                    let body = serde_json::json!({"ok": false, "error": e.to_string()}).to_string();
                    respond(&mut out, &body);
                }
            }
        }
        "/accounts/signin" => {
            let p = query_param(query, "provider").unwrap_or_else(|| "youtube".into());
            match crate::accounts::open_signin(&p) {
                Ok(()) => respond(&mut out, "{\"ok\":true}"),
                Err(e) => {
                    let body = serde_json::json!({"ok": false, "error": e}).to_string();
                    respond(&mut out, &body);
                }
            }
        }
        "/accounts/test" => {
            let body = crate::accounts::test_active();
            respond(&mut out, &body);
        }
        // the phone plays what the shelf holds: one row as a byte range, so
        // AVPlayer can stream it over the LAN and seek without downloading
        "/audio" => {
            let row = query_param(query, "id")
                .and_then(|v| v.parse::<usize>().ok())
                .and_then(|id| {
                    let l = lib.lock().unwrap();
                    l.tracks.get(id).map(|t| (t.path.clone(), t.title.clone()))
                });
            let Some((path, title)) = row else {
                respond(&mut out, "{\"ok\":false,\"error\":\"no such track\"}");
                return;
            };
            serve_media(&mut out, &path, &title, range_header.as_deref(), head_only);
        }
        // One route for either kind of row: a file is ranged off the disk, a
        // web row is resolved and relayed. The phone does not have to know
        // which one it tapped.
        "/stream/audio" => {
            let row = query_param(query, "id")
                .and_then(|v| v.parse::<usize>().ok())
                .and_then(|id| {
                    let l = lib.lock().unwrap();
                    l.tracks
                        .get(id)
                        .map(|t| (t.path.clone(), t.web.clone(), t.title.clone()))
                });
            let Some((path, web, title)) = row else {
                respond(&mut out, "{\"ok\":false,\"error\":\"no such track\"}");
                return;
            };
            if !path.is_empty() && std::path::Path::new(&path).is_file() {
                serve_media(&mut out, &path, &title, range_header.as_deref(), head_only);
            } else {
                serve_stream(&mut out, &web, &title, range_header.as_deref(), head_only);
            }
        }
        // A search result that is not in the library yet: the phone hands over
        // the page it found and the bridge relays the song itself.
        "/stream/raw" => {
            let page = query_param(query, "u").unwrap_or_default();
            let title = query_param(query, "t").unwrap_or_default();
            serve_stream(&mut out, &page, &title, range_header.as_deref(), head_only);
        }
        // Searching spawns an extractor, which is the one expensive thing the
        // phone is allowed to ask for. One search every couple of seconds is
        // enough for a human thumb and useless to anything else on the Wi-Fi.
        "/stream/search" => {
            static LAST: Mutex<Option<std::time::Instant>> = Mutex::new(None);
            static CACHE: Mutex<Option<(String, String)>> = Mutex::new(None);
            let q = query_param(query, "q").unwrap_or_default();
            let src = query_param(query, "src").unwrap_or_else(|| "youtube".into());
            let key = format!("{src}\u{1}{}", q.trim().to_lowercase());
            if q.trim().chars().count() < 2 {
                respond(
                    &mut out,
                    "{\"ok\":false,\"error\":\"type at least two letters\"}",
                );
                return;
            }
            // the same search twice in a row (a thumb landing on the button
            // twice) is answered from memory instead of spawning yt-dlp again
            if let Ok(g) = CACHE.lock() {
                if let Some((k, body)) = g.as_ref() {
                    if *k == key {
                        let body = body.clone();
                        drop(g);
                        respond(&mut out, &body);
                        return;
                    }
                }
            }
            let too_soon = {
                let mut g = LAST.lock().unwrap();
                let now = std::time::Instant::now();
                let soon = match *g {
                    Some(t) => now.duration_since(t).as_secs() < 2,
                    None => false,
                };
                if !soon {
                    *g = Some(now);
                }
                soon
            };
            if too_soon {
                respond(
                    &mut out,
                    "{\"ok\":false,\"error\":\"one search every couple of seconds\"}",
                );
                return;
            }
            let body = crate::ytcvt::search_source_json(&q, &src, 10);
            if let Ok(mut g) = CACHE.lock() {
                *g = Some((key, body.clone()));
            }
            respond(&mut out, &body);
        }
        // A search result that should become part of the shared library. It
        // joins as a stream row and is never started on the desktop's deck: the
        // phone is the one that pressed play.
        "/stream/save" => {
            static LAST: Mutex<Option<std::time::Instant>> = Mutex::new(None);
            let url = query_param(query, "url").unwrap_or_default();
            if !url.starts_with("http") {
                respond(&mut out, "{\"ok\":false,\"error\":\"need a page url\"}");
                return;
            }
            let too_soon = {
                let mut g = LAST.lock().unwrap();
                let now = std::time::Instant::now();
                let soon = match *g {
                    Some(t) => now.duration_since(t).as_secs() < 3,
                    None => false,
                };
                if !soon {
                    *g = Some(now);
                }
                soon
            };
            if too_soon {
                respond(
                    &mut out,
                    "{\"ok\":false,\"error\":\"slow down a moment\"}",
                );
                return;
            }
            crate::ytcvt::add_stream_playing(lib.clone(), app.clone(), url, false);
            respond(&mut out, "{\"ok\":true,\"queued\":true}");
        }
        // A link from the phone becomes a room: same importer the desktop uses
        // (cover, name, one song at a time), gated so a LAN peer cannot queue
        // twenty conversions at once.
        "/convert/preview" | "/convert/start" => {
            static LAST: Mutex<Option<std::time::Instant>> = Mutex::new(None);
            let url = query_param(query, "url").unwrap_or_default();
            let name = query_param(query, "name").unwrap_or_default();
            let limit = query_param(query, "limit").and_then(|x| x.parse().ok()).unwrap_or(0);
            let too_soon = {
                let mut g = LAST.lock().unwrap();
                let now = std::time::Instant::now();
                let soon = match *g {
                    Some(t) => now.duration_since(t).as_secs() < 2,
                    None => false,
                };
                if !soon {
                    *g = Some(now);
                }
                soon
            };
            if too_soon {
                respond(
                    &mut out,
                    "{\"ok\":false,\"error\":\"one conversion at a time\"}",
                );
                return;
            }
            let body = if path == "/convert/preview" {
                crate::playlist_import::preview_json(&url, limit)
            } else {
                crate::playlist_import::start(&url, &name, limit, lib.clone(), app.clone())
            };
            respond(&mut out, &body);
        }
        "/convert/status" => {
            respond(&mut out, &crate::playlist_import::status_json());
        }
        // A room is a playlist file. The phone may read one and stream its
        // rows without making it the desktop's open playlist, so browsing on
        // the phone never moves the desktop's deck: two harnesses, one library.
        "/room" => {
            let id = query_param(query, "id").unwrap_or_default();
            match room_file(&id, lib) {
                Some(p) => match room_json(&p) {
                    Ok(body) => respond(&mut out, &body),
                    Err(e) => {
                        let body = serde_json::json!({"ok": false, "error": e}).to_string();
                        respond(&mut out, &body);
                    }
                },
                None => respond(&mut out, "{\"ok\":false,\"error\":\"no such room\"}"),
            }
        }
        "/room/audio" => {
            let id = query_param(query, "id").unwrap_or_default();
            let row: usize = query_param(query, "row")
                .and_then(|v| v.parse().ok())
                .unwrap_or(usize::MAX);
            // path or page: a room can hold both, and the phone asks the same
            // question either way
            let found = room_file(&id, lib)
                .and_then(|p| std::fs::read_to_string(&p).ok())
                .and_then(|b| serde_json::from_str::<serde_json::Value>(&b).ok())
                .and_then(|v| {
                    v.get("tracks")
                        .and_then(|x| x.as_array())
                        .and_then(|a| a.get(row))
                        .map(|t| {
                            let path = t.get("path").and_then(|x| x.as_str()).unwrap_or("");
                            let web = t
                                .get("web")
                                .or_else(|| t.get("uri"))
                                .and_then(|x| x.as_str())
                                .filter(|s| s.starts_with("http"))
                                .unwrap_or("");
                            let title = t.get("title").and_then(|x| x.as_str()).unwrap_or("");
                            (path.to_string(), web.to_string(), title.to_string())
                        })
                });
            let Some((path, web, title)) = found else {
                respond(&mut out, "{\"ok\":false,\"error\":\"no such row\"}");
                return;
            };
            if !path.is_empty() && std::path::Path::new(&path).is_file() {
                serve_media(&mut out, &path, &title, range_header.as_deref(), head_only);
            } else {
                serve_stream(&mut out, &web, &title, range_header.as_deref(), head_only);
            }
        }
        // Covers are files on the PC, and the phone cannot open a file:// URL.
        // Serve the same bytes over HTTP, restricted to the content-addressed
        // cover cache so a crafted path cannot read anything else on the disk.
        "/cover" | "/art" => {
            let raw = query_param(query, "path")
                .or_else(|| query_param(query, "p"))
                .or_else(|| query_param(query, "u"))
                .unwrap_or_default();
            let mut rendered = raw.trim().to_string();
            if let Some(rest) = rendered.strip_prefix("file://") {
                rendered = rest.to_string();
            } else if let Some(rest) = rendered.strip_prefix("file:/") {
                rendered = rest.to_string();
            }
            // file URLs carry a leading slash before the drive letter
            if rendered.len() > 2
                && rendered.starts_with('/')
                && rendered.as_bytes().get(2) == Some(&b':')
            {
                rendered.remove(0);
            }
            let path = std::path::PathBuf::from(&rendered);
            let root = std::path::Path::new(concat!(env!("AETHER_ROOT"), "/cache/covers"));
            let inside = match (std::fs::canonicalize(&path), std::fs::canonicalize(root)) {
                (Ok(c), Ok(r)) => c.starts_with(r),
                _ => false,
            };
            let image_ext = path
                .extension()
                .and_then(|e| e.to_str())
                .map(|e| matches!(e.to_ascii_lowercase().as_str(), "jpg" | "jpeg" | "png" | "webp" | "gif"))
                .unwrap_or(false);
            if !inside || !image_ext {
                let head = "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: 34\r\nConnection: close\r\n\r\n{\"ok\":false,\"error\":\"not a cover\"}";
                let _ = out.write_all(head.as_bytes());
                let _ = out.flush();
                return;
            }
            match std::fs::read(path) {
                Ok(bytes) => {
                    let mime = image_mime(&bytes);
                    let head = format!(
                        "HTTP/1.1 200 OK\r\nContent-Type: {mime}\r\nContent-Length: {}\r\nCache-Control: public, max-age=86400\r\nConnection: close\r\n\r\n",
                        bytes.len()
                    );
                    if out.write_all(head.as_bytes()).is_ok() && !head_only {
                        let _ = out.write_all(&bytes);
                    }
                    let _ = out.flush();
                }
                Err(_) => {
                    let head = "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: 27\r\nConnection: close\r\n\r\n{\"ok\":false,\"error\":\"no file\"}";
                    let _ = out.write_all(head.as_bytes());
                    let _ = out.flush();
                }
            }
        }
        "/thumb" => {
            let url = query_param(query, "u").unwrap_or_default();
            eprintln!("[thumb] request {}", &url.chars().take(80).collect::<String>());
            match cached_thumb(&url) {
                Some(b) => {
                    let mime = image_mime(&b);
                    respond_bytes(&mut out, mime, &b);
                }
                None => respond(&mut out, "{\"ok\":false}"),
            }
        }
        "/backdrop/prepare" => {
            let url = query_param(query, "url").unwrap_or_default();
            let body = crate::ytcvt::prepare_backdrop(&url);
            respond(&mut out, &body);
        }
        "/backdrop/status" => {
            let body = crate::ytcvt::backdrop_status();
            respond(&mut out, &body);
        }
        "/backdrop/library" => {
            let body = crate::ytcvt::backdrop_library();
            respond(&mut out, &body);
        }
        "/live" => {
            let body = serde_json::json!({
                "active": crate::live::active(),
                "playing": crate::live::is_playing(),
                "pos": crate::live::position_ms(),
                "dur": crate::live::duration_ms(),
                "label": crate::live::now_label(),
            })
            .to_string();
            respond(&mut out, &body);
        }
        "/youtube/status" => {
            let body = crate::ytcvt::add_status_json();
            respond(&mut out, &body);
        }
        "/playlist/add_spotify" => {
            let raw = query_param(query, "url").unwrap_or_default();
            let Some(uri) = spotify_uri(&raw) else {
                respond(&mut out, "{\"ok\":false,\"error\":\"bad spotify track link\"}");
                return;
            };
            // known catalog rows already have the real artist/cover
            let known = {
                let l = lib.lock().unwrap();
                l.tracks
                    .iter()
                    .find(|t| t.uri == uri)
                    .map(|t| (t.title.clone(), t.artist.clone(), t.cover_file.clone()))
            };
            let (title, artist, cover) = match known {
                Some(v) => v,
                None => {
                    let body = ureq::get(&format!(
                        "https://open.spotify.com/oembed?url={}",
                        uri.replace(':', "%3A")
                    ))
                    .timeout(Duration::from_secs(8))
                    .set("User-Agent", "Mozilla/5.0 AetherMix/0.5")
                    .call()
                    .ok()
                    .and_then(|r| r.into_string().ok())
                    .unwrap_or_default();
                    let v: serde_json::Value = serde_json::from_str(&body).unwrap_or_default();
                    let t = v.get("title").and_then(|x| x.as_str()).unwrap_or("untitled").to_string();
                    let c = v.get("thumbnail_url").and_then(|x| x.as_str()).unwrap_or("").to_string();
                    (t, "Spotify".to_string(), c)
                }
            };
            let mut l = lib.lock().unwrap();
            let id = l.add_track(&title, &artist, "", 0, "", &uri, "", &cover);
            l.save_playlist();
            let ver = l.version;
            drop(l);
            app.lock().unwrap().library_version = ver;
            respond(&mut out, &serde_json::json!({"ok": true, "id": id}).to_string());
        }
        "/playlist/add_local" => {
            let path = query_param(query, "path").unwrap_or_default();
            let p = std::path::Path::new(&path);
            let allowed = path
                .replace('\\', "/")
                .to_lowercase()
                .starts_with("c:/users/owner/downloads/")
                || path
                    .replace('\\', "/")
                    .to_lowercase()
                    .starts_with("c:/users/owner/music/");
            if !allowed || !p.is_file() {
                respond(&mut out, "{\"ok\":false,\"error\":\"file must live in Downloads or Music\"}");
            } else if let Some(meta) = crate::library::probe_file(&path) {
                let mut l = lib.lock().unwrap();
                let id = l.add_track(
                    &meta.title,
                    &meta.artist,
                    &meta.album,
                    meta.duration_ms,
                    &path,
                    "",
                    "",
                    "",
                );
                l.save_playlist();
                let v = l.version;
                drop(l);
                app.lock().unwrap().library_version = v;
                let body = serde_json::json!({"ok": true, "id": id}).to_string();
                respond(&mut out, &body);
            } else {
                respond(&mut out, "{\"ok\":false,\"error\":\"could not read audio tags\"}");
            }
        }
        "/engine" => {
            let ram_mb = process_ram_mb();
            let (qlen, tracks) = {
                let p = pst.lock().unwrap();
                let n = lib.lock().unwrap().tracks.len();
                (p.queue.len(), n)
            };
            let body = serde_json::json!({
                "version": "0.5.0",
                "ram_mb": ram_mb,
                "underruns": core.underruns.load(Ordering::Relaxed),
                "streaming": crate::stream::available(),
                "queue_len": qlen,
                "tracks": tracks,
            })
            .to_string();
            respond(&mut out, &body);
        }
        "/spotify/library" => {
            let body = crate::stream::api_get("/v1/me/tracks?limit=50", 8).unwrap_or_default();
            respond(&mut out, &slim_tracks(&body, "/items"));
        }
        "/spotify/search" => {
            let q = query_param(query, "q").unwrap_or_default();
            if q.is_empty() {
                respond(&mut out, "{\"tracks\":[]}");
            } else {
                let path = format!("/v1/search?type=track&limit=12&q={}", urlencode(&q));
                let body = crate::stream::api_get(&path, 8).unwrap_or_default();
                respond(&mut out, &slim_tracks(&body, "/tracks/items"));
            }
        }
        "/spotify/add" => {
            let uri = query_param(query, "uri").unwrap_or_default();
            if !uri.starts_with("spotify:track:") {
                respond(&mut out, "{\"ok\":false,\"error\":\"bad uri\"}");
            } else {
                let pid = crate::catalog::playlist_id(&crate::catalog::playlist_url())
                    .unwrap_or_default();
                if pid.is_empty() {
                    respond(&mut out, "{\"ok\":false,\"error\":\"no playlist\"}");
                } else {
                    let body = format!("{{\"uris\":[\"{uri}\"]}}");
                    match crate::stream::api_post(&format!("/v1/playlists/{pid}/tracks"), &body, 8) {
                        Some((code, text)) => {
                            eprintln!("[api] add -> {code} {text}");
                            if (200..300).contains(&code) {
                                let lib2 = lib.clone();
                                let app2 = app.clone();
                                std::thread::spawn(move || {
                                    crate::catalog::sync_once(&lib2, &app2);
                                });
                                respond(&mut out, "{\"ok\":true}");
                            } else if code == 403 {
                                respond(&mut out, "{\"ok\":false,\"error\":\"needs full access - hit GRANT in settings and re-authorize\"}");
                            } else {
                                respond(&mut out, &format!("{{\"ok\":false,\"error\":\"http {code}\"}}"));
                            }
                        }
                        None => respond(&mut out, "{\"ok\":false,\"error\":\"api unavailable\"}"),
                    }
                }
            }
        }
        "/spotify/suggest" => {
            let seed = {
                let a = app.lock().unwrap();
                let l = lib.lock().unwrap();
                a.track_id
                    .and_then(|id| l.tracks.get(id))
                    .map(|t| t.uri.clone())
                    .unwrap_or_default()
            };
            let pl = crate::catalog::playlist_url();
            let app2 = app.clone();
            std::thread::spawn(move || {
                crate::stream::refresh_suggestions_capped(&seed, &pl);
            });
            // current pool snapshot for the UI
            let pool: Vec<serde_json::Value> = crate::stream::SUGGESTIONS
                .lock()
                .map(|g| {
                    g.iter()
                        .map(|s| {
                            serde_json::json!({
                                "uri": s.uri, "title": s.title, "artist": s.artist,
                                "cover": s.cover, "duration_ms": s.duration_ms,
                            })
                        })
                        .collect()
                })
                .unwrap_or_default();
            respond(&mut out, &serde_json::json!({ "tracks": pool }).to_string());
        }
        "/lyricoffset" => {
            // with an id: nudge THIS song (delta or absolute ms). without one:
            // the global default, the way every earlier build did it.
            let id = query_param(query, "id").and_then(|v| v.parse::<usize>().ok());
            let delta = query_param(query, "delta").and_then(|v| v.parse::<i64>().ok());
            let abs = query_param(query, "ms").and_then(|v| v.parse::<i64>().ok());
            match id {
                Some(id) => {
                    let key = {
                        let l = lib.lock().unwrap();
                        l.tracks.get(id).map(|t| crate::state::song_key(&t.title, &t.artist))
                    };
                    let Some(key) = key else {
                        respond(&mut out, "{\"ok\":false,\"error\":\"no such track\"}");
                        return;
                    };
                    let base = crate::state::lyric_offset_for(&key).unwrap_or(0);
                    let next = match (abs, delta) {
                        (Some(a), _) => a,
                        (None, Some(d)) => base + d,
                        _ => base,
                    };
                    let next = next.clamp(-30000, 30000);
                    crate::state::set_lyric_offset_for(&key, next);
                    let body = serde_json::json!({"ok": true, "offset_ms": next}).to_string();
                    respond(&mut out, &body);
                }
                None => {
                    if let Some(ms) = abs {
                        crate::state::set_config_str("lyric_offset_ms", &ms.to_string());
                        if let Ok(mut a) = app.lock() {
                            a.lyric_offset_ms = ms;
                        }
                        respond(&mut out, "{\"ok\":true}");
                    } else {
                        respond(&mut out, "{\"ok\":false}");
                    }
                }
            }
        }
        "/stats" => {
            respond(&mut out, &crate::state::stats_snapshot().to_string());
        }
        // ---- liked songs ----
        "/favorite" => {
            let id = query_param(query, "id").and_then(|v| v.parse::<usize>().ok());
            let Some(id) = id else {
                respond(&mut out, "{\"ok\":false,\"error\":\"missing id\"}");
                return;
            };
            let found = {
                let l = lib.lock().unwrap();
                l.tracks.get(id).map(|t| {
                    (
                        crate::state::song_key(&t.title, &t.artist),
                        t.title.clone(),
                        t.artist.clone(),
                    )
                })
            };
            let Some((key, title, artist)) = found else {
                respond(&mut out, "{\"ok\":false,\"error\":\"no such track\"}");
                return;
            };
            // no `on` argument means "flip it", which is what a heart button
            // wants; an explicit 0/1 is what a menu wants
            let on = match query_param(query, "on") {
                Some(v) => v == "1" || v == "true",
                None => !crate::state::is_favorite(&key),
            };
            crate::state::set_favorite(&key, on);
            app.lock().unwrap().status = format!(
                "{} \"{}\"",
                if on { "liked" } else { "removed from liked" },
                title
            );
            let body = serde_json::json!({
                "ok": true, "liked": on, "key": key, "title": title, "artist": artist
            })
            .to_string();
            respond(&mut out, &body);
        }
        "/favorites" => {
            let set = crate::state::favorites();
            let body = serde_json::json!({
                "count": set.len(),
                "keys": set.iter().collect::<Vec<_>>(),
            })
            .to_string();
            respond(&mut out, &body);
        }
        // ---- one row in full: the sheet behind a long press ----
        "/track/info" => {
            let id = query_param(query, "id").and_then(|v| v.parse::<usize>().ok());
            let info = id.and_then(|id| {
                let l = lib.lock().unwrap();
                l.tracks.get(id).map(|t| {
                    let p = std::path::Path::new(&t.path);
                    let meta = std::fs::metadata(p).ok();
                    serde_json::json!({
                        "id": t.id,
                        "title": t.title,
                        "artist": t.artist,
                        "album": t.album,
                        "origin": t.origin,
                        "duration_ms": t.duration_ms,
                        "path": t.path,
                        "exists": p.is_file(),
                        "size": meta.as_ref().map(|m| m.len()).unwrap_or(0),
                        "format": p.extension().and_then(|e| e.to_str()).unwrap_or("").to_uppercase(),
                        "plays": crate::state::plays_of(t.id),
                        "liked": crate::state::is_favorite(&crate::state::song_key(&t.title, &t.artist)),
                        "streamable": !t.uri.is_empty(),
                    })
                })
            });
            match info {
                Some(v) => respond(&mut out, &v.to_string()),
                None => respond(&mut out, "{\"ok\":false,\"error\":\"no such track\"}"),
            }
        }
        "/track/reveal" => {
            let path = query_param(query, "id")
                .and_then(|v| v.parse::<usize>().ok())
                .and_then(|id| {
                    let l = lib.lock().unwrap();
                    l.tracks.get(id).map(|t| t.path.clone())
                })
                .unwrap_or_default();
            if path.is_empty() {
                respond(&mut out, "{\"ok\":false,\"error\":\"this row has no file\"}");
                return;
            }
            let win = path.replace('/', "\\");
            let ok = crate::library::reveal_in_explorer(&win);
            respond(&mut out, &serde_json::json!({"ok": ok}).to_string());
        }
        // ---- playlists on disk: an m3u of this room, and reading one back ----
        "/playlist/export" => {
            let (name, rows) = {
                let l = lib.lock().unwrap();
                (
                    l.playlist_name.clone(),
                    l.tracks
                        .iter()
                        .map(|t| {
                            (
                                t.title.clone(),
                                t.artist.clone(),
                                t.duration_ms,
                                if t.path.is_empty() { t.uri.clone() } else { t.path.clone() },
                            )
                        })
                        .collect::<Vec<_>>(),
                )
            };
            match crate::library::export_m3u(&name, &rows) {
                Ok(path) => {
                    app.lock().unwrap().status = format!("exported to {path}");
                    respond(
                        &mut out,
                        &serde_json::json!({"ok": true, "path": path, "rows": rows.len()})
                            .to_string(),
                    );
                }
                Err(e) => respond(
                    &mut out,
                    &serde_json::json!({"ok": false, "error": e}).to_string(),
                ),
            }
        }
        "/playlist/import/m3u" => {
            let path = query_param(query, "path").unwrap_or_default();
            if path.len() < 4 {
                respond(&mut out, "{\"ok\":false,\"error\":\"need a .m3u path\"}");
                return;
            }
            let paths = crate::library::read_m3u(&path);
            if paths.is_empty() {
                respond(&mut out, "{\"ok\":false,\"error\":\"no playable lines in that file\"}");
                return;
            }
            let mut missing = 0usize;
            let mut l = lib.lock().unwrap();
            // add_track de-duplicates by path/name, so counting attempts would
            // claim songs that were already there. measure the real delta - and
            // measure it in playlist rows, not in library rows: a file already
            // in the vault is not a new row, it is an existing row joining the
            // list, which is exactly what the caller asked for.
            let before = l.tracks.iter().filter(|t| t.origin == "playlist").count();
            for p in paths.iter() {
                if !std::path::Path::new(p).is_file() {
                    missing += 1;
                    continue;
                }
                if let Some(meta) = crate::library::probe_file(p) {
                    l.add_track(
                        &meta.title,
                        &meta.artist,
                        &meta.album,
                        meta.duration_ms,
                        p,
                        "",
                        "",
                        "",
                    );
                } else {
                    missing += 1;
                }
            }
            let added = l
                .tracks
                .iter()
                .filter(|t| t.origin == "playlist")
                .count()
                .saturating_sub(before);
            l.save_playlist();
            let v = l.version;
            drop(l);
            app.lock().unwrap().library_version = v;
            let body = serde_json::json!({"ok": true, "added": added, "missing": missing})
                .to_string();
            respond(&mut out, &body);
        }
        // one tiny key/value door for preferences that have no panel of their
        // own yet (global keys, and whatever comes next)
        "/config" => {
            let k = query_param(query, "k").unwrap_or_default();
            if k.is_empty() {
                respond(&mut out, "{\"ok\":false,\"error\":\"need k\"}");
                return;
            }
            // no `v` means read: the browser keeps its history and bookmarks in
            // the same key/value store as every other preference
            let v = match query_param(query, "v") {
                Some(v) => v,
                None => {
                    let cur = crate::state::config_str(&k).unwrap_or_default();
                    let body = serde_json::json!({"ok": true, "key": k, "value": cur}).to_string();
                    respond(&mut out, &body);
                    return;
                }
            };
            crate::state::set_config_str(&k, &v);
            respond(&mut out, &serde_json::json!({"ok": true, "key": k, "value": v}).to_string());
        }
        "/sleep" => {
            // `s` is seconds, `m` minutes (the settings chips), `fade` the ramp
            // in ms (default 20 s). the timer ramps the output down, pauses,
            // and puts the volume back so the room is not left silent.
            let secs = query_param(query, "s")
                .and_then(|v| v.parse::<u64>().ok())
                .or_else(|| query_param(query, "m").and_then(|v| v.parse::<u64>().ok()).map(|m| m * 60))
                .unwrap_or(0);
            let fade = query_param(query, "fade")
                .and_then(|v| v.parse::<u64>().ok())
                .unwrap_or(20_000)
                .min(secs.saturating_mul(1000));
            // a new request replaces the old timer, and a cancel must put the
            // volume back if the ramp had already begun
            crate::state::sleep_cancel_restore(&core, &app);
            let ms = crate::state::sleep_start(&core, &app, PLAYER_TX.get().cloned(), secs, fade);
            let body = serde_json::json!({
                "ok": true, "ms": ms, "fade_ms": fade, "cleared": ms == 0
            })
            .to_string();
            respond(&mut out, &body);
        }
        "/convert/start" => {
            crate::ytcvt::start_convert(lib.clone(), app.clone());
            respond(&mut out, "{\"ok\":true}");
        }
        "/convert/covers" => {
            crate::ytcvt::backfill_covers(lib.clone());
            crate::ytcvt::repair_covers(lib.clone(), app.clone());
            respond(&mut out, "{\"ok\":true}");
        }
        "/convert/one" => {
            let id = query_param(query, "id").and_then(|v| v.parse::<usize>().ok()).unwrap_or(usize::MAX);
            if id != usize::MAX {
                crate::ytcvt::convert_one(lib.clone(), id);
                respond(&mut out, "{\"ok\":true}");
            } else {
                respond(&mut out, "{\"ok\":false}");
            }
        }
        "/convert/status" => {
            respond(&mut out, &crate::ytcvt::status_snapshot().to_json());
        }
        "/shell/on" => {
            let mut app2 = app.lock().unwrap();
            app2.shell_mode = true;
            app2.status = "shell mode on - controlling the official Spotify client".into();
            respond(&mut out, "{\"ok\":true}");
        }
        "/shell/off" => {
            let mut app2 = app.lock().unwrap();
            app2.shell_mode = false;
            app2.status = "shell mode off".into();
            respond(&mut out, "{\"ok\":true}");
        }
        "/shell/state" => {
            respond(&mut out, &crate::shell::now_playing().to_string());
        }
        "/shell/devices" => {
            match crate::shell::devices() {
                Ok(devs) => {
                    let items: Vec<serde_json::Value> = devs
                        .iter()
                        .map(|d| serde_json::json!({"id": d.id, "name": d.name, "type": d.kind, "active": d.active}))
                        .collect();
                    respond(&mut out, &serde_json::json!({"devices": items}).to_string());
                }
                Err(e) => respond(&mut out, &serde_json::json!({"devices": [], "error": e}).to_string()),
            }
        }
        "/page" => {
            if let Some(n) = query_param(query, "n").and_then(|v| v.parse::<i64>().ok()) {
                app.lock().unwrap().page = n;
                respond(&mut out, "{\"ok\":true}");
            } else {
                respond(&mut out, "{\"ok\":false}");
            }
        }
        "/catalog/sync" => {
            // background thread: the API path may wait out a rate limit (up to minutes)
            let lib2 = lib.clone();
            let app2 = app.clone();
            std::thread::spawn(move || {
                let r = crate::catalog::sync_once(&lib2, &app2);
                if r.ok {
                    let mut s = app2.lock().unwrap();
                    s.status = if r.added > 0 {
                        format!("sync: +{} new", r.added)
                    } else {
                        "sync: up to date".into()
                    };
                }
            });
            respond(&mut out, "{\"ok\":true,\"async\":true}");
        }
        "/rescan" => {
            // a rescan renumbers every row, so the deck's id - and every id in
            // the queue - stops meaning what it meant a moment ago. The audio
            // itself is untouched (the engine holds a path), so the fix is to
            // re-point the bookkeeping at the same file instead of letting the
            // ui announce a different song than the one coming out of the
            // speakers.
            let playing_path = pst.lock().map(|p| p.cur_path.clone()).unwrap_or_default();
            {
                let mut l = lib.lock().unwrap();
                l.invalidate_local_cache();
                l.load_all();
            }
            let v = lib.lock().unwrap().version;
            app.lock().unwrap().library_version = v;
            if !playing_path.is_empty() {
                let found = {
                    let l = lib.lock().unwrap();
                    l.tracks
                        .iter()
                        .find(|t| crate::library::same_path(&t.path, &playing_path))
                        .map(|t| {
                            let ids: Vec<usize> = l
                                .tracks
                                .iter()
                                .filter(|x| x.origin == "playlist")
                                .map(|x| x.id)
                                .collect();
                            (t.id, ids)
                        })
                };
                if let Some((id, ids)) = found {
                    if let Ok(mut p) = pst.lock() {
                        p.current_id = Some(id);
                        p.pos = ids.iter().position(|&x| x == id).unwrap_or(0);
                        p.queue = ids;
                        p.smart_remaining.clear();
                    }
                }
            }
            respond(&mut out, "{\"ok\":true}");
        }
        _ => {
            respond(&mut out, "{\"ok\":false,\"error\":\"not found\"}");
        }
    }
}

// switching/creating a playlist changes every track id, so stop the old queue
// instead of letting it point at rows that now belong to someone else.
fn reset_playback(app: &Arc<Mutex<AppState>>, pst: &Arc<Mutex<PlayerState>>) {
    if let Some(tx) = PLAYER_TX.get() {
        let _ = tx.send(PlayerCmd::Stop);
    }
    {
        let mut p = pst.lock().unwrap();
        p.queue.clear();
        p.pos = 0;
        p.pending_override = None;
        p.current_id = None;
        p.cur_path.clear();
        p.streaming = false;
    }
    {
        let mut s = app.lock().unwrap();
        s.track_id = None;
        s.title.clear();
        s.artist.clear();
        s.album.clear();
        s.cover_url.clear();
        s.origin.clear();
        s.status = "playlist switched".into();
    }
}

fn spotify_uri(raw: &str) -> Option<String> {
    if let Some(rest) = raw.strip_prefix("spotify:track:") {
        let id: String = rest.chars().take_while(|c| c.is_ascii_alphanumeric()).collect();
        if !id.is_empty() {
            return Some(format!("spotify:track:{id}"));
        }
    }
    if let Some(pos) = raw.find("/track/") {
        let id: String = raw[pos + 7..]
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric())
            .collect();
        if !id.is_empty() {
            return Some(format!("spotify:track:{id}"));
        }
    }
    None
}

fn urlencode(x: &str) -> String {
    let mut out = String::new();
    for b in x.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*b as char)
            }
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

// slim track json from any Web API "track" object
// spotify rows shaped like every other source, so one results list can mix
// youtube, soundcloud and a signed-in spotify without special cases
fn spotify_results(body: &str) -> String {
    let v: serde_json::Value = serde_json::from_str(body).unwrap_or_default();
    let Some(arr) = v
        .pointer("/tracks/items")
        .and_then(|x| x.as_array())
    else {
        return serde_json::json!({"results": []}).to_string();
    };
    let mut out = Vec::new();
    for t in arr {
        let uri = t.get("uri").and_then(|x| x.as_str()).unwrap_or("");
        if !uri.starts_with("spotify:track:") {
            continue;
        }
        let id = uri.rsplit(':').next().unwrap_or("");
        out.push(serde_json::json!({
            "id": id,
            "source": "spotify",
            "uri": uri,
            "url": uri,
            "title": t.get("name").and_then(|x| x.as_str()).unwrap_or(""),
            "artist": t.get("artists").and_then(|a| a.as_array()).map(|a| a
                .iter().filter_map(|x| x.get("name").and_then(|n| n.as_str()))
                .collect::<Vec<_>>().join(", ")).unwrap_or_default(),
            "thumb": t.pointer("/album/images/0/url").and_then(|x| x.as_str()).unwrap_or(""),
            "duration_ms": t.get("duration_ms").and_then(|x| x.as_u64()).unwrap_or(0),
        }));
    }
    serde_json::json!({"results": out}).to_string()
}

fn slim_tracks(body: &str, pointer: &str) -> String {
    let v: serde_json::Value = match serde_json::from_str(body) {
        Ok(v) => v,
        Err(_) => return "{}".into(),
    };
    let arr = match v.pointer(pointer).and_then(|x| x.as_array()) {
        Some(a) => a,
        None => return "{}".into(),
    };
    let mut out = Vec::new();
    for t in arr {
        let uri = t.get("uri").and_then(|x| x.as_str()).unwrap_or("");
        if !uri.starts_with("spotify:track:") {
            continue;
        }
        out.push(serde_json::json!({
            "uri": uri,
            "title": t.get("name").and_then(|x| x.as_str()).unwrap_or(""),
            "artist": t.get("artists").and_then(|a| a.as_array()).map(|a| a
                .iter().filter_map(|x| x.get("name").and_then(|n| n.as_str()))
                .collect::<Vec<_>>().join(", ")).unwrap_or_else(|| "".into()),
            "cover": t.pointer("/album/images/0/url").and_then(|x| x.as_str()).unwrap_or(""),
            "duration_ms": t.get("duration_ms").and_then(|x| x.as_u64()).unwrap_or(0),
        }));
    }
    serde_json::json!({ "tracks": out }).to_string()
}

// engine stats via raw FFI (no extra crates)
#[cfg(windows)]
mod winffi {
    #[repr(C)]
    #[derive(Default)]
    pub struct ProcessMemoryCounters {
        pub cb: u32,
        pub page_fault_count: u32,
        pub peak_working_set_size: u64,
        pub working_set_size: u64,
        pub quota_peak_paged_pool_usage: u64,
        pub quota_paged_pool_usage: u64,
        pub quota_peak_non_paged_pool_usage: u64,
        pub quota_non_paged_pool_usage: u64,
        pub pagefile_usage: u64,
        pub peak_pagefile_usage: u64,
    }
    #[link(name = "kernel32")]
    extern "system" {
        pub fn GetCurrentProcess() -> *mut core::ffi::c_void;
    }
    #[link(name = "psapi")]
    extern "system" {
        pub fn GetProcessMemoryInfo(
            process: *mut core::ffi::c_void,
            counters: *mut ProcessMemoryCounters,
            cb: u32,
        ) -> i32;
    }
}

#[cfg(windows)]
fn process_ram_mb() -> u64 {
    unsafe {
        let mut pmc = winffi::ProcessMemoryCounters::default();
        pmc.cb = std::mem::size_of::<winffi::ProcessMemoryCounters>() as u32;
        let h = winffi::GetCurrentProcess();
        if winffi::GetProcessMemoryInfo(h, &mut pmc, pmc.cb) != 0 {
            pmc.working_set_size / (1024 * 1024)
        } else {
            0
        }
    }
}

// Which matcher wrote a cached lyric answer. Bumped whenever the search gets
// better, so "we found nothing" answers from an older version are retried
// instead of being trusted for a week. Real lyrics never need a retry.
const LYRICS_MATCHER: u64 = 2;

// lyrics: local tags/lrc first, then lrclib (public, no auth) with a disk cache
fn lyrics_for_track(
    lib: &Arc<Mutex<Library>>,
    id: usize,
    refresh: bool,
) -> (String, bool) {
    let (lyrics, synced) = lib.lock().unwrap().lyrics_for(id);
    if !lyrics.is_empty() {
        return (lyrics, synced);
    }
    let meta = {
        let l = lib.lock().unwrap();
        l.tracks
            .get(id)
            .map(|t| (t.title.clone(), t.artist.clone(), t.album.clone(), t.duration_ms))
    };
    let Some((title, artist, album, duration_ms)) = meta else {
        return (String::new(), false);
    };
    lyrics_named(&title, &artist, &album, duration_ms, refresh)
}

/// The words for a song the library may not hold yet - a row the phone found
/// on the web a second ago, or one that is still landing. Everything is keyed
/// by title+artist, so being in the shelf was never what the cache needed.
fn lyrics_named(
    title: &str,
    artist: &str,
    album: &str,
    duration_ms: u32,
    refresh: bool,
) -> (String, bool) {
    let dir = concat!(env!("AETHER_ROOT"), "/cache/lyrics");
    let _ = std::fs::create_dir_all(dir);
    // lyrics are keyed by song identity, never by its transient playlist id:
    // ids shift when the playlist changes and that made caches point at the
    // wrong song (the reason synced lines could drift away from the audio).
    let key = crate::state::song_key(title, artist);
    let cpath = format!("{dir}/{key}.json");
    if !refresh {
        if let Ok(body) = std::fs::read_to_string(&cpath) {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&body) {
                if v.get("miss").and_then(|m| m.as_bool()).unwrap_or(false) {
                    // a miss recorded by a weaker matcher (one that could not
                    // strip "feat_" or an uploader prefix) is not an answer, it
                    // is the old question. Retry it immediately instead of
                    // leaving the song wordless until the week runs out.
                    let old = v.get("v").and_then(|x| x.as_u64()).unwrap_or(0);
                    if old < LYRICS_MATCHER {
                        let _ = std::fs::remove_file(&cpath);
                    } else {
                    // a miss is not forever: lrclib grows every day, so retry
                    // after a week instead of burying the song for good
                    let at = v.get("t").and_then(|x| x.as_u64()).unwrap_or(0);
                    let now = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.as_secs())
                        .unwrap_or(0);
                    if now.saturating_sub(at) < 7 * 24 * 3600 {
                        return (String::new(), false);
                    }
                    }
                } else {
                    return (
                        v.get("lyrics").and_then(|x| x.as_str()).unwrap_or("").to_string(),
                        v.get("synced").and_then(|x| x.as_bool()).unwrap_or(false),
                    );
                }
            }
        }
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    match crate::catalog::fetch_lrclib(title, artist, album, duration_ms) {
        Some((ly, sy)) => {
            let _ = std::fs::write(
                &cpath,
                serde_json::json!({ "lyrics": ly, "synced": sy, "t": now, "v": LYRICS_MATCHER }).to_string(),
            );
            (ly, sy)
        }
        None => {
            let _ = std::fs::write(
                &cpath,
                serde_json::json!({ "miss": true, "t": now, "v": LYRICS_MATCHER }).to_string(),
            );
            (String::new(), false)
        }
    }
}

// the "where the room was left" chip. Reading this 90-byte file per poll is
// cheaper than a cache that goes stale the moment a song starts - and the
// stale version hid the resume point for a whole track.
fn resume_json() -> serde_json::Value {
    match crate::state::load_resume() {
        Some(r) => serde_json::json!({
            "id": r.id, "pos_ms": r.pos_ms, "title": r.title,
            "artist": r.artist, "key": r.key,
        }),
        None => serde_json::Value::Null,
    }
}

pub fn start(
    app: Arc<Mutex<AppState>>,
    core: Arc<Core>,
    lib: Arc<Mutex<Library>>,
    pst: Arc<Mutex<PlayerState>>,
) {
    std::thread::Builder::new()
        .name("http".into())
        .spawn(move || {
            let host = if lan_enabled() { "0.0.0.0" } else { "127.0.0.1" };
            let listener = match TcpListener::bind((host, PORT)) {
                Ok(l) => l,
                Err(first) => {
                    // stale instance may hold the port: try to evict it, then retry
                    eprintln!("[http] port {PORT} busy ({first}) - evicting stale instance");
                    let me = std::process::id();
                    if let Ok(entries) = std::fs::read_dir("C:/Windows/System32") { let _ = entries; }
                    for procid in stale_aethermix_pids(me) {
                        let h = open_process_for_kill(procid);
                        if !h.is_null() {
                            unsafe {
                                windows_sys::Win32::System::Threading::TerminateProcess(h, 1);
                                let _ = windows_sys::Win32::Foundation::CloseHandle(h);
                            }
                        }
                    }
                    std::thread::sleep(std::time::Duration::from_millis(800));
                    match TcpListener::bind((host, PORT)) {
                        Ok(l) => {
                            eprintln!("[http] port recovered after eviction");
                            l
                        }
                        Err(e2) => {
                            eprintln!("[http] bind still failing after eviction: {e2} - REBOOT recommended (kernel-stuck instance)");
                            return;
                        }
                    }
                }
            };
            if lan_enabled() {
                match lan_ip() {
                    Some(ip) => {
                        eprintln!("[http] bridge live on 0.0.0.0:{PORT}");
                        eprintln!("[http] phone: http://{ip}:{PORT}");
                    }
                    None => eprintln!("[http] bridge live on 0.0.0.0:{PORT} (no LAN address)"),
                }
            } else {
                eprintln!("[http] bridge live on 127.0.0.1:{PORT} (AETHER_LAN=0)");
            }
            for conn in listener.incoming() {
                match conn {
                    Ok(mut stream) => {
                        if LIVE_CONNS.fetch_add(1, Ordering::SeqCst) >= MAX_CONNS {
                            LIVE_CONNS.fetch_sub(1, Ordering::SeqCst);
                            let body = "{\"ok\":false,\"error\":\"busy\"}";
                            let head = format!(
                                "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                                body.len(), body
                            );
                            // closing with unread request bytes makes Windows send
                            // an RST, so the client sees a reset instead of the 503:
                            // drain the request line/headers first, then close with FIN
                            let _ = stream.set_read_timeout(Some(Duration::from_millis(250)));
                            let mut buf = [0u8; 1024];
                            let mut drained = 0usize;
                            while drained < 16_384 {
                                match stream.read(&mut buf) {
                                    Ok(0) => break,
                                    Ok(n) => {
                                        drained += n;
                                        if buf[..n].windows(4).any(|w| w == b"\r\n\r\n") {
                                            break;
                                        }
                                    }
                                    Err(_) => break,
                                }
                            }
                            let _ = stream.write_all(head.as_bytes());
                            let _ = stream.flush();
                            let _ = stream.shutdown(std::net::Shutdown::Write);
                            continue;
                        }
                        let app = app.clone();
                        let core = core.clone();
                        let lib = lib.clone();
                        let pst = pst.clone();
                        std::thread::spawn(move || {
                            handle(stream, &app, &core, &lib, &pst);
                            LIVE_CONNS.fetch_sub(1, Ordering::SeqCst);
                        });
                    }
                    Err(_) => continue,
                }
            }
        })
        .expect("spawn http thread");
}
