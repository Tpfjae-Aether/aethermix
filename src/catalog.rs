// lang: Rust, file: catalog.rs
// playlist auto-sync: mirrors the public Spotify playlist into the catalog.
// startup + on demand (/catalog/sync) + every 15 min while streaming.
// covers for new tracks come from the public oEmbed endpoint - no auth, no scopes.
use crate::library::Library;
use crate::state::AppState;
use serde_json::Value;
use std::collections::HashSet;
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub const DEFAULT_PLAYLIST: &str =
    "https://open.spotify.com/embed/playlist/2fDNrzefEE7C8rachwHHgY";

pub fn playlist_url() -> String {
    if let Ok(b) = std::fs::read_to_string(crate::state::CONFIG_FILE) {
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&b) {
            if let Some(u) = v.get("playlist_url").and_then(|x| x.as_str()) {
                if !u.is_empty() {
                    return u.to_string();
                }
            }
        }
    }
    DEFAULT_PLAYLIST.to_string()
}

pub struct SyncResult {
    pub ok: bool,
    pub added: usize,
    pub playlist_total: usize,
}

struct Found {
    uri: String,
    title: String,
    artist: String,
    album: String,
    cover: String,
    duration_ms: u32,
}

fn build_client() -> Option<reqwest::Client> {
    match reqwest::Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
    {
        Ok(c) => Some(c),
        Err(e) => {
            eprintln!("[catalog] client build: {e}");
            None
        }
    }
}

async fn fetch_embed_html(client: &reqwest::Client) -> Option<String> {
    let resp = match client
        .get(playlist_url())
        .header(
            "User-Agent",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
        )
        .send()
        .await
    {
        Ok(r) => r,
        Err(e) => {
            eprintln!("[catalog] send: {e}");
            return None;
        }
    };
    if !resp.status().is_success() {
        eprintln!("[catalog] status: {}", resp.status());
        return None;
    }
    match resp.text().await {
        Ok(b) => {
            eprintln!("[catalog] embed fetched: {} bytes", b.len());
            Some(b)
        }
        Err(e) => {
            eprintln!("[catalog] body: {e}");
            None
        }
    }
}

// public oEmbed: thumbnail art for one track uri, no credentials involved
async fn fetch_track_cover(client: &reqwest::Client, uri: &str) -> String {
    let url = format!(
        "https://open.spotify.com/oembed?url={}",
        uri.replace(':', "%3A")
    );
    let Ok(resp) = client.get(&url).send().await else {
        return String::new();
    };
    if !resp.status().is_success() {
        return String::new();
    }
    let Ok(body) = resp.text().await else {
        return String::new();
    };
    serde_json::from_str::<Value>(&body)
        .ok()
        .and_then(|v| {
            v.get("thumbnail_url")
                .and_then(|x| x.as_str())
                .map(String::from)
        })
        .unwrap_or_default()
}

// application/json script bodies out of the embed HTML
fn extract_json_blobs(html: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = html;
    while let Some(i) = rest.find("<script") {
        let Some(tag_end) = rest[i..].find('>') else { break };
        let open = &rest[i..i + tag_end];
        let body_start = i + tag_end + 1;
        let Some(close_rel) = rest[body_start..].find("</script>") else { break };
        let body = &rest[body_start..body_start + close_rel];
        if open.contains("application/json") || open.contains("__NEXT_DATA__") {
            out.push(body.trim().to_string());
        }
        rest = &rest[body_start + close_rel + 9..];
    }
    out
}

// schema-tolerant walk: any object with a spotify:track uri + a title is a track
fn harvest(node: &Value, out: &mut Vec<Found>, seen: &mut HashSet<String>) {
    match node {
        Value::Object(map) => {
            let uri = map.get("uri").and_then(|v| v.as_str()).unwrap_or("");
            if uri.starts_with("spotify:track:") && !seen.contains(uri) {
                if let Some(title) = map.get("title").and_then(|v| v.as_str()) {
                    seen.insert(uri.to_string());
                    let artist = match map.get("artists") {
                        Some(Value::Array(arr)) => arr
                            .iter()
                            .filter_map(|a| a.get("name").and_then(|n| n.as_str()))
                            .collect::<Vec<_>>()
                            .join(", "),
                        _ => map
                            .get("subtitle")
                            .and_then(|v| v.as_str())
                            .unwrap_or("")
                            .to_string(),
                    };
                    let album = map
                        .get("album")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    let duration_ms = map
                        .get("duration")
                        .and_then(|v| v.as_u64())
                        .unwrap_or(0) as u32;
                    out.push(Found {
                        uri: uri.to_string(),
                        title: title.to_string(),
                        artist,
                        album,
                        cover: String::new(),
                        duration_ms,
                    });
                    return;
                }
            }
            for v in map.values() {
                harvest(v, out, seen);
            }
        }
        Value::Array(arr) => {
            for v in arr {
                harvest(v, out, seen);
            }
        }
        _ => {}
    }
}

// playlist entity: object carrying a name next to trackList/trackCount
fn find_entity(node: &Value) -> Option<(String, String)> {
    match node {
        Value::Object(map) => {
            let has_tracks =
                map.contains_key("trackCount") || map.contains_key("trackList");
            if has_tracks {
                let name = map.get("name").and_then(|v| v.as_str()).unwrap_or("");
                if !name.is_empty() {
                    let owner = map
                        .get("owner")
                        .and_then(|o| match o {
                            Value::String(s) => Some(s.clone()),
                            Value::Object(_) => {
                                o.get("name").and_then(|v| v.as_str()).map(String::from)
                            }
                            _ => None,
                        })
                        .unwrap_or_default();
                    return Some((name.to_string(), owner));
                }
            }
            for v in map.values() {
                if let Some(hit) = find_entity(v) {
                    return Some(hit);
                }
            }
            None
        }
        Value::Array(arr) => {
            for v in arr {
                if let Some(hit) = find_entity(v) {
                    return Some(hit);
                }
            }
            None
        }
        _ => None,
    }
}

// playlist id from any URL/URI form
pub fn playlist_id(url: &str) -> Option<String> {
    if let Some(pos) = url.find("playlist/") {
        let cand: String = url[pos + 9..]
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric())
            .collect();
        if cand.len() == 22 {
            return Some(cand);
        }
    }
    if let Some(pos) = url.find("spotify:playlist:") {
        let cand: String = url[pos + 16..]
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric())
            .collect();
        if cand.len() == 22 {
            return Some(cand);
        }
    }
    None
}

struct PlaylistMeta {
    name: String,
    owner: String,
    cover: String,
}

enum ApiOutcome {
    Ok(Box<(PlaylistMeta, Vec<Found>)>),
    Throttled(u64), // retry-after seconds
    Dead,
}

// full playlist via Spotify Web API - no embed caps, covers included.
// the shared librespot client id sits in a globally saturated rate pool,
// so 429 + Retry-After is a normal, waitable condition.
async fn try_api_playlist(
    client: &reqwest::Client,
    id: &str,
    token: &str,
) -> ApiOutcome {
    let auth = format!("Bearer {token}");
    let meta_url = format!("https://api.spotify.com/v1/playlists/{id}");
    let resp = match client
        .get(&meta_url)
        .header("Authorization", &auth)
        .send()
        .await
    {
        Ok(r) => r,
        Err(_) => return ApiOutcome::Dead,
    };
    if resp.status().as_u16() == 429 {
        let ra = resp
            .headers()
            .get("retry-after")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(30);
        return ApiOutcome::Throttled(ra);
    }
    if !resp.status().is_success() {
        eprintln!("[catalog] api meta status {}", resp.status());
        return ApiOutcome::Dead;
    }
    let meta: Value = match resp.json().await {
        Ok(v) => v,
        Err(_) => return ApiOutcome::Dead,
    };
    let pm = PlaylistMeta {
        name: meta
            .pointer("/name")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        owner: meta
            .pointer("/owner/display_name")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        cover: meta
            .pointer("/images/0/url")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
    };

    let mut items = Vec::new();
    let mut offset = 0usize;
    let mut total_count = 0usize;
    let mut waited: Option<u64> = None;
    for _page in 0..25 {
        let url = format!("https://api.spotify.com/v1/playlists/{id}/tracks?limit=100&offset={offset}");
        let mut page_resp = None;
        for attempt in 0..3 {
            let Ok(resp) = client.get(&url).header("Authorization", &auth).send().await else {
                break;
            };
            if resp.status().as_u16() == 429 {
                let ra = resp
                    .headers()
                    .get("retry-after")
                    .and_then(|v| v.to_str().ok())
                    .and_then(|v| v.parse::<u64>().ok())
                    .unwrap_or(20);
                waited = Some(ra);
                if attempt < 2 {
                    // a page-level throttle is normal on the shared client:
                    // breathe, then continue this page instead of discarding
                    // every page we already fetched.
                    std::thread::sleep(Duration::from_secs(ra.min(20)));
                    continue;
                }
                page_resp = None;
                break;
            }
            page_resp = Some(resp);
            break;
        }
        let Some(resp) = page_resp else {
            break;
        };
        if !resp.status().is_success() {
            break;
        }
        let Ok(page) = resp.json::<Value>().await else {
            break;
        };
        total_count = page.pointer("/total").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
        let Some(arr) = page.get("items").and_then(|v| v.as_array()) else {
            break;
        };
        if arr.is_empty() {
            break;
        }
        for it in arr {
            let Some(t) = it.get("track") else { continue };
            let uri = t.get("uri").and_then(|v| v.as_str()).unwrap_or("").to_string();
            if !uri.starts_with("spotify:track:") {
                continue;
            }
            let artist = t
                .get("artists")
                .and_then(|a| a.as_array())
                .map(|arr| {
                    arr.iter()
                        .filter_map(|a| a.get("name").and_then(|n| n.as_str()))
                        .collect::<Vec<_>>()
                        .join(", ")
                })
                .unwrap_or_default();
            items.push(Found {
                uri,
                title: t.get("name").and_then(|v| v.as_str()).unwrap_or("").to_string(),
                artist,
                album: t.pointer("/album/name").and_then(|v| v.as_str()).unwrap_or("").to_string(),
                cover: t.pointer("/album/images/0/url").and_then(|v| v.as_str()).unwrap_or("").to_string(),
                duration_ms: t.get("duration_ms").and_then(|v| v.as_u64()).unwrap_or(0) as u32,
            });
        }
        offset += arr.len();
        if total_count > 0 && offset >= total_count {
            break;
        }
    }
    eprintln!(
        "[catalog] web api: {} / {} playlist row(s)",
        items.len(),
        total_count
    );
    if items.is_empty() {
        return match waited {
            Some(secs) => ApiOutcome::Throttled(secs),
            None => ApiOutcome::Dead,
        };
    }
    ApiOutcome::Ok(Box::new((pm, items)))
}

// public lyrics lookup (lrclib - free, no auth, no account)
// A single exact query misses too often: YouTube-sourced titles carry
// "Official Video", "feat. X", remaster tags and uploader names. We try a
// small ladder of cleaned variants and score the answers against the real
// duration, preferring a synced file every time.
/// Drop a bracketed group that credits somebody instead of naming the song:
/// "(feat. X)", "[prod. Y]", "(slowed + reverb)". A bracket that is part of
/// the title ("(Don't Fear) The Reaper") is left alone.
fn drop_credit_groups(s: &str) -> String {
    const CREDITS: [&str; 12] = [
        "feat", "ft.", "ft ", "featuring", "with ", "prod", "remix", "version", "edit",
        "live", "demo", "cover",
    ];
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(i) = rest.find(['(', '[']) {
        let open = rest.as_bytes()[i] as char;
        let close = if open == '(' { ')' } else { ']' };
        out.push_str(&rest[..i]);
        let tail = &rest[i + 1..];
        match tail.find(close) {
            Some(j) => {
                let inner = tail[..j].to_lowercase();
                if CREDITS.iter().any(|c| inner.starts_with(c) || inner.contains(c)) {
                    out.push(' ');
                } else {
                    out.push(open);
                    out.push_str(&tail[..j]);
                    out.push(close);
                }
                rest = &tail[j + 1..];
            }
            // an unbalanced bracket is just a character
            None => {
                out.push(open);
                rest = tail;
            }
        }
    }
    out.push_str(rest);
    out
}

fn lyric_clean(s: &str) -> String {
    // downloads name files with underscores where the uploader typed spaces,
    // and "feat_ X" then slips past every " feat. " rule below
    let mut out = s.replace('_', " ").replace('\u{2013}', "-").replace('\u{2014}', "-");
    out = drop_credit_groups(&out);
    for junk in [
        "(Official Video)", "[Official Video]", "(Official Music Video)",
        "[Official Music Video]", "(Official Audio)", "[Official Audio]",
        "(Lyric Video)", "[Lyric Video]", "(Lyrics)", "[Lyrics]", "(Lyric)",
        "(Visualizer)", "[Visualizer]", "(Audio)", "[Audio]", "(MV)", "[MV]",
        "(HD)", "[HD]", "(4K)", "[4K]", "(Explicit)", "[Explicit]",
    ] {
        out = out.replace(junk, " ");
    }
    let low = out.to_lowercase();
    for cut in [" feat. ", " ft. ", " feat ", " ft ", " featuring ", " prod. by ", " prod "] {
        if let Some(i) = low.find(cut) {
            out.truncate(i);
            break;
        }
    }
    // drop a leading uploader prefix such as "Artist - " when the artist is
    // already known separately (the two get recombined by the caller)
    while out.contains("  ") {
        out = out.replace("  ", " ");
    }
    out.trim().trim_matches('-').trim().to_string()
}

fn generic_artist(a: &str) -> bool {
    let l = a.trim().to_lowercase();
    // "Unknown Artist" is what a bare download writes, and it used to miss this
    // list by one word, which kept the whole recovered-title branch switched off
    l.is_empty()
        || l == "youtube"
        || l == "spotify"
        || l == "unknown"
        || l == "unknown artist"
        || l == "various"
        || l == "various artists"
        || l == "the web"
}

// "Artist - Title" (or the reverse) recovered from a messy uploader title
fn split_dash(t: &str) -> Option<(String, String)> {
    let i = t.find(" - ")?;
    let a = t[..i].trim();
    let b = t[i + 3..].trim();
    if a.len() < 2 || b.len() < 2 {
        return None;
    }
    Some((a.to_string(), b.to_string()))
}

fn lyric_enc(s: &str, out: &mut String) {
    use std::fmt::Write as _;
    for b in s.as_bytes().iter().take(160) {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                let _ = write!(out, "{}", *b as char);
            }
            _ => {
                let _ = write!(out, "%{:02X}", b);
            }
        }
    }
}

struct LyricHit {
    text: String,
    synced: bool,
    score: f64,
}

fn score_lyric_item(
    item: &Value,
    want_title: &str,
    want_artist: &str,
    want_ms: u32,
) -> Option<LyricHit> {
    if item.get("instrumental").and_then(|x| x.as_bool()).unwrap_or(false) {
        return None;
    }
    let synced = item
        .get("syncedLyrics")
        .and_then(|x| x.as_str())
        .filter(|s| !s.trim().is_empty());
    let plain = item
        .get("plainLyrics")
        .and_then(|x| x.as_str())
        .filter(|s| !s.trim().is_empty());
    let (text, is_synced) = match (synced, plain) {
        (Some(s), _) => (s.to_string(), true),
        (None, Some(p)) => (p.to_string(), false),
        _ => return None,
    };
    let name = item
        .get("trackName")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_lowercase();
    let art = item
        .get("artistName")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_lowercase();
    let mut s = 0.0;
    if !name.is_empty() && name == want_title.to_lowercase() {
        s += 8.0;
    } else if !name.is_empty() && (name.contains(&want_title.to_lowercase()) || want_title.to_lowercase().contains(&name)) {
        s += 4.0;
    }
    let want_art = want_artist.to_lowercase();
    if !want_art.is_empty() && !generic_artist(&want_art) {
        if art.contains(&want_art) || want_art.contains(&art) {
            s += 5.0;
        } else {
            s -= 3.0;
        }
    }
    if is_synced {
        s += 6.0;
    }
    let dur = item.get("duration").and_then(|x| x.as_f64()).unwrap_or(0.0);
    if want_ms > 0 && dur > 0.0 {
        let delta = (dur - want_ms as f64 / 1000.0).abs();
        if delta < 2.0 {
            s += 8.0;
        } else if delta < 5.0 {
            s += 4.0;
        } else if delta > 25.0 {
            s -= 6.0;
        }
    }
    Some(LyricHit { text, synced: is_synced, score: s })
}

pub fn fetch_lrclib(title: &str, artist: &str, album: &str, duration_ms: u32) -> Option<(String, bool)> {
    let Some(client) = build_client() else { return None };
    let Ok(rt) = tokio::runtime::Builder::new_current_thread().enable_all().build() else {
        return None;
    };
    let clean_t = lyric_clean(title);
    let clean_a = lyric_clean(artist);
    // variant ladder: exact, cleaned, and (artist/title recovered from a
    // "Artist - Title" upload) - the last one fixes most YouTube rows
    let mut variants: Vec<(String, String)> = Vec::new();
    variants.push((title.to_string(), artist.to_string()));
    if clean_t != title || clean_a != artist {
        variants.push((clean_t.clone(), clean_a.clone()));
    }
    if generic_artist(artist) {
        if let Some((a, t)) = split_dash(&clean_t) {
            variants.push((t.clone(), a.clone()));
            variants.push((t, String::new()));
        }
    }
    if let Some((a, t)) = split_dash(&clean_t) {
        if a.to_lowercase().contains(&clean_a.to_lowercase()) || clean_a.is_empty() {
            variants.push((t.clone(), a.clone()));
        }
        // last resort, and it is the one that actually finds most of them: an
        // uploader-prefixed title ("Channel - Song") in a room whose artist is
        // "Unknown Artist". The prefix is never the artist the lyrics site
        // knows, so drop it and search the song alone. Bounded to the end of
        // the ladder so a clean row never pays for it.
        variants.push((t.clone(), String::new()));
        variants.push((t, a));
    }
    let album_clean = lyric_clean(album);
    if !album.is_empty() && !generic_artist(album) {
        variants.push((clean_t.clone(), clean_a.clone()));
    }
    let mut seen: Vec<(String, String)> = Vec::new();
    variants.retain(|v| {
        if v.0.trim().is_empty() || seen.contains(v) {
            false
        } else {
            seen.push(v.clone());
            true
        }
    });

    rt.block_on(async {
        let mut best: Option<LyricHit> = None;
        fn take_best(best: &mut Option<LyricHit>, list: &Value, t: &str, a: &str, d: u32) {
            if let Some(arr) = list.as_array() {
                for item in arr.iter().take(12) {
                    if let Some(hit) = score_lyric_item(item, t, a, d) {
                        let better = match best {
                            None => true,
                            Some(b) => hit.score > b.score,
                        };
                        if better {
                            *best = Some(hit);
                        }
                    }
                }
            }
        }
        for (t, a) in variants.iter().take(6) {
            let mut url = String::from("https://lrclib.net/api/search?track_name=");
            lyric_enc(t, &mut url);
            if !a.trim().is_empty() {
                url.push_str("&artist_name=");
                lyric_enc(a, &mut url);
            }
            if let Ok(resp) = client
                .get(&url)
                .header("User-Agent", "AetherMix/0.5 (local sovereign player)")
                .send()
                .await
            {
                if resp.status().is_success() {
                    if let Ok(list) = resp.json::<Value>().await {
                        take_best(&mut best, &list, &clean_t, &clean_a, duration_ms);
                    }
                }
            }
            if let Some(b) = &best {
                if b.synced && b.score >= 14.0 {
                    break;
                }
            }
        }
        // free-text last resort: the search endpoint tolerates a plain query
        if best.as_ref().map(|b| !b.synced).unwrap_or(true) {
            let mut url = String::from("https://lrclib.net/api/search?q=");
            lyric_enc(&format!("{clean_t} {clean_a}"), &mut url);
            if let Ok(resp) = client
                .get(&url)
                .header("User-Agent", "AetherMix/0.5 (local sovereign player)")
                .send()
                .await
            {
                if resp.status().is_success() {
                    if let Ok(list) = resp.json::<Value>().await {
                        take_best(&mut best, &list, &clean_t, &clean_a, duration_ms);
                    }
                }
            }
        }
        // strict get as the final fallback, album included when we have one
        if best.is_none() {
            let mut url = String::from("https://lrclib.net/api/get?track_name=");
            lyric_enc(&clean_t, &mut url);
            url.push_str("&artist_name=");
            lyric_enc(&clean_a, &mut url);
            if !album_clean.is_empty() {
                url.push_str("&album_name=");
                lyric_enc(&album_clean, &mut url);
            }
            if let Ok(resp) = client
                .get(&url)
                .header("User-Agent", "AetherMix/0.5 (local sovereign player)")
                .send()
                .await
            {
                if resp.status().is_success() {
                    if let Ok(v) = resp.json::<Value>().await {
                        take_best(&mut best, &Value::Array(vec![v]), &clean_t, &clean_a, duration_ms);
                    }
                }
            }
        }
        best.map(|b| (b.text, b.synced))
    })
}

pub fn sync_once(lib: &Arc<Mutex<Library>>, app: &Arc<Mutex<AppState>>) -> SyncResult {
    // a hand-built playlist is not a mirror of a Spotify embed. never let a
    // background catalog sync write into it.
    if lib.lock().unwrap().playlist_source == "local" {
        let total = lib
            .lock()
            .unwrap()
            .tracks
            .iter()
            .filter(|t| t.origin == "playlist")
            .count();
        eprintln!("[catalog] active playlist is local - sync skipped");
        return SyncResult { ok: true, added: 0, playlist_total: total };
    }
    let Some(client) = build_client() else {
        return SyncResult { ok: false, added: 0, playlist_total: 0 };
    };
    let Ok(rt) = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    else {
        return SyncResult { ok: false, added: 0, playlist_total: 0 };
    };

    // ---- source 1: Web API (full playlist, no caps, covers inline) ----
    let pid = playlist_id(&playlist_url());
    let mut api_meta: Option<PlaylistMeta> = None;
    let mut found: Vec<Found> = Vec::new();
    if let Some(pid) = &pid {
        // two quick attempts, then the embed fallback: five 45-second sleeps
        // made a throttled start feel like a hang for two minutes.
        for attempt in 0..2 {
            let Some(tok) = crate::stream::access_token() else { break };
            match rt.block_on(try_api_playlist(&client, pid, &tok)) {
                ApiOutcome::Ok(boxed) => {
                    let (meta, items) = *boxed;
                    eprintln!("[catalog] web api: {} tracks", items.len());
                    api_meta = Some(meta);
                    found = items;
                    break;
                }
                ApiOutcome::Throttled(secs) => {
                    let wait = secs.min(6);
                    eprintln!("[catalog] api throttled - waiting {wait}s (attempt {})", attempt + 1);
                    std::thread::sleep(Duration::from_secs(wait));
                    if attempt == 0 {
                        let _ = crate::stream::refresh_access_token();
                    }
                }
                ApiOutcome::Dead => {
                    if attempt == 0 {
                        eprintln!("[catalog] api failed - refreshing token");
                        let _ = crate::stream::refresh_access_token();
                        std::thread::sleep(Duration::from_secs(2));
                    } else {
                        break;
                    }
                }
            }
        }
    }

    // ---- source 2: public embed (fallback when the API path is unavailable) ----
    let mut embed_name = String::new();
    let mut embed_owner = String::new();
    if found.is_empty() {
        let Some(html) = rt.block_on(fetch_embed_html(&client)) else {
            eprintln!("[catalog] sync unavailable - keeping snapshot");
            return SyncResult { ok: false, added: 0, playlist_total: 0 };
        };
        let mut root = match serde_json::from_str::<Value>(&html) {
            Ok(v) => Some(v),
            Err(_) => {
                let mut hit = None;
                for blob in extract_json_blobs(&html) {
                    if let Ok(v) = serde_json::from_str::<Value>(&blob) {
                        let mut probe = Vec::new();
                        let mut seen = HashSet::new();
                        harvest(&v, &mut probe, &mut seen);
                        if !probe.is_empty() {
                            hit = Some(v);
                            break;
                        }
                    }
                }
                hit
            }
        };
        match root.take() {
            Some(v) => {
                harvest(&v, &mut found, &mut HashSet::new());
                if let Some((n, o)) = find_entity(&v) {
                    embed_name = n;
                    embed_owner = o;
                }
            }
            None => {
                eprintln!("[catalog] no track JSON found - keeping snapshot");
                return SyncResult { ok: false, added: 0, playlist_total: 0 };
            }
        }
    }

    if found.is_empty() {
        eprintln!("[catalog] harvest empty - keeping snapshot");
        return SyncResult { ok: false, added: 0, playlist_total: 0 };
    }
    let total = found.len();

    // which uris are new? (read lock only)
    let known: HashSet<String> = {
        let l = lib.lock().unwrap();
        l.tracks
            .iter()
            .filter(|t| !t.uri.is_empty())
            .map(|t| t.uri.clone())
            .collect()
    };

    // a song the listener removed from this playlist stays removed: the sync
    // respects the tombstones instead of quietly mirroring it back in.
    let removed: Vec<String> = {
        let l = lib.lock().unwrap();
        l.removed.clone()
    };

    // covers for new rows: inline when present, oEmbed otherwise (no locks held)
    let mut fresh: Vec<(&Found, String)> = Vec::new();
    for f in &found {
        if known.contains(&f.uri) || removed.contains(&f.uri) {
            continue;
        }
        let raw = if f.cover.is_empty() {
            rt.block_on(fetch_track_cover(&client, &f.uri))
        } else {
            f.cover.clone()
        };
        let cover = local_cover_for(&client, &rt, &f.uri, &raw);
        fresh.push((f, cover));
    }

    let fresh_playlist_cover = api_meta
        .as_ref()
        .map(|m| local_cover_for(&client, &rt, "playlist", &m.cover))
        .unwrap_or_default();
    let mut changed = false;
    let added = {
        let mut l = lib.lock().unwrap();
        let name = api_meta.as_ref().map(|m| m.name.clone()).unwrap_or(embed_name);
        let owner = api_meta.as_ref().map(|m| m.owner.clone()).unwrap_or(embed_owner);
        if !name.is_empty() && name != l.playlist_name {
            l.playlist_name = name;
            changed = true;
        }
        if !owner.is_empty() && owner != l.playlist_owner {
            l.playlist_owner = owner;
            changed = true;
        }
        if !fresh_playlist_cover.is_empty() && fresh_playlist_cover != l.playlist_cover {
            l.playlist_cover = fresh_playlist_cover;
            changed = true;
        }
        let mut added = 0usize;
        for (f, cover) in &fresh {
            l.push_stream_track(&f.uri, &f.title, &f.artist, &f.album, f.duration_ms, cover);
            added += 1;
        }
        // backfill durations + covers for known rows from the fresh harvest
        for t in l.tracks.iter_mut() {
            if t.uri.is_empty() {
                continue;
            }
            if let Some(f) = found.iter().find(|f| f.uri == t.uri) {
                if t.cover_file.is_empty() && !f.cover.is_empty() {
                    t.cover_file = f.cover.clone();
                    changed = true;
                }
                if t.duration_ms == 0 && f.duration_ms > 0 {
                    t.duration_ms = f.duration_ms;
                    changed = true;
                }
            }
        }
        if added > 0 {
            println!("[catalog] +{added} new track(s) mirrored from playlist");
        }
        if changed || added > 0 {
            l.version += 1;
        }
        app.lock().unwrap().library_version = l.version;
        added
    };

    // cover backfill for whatever is still bare (oEmbed sweep, disk-cached)
    backfill_covers(&client, &rt, lib, app);

    // local rows without art inherit covers from matched playlist rows
    {
        let mut l = lib.lock().unwrap();
        let mut by_title = std::collections::HashMap::new();
        for t in l.tracks.iter().filter(|t| t.origin == "playlist") {
            if !t.cover_file.is_empty() {
                let nt = crate::library::norm_title(&t.title);
                if !nt.is_empty() {
                    by_title.insert(nt, t.cover_file.clone());
                }
            }
        }
        let mut linked = 0;
        for t in l.tracks.iter_mut() {
            if t.origin == "local" && t.cover_file.is_empty() {
                let nt = crate::library::norm_title(&t.title);
                if let Some(c) = by_title.get(&nt) {
                    t.cover_file = c.clone();
                    linked += 1;
                }
            }
        }
        if linked > 0 {
            eprintln!("[catalog] {linked} local rows inherited playlist art");
            l.version += 1;
            app.lock().unwrap().library_version = l.version;
        }
    }

    // the synced catalog is valuable: keep it on disk so the full playlist is
    // still there after a restart, even when the public API is throttled.
    {
        let l = lib.lock().unwrap();
        l.save_playlist();
    }

    SyncResult { ok: true, added, playlist_total: total }
}

const COVER_CACHE: &str = concat!(env!("AETHER_ROOT"), "/cache/covers/catalog.json");
const COVERS_DIR: &str = concat!(env!("AETHER_ROOT"), "/cache/covers");

fn cover_key(uri_or_key: &str) -> String {
    uri_or_key
        .trim_start_matches("spotify:track:")
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-')
        .collect()
}

// remote art becomes a local file beside the other covers: the library keeps
// working offline, and every row can point at a real, relative image.
fn local_cover_for(
    client: &reqwest::Client,
    rt: &tokio::runtime::Runtime,
    key: &str,
    url: &str,
) -> String {
    if url.is_empty() || !url.starts_with("http") {
        return url.to_string();
    }
    let safe = cover_key(key);
    if safe.is_empty() {
        return url.to_string();
    }
    let ext = if url.contains(".png") || url.contains("format=png") {
        "png"
    } else if url.contains(".webp") {
        "webp"
    } else {
        "jpg"
    };
    let path = format!("{COVERS_DIR}/{safe}.{ext}");
    if std::path::Path::new(&path).is_file() {
        // a cached file that is not an image would be a permanent broken cover
        let head = std::fs::read(&path).unwrap_or_default();
        if crate::library::looks_like_image(&head) {
            return format!("file:///{path}");
        }
        let _ = std::fs::remove_file(&path);
    }
    let bytes = rt.block_on(async {
        let resp = client.get(url).send().await.ok()?;
        if !resp.status().is_success() {
            return None;
        }
        resp.bytes().await.ok()
    });
    match bytes {
        Some(b) if crate::library::looks_like_image(&b) => match std::fs::write(&path, &b) {
            Ok(_) => format!("file:///{path}"),
            Err(_) => url.to_string(),
        },
        _ => url.to_string(),
    }
}

fn load_cover_cache() -> serde_json::Value {
    std::fs::read_to_string(COVER_CACHE)
        .ok()
        .and_then(|b| serde_json::from_str::<serde_json::Value>(&b).ok())
        .unwrap_or_else(|| serde_json::json!({}))
}

fn backfill_covers(
    client: &reqwest::Client,
    rt: &tokio::runtime::Runtime,
    lib: &Arc<Mutex<Library>>,
    app: &Arc<Mutex<AppState>>,
) {
    // pull any cover that is still a remote url onto disk once, then use files forever
    let remote: Vec<(usize, String, String)> = {
        let l = lib.lock().unwrap();
        l.tracks
            .iter()
            .filter(|t| t.cover_file.starts_with("http"))
            .map(|t| (t.id, t.uri.clone(), t.cover_file.clone()))
            .collect()
    };
    if !remote.is_empty() {
        let mut downloaded = 0;
        for (id, uri, url) in &remote {
            let key = if uri.is_empty() {
                format!("cover-{id}")
            } else {
                cover_key(uri)
            };
            let local = local_cover_for(client, rt, &key, url);
            if local != *url {
                let mut l = lib.lock().unwrap();
                if let Some(t) = l.tracks.get_mut(*id) {
                    t.cover_file = local;
                }
                downloaded += 1;
            }
        }
        if downloaded > 0 {
            eprintln!("[catalog] {downloaded} remote cover(s) stored locally");
            let mut l = lib.lock().unwrap();
            l.version += 1;
            app.lock().unwrap().library_version = l.version;
        }
    }

    let missing: Vec<(usize, String)> = {
        let l = lib.lock().unwrap();
        l.tracks
            .iter()
            .filter(|t| t.origin == "playlist" && !t.uri.is_empty() && t.cover_file.is_empty())
            .map(|t| (t.id, t.uri.clone()))
            .collect()
    };
    if missing.is_empty() {
        return;
    }
    let mut cache = load_cover_cache();
    let mut to_fetch: Vec<(usize, String, String)> = Vec::new();
    for (id, uri) in &missing {
        let key = uri.trim_start_matches("spotify:track:").to_string();
        let hit = cache
            .get(&key)
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());
        match hit {
            Some(u) => {
                let mut l = lib.lock().unwrap();
                if let Some(t) = l.tracks.get_mut(*id) {
                    t.cover_file = u;
                }
            }
            None => to_fetch.push((*id, uri.clone(), key)),
        }
    }
    if to_fetch.is_empty() {
        let mut l = lib.lock().unwrap();
        l.version += 1;
        app.lock().unwrap().library_version = l.version;
        return;
    }
    eprintln!("[catalog] fetching {} cover(s) via oEmbed...", to_fetch.len());
    use futures::stream::{self, StreamExt};
    let results: Vec<((usize, String), String)> = rt.block_on(async {
        stream::iter(to_fetch.into_iter().map(|(id, uri, key)| {
            let client = client.clone();
            async move {
                let c = fetch_track_cover(&client, &uri).await;
                ((id, key), c)
            }
        }))
        .buffer_unordered(6)
        .collect()
        .await
    });
    // store the image first (no library lock held), then attach the file url
    let results: Vec<((usize, String), String)> = results
        .into_iter()
        .map(|((id, key), cover)| {
            let local = local_cover_for(client, rt, &key, &cover);
            ((id, key), local)
        })
        .collect();
    let mut fetched = 0;
    let mut l = lib.lock().unwrap();
    for ((id, key), cover) in results {
        if !cover.is_empty() {
            if let Some(t) = l.tracks.get_mut(id) {
                t.cover_file = cover.clone();
            }
            if let Some(o) = cache.as_object_mut() {
                o.insert(key, serde_json::Value::String(cover));
            }
            fetched += 1;
        }
    }
    if fetched > 0 {
        eprintln!("[catalog] +{fetched} covers");
        if let Ok(b) = serde_json::to_string_pretty(&cache) {
            let _ = std::fs::write(COVER_CACHE, b);
        }
        l.version += 1;
        app.lock().unwrap().library_version = l.version;
    }
}

// startup sync + periodic re-check (only while a streaming session is live)
pub fn spawn_sync_worker(lib: Arc<Mutex<Library>>, app: Arc<Mutex<AppState>>) {
    std::thread::Builder::new()
        .name("catalog-sync".into())
        .spawn(move || {
            // the streaming thread needs a few seconds to refresh the OAuth token;
            // wait for it so the first sync can use the Web API path (full playlist)
            for _ in 0..20 {
                if crate::stream::available() {
                    break;
                }
                std::thread::sleep(Duration::from_secs(2));
            }
            sync_once(&lib, &app);
            loop {
                std::thread::sleep(Duration::from_secs(900));
                if crate::stream::available() {
                    sync_once(&lib, &app);
                }
            }
        })
        .expect("spawn catalog sync");
}
