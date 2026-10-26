// lang: Rust, file: library.rs
// track catalog: playlist metadata + local file scan, tag probing via symphonia
use serde_json::json;
use std::path::{Path, PathBuf};

pub struct Track {
    pub id: usize,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration_ms: u32,
    pub origin: String, // "playlist" | "local"
    pub path: String,   // "" = metadata only
    pub uri: String,    // spotify:track:... when known
    // page url for a song that lives on the web (youtube / soundcloud / bandcamp).
    // a row with a `web` and no `path` is streamed live; a row with both was
    // saved for offline and still remembers where it came from.
    pub web: String,
    pub cover_file: String, // file:// URL of extracted local art, "" = none
}

pub struct Library {
    pub playlist_name: String,
    pub playlist_owner: String,
    pub playlist_cover: String,
    pub playlist_file: String,
    // "spotify" playlists follow the linked catalog; "local" playlists are
    // assembled by hand and must never be overwritten by a catalog sync
    pub playlist_source: String,
    pub tracks: Vec<Track>,
    // spotify uris the listener deliberately removed from this playlist. they
    // are written back into the playlist file so a catalog sync can never
    // resurrect a song that was thrown out on purpose.
    pub removed: Vec<String>,
    pub version: u64,
    // The local vault is expensive to walk (Downloads can be thousands of
    // files) and nearly never changes while the app is running. Cache the scan
    // and drop it only when a rescan / new file asks for it.
    pub local_cache: Option<Vec<(String, FileMeta)>>,
}

const PLAYLIST_FILE: &str = concat!(env!("AETHER_ROOT"), "/library/my_playlist.json");
const PLAYLISTS_DIR: &str = concat!(env!("AETHER_ROOT"), "/library/playlists");

pub fn default_playlist_file() -> String {
    PLAYLIST_FILE.to_string()
}

pub fn playlists_dir() -> PathBuf {
    PathBuf::from(PLAYLISTS_DIR)
}

// covers are files on disk: make sure a truncated download or an html error page
// never reaches the QML image loader as a cover
pub fn looks_like_image(b: &[u8]) -> bool {
    if b.len() < 64 {
        return false;
    }
    let jpeg = b[0] == 0xFF && b[1] == 0xD8;
    let png = b.starts_with(&[0x89, 0x50, 0x4E, 0x47]);
    let gif = b.starts_with(b"GIF8");
    let bmp = b.starts_with(b"BM");
    jpeg || png || gif || bmp
}

fn is_webp(b: &[u8]) -> bool {
    b.len() > 12 && &b[0..4] == b"RIFF" && &b[8..12] == b"WEBP"
}

fn is_avif(b: &[u8]) -> bool {
    // ISO-BMFF: ....ftyp + brand
    b.len() > 16 && &b[4..8] == b"ftyp" && (&b[8..12] == b"avif" || &b[8..12] == b"avis")
}

/// Turn whatever an image host answered with into something this Qt build can
/// paint. YouTube and SoundCloud increasingly serve WebP (and AVIF) covers;
/// Qt here has no decoder for either, so a webp saved as `.jpg` renders as a
/// blank sleeve. One ffmpeg pass turns it into a real JPEG and the bytes stop
/// lying about their format.
pub fn renderable_image(body: Vec<u8>) -> Option<Vec<u8>> {
    if looks_like_image(&body) {
        return Some(body);
    }
    let webp = is_webp(&body);
    let avif = is_avif(&body);
    if !webp && !avif {
        return None;
    }
    use std::io::Write;
    use std::process::{Command, Stdio};
    let mut cmd = Command::new(concat!(env!("AETHER_ROOT"), "/bin/ffmpeg.exe"));
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000);
    }
    let mut args: Vec<&str> = vec!["-hide_banner", "-loglevel", "error"];
    if webp {
        args.extend(["-f", "webp"]);
    }
    args.extend([
        "-i", "pipe:0", "-frames:v", "1", "-f", "image2pipe", "-vcodec", "mjpeg", "pipe:1",
    ]);
    let mut child = cmd
        .args(&args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    child.stdin.take()?.write_all(&body).ok()?;
    let out = child.wait_with_output().ok()?;
    if out.status.success() && looks_like_image(&out.stdout) {
        Some(out.stdout)
    } else {
        None
    }
}

// the active playlist is a *file*, so switching playlists is just a config
// write plus a rescan. this keeps the rest of the player id-based and simple.
/// one separator, one spelling: a path pasted with `C://` or `\\` must still
/// compare equal to the file the shelf lists, or nothing shows as ACTIVE.
pub fn norm_slashes(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut prev = false;
    for ch in s.chars() {
        if ch == '/' || ch == '\\' {
            if !prev {
                out.push('/');
            }
            prev = true;
        } else {
            out.push(ch);
            prev = false;
        }
    }
    out
}

pub fn active_playlist_file() -> String {
    let stored = crate::state::config_str("active_playlist").unwrap_or_default();
    let mut stored = norm_slashes(&stored);
    // heal a path that was written with the windows verbatim prefix
    if let Some(rest) = stored.strip_prefix("/?/") {
        if rest.len() > 2 && rest.as_bytes().get(1) == Some(&b':') {
            stored = rest.to_string();
        }
    }
    if !stored.is_empty() && Path::new(&stored).is_file() {
        return stored;
    }
    PLAYLIST_FILE.to_string()
}

pub fn resolve_playlist_file(id: &str) -> Option<String> {
    // a playlist is a file inside library/, and nothing else. the old check
    // compared the *unresolved* string against a prefix, so
    // "library/playlists/../../Cargo.toml" passed it and every later write
    // (append, remove) would have landed on the program's own source.
    // canonicalize first, then require the real path to sit under the library.
    // canonicalize on windows hands back an extended-length path
    // (\\?\C:\...). stored in config it comes back as "/?/C:/..." and
    // every later load misses the file. unwrap the prefix before it leaves
    // this function.
    fn plain(p: &std::path::Path) -> String {
        let s = p.to_string_lossy().to_string();
        let s = s.strip_prefix("\\\\?\\").unwrap_or(&s).to_string();
        norm_slashes(&s)
    }
    let root = plain(&std::fs::canonicalize(LIB_DIR).ok()?);
    let mut candidates: Vec<PathBuf> = Vec::new();
    let direct = PathBuf::from(norm_slashes(id));
    if direct.is_file() {
        candidates.push(direct);
    }
    let from_dir = playlists_dir().join(norm_slashes(id));
    if from_dir.is_file() {
        candidates.push(from_dir);
    }
    for c in candidates {
        let Ok(real) = std::fs::canonicalize(&c) else { continue };
        let text = plain(&real);
        if text.starts_with(&root) {
            return Some(text);
        }
    }
    None
}

fn playlist_slug(name: &str) -> String {
    let mut out = String::new();
    for c in name.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
        } else if c.is_whitespace() || c == '-' || c == '_' {
            out.push('-');
        }
    }
    while out.contains("--") {
        out = out.replace("--", "-");
    }
    let out = out.trim_matches('-').to_string();
    if out.is_empty() {
        "playlist".into()
    } else {
        out.chars().take(48).collect()
    }
}
const LIB_DIR: &str = concat!(env!("AETHER_ROOT"), "/library");

/// Where the local vault is read from. The user's own folders, taken from the
/// environment, plus `AETHER_MUSIC` for anything else (semicolon separated) -
/// so a clone on a different machine, or on a different drive, still finds
/// music without editing source.
fn music_dirs() -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    if let Ok(extra) = std::env::var("AETHER_MUSIC") {
        for part in extra.split(';').map(|s| s.trim()).filter(|s| !s.is_empty()) {
            out.push(part.replace('\\', "/"));
        }
    }
    if let Ok(home) = std::env::var("USERPROFILE") {
        let home = home.replace('\\', "/");
        out.push(format!("{home}/Music"));
        out.push(format!("{home}/Music/AetherMix"));
        out.push(format!("{home}/Downloads"));
    }
    out
}
// audio containers only: the library is a music shelf, not a video folder.
// youtube adds pin their exact path, so an occasional audio-only webm still plays.
const AUDIO_EXTS: [&str; 7] = ["mp3", "flac", "ogg", "opus", "wav", "m4a", "aac"];
const SCAN_DEPTH: u32 = 3;

#[derive(Clone)]
pub struct FileMeta {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration_ms: u32,
    pub lyrics: String,
}

// open a decoder for a path: (format reader, decoder, sample rate)
pub fn open_decoder(
    path: &str,
) -> Option<(
    Box<dyn symphonia::core::formats::FormatReader>,
    Box<dyn symphonia::core::codecs::Decoder>,
    u32,
)> {
    let file = std::fs::File::open(path).ok()?;
    let mss = symphonia::core::io::MediaSourceStream::new(
        Box::new(file),
        symphonia::core::io::MediaSourceStreamOptions::default(),
    );
    let probed = symphonia::default::get_probe()
        .format(
            &symphonia::core::probe::Hint::new(),
            mss,
            &symphonia::core::formats::FormatOptions::default(),
            &symphonia::core::meta::MetadataOptions::default(),
        )
        .ok()?;
    let format = probed.format;
    let decoder = symphonia::default::get_codecs()
        .make(
            &format.tracks().first()?.codec_params,
            &symphonia::core::codecs::DecoderOptions::default(),
        )
        .ok()?;
    let rate = format
        .tracks()
        .first()?
        .codec_params
        .sample_rate
        .unwrap_or(44100);
    Some((format, decoder, rate))
}

fn duration_of(track: &symphonia::core::formats::Track) -> u64 {
    match (track.codec_params.n_frames, track.codec_params.time_base) {
        (Some(nf), Some(tb)) => {
            let t = tb.calc_time(nf);
            t.seconds * 1000 + (t.frac * 1000.0) as u64
        }
        _ => 0,
    }
}

// probe tags for one file
pub fn probe_file(path: &str) -> Option<FileMeta> {
    use symphonia::core::meta::StandardTagKey;
    let file = std::fs::File::open(path).ok()?;
    let mss = symphonia::core::io::MediaSourceStream::new(
        Box::new(file),
        symphonia::core::io::MediaSourceStreamOptions::default(),
    );
    let probed = symphonia::default::get_probe()
        .format(
            &symphonia::core::probe::Hint::new(),
            mss,
            &symphonia::core::formats::FormatOptions::default(),
            &symphonia::core::meta::MetadataOptions::default(),
        )
        .ok()?;
    let mut format = probed.format;
    let track = format.tracks().first()?.clone();
    let dur_ms = duration_of(&track) as u32;
    let (mut title, mut artist, mut album, mut lyrics) =
        (None, None, None, None);
    if let Some(md) = format.metadata().current() {
        for tag in md.tags() {
            let key = tag.key.to_lowercase();
            if key.contains("lyrics") {
                lyrics = Some(tag.value.to_string());
                continue;
            }
            match tag.std_key {
                Some(StandardTagKey::TrackTitle) => title = Some(tag.value.to_string()),
                Some(StandardTagKey::Artist) => artist = Some(tag.value.to_string()),
                Some(StandardTagKey::Album) => album = Some(tag.value.to_string()),
                _ => {}
            }
        }
    }
    let stem = Path::new(path)
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("track");
    Some(FileMeta {
        title: title.unwrap_or_else(|| stem.to_string()),
        artist: artist.unwrap_or_else(|| "Unknown Artist".into()),
        album: album.unwrap_or_default(),
        duration_ms: dur_ms,
        lyrics: lyrics.unwrap_or_default(),
    })
}

// stable cover cache key: the audio path when known, otherwise title+artist.
// using track ids was fragile because ids shift whenever the playlist changes.
fn cover_key(t: &Track) -> String {
    if t.path.is_empty() {
        use std::hash::{Hash, Hasher};
        let mut h = std::collections::hash_map::DefaultHasher::new();
        t.title.hash(&mut h);
        t.artist.hash(&mut h);
        format!("{:016x}", h.finish())
    } else {
        cover_key_for_path(&t.path)
    }
}

/// the same cache name the scanner looks up, so art repaired later survives a
/// rescan even when the audio file itself cannot be re-tagged.
pub fn cover_key_for_path(path: &str) -> String {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    path.hash(&mut h);
    format!("{:016x}", h.finish())
}

// embedded artwork from the audio container. lofty understands the tags that
// yt-dlp/mp4 actually write, so downloaded songs keep their faces; symphonia
// stays as the fallback for formats lofty cannot probe.
fn embedded_art(path: &str) -> Option<(String, Vec<u8>)> {
    use lofty::prelude::*;
    if let Ok(tagged) = lofty::probe::Probe::open(path).and_then(|p| p.read()) {
        if let Some(tag) = tagged.primary_tag().or_else(|| tagged.first_tag()) {
            if let Some(pic) = tag.pictures().first() {
                if !pic.data().is_empty() {
                    return Some((
                        pic.mime_type().map(|m| m.to_string()).unwrap_or_else(|| "image/jpeg".into()),
                        pic.data().to_vec(),
                    ));
                }
            }
        }
    }
    let file = std::fs::File::open(path).ok()?;
    let mss = symphonia::core::io::MediaSourceStream::new(
        Box::new(file),
        symphonia::core::io::MediaSourceStreamOptions::default(),
    );
    let probed = symphonia::default::get_probe()
        .format(
            &symphonia::core::probe::Hint::new(),
            mss,
            &symphonia::core::formats::FormatOptions::default(),
            &symphonia::core::meta::MetadataOptions::default(),
        )
        .ok()?;
    let mut format = probed.format;
    format.metadata().current().and_then(|rev| {
        rev.visuals()
            .first()
            .map(|v| (v.media_type.clone(), v.data.to_vec()))
    })
}

// artwork shipped next to the file: cover/folder/front/album/<stem>, any image ext.
fn folder_art(path: &str) -> Option<String> {
    let p = Path::new(path);
    let dir = p.parent()?;
    let stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or("");
    let names = ["cover", "folder", "front", "album", "artwork", stem];
    // one folder up as well: albums are normally <Album>/art.jpg with the
    // audio in <Album>/disc/ or a "CD1" subfolder
    for d in [Some(dir), dir.parent()] {
        let Some(d) = d else { continue };
        for name in names {
            if name.is_empty() {
                continue;
            }
            for ext in ["jpg", "jpeg", "png", "webp"] {
                for candidate in [
                    d.join(format!("{name}.{ext}")),
                    d.join(format!("{name}.{}", ext.to_uppercase())),
                ] {
                    if candidate.is_file() {
                        let url = candidate.to_string_lossy().replace('\\', "/");
                        return Some(format!("file:///{url}"));
                    }
                }
            }
        }
    }
    None
}

// One file, two spellings. A directory walk hands back `\` and the playlist
// json keeps `/`; both name the same bytes, so every path test goes through
// here - a raw == made each pinned song appear twice, once in the list and once
// as a "separate" local file.
pub fn same_path(a: &str, b: &str) -> bool {
    a.replace('\\', "/")
        .eq_ignore_ascii_case(&b.replace('\\', "/"))
}

pub fn norm_title(s: &str) -> String {
    s.chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .collect::<String>()
        .to_lowercase()
}

// conservative fuzzy link: exact, or containment with a length floor + ratio guard
fn fuzzy_match(a: &str, b: &str) -> bool {
    if a == b {
        return true;
    }
    if a.len() < 5 || b.len() < 5 {
        return false;
    }
    if a.contains(b) || b.contains(a) {
        let (lo, hi) = if a.len() < b.len() {
            (a.len(), b.len())
        } else {
            (b.len(), a.len())
        };
        return (hi as f64) <= (lo as f64) * 2.5;
    }
    false
}

// folders that are never a music collection: build output, dependency trees
// and the asset folders inside unzipped web projects. downloads are full of
// those, and walking them used to fill the vault with the same clip 40 times.
const SKIP_DIRS: [&str; 14] = [
    "node_modules",
    "target",
    "build",
    "dist",
    "out",
    "assets",
    "imported_assets",
    "public",
    "static",
    "vendor",
    ".git",
    "cache",
    "appdata",
    "$recycle.bin",
];

fn scan_dir(out: &mut Vec<(String, FileMeta)>, dir: &Path, depth: u32) {
    if depth == 0 {
        return;
    }
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for e in entries.flatten() {
        let p = e.path();
        if p.is_dir() {
            let name = p
                .file_name()
                .and_then(|x| x.to_str())
                .unwrap_or("")
                .to_lowercase();
            if SKIP_DIRS.contains(&name.as_str()) {
                continue;
            }
            scan_dir(out, &p, depth - 1);
            continue;
        }
        let ext = p
            .extension()
            .and_then(|x| x.to_str())
            .map(|x| x.to_lowercase())
            .unwrap_or_default();
        if AUDIO_EXTS.contains(&ext.as_str()) {
            let path_str = p.to_string_lossy().into_owned();
            if let Some(meta) = probe_file(&path_str) {
                out.push((path_str, meta));
            }
        }
    }
}

impl Library {
    pub fn new() -> Self {
        Self {
            playlist_name: String::from("Library"),
            playlist_owner: String::new(),
            playlist_cover: String::new(),
            playlist_file: default_playlist_file(),
            playlist_source: String::from("spotify"),
            tracks: Vec::new(),
            removed: Vec::new(),
            version: 0,
            local_cache: None,
        }
    }

    // append a track discovered by playlist sync; fuzzy-links a local file if one exists
    pub fn push_stream_track(
        &mut self,
        uri: &str,
        title: &str,
        artist: &str,
        album: &str,
        duration_ms: u32,
        cover_url: &str,
    ) -> usize {
        // the harvest runs on every sync: a row that is already in the room
        // gets its new art/duration instead of being appended again.
        let nt = norm_title(title);
        let na = norm_title(artist);
        if let Some(idx) = self.tracks.iter().position(|t| {
            (!uri.is_empty() && t.uri == uri)
                || (!nt.is_empty()
                    && norm_title(&t.title) == nt
                    && norm_title(&t.artist) == na)
        }) {
            let mut changed = false;
            {
                let existing = &mut self.tracks[idx];
                if !uri.is_empty() && existing.uri.is_empty() {
                    existing.uri = uri.into();
                    changed = true;
                }
                if existing.duration_ms == 0 && duration_ms > 0 {
                    existing.duration_ms = duration_ms;
                    changed = true;
                }
                if (existing.cover_file.is_empty() || existing.cover_file.starts_with("http"))
                    && !cover_url.is_empty()
                {
                    existing.cover_file = cover_url.into();
                    changed = true;
                }
            }
            if changed {
                self.version += 1;
            }
            return idx;
        }
        let id = self.tracks.len();
        let mut path = String::new();
        let nt = norm_title(title);
        if !nt.is_empty() {
            for t in self.tracks.iter() {
                if t.origin != "local" || t.path.is_empty() {
                    continue;
                }
                if fuzzy_match(&nt, &norm_title(&t.title)) {
                    path = t.path.clone();
                    break;
                }
            }
        }
        self.tracks.push(Track {
            id,
            title: title.into(),
            artist: artist.into(),
            album: album.into(),
            duration_ms,
            origin: "playlist".into(),
            path,
            uri: uri.into(),
            web: String::new(),
            cover_file: cover_url.into(),
        });
        self.version += 1;
        id
    }

    pub fn load_all(&mut self) {
        self.tracks.clear();
        self.removed.clear();
        let mut id = 0usize;
        // a sync bug in earlier builds appended the whole catalog on every
        // harvest, so one playlist could list every song twice. duplicates
        // are folded here and the healed file is written once the covers are
        // attached further down.
        let mut deduped = 0usize;
        self.playlist_file = active_playlist_file();
        self.playlist_name = String::from("Library");
        self.playlist_owner = String::new();
        self.playlist_cover = String::new();
        self.playlist_source = String::from("spotify");

        // 1) active playlist catalog (metadata-only entries + pinned local files)
        if let Ok(body) = std::fs::read_to_string(&self.playlist_file) {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&body) {
                // rooms written before the yt-dlp encoding fix hold a name that
                // was decoded through the console code page ("ð\u{9d}..." for a
                // starred title). Repair it on the way in so the shelf shows the
                // name that was actually typed; the file itself is healed the
                // next time anything writes the room.
                self.playlist_name = crate::ytcvt::repair_mojibake(
                    v.get("name").and_then(|x| x.as_str()).unwrap_or("Playlist"),
                );
                self.playlist_owner = v
                    .get("owner")
                    .and_then(|x| x.as_str())
                    .unwrap_or("")
                    .into();
                self.playlist_cover = v
                    .get("cover")
                    .and_then(|x| x.as_str())
                    .unwrap_or("")
                    .into();
                self.playlist_source = v
                    .get("source")
                    .and_then(|x| x.as_str())
                    .unwrap_or("spotify")
                    .into();
                if let Some(arr) = v.get("removed").and_then(|x| x.as_array()) {
                    for u in arr {
                        if let Some(u) = u.as_str() {
                            self.removed.push(u.to_string());
                        }
                    }
                }
                if let Some(arr) = v.get("tracks").and_then(|x| x.as_array()) {
                    for t in arr {
                        let uri = t.get("uri").and_then(|x| x.as_str()).unwrap_or("");
                        if !uri.is_empty() && self.removed.iter().any(|u| u == uri) {
                            continue;
                        }
                        let title = crate::ytcvt::repair_mojibake(
                            t.get("title").and_then(|x| x.as_str()).unwrap_or("?"),
                        );
                        let artist = crate::ytcvt::repair_mojibake(
                            t.get("artist").and_then(|x| x.as_str()).unwrap_or(""),
                        );
                        let album = crate::ytcvt::repair_mojibake(
                            t.get("album").and_then(|x| x.as_str()).unwrap_or(""),
                        );
                        let duration_ms = t.get("duration_ms").and_then(|x| x.as_u64()).unwrap_or(0) as u32;
                        let path = t.get("path").and_then(|x| x.as_str()).unwrap_or("");
                        let web = t.get("web").and_then(|x| x.as_str()).unwrap_or("");
                        let cover = t.get("cover").and_then(|x| x.as_str()).unwrap_or("");
                        // the same track twice in the file is a sync artefact,
                        // not an arrangement: fold it into the first row.
                        let nt = norm_title(&title);
                        let na = norm_title(&artist);
                        let dup = self.tracks.iter_mut().find(|x| {
                            (!uri.is_empty() && x.uri == uri)
                                || (!nt.is_empty()
                                    && norm_title(&x.title) == nt
                                    && norm_title(&x.artist) == na)
                        });
                        if let Some(x) = dup {
                            deduped += 1;
                            if x.path.is_empty() && !path.is_empty() {
                                x.path = path.into();
                            }
                            if x.web.is_empty() && !web.is_empty() {
                                x.web = web.into();
                            }
                            if (x.cover_file.is_empty() || x.cover_file.starts_with("http"))
                                && !cover.is_empty()
                                && !cover.starts_with("http")
                            {
                                x.cover_file = cover.into();
                            }
                            if x.duration_ms == 0 && duration_ms > 0 {
                                x.duration_ms = duration_ms;
                            }
                            continue;
                        }
                        self.tracks.push(Track {
                            id,
                            title: title.into(),
                            artist: artist.into(),
                            album: album.into(),
                            duration_ms,
                            origin: "playlist".into(),
                            path: path.into(),
                            uri: uri.into(),
                            web: web.into(),
                            cover_file: cover.into(),
                        });
                        id += 1;
                    }
                }
            }
        }

        // 2) local audio files (cached: a playlist switch must not re-walk
        //    every folder on disk)
        let files: Vec<(String, FileMeta)> = match &self.local_cache {
            Some(c) => c.clone(),
            None => {
                let mut files: Vec<(String, FileMeta)> = Vec::new();
                let dirs = music_dirs();
                for d in dirs.iter() {
                    scan_dir(&mut files, Path::new(d), SCAN_DEPTH);
                }
                // the same clip tends to exist in a dozen unzipped project
                // copies: keep one row per (name, size) pair
                let mut seen: std::collections::HashSet<(String, u64)> =
                    std::collections::HashSet::new();
                files.retain(|(p, _)| {
                    let name = Path::new(p)
                        .file_name()
                        .and_then(|x| x.to_str())
                        .unwrap_or("")
                        .to_lowercase();
                    let size = std::fs::metadata(p).map(|m| m.len()).unwrap_or(0);
                    seen.insert((name, size))
                });
                // and a folder reached twice under two spellings is still one
                // folder: keep the first path for each real file
                let mut seen_path: std::collections::HashSet<String> =
                    std::collections::HashSet::new();
                files.retain(|(p, _)| seen_path.insert(p.replace('\\', "/").to_lowercase()));
                self.local_cache = Some(files.clone());
                files
            }
        };

        // 3) match local files onto catalog entries (exact then fuzzy)
        let mut matched = vec![false; files.len()];
        for t in self.tracks.iter_mut() {
            // a pinned local file keeps its exact path; don't duplicate it below.
            // The compare has to ignore slash direction and case: the scanner
            // walks with backslashes, the playlist file stores forward slashes,
            // and a raw == made every pinned song appear twice - once in the
            // list, once as a "separate" local file.
            if !t.path.is_empty() {
                if let Some(i) = files.iter().position(|(p, _)| same_path(p, &t.path)) {
                    matched[i] = true;
                }
                continue;
            }
            let nt = norm_title(&t.title);
            if nt.is_empty() {
                continue;
            }
            for (i, (path, meta)) in files.iter().enumerate() {
                if matched[i] {
                    continue;
                }
                let stem = Path::new(path)
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or("");
                let nstem = norm_title(stem);
                let nmeta = norm_title(&meta.title);
                if fuzzy_match(&nt, &nstem) || fuzzy_match(&nt, &nmeta) {
                    t.path = path.clone();
                    if t.duration_ms == 0 {
                        t.duration_ms = meta.duration_ms;
                    }
                    matched[i] = true;
                    break;
                }
            }
        }

        // 4) unmatched local files become standalone entries
        for (i, (path, meta)) in files.into_iter().enumerate() {
            if !matched[i] {
                self.tracks.push(Track {
                    id,
                    title: meta.title,
                    artist: meta.artist,
                    album: meta.album,
                    duration_ms: meta.duration_ms,
                    origin: "local".into(),
                    path,
                    uri: String::new(),
                    web: String::new(),
                    cover_file: String::new(),
                });
                id += 1;
            }
        }

        // 5) cover art for every track that has local audio:
        //    embedded art first, then a sidecar image in the same folder.
        //    stable cache names keep art attached when playlist ids shift.
        let covers_dir = Path::new(concat!(env!("AETHER_ROOT"), "/cache/covers"));
        let _ = std::fs::create_dir_all(covers_dir);
        for t in self.tracks.iter_mut() {
            if t.path.is_empty() {
                continue;
            }
            let key = cover_key(t);
            // art already extracted on a previous load: keep it and skip the
            // tag parse (this loop used to re-read every file on every switch)
            let known = ["jpg", "png", "webp"]
                .iter()
                .map(|ext| covers_dir.join(format!("{key}.{ext}")))
                .find(|p| p.is_file());
            if let Some(p) = known {
                if let Some(name) = p.file_name().and_then(|x| x.to_str()) {
                    t.cover_file = format!(
                        concat!("file:///", env!("AETHER_ROOT"), "/cache/covers/{}"),
                        name
                    );
                    continue;
                }
            }
            if let Some((media_type, data)) = embedded_art(&t.path) {
                let ext = if media_type.contains("png") {
                    "png"
                } else if media_type.contains("webp") {
                    "webp"
                } else {
                    "jpg"
                };
                let file_name = format!("{key}.{ext}");
                let full = covers_dir.join(&file_name);
                if std::fs::write(&full, &data).is_ok() {
                    t.cover_file = format!(
                        concat!("file:///", env!("AETHER_ROOT"), "/cache/covers/{}"),
                        file_name
                    );
                    continue;
                }
            }
            if let Some(sidecar) = folder_art(&t.path) {
                t.cover_file = sidecar;
            }
        }

        // 5b) legacy cover bank: earlier builds cached art as <track-number>.jpg.
        //     those files are still the right faces for the playlist, so use
        //     them before falling back to remote art or generated gradients.
        for t in self.tracks.iter_mut() {
            // the numbered cover bank only describes original playlist rows;
            // a local file with id 4 must not inherit a random song's face
            if t.origin != "playlist" || !t.cover_file.is_empty() {
                continue;
            }
            let legacy = covers_dir.join(format!("{}.jpg", t.id + 1));
            if legacy.is_file() {
                t.cover_file = format!(
                    concat!("file:///", env!("AETHER_ROOT"), "/cache/covers/{}.jpg"),
                    t.id + 1
                );
            }
        }

        // 6) playlist rows with no art inherit the first catalog cover so the
        //    header always has a face; remote urls stay as-is when present.
        if self.playlist_cover.is_empty() {
            if let Some(c) = self
                .tracks
                .iter()
                .find(|t| t.origin == "playlist" && !t.cover_file.is_empty())
                .map(|t| t.cover_file.clone())
            {
                self.playlist_cover = c;
            }
        }

        // report catalog rows still lacking local audio
        let missing: Vec<String> = self
            .tracks
            .iter()
            .filter(|t| t.path.is_empty())
            .map(|t| format!("{} - {}", t.title, t.artist))
            .collect();
        let _ = std::fs::write(
            concat!(env!("AETHER_ROOT"), "/missing_tracks.txt"),
            if missing.is_empty() {
                String::from("all catalog tracks have local audio\n")
            } else {
                format!(
                    "drop these into Downloads or Music to complete the playlist ({}):\n\n{}\n",
                    missing.len(),
                    missing.join("\n")
                )
            },
        );

        // 7) a row can arrive without a length: a room merged from an older
        //    one, a download that landed before its probe, a hand-edited file.
        //    Without it the bar shows 0:00 and the words cannot be timed
        //    against the song, so ask the file itself - once, from disk, no
        //    network. A row called "untitled" is the same kind of hole and gets
        //    the tag (or the file name) in its place.
        let mut healed = 0usize;
        for t in self.tracks.iter_mut() {
            if t.path.is_empty() || !Path::new(&t.path).is_file() {
                continue;
            }
            let nameless = t.title.eq_ignore_ascii_case("untitled") || t.title.is_empty();
            if t.duration_ms > 0 && !nameless {
                continue;
            }
            let Some(m) = probe_file(&t.path) else { continue };
            if t.duration_ms == 0 && m.duration_ms > 0 {
                t.duration_ms = m.duration_ms;
                healed += 1;
            }
            if nameless && !m.title.trim().is_empty() {
                t.title = m.title.clone();
                if t.artist.trim().is_empty() {
                    t.artist = m.artist.clone();
                }
                healed += 1;
            }
        }

        if deduped > 0 {
            eprintln!("[library] folded {deduped} duplicate playlist row(s)");
            self.save_playlist();
        } else if healed > 0 {
            eprintln!("[library] healed {healed} row(s) with no length or name");
            self.save_playlist();
        }
        self.version += 1;
    }

    // ---------------- playlist management ----------------

    // write the active playlist back to disk so a long sync survives restarts
    pub fn save_playlist(&self) {
        let mut root = std::fs::read_to_string(&self.playlist_file)
            .ok()
            .and_then(|b| serde_json::from_str::<serde_json::Value>(&b).ok())
            .unwrap_or_else(|| json!({}));
        if !root.is_object() {
            root = json!({});
        }
        let rows: Vec<serde_json::Value> = self
            .tracks
            .iter()
            .filter(|t| t.origin == "playlist")
            .enumerate()
            .map(|(i, t)| {
                json!({
                    "n": i + 1,
                    "title": t.title,
                    "artist": t.artist,
                    "album": t.album,
                    "duration_ms": t.duration_ms,
                    "uri": t.uri,
                    "web": t.web,
                    "cover": t.cover_file,
                    "path": t.path,
                })
            })
            .collect();
        if let Some(o) = root.as_object_mut() {
            o.insert("name".into(), json!(self.playlist_name));
            o.insert("owner".into(), json!(self.playlist_owner));
            o.insert("cover".into(), json!(self.playlist_cover));
            o.insert("source".into(), json!(self.playlist_source));
            o.insert("tracks".into(), json!(rows));
            o.insert("removed".into(), json!(self.removed));
        }
        if let Some(dir) = Path::new(&self.playlist_file).parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(body) = serde_json::to_string_pretty(&root) {
            // rename, not truncate: a crash or a concurrent reader never sees
            // half a playlist
            let tmp = format!("{}.tmp", self.playlist_file);
            if std::fs::write(&tmp, body).is_ok() {
                let _ = std::fs::rename(&tmp, &self.playlist_file);
            }
        }
    }

    // take one song out of the active playlist. a downloaded file is kept on
    // disk: it simply falls back to the local vault, which is its own room.
    pub fn remove_track(&mut self, id: usize) -> bool {
        if id >= self.tracks.len() {
            return false;
        }
        let gone = self.tracks.remove(id);
        if !gone.uri.is_empty() && !self.removed.iter().any(|u| u == &gone.uri) {
            self.removed.push(gone.uri.clone());
        }
        for (i, t) in self.tracks.iter_mut().enumerate() {
            t.id = i;
        }
        self.version += 1;
        self.save_playlist();
        true
    }

    pub fn add_track(
        &mut self,
        title: &str,
        artist: &str,
        album: &str,
        duration_ms: u32,
        path: &str,
        uri: &str,
        web: &str,
        cover: &str,
    ) -> usize {
        // a song is the same song when its uri, file or normalised name matches
        let nt = norm_title(title);
        let na = norm_title(artist);
        if let Some(idx) = self.tracks.iter().position(|t| {
            (!uri.is_empty() && t.uri == uri)
                || (!path.is_empty() && t.path == path)
                || (!web.is_empty() && t.web == web)
                || (norm_title(&t.title) == nt && norm_title(&t.artist) == na && !nt.is_empty())
        }) {
            // the song is already in the playlist: enrich it with the newly
            // downloaded file/art instead of dropping the add on the floor
            let mut changed = false;
            if let Some(t) = self.tracks.get_mut(idx) {
                // an unscanned local row becomes a real playlist row when it is
                // explicitly added, instead of silently staying a loose file
                if t.origin == "local" {
                    t.origin = "playlist".into();
                    changed = true;
                }
                if !path.is_empty() && t.path != path {
                    t.path = path.into();
                    changed = true;
                }
                // local art beats no art, and it also beats a remote url that
                // may later 404: the add is the moment the real sleeve exists
                if !cover.is_empty()
                    && (t.cover_file.is_empty() || t.cover_file.starts_with("http"))
                {
                    t.cover_file = cover.into();
                    changed = true;
                }
                if !uri.is_empty() && t.uri.is_empty() {
                    t.uri = uri.into();
                    changed = true;
                }
                if !web.is_empty() && t.web.is_empty() {
                    t.web = web.into();
                    changed = true;
                }
                if duration_ms > 0 && t.duration_ms == 0 {
                    t.duration_ms = duration_ms;
                    changed = true;
                }
            }
            if changed {
                self.version += 1;
                self.save_playlist();
            }
            return idx;
        }
        let id = self.tracks.len();
        self.tracks.push(Track {
            id,
            title: title.into(),
            artist: artist.into(),
            album: album.into(),
            duration_ms,
            origin: "playlist".into(),
            path: path.into(),
            uri: uri.into(),
            web: web.into(),
            cover_file: cover.into(),
        });
        if self.playlist_cover.is_empty() && !cover.is_empty() {
            self.playlist_cover = cover.into();
        }
        self.version += 1;
        self.save_playlist();
        id
    }

    pub fn playlist_rows(&self) -> Vec<serde_json::Value> {
        let mut files: Vec<String> = vec![default_playlist_file()];
        if let Ok(rd) = std::fs::read_dir(PLAYLISTS_DIR) {
            for e in rd.flatten() {
                let p = e.path();
                if p.extension().and_then(|x| x.to_str()) == Some("json") {
                    files.push(p.to_string_lossy().replace('\\', "/"));
                }
            }
        }
        files.sort();
        files.dedup();
        let mut rows = Vec::new();
        for f in files {
            if !Path::new(&f).is_file() {
                continue;
            }
            let v = std::fs::read_to_string(&f)
                .ok()
                .and_then(|b| serde_json::from_str::<serde_json::Value>(&b).ok())
                .unwrap_or_else(|| json!({}));
            let active = f == self.playlist_file;
            let total = if active {
                self.tracks.iter().filter(|t| t.origin == "playlist").count()
            } else {
                v.get("tracks").and_then(|x| x.as_array()).map(|a| a.len()).unwrap_or(0)
            };
            let name = if active {
                self.playlist_name.clone()
            } else {
                crate::ytcvt::repair_mojibake(
                    v.get("name").and_then(|x| x.as_str()).unwrap_or("Playlist"),
                )
            };
            // the shelf shows a stack of real art: up to four covers from the
            // playlist itself, with the playlist cover first when it has one
            let mut covers: Vec<String> = Vec::new();
            let cover = if active {
                self.playlist_cover.clone()
            } else {
                v.get("cover").and_then(|x| x.as_str()).unwrap_or("").to_string()
            };
            if cover.len() > 4 {
                covers.push(cover.clone());
            }
            let source_tracks: Vec<&serde_json::Value> = if active {
                Vec::new()
            } else {
                v.get("tracks")
                    .and_then(|x| x.as_array())
                    .map(|a| a.iter().collect())
                    .unwrap_or_default()
            };
            if active {
                for t in self.tracks.iter().filter(|t| t.origin == "playlist") {
                    if covers.len() >= 4 {
                        break;
                    }
                    if t.cover_file.len() > 4 && !covers.contains(&t.cover_file) {
                        covers.push(t.cover_file.clone());
                    }
                }
            } else {
                for t in source_tracks {
                    if covers.len() >= 4 {
                        break;
                    }
                    if let Some(c) = t.get("cover").and_then(|x| x.as_str()) {
                        if c.len() > 4 && !covers.contains(&c.to_string()) {
                            covers.push(c.to_string());
                        }
                    }
                }
            }
            rows.push(json!({
                "id": f,
                "name": name,
                "total": total,
                "cover": cover,
                "covers": covers,
                "active": active,
            }));
        }
        rows
    }

    pub fn invalidate_local_cache(&mut self) {
        self.local_cache = None;
    }

    pub fn create_playlist(&mut self, name: &str) -> String {
        if let Some(parent) = playlists_dir().parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::create_dir_all(PLAYLISTS_DIR);
        let slug = playlist_slug(name);
        let mut file = playlists_dir().join(format!("{slug}.json"));
        let mut i = 2;
        while file.is_file() {
            file = playlists_dir().join(format!("{slug}-{i}.json"));
            i += 1;
        }
        let path = file.to_string_lossy().replace('\\', "/");
        let body = json!({
            "name": name,
            "owner": "you",
            "source": "local",
            "cover": "",
            "tracks": [],
        });
        let _ = std::fs::write(&file, serde_json::to_string_pretty(&body).unwrap_or_default());
        crate::state::set_config_str("active_playlist", &path);
        // Start the room empty in memory too. Reloading here used to rescan the
        // whole local vault (slow) and, worse, a concurrent save could write the
        // previous playlist's rows into this new file, so "new playlist" came
        // out as a copy of the old one.
        self.playlist_file = path.clone();
        self.playlist_name = name.to_string();
        self.playlist_owner = String::from("you");
        self.playlist_cover = String::new();
        self.playlist_source = String::from("local");
        self.removed.clear();
        // the local vault is not part of the playlist: keep its rows, drop
        // every catalog row, and renumber so ids stay dense
        let mut locals: Vec<Track> = self
            .tracks
            .drain(..)
            .filter(|t| t.origin == "local")
            .collect();
        for (i, t) in locals.iter_mut().enumerate() {
            t.id = i;
        }
        self.tracks = locals;
        self.version += 1;
        path
    }

    pub fn switch_playlist(&mut self, id: &str) -> bool {
        let Some(path) = resolve_playlist_file(id) else {
            return false;
        };
        crate::state::set_config_str("active_playlist", &path);
        self.load_all();
        self.version += 1;
        true
    }

    pub fn json(&self) -> String {
        self.json_scope(true)
    }

    // The desktop library is "the local vault plus the open playlist". A room on
    // the phone is only the playlist, so it asks for `scope=playlist`; otherwise
    // a fresh room would open showing the whole vault (and a card that says
    // "0 songs" would disagree with the list behind it).
    pub fn json_scope(&self, include_local: bool) -> String {
        // favourites and play counts ride along with every row so the list can
        // draw a heart and offer "most played" without a second request per
        // song. both are keyed by identity, not by the transient id.
        let favs = crate::state::favorites();
        let rows: Vec<&Track> = self
            .tracks
            .iter()
            .filter(|t| include_local || t.origin != "local")
            .collect();
        let tracks: Vec<serde_json::Value> = rows
            .iter()
            .map(|t| {
                json!({
                    "id": t.id,
                    "title": t.title,
                    "artist": t.artist,
                    "album": t.album,
                    "duration_ms": t.duration_ms,
                    "origin": t.origin,
                    "playable": !t.path.is_empty() || !t.web.is_empty(),
                    "web": t.web,
                    "streamable": !t.uri.is_empty(),
                    "cover": t.cover_file,
                    "path": t.path,
                    "key": crate::state::song_key(&t.title, &t.artist),
                    "liked": favs.contains(&crate::state::song_key(&t.title, &t.artist)),
                    "plays": crate::state::plays_of(t.id),
                })
            })
            .collect();
        let total_ms: u64 = rows.iter().map(|t| t.duration_ms as u64).sum();
        json!({
            "version": self.version,
            "playlist_name": self.playlist_name,
            "playlist_owner": self.playlist_owner,
            "playlist_cover": self.playlist_cover,
            "playlist_file": self.playlist_file,
            "total": rows.len(),
            "total_ms": total_ms,
            "liked": rows
                .iter()
                .filter(|t| favs.contains(&crate::state::song_key(&t.title, &t.artist)))
                .count(),
            "playable": rows.iter().filter(|t| !t.path.is_empty() || !t.web.is_empty()).count(),
            "stream_count": rows.iter().filter(|t| t.origin == "playlist").count(),
            "local_count": rows.iter().filter(|t| t.origin == "local").count(),
            "tracks": tracks,
        })
        .to_string()
    }

    // (lyrics text, synced?)
    pub fn lyrics_for(&self, id: usize) -> (String, bool) {
        let Some(t) = self.tracks.get(id) else {
            return (String::new(), false);
        };
        if t.path.is_empty() {
            return (String::new(), false);
        }
        // sibling .lrc file first
        let lrc = Path::new(&t.path).with_extension("lrc");
        if let Ok(body) = std::fs::read_to_string(&lrc) {
            let synced = body.contains("[0") || body.contains("[1");
            return (body, synced);
        }
        // embedded lyrics tag
        if let Some(meta) = probe_file(&t.path) {
            if !meta.lyrics.is_empty() {
                let synced = meta.lyrics.contains("[0") || meta.lyrics.contains("[1");
                return (meta.lyrics, synced);
            }
        }
        (String::new(), false)
    }
}

// ---------------- playlists on disk ----------------
/// Show a file in Explorer with it selected. Explorer is the only sane way to
/// say "here it is" without taking over the desktop.
pub fn reveal_in_explorer(path_win: &str) -> bool {
    let mut cmd = std::process::Command::new("explorer.exe");
    cmd.arg("/select,").arg(path_win);
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000);
    }
    cmd.spawn().is_ok()
}

fn m3u_slug(name: &str) -> String {
    // ASCII only: a stylised playlist name ("𝒆𝒏𝑻𝒑𝑭彡") produced a file name
    // full of mathematical-bold glyphs that Windows sorts oddly and nobody can
    // type. Anything that is not a plain word becomes "playlist".
    let mut out = String::new();
    for c in name.chars() {
        if c.is_ascii_alphanumeric() || c == ' ' || c == '-' || c == '_' {
            out.push(c);
        } else if c == '/' || c == '\\' {
            out.push('-');
        }
    }
    let s = out.trim().trim_matches('-').trim().to_string();
    let words = s.split_whitespace().count();
    if s.chars().filter(|c| c.is_ascii_alphanumeric()).count() < 2 || words == 0 {
        "playlist".into()
    } else {
        s
    }
}

/// Write this room to a standard .m3u8 next to the library. `rows` are
/// (title, artist, duration_ms, location) where location is a file path or a
/// spotify uri; uri rows survive as a comment so the file still opens
/// everywhere.
pub fn export_m3u(name: &str, rows: &[(String, String, u32, String)]) -> Result<String, String> {
    let dir = concat!(env!("AETHER_ROOT"), "/library/exports");
    std::fs::create_dir_all(dir).map_err(|e| format!("could not make {dir}: {e}"))?;
    let path = format!("{dir}/{}.m3u8", m3u_slug(name));
    let mut out = String::from("#EXTM3U\n");
    for (title, artist, dur, loc) in rows {
        if loc.is_empty() {
            continue;
        }
        let label = if artist.is_empty() {
            title.clone()
        } else {
            format!("{artist} - {title}")
        };
        out.push_str(&format!("#EXTINF:{},{}\n{}\n", dur / 1000, label, loc));
    }
    std::fs::write(&path, out).map_err(|e| format!("could not write: {e}"))?;
    Ok(path)
}

/// Read a .m3u/.m3u8 into absolute file paths. Relative entries resolve
/// against the playlist's own folder, which is how most players write them.
pub fn read_m3u(path: &str) -> Vec<String> {
    let body = match std::fs::read_to_string(path) {
        Ok(b) => b,
        Err(_) => return Vec::new(),
    };
    let base = Path::new(path)
        .parent()
        .map(|p| p.to_string_lossy().replace('\\', "/"))
        .unwrap_or_default();
    let mut out = Vec::new();
    for line in body.lines() {
        let l = line.trim().trim_start_matches('\u{feff}');
        if l.is_empty() || l.starts_with('#') {
            continue;
        }
        let mut p = l.to_string();
        if let Some(rest) = p.strip_prefix("file:///") {
            p = rest.to_string();
        }
        if p.starts_with("spotify:") {
            continue;
        }
        let abs = if p.len() > 2 && p.as_bytes()[1] == b':' {
            p
        } else if p.starts_with('/') {
            p
        } else if base.is_empty() {
            p
        } else {
            format!("{base}/{p}")
        };
        out.push(abs.replace('\\', "/"));
    }
    out
}
