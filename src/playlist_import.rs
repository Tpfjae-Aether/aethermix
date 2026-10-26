// lang: Rust, file: playlist_import.rs
// Paste a playlist link, get a room. YouTube and SoundCloud lists are read with
// yt-dlp (no key, no account), Spotify lists with the linked session. The file
// is written immediately with every song, then a worker pulls each audio file
// into the playlist and reports exactly which songs could not be fetched.

use serde_json::{json, Value};
use std::sync::Mutex;

const PLAYLISTS_DIR: &str = concat!(env!("AETHER_ROOT"), "/library/playlists");
const COVERS_DIR: &str = concat!(env!("AETHER_ROOT"), "/cache/covers");

#[derive(Clone, Default)]
struct Job {
    running: bool,
    source: String,
    name: String,
    file: String,
    cover: String,
    total: usize,
    done: usize,
    failed: Vec<(String, String)>,
}

static JOB: Mutex<Option<Job>> = Mutex::new(None);

fn job_json(j: &Job) -> Value {
    json!({
        "running": j.running,
        "source": j.source,
        "name": j.name,
        "file": j.file,
        "cover": j.cover,
        "total": j.total,
        "done": j.done,
        "failed": j.failed.iter().map(|(t, e)| json!({ "title": t, "error": e })).collect::<Vec<_>>(),
    })
}

pub fn status_json() -> String {
    match JOB.lock().unwrap().as_ref() {
        Some(j) => job_json(j).to_string(),
        None => json!({ "running": false, "total": 0, "done": 0, "failed": [] }).to_string(),
    }
}

pub fn source_of(url: &str) -> &'static str {
    let u = url.to_lowercase();
    if u.contains("spotify.com/playlist") || u.starts_with("spotify:playlist:") {
        "spotify"
    } else if u.contains("soundcloud.com") {
        "soundcloud"
    } else if u.contains("youtube.com") || u.contains("youtu.be") {
        "youtube"
    } else {
        "link"
    }
}

fn slug(x: &str) -> String {
    let mut out = String::new();
    for c in x.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
        } else if c.is_whitespace() || c == '-' || c == '_' {
            if !out.ends_with('-') {
                out.push('-');
            }
        }
        if out.len() >= 48 {
            break;
        }
    }
    let out = out.trim_matches('-').to_string();
    if out.is_empty() { "imported".into() } else { out }
}

fn ytdlp_flat(url: &str) -> Result<Value, String> {
    let mut cmd = crate::ytcvt::ytdlp();
    for a in crate::accounts::cookie_args() {
        cmd.arg(a);
    }
    let out = cmd
        .args(["--dump-single-json", "--flat-playlist", "--no-warnings", url])
        .output()
        .map_err(|e| format!("yt-dlp could not start: {e}"))?;
    if !out.status.success() {
        let msg = String::from_utf8_lossy(&out.stderr)
            .lines()
            .filter(|l| !l.trim().is_empty())
            .last()
            .unwrap_or("could not read that link")
            .to_string();
        return Err(msg);
    }
    // the same repaired decode the rest of the yt-dlp calls use: this is where
    // a pasted playlist's *name* is read, and that name is what gets written
    // into the room file, so a mangled read here poisons the room for good.
    let raw = String::from_utf8_lossy(&out.stdout).to_string();
    serde_json::from_str(&crate::ytcvt::repair_mojibake(&raw))
        .map_err(|e| format!("unreadable playlist: {e}"))
}

fn entry_thumb(e: &Value) -> String {
    if let Some(t) = e.get("thumbnails").and_then(|x| x.as_array()) {
        if let Some(last) = t.last().and_then(|x| x.get("url")).and_then(|x| x.as_str()) {
            return last.to_string();
        }
    }
    e.get("thumbnail").and_then(|x| x.as_str()).unwrap_or("").to_string()
}

fn entry_url(e: &Value, src: &str) -> String {
    if let Some(u) = e.get("webpage_url").and_then(|x| x.as_str()) {
        if u.starts_with("http") {
            return u.to_string();
        }
    }
    let id = e.get("id").and_then(|x| x.as_str()).unwrap_or("");
    if src == "soundcloud" {
        return e.get("url").and_then(|x| x.as_str()).unwrap_or("").to_string();
    }
    if id.is_empty() {
        String::new()
    } else {
        format!("https://www.youtube.com/watch?v={id}")
    }
}

/// One parsed playlist: what to write, and what to download.
struct Parsed {
    source: String,
    name: String,
    cover: String,
    tracks: Vec<Value>,
}

fn parse_youtube_like(url: &str, src: &str) -> Result<Parsed, String> {
    let v = ytdlp_flat(url)?;
    let name = v
        .get("title")
        .or_else(|| v.get("playlist_title"))
        .and_then(|x| x.as_str())
        .unwrap_or(if src == "soundcloud" { "SoundCloud set" } else { "YouTube playlist" })
        .to_string();
    let entries = v.get("entries").and_then(|x| x.as_array()).cloned().unwrap_or_default();
    let mut tracks = Vec::new();
    let mut cover = entry_thumb(&v);
    for (i, e) in entries.iter().enumerate() {
        let u = entry_url(e, src);
        if u.is_empty() || !u.starts_with("http") {
            continue;
        }
        let title = e.get("title").and_then(|x| x.as_str()).unwrap_or("untitled").to_string();
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
        let dur = (e.get("duration").and_then(|x| x.as_f64()).unwrap_or(0.0) * 1000.0) as u64;
        let thumb = entry_thumb(e);
        if cover.is_empty() && !thumb.is_empty() {
            cover = thumb.clone();
        }
        tracks.push(json!({
            "n": i + 1,
            "title": title,
            "artist": if artist.is_empty() { source_of(url) } else { artist.as_str() },
            "album": if src == "soundcloud" { "SoundCloud" } else { "YouTube" },
            "duration_ms": dur,
            "uri": u,
            "path": "",
            "cover": thumb,
        }));
    }
    if tracks.is_empty() {
        return Err("that link held no songs (a private, empty or region-locked list?)".into());
    }
    Ok(Parsed { source: src.into(), name, cover, tracks })
}

fn spotify_id(url: &str) -> Option<String> {
    if let Some(rest) = url.strip_prefix("spotify:playlist:") {
        let id: String = rest.chars().take_while(|c| c.is_ascii_alphanumeric()).collect();
        return if id.is_empty() { None } else { Some(id) };
    }
    if let Some(pos) = url.find("/playlist/") {
        let id: String = url[pos + 10..]
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric())
            .collect();
        return if id.is_empty() { None } else { Some(id) };
    }
    None
}

fn parse_spotify(url: &str) -> Result<Parsed, String> {
    let id = spotify_id(url).ok_or("that is not a Spotify playlist link")?;
    let head = crate::stream::api_get(&format!("/v1/playlists/{id}"), 8)
        .ok_or("Spotify is not linked - sign in from Studio > Accounts first")?;
    let v: Value = serde_json::from_str(&head).map_err(|e| format!("bad Spotify answer: {e}"))?;
    let name = v.get("name").and_then(|x| x.as_str()).unwrap_or("Spotify playlist").to_string();
    let cover = v
        .pointer("/images/0/url")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    let total = v.pointer("/tracks/total").and_then(|x| x.as_u64()).unwrap_or(0) as usize;
    let mut items: Vec<Value> = v
        .pointer("/tracks/items")
        .and_then(|x| x.as_array())
        .cloned()
        .unwrap_or_default();
    let mut off = items.len();
    while off < total && off < 1000 {
        let page = format!("/v1/playlists/{id}/tracks?limit=100&offset={off}");
        let Some(body) = crate::stream::api_get(&page, 8) else { break };
        let Ok(p) = serde_json::from_str::<Value>(&body) else { break };
        let arr = p.get("items").and_then(|x| x.as_array()).cloned().unwrap_or_default();
        if arr.is_empty() { break; }
        off += arr.len();
        items.extend(arr);
    }
    let mut tracks = Vec::new();
    for (i, it) in items.iter().enumerate() {
        let t = it.get("track").unwrap_or(it);
        let uri = t.get("uri").and_then(|x| x.as_str()).unwrap_or("");
        if !uri.starts_with("spotify:track:") {
            continue;
        }
        let artists = t
            .get("artists")
            .and_then(|a| a.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|x| x.get("name").and_then(|n| n.as_str()))
                    .collect::<Vec<_>>()
                    .join(", ")
            })
            .unwrap_or_default();
        tracks.push(json!({
            "n": i + 1,
            "title": t.get("name").and_then(|x| x.as_str()).unwrap_or("untitled"),
            "artist": artists,
            "album": t.pointer("/album/name").and_then(|x| x.as_str()).unwrap_or("Spotify"),
            "duration_ms": t.get("duration_ms").and_then(|x| x.as_u64()).unwrap_or(0),
            "uri": uri,
            "path": "",
            "cover": t.pointer("/album/images/0/url").and_then(|x| x.as_str()).unwrap_or(""),
        }));
    }
    if tracks.is_empty() {
        return Err("Spotify returned no playable tracks for that playlist".into());
    }
    Ok(Parsed { source: "spotify".into(), name, cover, tracks })
}

fn parse(url: &str) -> Result<Parsed, String> {
    match source_of(url) {
        "spotify" => parse_spotify(url),
        s @ ("youtube" | "soundcloud") => parse_youtube_like(url, s),
        _ => Err("paste a YouTube, SoundCloud or Spotify playlist link".into()),
    }
}

pub fn preview_json(url: &str, limit: usize) -> String {
    let url = url.trim();
    if url.is_empty() {
        return json!({ "ok": false, "error": "paste a link first" }).to_string();
    }
    match parse(url) {
        Ok(mut p) => {
            let count = p.tracks.len();
            if limit > 0 && count > limit {
                p.tracks.truncate(limit);
            }
            let head: Vec<Value> = p.tracks.iter().take(200).cloned().collect();
            json!({
                "ok": true,
                "source": p.source,
                "name": p.name,
                "cover": p.cover,
                "count": count,
                "tracks": head,
            })
            .to_string()
        }
        Err(e) => json!({ "ok": false, "error": e }).to_string(),
    }
}

fn fetch_cover_bytes(url: &str) -> Option<Vec<u8>> {
    if !url.starts_with("http") {
        return None;
    }
    let clean = if (url.contains("ytimg.com") || url.contains("img.youtube.com")) && url.contains('?') {
        url.split('?').next().unwrap_or(url).to_string()
    } else {
        url.to_string()
    };
    let r = ureq::get(&clean)
        .timeout(std::time::Duration::from_secs(12))
        .set("Accept", "image/jpeg,image/png,image/gif;q=0.9,*/*;q=0.5")
        .set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AetherMix/0.5")
        .call()
        .ok()?;
    let mut buf = Vec::new();
    use std::io::Read;
    r.into_reader().read_to_end(&mut buf).ok()?;
    // importer files are always named .jpg: webp/avif has to become real jpeg
    // here, or the shelf shows a blank tile for a cover it actually has
    crate::library::renderable_image(buf)
}

/// Write the whole playlist first, so it exists (with its art) the instant the
/// link is accepted, then let the worker fill in audio one song at a time.
pub fn start(
    url: &str,
    name: &str,
    limit: usize,
    lib: std::sync::Arc<Mutex<crate::library::Library>>,
    app: std::sync::Arc<Mutex<crate::state::AppState>>,
) -> String {
    let url = url.trim().to_string();
    let mut p = match parse(&url) {
        Ok(p) => p,
        Err(e) => return json!({ "ok": false, "error": e }).to_string(),
    };
    if limit > 0 && p.tracks.len() > limit {
        p.tracks.truncate(limit);
    }
    let title = if name.trim().is_empty() { p.name.clone() } else { name.trim().to_string() };
    let _ = std::fs::create_dir_all(PLAYLISTS_DIR);
    let base = slug(&title);
    let mut file = std::path::Path::new(PLAYLISTS_DIR).join(format!("{base}.json"));
    let mut n = 2;
    while file.is_file() {
        file = std::path::Path::new(PLAYLISTS_DIR).join(format!("{base}-{n}.json"));
        n += 1;
    }
    let path = file.to_string_lossy().replace('\\', "/");

    // the list's own art, copied once so the shelf and the room show the real
    // cover even if the link later dies
    let _ = std::fs::create_dir_all(COVERS_DIR);
    let mut cover = String::new();
    if let Some(b) = fetch_cover_bytes(&p.cover) {
        let cp = format!("{COVERS_DIR}/import_{base}.jpg");
        if std::fs::write(&cp, &b).is_ok() {
            cover = format!("file:///{cp}");
        }
    }

    let body = json!({
        "name": title,
        "owner": "you",
        "source": format!("import:{}", p.source),
        "origin_url": url,
        "cover": cover,
        "tracks": p.tracks,
    });
    if std::fs::write(&file, serde_json::to_string_pretty(&body).unwrap_or_default()).is_err() {
        return json!({ "ok": false, "error": "could not write the playlist" }).to_string();
    }

    let total = p.tracks.len();
    let job = Job {
        running: p.source != "spotify",
        source: p.source.clone(),
        name: title.clone(),
        file: path.clone(),
        cover: cover.clone(),
        total,
        done: if p.source == "spotify" { total } else { 0 },
        failed: Vec::new(),
    };
    {
        let mut g = JOB.lock().unwrap();
        *g = Some(job.clone());
    }

    if p.source == "spotify" {
        // spotify rows stream through the linked catalog: nothing to download
        return json!({ "ok": true, "file": path, "name": title, "total": total,
                       "cover": cover, "streamed": true }).to_string();
    }

    let urls: Vec<(String, String)> = p
        .tracks
        .iter()
        .filter_map(|t| {
            let u = t.get("uri").and_then(|x| x.as_str()).unwrap_or("");
            let ti = t.get("title").and_then(|x| x.as_str()).unwrap_or("song");
            if u.starts_with("http") { Some((u.to_string(), ti.to_string())) } else { None }
        })
        .collect();

    let fclone = path.clone();
    std::thread::Builder::new()
        .name("pl-import".into())
        .spawn(move || {
            for (u, ti) in urls {
                let got = crate::ytcvt::ingest_url(&u);
                let mut g = JOB.lock().unwrap();
                if let Some(j) = g.as_mut() {
                    match got {
                        Ok(song) => {
                            patch_row(&fclone, &u, &song.path, &song.cover_url);
                            j.done += 1;
                        }
                        Err(e) => {
                            j.done += 1;
                            j.failed.push((ti, e.chars().take(180).collect::<String>()));
                        }
                    }
                    if j.done >= j.total {
                        j.running = false;
                    }
                }
                drop(g);
            }
            {
                let mut g = JOB.lock().unwrap();
                if let Some(j) = g.as_mut() {
                    j.running = false;
                }
            }
            // a finished import becomes a browsable room even if another
            // playlist is active: the shelf reads the file, not the library.
            // the version always moves, so the shelf redraws and the new
            // collection appears without a restart.
            let mut l = lib.lock().unwrap();
            if l.playlist_file == fclone {
                l.load_all();
            }
            l.version += 1;
            app.lock().unwrap().library_version = l.version;
        })
        .ok();

    json!({ "ok": true, "file": path, "name": title, "total": total, "cover": cover }).to_string()
}

fn patch_row(file: &str, uri: &str, path: &str, cover: &str) {
    let Ok(raw) = std::fs::read_to_string(file) else { return };
    let Ok(mut v) = serde_json::from_str::<Value>(&raw) else { return };
    if let Some(arr) = v.get_mut("tracks").and_then(|x| x.as_array_mut()) {
        for t in arr.iter_mut() {
            if t.get("uri").and_then(|x| x.as_str()) == Some(uri) {
                t["path"] = json!(path);
                if !cover.is_empty() {
                    t["cover"] = json!(cover);
                }
                break;
            }
        }
    }
    if let Ok(body) = serde_json::to_string_pretty(&v) {
        let _ = std::fs::write(file, body);
    }
}
