// lang: Rust, file: state.rs
// shared UI state + config persistence (spicetify-style config)
use crate::audio::Core;
use crate::player::PlayerState;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};

pub struct AppState {
    pub status: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub origin: String,
    pub cover_url: String,
    pub volume: u32,
    pub viz_mode: u32,
    pub theme: String,
    pub levels: Vec<f32>,
    pub wave: Vec<f32>,
    pub library_version: u64,
    pub track_id: Option<usize>,
    pub lyric_offset_ms: i64,
    pub page: i64,
    pub shell_mode: bool,
}

impl Default for AppState {
    fn default() -> Self {
        Self {
            status: String::from("ready"),
            title: String::new(),
            artist: String::new(),
            album: String::new(),
            origin: String::new(),
            cover_url: String::new(),
            volume: 70,
            viz_mode: 0,
            theme: String::from("frutiger"),
            levels: vec![0.0; 32],
            wave: vec![0.0; 64],
            library_version: 0,
            track_id: None,
            lyric_offset_ms: 0,
            page: 5,
            shell_mode: false,
        }
    }
}

pub const CONFIG_FILE: &str = concat!(env!("AETHER_ROOT"), "/config.json");
const PLAYSTATS_FILE: &str = concat!(env!("AETHER_ROOT"), "/playstats.json");

use std::collections::HashMap;

pub struct PlayStats {
    pub plays: HashMap<usize, u64>,
    pub recent: Vec<usize>,
}

impl PlayStats {
    pub fn load() -> Self {
        let mut plays = HashMap::new();
        let mut recent = Vec::new();
        if let Ok(b) = std::fs::read_to_string(PLAYSTATS_FILE) {
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&b) {
                if let Some(map) = v.get("plays").and_then(|x| x.as_object()) {
                    for (k, val) in map {
                        if let (Ok(id), Some(n)) = (k.parse::<usize>(), val.as_u64()) {
                            plays.insert(id, n);
                        }
                    }
                }
                if let Some(arr) = v.get("recent").and_then(|x| x.as_array()) {
                    for id in arr.iter().filter_map(|x| x.as_u64()) {
                        recent.push(id as usize);
                    }
                }
            }
        }
        Self { plays, recent }
    }

    pub fn save(&self) {
        let v = serde_json::json!({
            "plays": self.plays.iter().map(|(k, v)| (k.to_string(), v)).collect::<std::collections::HashMap<_, _>>(),
            "recent": self.recent,
        });
        if let Ok(b) = serde_json::to_string_pretty(&v) {
            let _ = std::fs::write(PLAYSTATS_FILE, b);
        }
    }

    pub fn record(&mut self, id: usize) {
        *self.plays.entry(id).or_insert(0) += 1;
        self.recent.retain(|r| *r != id);
        self.recent.insert(0, id);
        if self.recent.len() > 12 {
            self.recent.truncate(12);
        }
        self.save();
    }

    pub fn top(&self, n: usize) -> Vec<(usize, u64)> {
        let mut v: Vec<(usize, u64)> = self.plays.iter().map(|(k, c)| (*k, *c)).collect();
        v.sort_by(|a, b| b.1.cmp(&a.1));
        v.truncate(n);
        v
    }
}

pub static PLAYSTATS: std::sync::Mutex<Option<PlayStats>> = std::sync::Mutex::new(None);

pub fn stats_init() {
    let mut g = PLAYSTATS.lock().unwrap();
    *g = Some(PlayStats::load());
}

pub fn record_play(id: usize) {
    let mut g = PLAYSTATS.lock().unwrap();
    if let Some(st) = g.as_mut() {
        st.record(id);
    }
}

pub fn plays_of(id: usize) -> u64 {
    let g = PLAYSTATS.lock().unwrap();
    g.as_ref().map(|st| *st.plays.get(&id).unwrap_or(&0)).unwrap_or(0)
}

pub fn recent_set() -> std::collections::HashSet<usize> {
    let g = PLAYSTATS.lock().unwrap();
    match g.as_ref() {
        Some(st) => st.recent.iter().take(6).copied().collect(),
        None => std::collections::HashSet::new(),
    }
}

pub fn stats_snapshot() -> serde_json::Value {
    let g = PLAYSTATS.lock().unwrap();
    match g.as_ref() {
        Some(st) => serde_json::json!({
            "top": st.top(6).iter().map(|(id, n)| serde_json::json!({"id": id, "plays": n})).collect::<Vec<_>>(),
            "recent": st.recent.iter().take(8).collect::<Vec<_>>(),
        }),
        None => serde_json::json!({ "top": [], "recent": [] }),
    }
}

// returns (shuffle, repeat) for the player to adopt
pub fn load_config(app: &Arc<Mutex<AppState>>, core: &Arc<Core>) -> (bool, u32) {
    let mut shuffle = false;
    let mut repeat = 0u32;
    if let Ok(body) = std::fs::read_to_string(CONFIG_FILE) {
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&body) {
            if let Some(t) = v.get("theme").and_then(|x| x.as_str()) {
                app.lock().unwrap().theme = t.into();
            }
            if let Some(lo) = v.get("lyric_offset_ms").and_then(|x| x.as_i64()) {
                app.lock().unwrap().lyric_offset_ms = lo;
            }
            if let Some(vol) = v.get("volume").and_then(|x| x.as_u64()) {
                let vol = vol.clamp(0, 100) as u32;
                core.volume.store(vol, Ordering::Relaxed);
                app.lock().unwrap().volume = vol;
            }
            if let Some(m) = v.get("viz_mode").and_then(|x| x.as_u64()) {
                app.lock().unwrap().viz_mode = m as u32;
            }
            if let Some(arr) = v.get("eq").and_then(|x| x.as_array()) {
                let mut g = [0f32; 5];
                for i in 0..5 {
                    g[i] = arr.get(i).and_then(|x| x.as_f64()).unwrap_or(0.0) as f32;
                }
                let en = v.get("eq_enabled").and_then(|x| x.as_bool()).unwrap_or(false);
                core.set_eq(en, g);
            }
            shuffle = v.get("shuffle").and_then(|x| x.as_bool()).unwrap_or(false);
            repeat = v
                .get("repeat")
                .and_then(|x| x.as_u64())
                .unwrap_or(0) as u32;
        }
    }
    (shuffle, repeat)
}

pub fn save_config(app: &Arc<Mutex<AppState>>, core: &Arc<Core>, st: &Arc<Mutex<PlayerState>>) {
    let (theme, volume, viz_mode) = {
        let s = app.lock().unwrap();
        (
            s.theme.clone(),
            core.volume.load(Ordering::Relaxed),
            s.viz_mode,
        )
    };
    let (shuffle, repeat) = {
        let s = st.lock().unwrap();
        (s.shuffle, s.repeat)
    };
    // One writer at a time: this is a read-modify-write of the whole config,
    // and the player, the theme loader and the library all call it. Without the
    // lock a save that read the file before a playlist switch could write it
    // back afterwards and undo "active_playlist".
    let _guard = CFG_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let mut v = read_config();
    {
        let eq: Vec<f32> = (0..5)
            .map(|i| f32::from_bits(core.eq_gains[i].load(Ordering::Relaxed)))
            .collect();
        let obj = serde_json::json!({
            "theme": theme,
            "volume": volume,
            "viz_mode": viz_mode,
            "shuffle": shuffle,
            "repeat": repeat,
            "eq_enabled": core.eq_enabled.load(Ordering::Relaxed),
            "eq": eq,
        });
        if let (Some(dst), Some(src)) = (v.as_object_mut(), obj.as_object()) {
            for (k, val) in src {
                dst.insert(k.clone(), val.clone());
            }
        }
    }
    write_config(&v);
}

// config.json is read and written from several threads (player, library,
// appearance, the HTTP bridge). Every mutation takes this lock and lands
// through a rename, so a reader never sees half a document and two writers
// never lose each other's keys.
static CFG_LOCK: Mutex<()> = Mutex::new(());

fn read_config() -> serde_json::Value {
    std::fs::read_to_string(CONFIG_FILE)
        .ok()
        .and_then(|b| serde_json::from_str::<serde_json::Value>(&b).ok())
        .unwrap_or_else(|| serde_json::json!({}))
}

fn write_config(v: &serde_json::Value) {
    if let Ok(body) = serde_json::to_string_pretty(v) {
        let tmp = format!("{CONFIG_FILE}.tmp");
        if std::fs::write(&tmp, body).is_ok() {
            let _ = std::fs::rename(&tmp, CONFIG_FILE);
        }
    }
}

pub fn config_str(key: &str) -> Option<String> {
    read_config()
        .get(key)
        .and_then(|x| x.as_str())
        .map(|x| x.to_string())
}

pub fn set_config_str(key: &str, val: &str) {
    let _guard = CFG_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let mut v = read_config();
    if let Some(o) = v.as_object_mut() {
        o.insert(key.into(), serde_json::Value::String(val.into()));
    }
    write_config(&v);
}

// ---------------- per-song lyric styling ----------------
const LYRIC_STYLES_FILE: &str = concat!(env!("AETHER_ROOT"), "/lyrics_styles.json");

fn read_styles() -> serde_json::Value {
    std::fs::read_to_string(LYRIC_STYLES_FILE)
        .ok()
        .and_then(|b| serde_json::from_str::<serde_json::Value>(&b).ok())
        .unwrap_or_else(|| serde_json::json!({}))
}

fn write_styles(v: &serde_json::Value) {
    if let Ok(b) = serde_json::to_string_pretty(v) {
        let _ = std::fs::write(LYRIC_STYLES_FILE, b);
    }
}

// merged style for a track: defaults <- per-track overrides
pub fn lyric_style(id: usize) -> Option<String> {
    let v = read_styles();
    let base = v.get("default");
    let over = v.get(&id.to_string());
    let mut m = serde_json::Map::new();
    for src in [base, over].into_iter().flatten() {
        if let Some(o) = src.as_object() {
            for (k, val) in o {
                m.insert(k.clone(), val.clone());
            }
        }
    }
    if m.is_empty() {
        // factory default
        m.insert("pattern".into(), serde_json::json!("accent"));
        m.insert("anim".into(), serde_json::json!("rise"));
        m.insert("emphasis".into(), serde_json::json!("glow"));
    }
    Some(serde_json::Value::Object(m).to_string())
}

pub fn set_lyric_style(id: usize, pattern: &str, anim: &str, emphasis: &str, global: bool) {
    let mut v = read_styles();
    let key = if global { "default".to_string() } else { id.to_string() };
    if let Some(o) = v.as_object_mut() {
        o.insert(
            key,
            serde_json::json!({ "pattern": pattern, "anim": anim, "emphasis": emphasis }),
        );
    }
    write_styles(&v);
}

// ---------------- per-song lyric offset ----------------
// Songs are keyed by identity (title + artist), never by the transient
// playlist id, so a nudge survives re-syncs and playlist switches.
const LYRIC_OFFSETS_FILE: &str = concat!(env!("AETHER_ROOT"), "/lyric_offsets.json");

pub fn song_key(title: &str, artist: &str) -> String {
    use std::hash::{Hash, Hasher};
    let mut h = std::collections::hash_map::DefaultHasher::new();
    title.to_lowercase().trim().hash(&mut h);
    artist.to_lowercase().trim().hash(&mut h);
    format!("{:016x}", h.finish())
}

fn read_offsets() -> serde_json::Value {
    std::fs::read_to_string(LYRIC_OFFSETS_FILE)
        .ok()
        .and_then(|b| serde_json::from_str::<serde_json::Value>(&b).ok())
        .filter(|v| v.is_object())
        .unwrap_or_else(|| serde_json::json!({}))
}

pub fn lyric_offset_for(key: &str) -> Option<i64> {
    read_offsets().get(key).and_then(|x| x.as_i64())
}

pub fn set_lyric_offset_for(key: &str, ms: i64) {
    let mut v = read_offsets();
    if let Some(o) = v.as_object_mut() {
        if ms == 0 {
            o.remove(key);
        } else {
            o.insert(key.into(), serde_json::json!(ms.clamp(-30000, 30000)));
        }
    }
    if let Ok(body) = serde_json::to_string_pretty(&v) {
        let _ = std::fs::write(LYRIC_OFFSETS_FILE, body);
    }
}

// ---------------- favourites (liked songs) ----------------
// keyed by song identity (title + artist) like lyric offsets, never by the
// transient playlist id: ids shift on every re-sync and a liked song must stay
// liked through that.
const FAVORITES_FILE: &str = concat!(env!("AETHER_ROOT"), "/cache/favorites.json");

fn read_favorites() -> std::collections::BTreeSet<String> {
    std::fs::read_to_string(FAVORITES_FILE)
        .ok()
        .and_then(|b| serde_json::from_str::<serde_json::Value>(&b).ok())
        .and_then(|v| v.get("keys").and_then(|x| x.as_array()).cloned())
        .map(|a| {
            a.iter()
                .filter_map(|x| x.as_str().map(|s| s.to_string()))
                .collect()
        })
        .unwrap_or_default()
}

pub fn favorites() -> std::collections::BTreeSet<String> {
    read_favorites()
}

pub fn is_favorite(key: &str) -> bool {
    read_favorites().contains(key)
}

/// Returns the resulting state (true = liked now).
pub fn set_favorite(key: &str, on: bool) -> bool {
    let mut set = read_favorites();
    if on {
        set.insert(key.to_string());
    } else {
        set.remove(key);
    }
    let _ = std::fs::create_dir_all(concat!(env!("AETHER_ROOT"), "/cache"));
    let v = serde_json::json!({ "keys": set.iter().collect::<Vec<_>>() });
    if let Ok(body) = serde_json::to_string_pretty(&v) {
        let _ = std::fs::write(FAVORITES_FILE, body);
    }
    on
}

// ---------------- resume point ----------------
// "where the room was left" - written while a song plays, offered on the next
// launch instead of the app opening on an empty deck.
const RESUME_FILE: &str = concat!(env!("AETHER_ROOT"), "/cache/resume.json");

#[derive(Clone)]
pub struct ResumePoint {
    pub id: usize,
    pub pos_ms: u32,
    pub title: String,
    pub artist: String,
    /// identity key: the id is an index into the active playlist file and can
    /// move when the playlist is re-synced, so the ui matches on this
    pub key: String,
}

pub fn load_resume() -> Option<ResumePoint> {
    let v: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(RESUME_FILE).ok()?).ok()?;
    let id = v.get("id")?.as_u64()? as usize;
    let title: String = v.get("title").and_then(|x| x.as_str()).unwrap_or("").into();
    let artist: String = v.get("artist").and_then(|x| x.as_str()).unwrap_or("").into();
    Some(ResumePoint {
        id,
        pos_ms: v.get("pos_ms").and_then(|x| x.as_u64()).unwrap_or(0) as u32,
        key: song_key(&title, &artist),
        title,
        artist,
    })
}

pub fn save_resume(id: usize, pos_ms: u32, title: &str, artist: &str) {
    let _ = std::fs::create_dir_all(concat!(env!("AETHER_ROOT"), "/cache"));
    let v = serde_json::json!({
        "id": id, "pos_ms": pos_ms, "title": title, "artist": artist,
    });
    let _ = std::fs::write(RESUME_FILE, v.to_string());
}

pub fn clear_resume() {
    let _ = std::fs::remove_file(RESUME_FILE);
}

// ---------------- sleep timer ----------------
// One live timer at a time, identified by a generation counter so a new request
// (or CANCEL) silently retires the old thread instead of racing it.
static SLEEP_END_MS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
static SLEEP_GEN: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
static SLEEP_BASE_VOL: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);

pub fn sleep_remaining_ms() -> u64 {
    let end = SLEEP_END_MS.load(Ordering::Relaxed);
    if end == 0 {
        return 0;
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    end.saturating_sub(now)
}

pub fn sleep_cancel() {
    SLEEP_GEN.fetch_add(1, Ordering::Relaxed);
    SLEEP_END_MS.store(0, Ordering::Relaxed);
}

/// Cancel and, if the ramp had already started, put the user's volume back.
pub fn sleep_cancel_restore(core: &Arc<Core>, app: &Arc<Mutex<AppState>>) {
    let base = SLEEP_BASE_VOL.load(Ordering::Relaxed);
    if SLEEP_END_MS.load(Ordering::Relaxed) != 0 && base > 0 {
        core.volume.store(base, Ordering::Relaxed);
        app.lock().unwrap().volume = base;
    }
    sleep_cancel();
}

/// Start (or replace) the sleep timer. The last `fade_ms` of the wait ramp the
/// output volume down to silence, then the deck pauses and the volume is put
/// back so the next morning is not silent. `fade_ms = 0` disables the ramp.
pub fn sleep_start(
    core: &Arc<Core>,
    app: &Arc<Mutex<AppState>>,
    tx: Option<std::sync::mpsc::Sender<crate::player::PlayerCmd>>,
    secs: u64,
    fade_ms: u64,
) -> u64 {
    sleep_cancel();
    let gen = SLEEP_GEN.load(Ordering::Relaxed) + 1;
    SLEEP_GEN.store(gen, Ordering::Relaxed);
    if secs == 0 {
        return 0;
    }
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    let end = now + secs * 1000;
    SLEEP_END_MS.store(end, Ordering::Relaxed);
    let base = core.volume.load(Ordering::Relaxed);
    SLEEP_BASE_VOL.store(base, Ordering::Relaxed);
    let core = core.clone();
    let app = app.clone();
    std::thread::Builder::new()
        .name("sleep-timer".into())
        .spawn(move || loop {
            if SLEEP_GEN.load(Ordering::Relaxed) != gen {
                return; // replaced or cancelled
            }
            let left = sleep_remaining_ms();
            if left == 0 {
                if let Some(tx) = tx {
                    let _ = tx.send(crate::player::PlayerCmd::Pause);
                }
                let back = SLEEP_BASE_VOL.load(Ordering::Relaxed);
                core.volume.store(back, Ordering::Relaxed);
                // the slider reads AppState, the engine reads Core: the ramp
                // only touches the engine, so put the visible level back too
                app.lock().unwrap().volume = back;
                SLEEP_END_MS.store(0, Ordering::Relaxed);
                return;
            }
            if fade_ms > 0 && left < fade_ms {
                let f = left as f32 / fade_ms as f32;
                let v = (base as f32 * f).round() as u32;
                core.volume.store(v.clamp(0, 100), Ordering::Relaxed);
            }
            std::thread::sleep(std::time::Duration::from_millis(250));
        })
        .ok();
    secs * 1000
}
