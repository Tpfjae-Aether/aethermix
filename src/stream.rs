// lang: Rust, file: stream.rs
// librespot streaming - lazy credential chain:
//   1. spotify_login.json (password, legacy - Spotify may email-challenge this)
//   2. oauth_token.json (browser OAuth refresh token - the reliable path)
//   3. cache/credentials.json (librespot session cache)
//   4. none -> offline local mode, zero runtime cost
use crate::audio::{Core, EngineSink};
use crate::player::PlayerCmd;
use crate::state::AppState;
use librespot_core::authentication::Credentials;
use librespot_core::cache::Cache;
use librespot_core::session::Session;
use librespot_metadata::audio::{AudioItem, UniqueFields};
use librespot_oauth::OAuthClientBuilder;
use librespot_playback::audio_backend::Sink;
use librespot_playback::config::{Bitrate, PlayerConfig};
use librespot_playback::mixer::NoOpVolume;
use librespot_playback::player::{Player, PlayerEvent};
use std::path::PathBuf;
use std::sync::atomic::Ordering;
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

pub static PLAYER: OnceLock<Arc<Player>> = OnceLock::new();
pub static ACCESS_TOKEN: Mutex<Option<String>> = Mutex::new(None);

pub fn access_token() -> Option<String> {
    ACCESS_TOKEN.lock().ok().and_then(|g| g.clone())
}

// refresh from the saved oauth token; also updates the shared access token
pub fn refresh_access_token() -> Option<String> {
    match creds_from_oauth_file() {
        Some(_) => access_token(),
        None => None,
    }
}

const LOGIN_FILE: &str = concat!(env!("AETHER_ROOT"), "/spotify_login.json");
const OAUTH_FILE: &str = concat!(env!("AETHER_ROOT"), "/oauth_token.json");
const CACHE_DIR: &str = concat!(env!("AETHER_ROOT"), "/cache");

// Spotify's public web/desktop client id (same one librespot-core embeds)
const CLIENT_ID: &str = "65b708073fc0480ea92a077233ca87bd";
// loopback redirect: Spotify accepts localhost redirects for public clients
const REDIRECT_URI: &str = "http://127.0.0.1:8898/login";

const SCOPES: [&str; 17] = [
    "streaming",
    "app-remote-control",
    "user-read-email",
    "user-read-private",
    "user-read-playback-state",
    "user-modify-playback-state",
    "user-read-currently-playing",
    "user-read-playback-position",
    "playlist-read-private",
    "playlist-read-collaborative",
    "user-library-read",
    "user-follow-read",
    "user-top-read",
    "user-read-recently-played",
    "playlist-modify-public",
    "playlist-modify-private",
    "user-library-modify",
];

pub fn available() -> bool {
    PLAYER.get().is_some()
}

// stream health: a session can be CONNECTED but useless (free-tier account,
// per-account audio-key block). The first failed playback trips the gate and
// every later stream attempt fails fast with an honest status instead of wedging.
pub static STREAM_USABLE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(true);

pub fn usable() -> bool {
    available() && STREAM_USABLE.load(std::sync::atomic::Ordering::Relaxed)
}

pub fn mark_unusable() {
    STREAM_USABLE.store(false, std::sync::atomic::Ordering::Relaxed);
    crate::state::set_config_str("stream_healthy", "0");
    eprintln!("[stream] session marked UNUSABLE for playback (free tier or key denial)");
}

pub fn mark_usable() {
    STREAM_USABLE.store(true, std::sync::atomic::Ordering::Relaxed);
    crate::state::set_config_str("stream_healthy", "1");
}

// client id: private app id from config, else the shared librespot keymaster id
pub fn client_id() -> String {
    std::fs::read_to_string(crate::state::CONFIG_FILE)
        .ok()
        .and_then(|b| serde_json::from_str::<serde_json::Value>(&b).ok())
        .and_then(|v| {
            v.get("client_id")
                .and_then(|x| x.as_str())
                .map(String::from)
        })
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "65b708073fc0480ea92a077233ca87bd".to_string())
}

// ---------------- Web API helpers (patient against the shared rate pool) ----------------
fn read_retry_after(resp: &reqwest::Response) -> u64 {
    resp.headers()
        .get("retry-after")
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(10)
}

// one client and one runtime for every API call. building a fresh TLS stack
// per request cost ~200ms and a thread each; the shared pool is both faster
// and gentler on the rate limiter.
static API_CLIENT: OnceLock<reqwest::Client> = OnceLock::new();
static API_RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
static API_CACHE: Mutex<Option<std::collections::HashMap<String, (std::time::Instant, String)>>> =
    Mutex::new(None);
static API_COOL_UNTIL: Mutex<Option<std::time::Instant>> = Mutex::new(None);

fn api_client() -> Option<&'static reqwest::Client> {
    Some(API_CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .timeout(Duration::from_secs(15))
            .build()
            .expect("api client")
    }))
}

fn api_runtime() -> Option<&'static tokio::runtime::Runtime> {
    Some(API_RT.get_or_init(|| {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .expect("api runtime")
    }))
}

fn cache_get(path: &str, ttl_secs: u64) -> Option<String> {
    let g = API_CACHE.lock().ok()?;
    let map = g.as_ref()?;
    let (at, body) = map.get(path)?;
    if at.elapsed().as_secs() <= ttl_secs {
        Some(body.clone())
    } else {
        None
    }
}

fn cache_put(path: &str, body: &str) {
    if let Ok(mut g) = API_CACHE.lock() {
        let map = g.get_or_insert_with(std::collections::HashMap::new);
        if map.len() > 60 {
            map.clear();
        }
        map.insert(path.to_string(), (std::time::Instant::now(), body.to_string()));
    }
}

fn cooling_down() -> bool {
    API_COOL_UNTIL
        .lock()
        .ok()
        .and_then(|g| *g)
        .map(|t| std::time::Instant::now() < t)
        .unwrap_or(false)
}

fn start_cooldown(secs: u64) {
    if let Ok(mut g) = API_COOL_UNTIL.lock() {
        *g = Some(std::time::Instant::now() + Duration::from_secs(secs.clamp(2, 90)));
    }
}

pub fn api_get(path: &str, wait_cap_secs: u64) -> Option<String> {
    // a hit is a hit for a minute: opening the same room twice must not spend
    // the shared rate pool twice.
    if let Some(body) = cache_get(path, 60) {
        return Some(body);
    }
    // once Spotify says 429, every caller goes quiet until the window passes
    // instead of sleeping 24 seconds in three parallel UI fetches.
    if cooling_down() {
        return cache_get(path, 600);
    }
    let (client, rt) = (api_client()?, api_runtime()?);
    let tok = access_token()?;
    let url = format!("https://api.spotify.com{path}");
    let result = rt.block_on(async {
        let resp = client
            .get(&url)
            .header("Authorization", format!("Bearer {tok}"))
            .send()
            .await
            .ok()?;
        if resp.status().as_u16() == 429 {
            let wait = read_retry_after(&resp).min(wait_cap_secs.max(2));
            eprintln!("[api] 429 - cooling {wait}s");
            start_cooldown(wait);
            return None;
        }
        if !resp.status().is_success() {
            eprintln!("[api] {} -> {}", path, resp.status());
            return None;
        }
        resp.text().await.ok()
    });
    if let Some(body) = &result {
        cache_put(path, body);
    }
    result
}

// POST with a JSON body; returns (status, body) so callers can see 201 vs 403
pub fn api_post(path: &str, body: &str, wait_cap_secs: u64) -> Option<(u16, String)> {
    if cooling_down() {
        return None;
    }
    let (client, rt) = (api_client()?, api_runtime()?);
    let tok = access_token()?;
    let url = format!("https://api.spotify.com{path}");
    rt.block_on(async {
        let resp = client
            .post(&url)
            .header("Authorization", format!("Bearer {tok}"))
            .header("Content-Type", "application/json")
            .body(body.to_string())
            .send()
            .await
            .ok()?;
        if resp.status().as_u16() == 429 {
            let wait = read_retry_after(&resp).min(wait_cap_secs.max(2));
            eprintln!("[api] 429 - cooling {wait}s");
            start_cooldown(wait);
            return None;
        }
        let code = resp.status().as_u16();
        let text = resp.text().await.unwrap_or_default();
        Some((code, text))
    })
}

// ---------------- suggestion pool for smart shuffle ----------------
pub struct Sugg {
    pub uri: String,
    pub title: String,
    pub artist: String,
    pub cover: String,
    pub duration_ms: u32,
}

pub static SUGGESTIONS: Mutex<Vec<Sugg>> = Mutex::new(Vec::new());

pub fn take_suggestion() -> Option<Sugg> {
    let mut g = SUGGESTIONS.lock().ok()?;
    if g.is_empty() {
        None
    } else {
        Some(g.remove(0))
    }
}

fn parse_track(t: &serde_json::Value) -> Sugg {
    Sugg {
        uri: t.get("uri").and_then(|x| x.as_str()).unwrap_or("").to_string(),
        title: t.get("name").and_then(|x| x.as_str()).unwrap_or("").to_string(),
        artist: t
            .get("artists")
            .and_then(|a| a.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|a| a.get("name").and_then(|n| n.as_str()))
                    .collect::<Vec<_>>()
                    .join(", ")
            })
            .unwrap_or_default(),
        cover: t
            .pointer("/album/images/0/url")
            .and_then(|x| x.as_str())
            .unwrap_or("")
            .to_string(),
        duration_ms: t.get("duration_ms").and_then(|x| x.as_u64()).unwrap_or(0) as u32,
    }
}

// capped variant for interactive calls
pub fn refresh_suggestions_capped(seed_uri: &str, playlist_uri: &str) {
    refresh_suggestions_inner(seed_uri, playlist_uri, 8);
}

// refresh the suggestion pool seeded by the current track (or the playlist)
pub fn refresh_suggestions(seed_uri: &str, playlist_uri: &str) {
    refresh_suggestions_inner(seed_uri, playlist_uri, 45);
}

fn refresh_suggestions_inner(seed_uri: &str, playlist_uri: &str, cap: u64) {
    let mut pool: Vec<Sugg> = Vec::new();
    if !seed_uri.is_empty() {
        let path = format!(
            "/v1/recommendations?limit=10&seed_tracks={}",
            seed_uri.trim_start_matches("spotify:track:")
        );
        if let Some(body) = api_get(&path, cap) {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&body) {
                if let Some(arr) = v.get("tracks").and_then(|x| x.as_array()) {
                    for t in arr {
                        pool.push(parse_track(t));
                    }
                }
            }
        }
    }
    if pool.is_empty() && !playlist_uri.is_empty() {
        // fallback: seed from the playlist id itself
        let pid = playlist_uri.trim_start_matches("spotify:playlist:").to_string();
        let path = format!("/v1/recommendations?limit=10&seed_playlists={pid}");
        if let Some(body) = api_get(&path, cap) {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&body) {
                if let Some(arr) = v.get("tracks").and_then(|x| x.as_array()) {
                    for t in arr {
                        pool.push(parse_track(t));
                    }
                }
            }
        }
    }
    if let Ok(mut g) = SUGGESTIONS.lock() {
        *g = pool;
        eprintln!("[api] suggestions: {}", g.len());
    }
}

fn set_status(app: &Arc<Mutex<AppState>>, msg: &str) {
    if let Ok(mut s) = app.lock() {
        s.status = msg.into();
    }
}

fn cache_path() -> PathBuf {
    PathBuf::from(CACHE_DIR).join("credentials.json")
}

fn make_cache() -> Option<Cache> {
    let dir = PathBuf::from(CACHE_DIR);
    let _ = std::fs::create_dir_all(&dir);
    Cache::new(Some(cache_path()), None, None, None).ok()
}

// password login file (legacy)
fn read_login_file() -> Option<Credentials> {
    let body = std::fs::read_to_string(LOGIN_FILE).ok()?;
    let v: serde_json::Value = serde_json::from_str(&body).ok()?;
    let user = v.get("username")?.as_str()?.to_string();
    let pass = v.get("password")?.as_str()?.to_string();
    if user.is_empty() || pass.is_empty() {
        return None;
    }
    Some(Credentials::with_password(user, pass))
}

fn save_oauth_token(refresh_token: &str) {
    let v = serde_json::json!({ "refresh_token": refresh_token });
    if let Ok(body) = serde_json::to_string_pretty(&v) {
        let _ = std::fs::write(OAUTH_FILE, body);
    }
}

// OAuth: exchange the saved refresh token for a fresh access token.
// Spotify rotates refresh tokens on use, so the new one is written back.
fn creds_from_oauth_file() -> Option<Credentials> {
    let body = std::fs::read_to_string(OAUTH_FILE).ok()?;
    let v: serde_json::Value = serde_json::from_str(&body).ok()?;
    let refresh = v.get("refresh_token")?.as_str()?.to_string();
    if refresh.is_empty() {
        return None;
    }
    let client = OAuthClientBuilder::new(&client_id(), REDIRECT_URI, SCOPES.to_vec())
        .build()
        .ok()?;
    match client.refresh_token(&refresh) {
        Ok(token) => {
            save_oauth_token(&token.refresh_token);
            if let Ok(mut g) = ACCESS_TOKEN.lock() {
                *g = Some(token.access_token.clone());
            }
            Some(Credentials::with_access_token(token.access_token))
        }
        Err(e) => {
            eprintln!("[stream] oauth refresh failed: {e}");
            None
        }
    }
}

fn apply_audio_item(app: &Arc<Mutex<AppState>>, core: &Arc<Core>, item: &AudioItem) {
    {
        let mut s = app.lock().unwrap();
        s.title = item.name.clone();
        s.cover_url = item
            .covers
            .first()
            .map(|c| c.url.clone())
            .unwrap_or_default();
        if let UniqueFields::Track {
            artists, album, ..
        } = &item.unique_fields
        {
            s.artist = artists
                .iter()
                .map(|a| a.name.clone())
                .collect::<Vec<_>>()
                .join(", ");
            s.album = album.clone();
        }
    }
    core.duration_ms.store(item.duration_ms, Ordering::Relaxed);
}

fn pump(
    app: Arc<Mutex<AppState>>,
    core: Arc<Core>,
    tx: Sender<PlayerCmd>,
    channel: &mut librespot_playback::player::PlayerEventChannel,
) {
    while let Some(ev) = channel.blocking_recv() {
        match ev {
            PlayerEvent::TrackChanged { audio_item } => {
                apply_audio_item(&app, &core, &audio_item);
            }
            PlayerEvent::Playing { position_ms, .. } => {
                core.playing.store(true, Ordering::Relaxed);
                core.position_ms.store(position_ms, Ordering::Relaxed);
            }
            PlayerEvent::Paused { position_ms, .. } => {
                core.playing.store(false, Ordering::Relaxed);
                core.position_ms.store(position_ms, Ordering::Relaxed);
            }
            PlayerEvent::Stopped { .. } => {
                core.playing.store(false, Ordering::Relaxed);
            }
            PlayerEvent::Seeked { position_ms, .. }
            | PlayerEvent::PositionChanged { position_ms, .. }
            | PlayerEvent::PositionCorrection { position_ms, .. } => {
                core.position_ms.store(position_ms, Ordering::Relaxed);
            }
            PlayerEvent::EndOfTrack { .. } => {
                let _ = tx.send(PlayerCmd::Next);
            }
            PlayerEvent::Unavailable { .. } => {
                app.lock().unwrap().status = "track unavailable on spotify".into();
                core.playing.store(false, Ordering::Relaxed);
                let _ = tx.send(PlayerCmd::Next);
            }
            PlayerEvent::SessionConnected { user_name, .. } => {
                app.lock().unwrap().status = format!("stream session: {user_name}");
            }
            PlayerEvent::SessionDisconnected { .. } => {
                app.lock().unwrap().status = "stream session lost".into();
            }
            _ => {}
        }
    }
}

// bring up the session + player on a leaked runtime; shared by startup and the
// live oauth flow (which enables streaming without an app restart)
fn bring_up(
    app: Arc<Mutex<AppState>>,
    core: Arc<Core>,
    tx: Sender<PlayerCmd>,
    cache: Option<Cache>,
    creds: Credentials,
) {
    mark_usable(); // fresh session: reset the playback-health gate
    let rt = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
        Ok(rt) => Box::leak(Box::new(rt)),
        Err(e) => {
            set_status(&app, &format!("stream runtime failed: {e}"));
            return;
        }
    };

    let session = match rt.block_on(async {
        let s = Session::new(librespot_core::config::SessionConfig::default(), cache);
        s.connect(creds, true).await.map(|_| s)
    }) {
        Ok(s) => s,
        Err(e) => {
            eprintln!("[stream] login failed: {e}");
            set_status(&app, &format!("stream login failed: {e}"));
            return;
        }
    };

    let player_config = PlayerConfig {
        bitrate: Bitrate::Bitrate320,
        position_update_interval: Some(Duration::from_millis(1000)),
        ..Default::default()
    };

    let core_sink = core.clone();
    let player = Player::new(
        player_config,
        session,
        Box::new(NoOpVolume),
        move || Box::new(EngineSink(core_sink)) as Box<dyn Sink>,
    );
    let _ = PLAYER.set(player.clone());
    eprintln!("[stream] session live - catalog streaming enabled");
    set_status(&app, "stream ready");

    let mut channel = player.get_player_event_channel();
    pump(app, core, tx, &mut channel);
}

pub fn start(
    app: Arc<Mutex<AppState>>,
    core: Arc<Core>,
    _lib: Arc<Mutex<crate::library::Library>>,
    _pst: Arc<Mutex<crate::player::PlayerState>>,
    tx: Sender<PlayerCmd>,
) {
    std::thread::Builder::new()
        .name("stream".into())
        .spawn(move || {
            let cache = make_cache();
            let creds = match read_login_file() {
                Some(c) => Some(c),
                None => match creds_from_oauth_file() {
                    Some(c) => Some(c),
                    None => cache.as_ref().and_then(|c| c.credentials()),
                },
            };
            let Some(creds) = creds else {
                eprintln!("[stream] off - no credentials (password file, oauth token, or cache)");
                let mut s = app.lock().unwrap();
                if s.status == "ready" {
                    s.status = "local mode - connect streaming in the sidebar".into();
                }
                return;
            };
            // Premium sessions boot safely - bring the session up even when the
            // last one was audio-denied: the Web API (catalog, shell control)
            // still works, only librespot AUDIO stays blocked via STREAM_USABLE.
            bring_up(app, core, tx, cache, creds);
        })
        .expect("spawn stream thread");
}

// live browser authorize: opens the browser, waits for the localhost callback,
// saves the refresh token, and brings the session up immediately
pub fn start_oauth_flow(app: Arc<Mutex<AppState>>, core: Arc<Core>, tx: Sender<PlayerCmd>) {
    start_oauth_flow_inner(app, core, tx, false)
}

// force = re-authorize even while a session is live (needed to upgrade scopes:
// a live session cannot add playlist-write, so GRANT must always open the browser)
pub fn start_oauth_flow_force(app: Arc<Mutex<AppState>>, core: Arc<Core>, tx: Sender<PlayerCmd>) {
    start_oauth_flow_inner(app, core, tx, true)
}

fn start_oauth_flow_inner(app: Arc<Mutex<AppState>>, core: Arc<Core>, tx: Sender<PlayerCmd>, force: bool) {
    std::thread::Builder::new()
        .name("oauth".into())
        .spawn(move || {
            if available() && !force {
                set_status(&app, "stream already live");
                return;
            }
            set_status(&app, "oauth: complete the login in your browser");
            eprintln!("[oauth] opening browser for Spotify authorization...");
            let client = match OAuthClientBuilder::new(&client_id(), REDIRECT_URI, SCOPES.to_vec())
                .open_in_browser()
                .build()
            {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("[oauth] client build failed: {e}");
                    set_status(&app, &format!("oauth failed: {e}"));
                    return;
                }
            };
            match client.get_access_token() {
                Ok(token) => {
                    save_oauth_token(&token.refresh_token);
                    if let Ok(mut g) = ACCESS_TOKEN.lock() {
                        *g = Some(token.access_token.clone());
                    }
                    eprintln!("[oauth] authorized - refresh token saved");
                    set_status(&app, "oauth authorized - starting session");
                    let cache = make_cache();
                    bring_up(
                        app,
                        core,
                        tx,
                        cache,
                        Credentials::with_access_token(token.access_token),
                    );
                }
                Err(e) => {
                    eprintln!("[oauth] authorize failed: {e}");
                    set_status(&app, &format!("oauth failed: {e}"));
                }
            }
        })
        .expect("spawn oauth thread");
}
