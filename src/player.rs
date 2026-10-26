// lang: Rust, file: player.rs
// decode engine: symphonia -> ring -> cpal, queue, shuffle/repeat, auto-advance
use crate::audio::Core;
use crate::library;
use crate::state::{self, AppState};
use crate::stream;
use librespot_core::spotify_uri::SpotifyUri;
use std::sync::atomic::Ordering;
use std::sync::mpsc::{Receiver, Sender, TryRecvError};
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Clone)]
pub enum PlayerCmd {
    PlayId(usize),
    Toggle,
    Pause,
    Resume,
    Stop,
    Next,
    Prev,
    Seek(u32),
    SetShuffle(bool),
    SetRepeat(u32),
}

pub struct PlayerState {
    pub pending_override: Option<usize>, // smart shuffle: next track forced
    pub inject_counter: u32,
    pub queue: Vec<usize>,
    pub pos: usize,
    pub smart_mode: bool,          // smart shuffle: play-count weighted picks
    pub smart_remaining: Vec<usize>, // not-yet-picked ids this epoch
    pub advance_times: Vec<std::time::Instant>, // skip-storm detection
    pub shuffle: bool,
    pub repeat: u32, // 0 off, 1 all, 2 one
    pub current_id: Option<usize>,
    pub cur_path: String,
    pub streaming: bool,
}

impl Default for PlayerState {
    fn default() -> Self {
        Self {
            pending_override: None,
            inject_counter: 0,
            queue: Vec::new(),
            pos: 0,
            smart_mode: false,
            smart_remaining: Vec::new(),
            advance_times: Vec::new(),
            shuffle: false,
            repeat: 0,
            current_id: None,
            cur_path: String::new(),
            streaming: false,
        }
    }
}

pub fn start(
    app: Arc<Mutex<AppState>>,
    core: Arc<Core>,
    lib: Arc<Mutex<library::Library>>,
    st: Arc<Mutex<PlayerState>>,
) -> Sender<PlayerCmd> {
    let (tx, rx) = std::sync::mpsc::channel::<PlayerCmd>();
    std::thread::Builder::new()
        .name("player".into())
        .spawn(move || run(rx, app, core, lib, st))
        .expect("spawn player thread");
    tx
}

struct Ctx {
    fmt: Box<dyn symphonia::core::formats::FormatReader>,
    dec: Box<dyn symphonia::core::codecs::Decoder>,
    rate: u32,
    frames: u64,
    base_ms: u64,
}

fn lcg_shuffle(v: &mut [usize]) {
    let n = v.len();
    if n < 2 {
        return;
    }
    let mut seed = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0x9e3779b97f4a7c15);
    let mut i = n - 1;
    while i > 0 {
        seed = seed
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        let j = ((seed >> 33) as usize) % (i + 1);
        v.swap(i, j);
        i -= 1;
    }
}

// smart shuffle v2: weight by play count, penalize recently played, avoid
// same-artist streaks. Samples without replacement from the remaining pool.
fn smart_pick(s: &mut PlayerState, lib: &Arc<Mutex<library::Library>>) -> Option<usize> {
    if s.smart_remaining.is_empty() {
        let cur = s.current_id;
        let mut pool: Vec<usize> = s.queue.clone();
        pool.retain(|&x| Some(x) != cur);
        s.smart_remaining = pool;
        if s.smart_remaining.is_empty() {
            return s.current_id;
        }
    }
    let stats = crate::state::recent_set();
    let cur_artist = {
        let l = lib.lock().unwrap();
        s.current_id
            .and_then(|id| l.tracks.iter().find(|t| t.id == id))
            .map(|t| t.artist.clone())
            .unwrap_or_default()
    };
    let l = lib.lock().unwrap();
    let mut weights: Vec<f64> = s
        .smart_remaining
        .iter()
        .map(|&id| {
            let plays = crate::state::plays_of(id) as f64;
            let mut w = (plays + 1.0).powf(0.8);
            if stats.contains(&id) {
                w *= 0.28; // recently heard: cool it down
            }
            if let Some(t) = l.tracks.iter().find(|t| t.id == id) {
                if !cur_artist.is_empty() && t.artist == cur_artist {
                    w *= 0.45; // artist spacing
                }
            }
            w
        })
        .collect();
    let total: f64 = weights.iter().sum();
    let mut r = crate::player::lcg_next_f64() * total;
    let mut idx = s.smart_remaining.len() - 1;
    for (i, w) in weights.iter().enumerate() {
        r -= w;
        if r <= 0.0 {
            idx = i;
            break;
        }
    }
    Some(s.smart_remaining.remove(idx))
}

// deterministic-ish rng for the picker (xorshift, seeded from time)
fn lcg_next_f64() -> f64 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static STATE: AtomicU64 = AtomicU64::new(0x9E3779B97F4A7C15);
    let mut x = STATE.load(Ordering::Relaxed);
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    STATE.store(x, Ordering::Relaxed);
    (x % 1_000_000) as f64 / 1_000_000.0
}

fn reshuffle_keep_current(s: &mut PlayerState) {
    let cur = s.current_id;
    let mut rest: Vec<usize> = s.queue.clone();
    if let Some(c) = cur {
        rest.retain(|&x| x != c);
    }
    lcg_shuffle(&mut rest);
    if let Some(c) = cur {
        s.queue = std::iter::once(c).chain(rest).collect();
        s.pos = 0;
    } else {
        s.queue = rest;
        s.pos = 0;
    }
}

fn set_status(app: &Arc<Mutex<AppState>>, msg: &str) {
    if let Ok(mut s) = app.lock() {
        s.status = msg.into();
    }
}

const NOW_PLAYING_FILE: &str = concat!(env!("AETHER_ROOT"), "/now_playing.json");

// WebNowPlaying-style broadcast: external tools (Rainmeter, OBS, scripts) read this file
fn write_now_playing(
    app: &Arc<Mutex<AppState>>,
    core: &Arc<Core>,
    st: &Arc<Mutex<PlayerState>>,
) {
    let (title, artist, album) = {
        let s = app.lock().unwrap();
        (s.title.clone(), s.artist.clone(), s.album.clone())
    };
    let current_id = st.lock().unwrap().current_id;
    let v = serde_json::json!({
        "title": title,
        "artist": artist,
        "album": album,
        "duration_ms": core.duration_ms.load(Ordering::Relaxed),
        "position_ms": core.position_ms.load(Ordering::Relaxed),
        "playing": core.playing.load(Ordering::Relaxed),
        "track_id": current_id,
        "updated": std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0),
    });
    if let Ok(body) = serde_json::to_string_pretty(&v) {
        let _ = std::fs::write(NOW_PLAYING_FILE, body);
    }
}

fn open_track(
    app: &Arc<Mutex<AppState>>,
    core: &Arc<Core>,
    lib: &Arc<Mutex<library::Library>>,
    st: &Arc<Mutex<PlayerState>>,
    id: usize,
) -> Option<Ctx> {
    let (title, artist, album, origin, path, dur, cover) = {
        let l = lib.lock().unwrap();
        let t = l.tracks.get(id)?;
        if t.path.is_empty() {
            return None;
        }
        (
            t.title.clone(),
            t.artist.clone(),
            t.album.clone(),
            t.origin.clone(),
            t.path.clone(),
            t.duration_ms,
            t.cover_file.clone(),
        )
    };
    core.ring.clear();
    let (fmt, dec, rate) = library::open_decoder(&path)?;
    core.src_rate.store(rate, Ordering::Relaxed);
    core.position_ms.store(0, Ordering::Relaxed);
    if dur > 0 {
        core.duration_ms.store(dur, Ordering::Relaxed);
    }
    core.playing.store(true, Ordering::Relaxed);
    {
        let mut s = app.lock().unwrap();
        s.title = title;
        s.artist = artist;
        s.album = album;
        s.origin = origin;
        s.cover_url = cover;
        s.track_id = Some(id);
        s.status = "playing".into();
    }
    {
        let mut s2 = st.lock().unwrap();
        s2.current_id = Some(id);
        s2.cur_path = path;
    }
    Some(Ctx {
        fmt,
        dec,
        rate,
        frames: 0,
        base_ms: 0,
    })
}

// route a track: local file first, else stream via librespot when a session exists
fn open_any(
    app: &Arc<Mutex<AppState>>,
    core: &Arc<Core>,
    lib: &Arc<Mutex<library::Library>>,
    st: &Arc<Mutex<PlayerState>>,
    id: usize,
) -> Option<Ctx> {
    crate::state::record_play(id);
    let (path, uri, web, title, artist, album, dur) = {
        let l = lib.lock().unwrap();
        let t = l.tracks.get(id)?;
        (
            t.path.clone(),
            t.uri.clone(),
            t.web.clone(),
            t.title.clone(),
            t.artist.clone(),
            t.album.clone(),
            t.duration_ms,
        )
    };
    // a live stream belongs to the track that started it: anything that opens
    // a new source closes the old pipe first
    crate::live::stop();

    if !path.is_empty() {
        // switching away from a stream: silence librespot
        if st.lock().unwrap().streaming {
            if let Some(p) = stream::PLAYER.get() {
                p.stop();
            }
            st.lock().unwrap().streaming = false;
        }
        // a file on disk wins. if it exists but cannot be decoded (an older add
        // in a container this build cannot read) fall through to the stream
        // instead of dying silently on the click.
        if let Some(ctx) = open_track(app, core, lib, st, id) {
            return Some(ctx);
        }
        eprintln!("[player] unreadable local file: {path}");
    }

    // web rows: no file on disk, no spotify session needed. ffmpeg decodes the
    // page's audio straight into the ring, so a playlist can hold streamed
    // songs next to downloaded ones.
    if !web.is_empty() {
        let label = if web.contains("soundcloud.com") {
            "soundcloud"
        } else if web.contains("bandcamp.com") {
            "bandcamp"
        } else {
            "youtube"
        };
        if crate::live::start(core, &web, &title, &artist, dur, id) {
            {
                let mut s2 = st.lock().unwrap();
                s2.streaming = false;
                s2.current_id = Some(id);
                s2.cur_path = String::new();
            }
            {
                let mut s = app.lock().unwrap();
                s.title = title;
                s.artist = artist;
                s.album = album;
                s.origin = "stream".into();
                s.track_id = Some(id);
                s.status = format!("streaming from {label}");
            }
            write_now_playing(app, core, st);
            return None;
        }
        eprintln!("[player] live stream refused for {web}");
    }

    if !uri.is_empty() && stream::usable() {
        if let Some(p) = stream::PLAYER.get() {
            if let Ok(u) = SpotifyUri::from_uri(&uri) {
                core.ring.clear();
                core.src_rate.store(44100, Ordering::Relaxed);
                core.position_ms.store(0, Ordering::Relaxed);
                core.duration_ms.store(dur, Ordering::Relaxed);
                core.playing.store(true, Ordering::Relaxed);
                p.load(u, true, 0);
                // watchdog: if the stream never delivers audio within 4s, surface it
                {
                    let core2 = core.clone();
                    let app2 = app.clone();
                    let dur2 = dur;
                    std::thread::spawn(move || {
                        std::thread::sleep(std::time::Duration::from_secs(4));
                        let pos = core2.position_ms.load(Ordering::Relaxed);
                        let playing = core2.playing.load(Ordering::Relaxed);
                        if playing && pos < 1200 && dur2 > 5000 {
                            core2.playing.store(false, Ordering::Relaxed);
                            crate::stream::mark_unusable();
                            set_status(&app2, "stream unavailable on this account (free tier or key block) - GRANT with a Premium account, or play local files");
                            eprintln!("[stream] watchdog: no audio 4s after load (pos={pos}ms) - session marked unusable");
                        }
                    });
                }
                {
                    let mut s2 = st.lock().unwrap();
                    s2.streaming = true;
                    s2.current_id = Some(id);
                    s2.cur_path = String::new();
                }
                {
                    let mut s = app.lock().unwrap();
                    s.title = title;
                    s.artist = artist;
                    s.album = album;
                    s.origin = "stream".into();
                    s.track_id = Some(id);
                    s.status = "streaming".into();
                }
                write_now_playing(app, core, st);
                return None; // librespot drives; no local decode context
            }
        }
    }

    set_status(
        app,
        "no source: drop the file in Downloads/Music, or add spotify_login.json for streaming",
    );
    None
}

// start a track: rebuild the playable queue, position at this id
fn play_id(
    app: &Arc<Mutex<AppState>>,
    core: &Arc<Core>,
    lib: &Arc<Mutex<library::Library>>,
    st: &Arc<Mutex<PlayerState>>,
    id: usize,
) -> Option<Ctx> {
    // the queue stays inside one world (the loose-file library, or the
    // playlist you clicked in) but no longer inside one *source*: a playlist
    // legitimately holds downloaded youtube songs next to spotify-only rows.
    // filtering by origin alone made every youtube add "unplayable" even
    // though its file was sitting on disk and decoded fine.
    let clicked_origin = {
        let l = lib.lock().unwrap();
        l.tracks.get(id)?.origin.clone()
    };
    let candidates: Vec<usize> = {
        let l = lib.lock().unwrap();
        let local_world = clicked_origin == "local";
        l.tracks
            .iter()
            .filter(|t| (t.origin == "local") == local_world)
            .filter(|t| {
                !t.path.is_empty()
                    || !t.web.is_empty()
                    || (!t.uri.is_empty() && stream::available())
            })
            .map(|t| t.id)
            .collect()
    };
    if !candidates.contains(&id) {
        set_status(
            app,
            "no audio source for this track - drop the file in Downloads or Music",
        );
        return None;
    }
    let pos = candidates.iter().position(|&x| x == id).unwrap_or(0);
    {
        let mut s2 = st.lock().unwrap();
        s2.queue = candidates;
        s2.pos = pos;
        if s2.shuffle {
            reshuffle_keep_current(&mut s2);
        }
    }
    open_any(app, core, lib, st, id)
}

// advance in queue; dir=+1 next, dir=-1 previous
fn advance(
    app: &Arc<Mutex<AppState>>,
    core: &Arc<Core>,
    lib: &Arc<Mutex<library::Library>>,
    st: &Arc<Mutex<PlayerState>>,
    dir: isize,
) -> Option<Ctx> {
    let (queue_len, pos, repeat, override_id, shuffle_on, s_smart) = {
        let mut s = st.lock().unwrap();
        let take = s.pending_override.take();
        (s.queue.len(), s.pos, s.repeat, take, s.shuffle, s.smart_mode)
    };
    if queue_len == 0 {
        core.playing.store(false, Ordering::Relaxed);
        set_status(app, "queue empty - add audio files to Downloads or Music");
        return None;
    }

    // skip-storm breaker: tracks ending back-to-back means loads are failing.
    // Halt instead of walking the whole library in a second.
    {
        let mut s = st.lock().unwrap();
        let now = std::time::Instant::now();
        s.advance_times.retain(|t| now.duration_since(*t).as_secs() < 6);
        if s.advance_times.len() >= 5 {
            s.advance_times.clear();
            core.playing.store(false, Ordering::Relaxed);
            set_status(app, "tracks failing back-to-back - paused. stream issue: press GRANT FULL ACCESS again or play local files");
            eprintln!("[player] SKIP-STORM BREAKER: halted after 5 rapid advances");
            return None;
        }
        s.advance_times.push(now);
    }

    // smart shuffle: every 3rd advance while shuffling a stream, sprinkle a suggestion
    if override_id.is_none() && shuffle_on && crate::stream::available() {
        let inject = {
            let mut s = st.lock().unwrap();
            s.inject_counter = s.inject_counter.wrapping_add(1);
            s.inject_counter % 3 == 0
        };
        if inject {
            if let Some(sugg) = crate::stream::take_suggestion() {
                let id = {
                    let mut l = lib.lock().unwrap();
                    match l.tracks.iter().position(|t| t.uri == sugg.uri) {
                        Some(i) => l.tracks[i].id,
                        None => l.push_stream_track(
                            &sugg.uri, &sugg.title, &sugg.artist, "", sugg.duration_ms, &sugg.cover,
                        ),
                    }
                };
                if let Ok(mut s) = st.lock() {
                    s.pending_override = Some(id);
                    set_status(app, "smart shuffle: sprinkling a suggestion");
                }
            }
        }
    }
    if let Some(oid) = override_id {
        let t0 = std::time::Instant::now();
        let ctx = open_any(app, core, lib, st, oid);
        eprintln!("[player] suggestion switch: {} ms", t0.elapsed().as_millis());
        if ctx.is_some() {
            return ctx;
        }
        // fall through to linear advance if the suggestion can't open
    }
    // smart shuffle: pick the next track from the weighted remaining pool
    if dir > 0 && shuffle_on && s_smart {
        if let Some(id) = {
            let mut s = st.lock().unwrap();
            smart_pick(&mut s, lib)
        } {
            let t0 = std::time::Instant::now();
            let ctx = open_any(app, core, lib, st, id);
            eprintln!("[player] smart pick: {} ms", t0.elapsed().as_millis());
            if ctx.is_some() {
                return ctx;
            }
        }
    }
    let mut new_pos = pos as isize + dir;
    if new_pos >= queue_len as isize {
        match repeat {
            1 => new_pos = 0,
            2 => new_pos = pos as isize,
            _ => {
                core.playing.store(false, Ordering::Relaxed);
                let end = core.duration_ms.load(Ordering::Relaxed);
                core.position_ms.store(end, Ordering::Relaxed);
                set_status(app, "end of queue");
                return None;
            }
        }
    }
    if new_pos < 0 {
        new_pos = if repeat == 1 {
            queue_len as isize - 1
        } else {
            0
        };
    }
    let id = {
        let mut s = st.lock().unwrap();
        s.pos = new_pos as usize;
        s.queue.get(new_pos as usize).copied()
    }?;
    let t0 = std::time::Instant::now();
    let ctx = open_any(app, core, lib, st, id);
    eprintln!("[player] track switch: {} ms", t0.elapsed().as_millis());
    ctx
}

// seek: reopen current file and discard packets up to the target position
fn reopen_at(
    app: &Arc<Mutex<AppState>>,
    core: &Arc<Core>,
    st: &Arc<Mutex<PlayerState>>,
    ms: u32,
) -> Option<Ctx> {
    let path = st.lock().unwrap().cur_path.clone();
    if path.is_empty() {
        return None;
    }
    core.ring.clear();
    let (mut fmt, mut dec, rate) = library::open_decoder(&path)?;
    core.src_rate.store(rate, Ordering::Relaxed);
    let target = ms as u64;
    let mut frames: u64 = 0;
    let mut guard = 0u32;
    loop {
        guard += 1;
        if guard > 400_000 {
            break;
        }
        match fmt.next_packet() {
            Ok(p) => {
                if let Ok(abuf) = dec.decode(&p) {
                    frames += abuf.frames() as u64;
                    if frames * 1000 / rate as u64 >= target {
                        break;
                    }
                }
            }
            Err(_) => break,
        }
    }
    let base = frames * 1000 / rate as u64;
    core.position_ms.store(base as u32, Ordering::Relaxed);
    let _ = app;
    Some(Ctx {
        fmt,
        dec,
        rate,
        frames: 0,
        base_ms: base,
    })
}

fn run(
    rx: Receiver<PlayerCmd>,
    app: Arc<Mutex<AppState>>,
    core: Arc<Core>,
    lib: Arc<Mutex<library::Library>>,
    st: Arc<Mutex<PlayerState>>,
) {
    let mut ctx: Option<Ctx> = None;
    let mut seek_req: Option<u32> = None;
    loop {
        let cmd = if ctx.is_some() || crate::live::active() {
            match rx.try_recv() {
                Ok(c) => Some(c),
                Err(TryRecvError::Empty) => None,
                Err(TryRecvError::Disconnected) => break,
            }
        } else {
            match rx.recv() {
                Ok(c) => Some(c),
                Err(_) => break,
            }
        };

        match cmd {
            Some(PlayerCmd::PlayId(id)) => {
                crate::live::stop();
                ctx = play_id(&app, &core, &lib, &st, id);
                seek_req = None;
                write_now_playing(&app, &core, &st);
            }
            Some(PlayerCmd::Pause) => {
                core.playing.store(false, Ordering::Relaxed);
                if crate::live::active() {
                    crate::live::pause();
                }
                if st.lock().unwrap().streaming {
                    if let Some(p) = stream::PLAYER.get() {
                        p.pause();
                    }
                }
                set_status(&app, "paused");
                write_now_playing(&app, &core, &st);
            }
            Some(PlayerCmd::Resume) => {
                core.playing.store(true, Ordering::Relaxed);
                if crate::live::active() {
                    crate::live::play();
                }
                if st.lock().unwrap().streaming {
                    if let Some(p) = stream::PLAYER.get() {
                        p.play();
                    }
                }
                set_status(&app, "playing");
                write_now_playing(&app, &core, &st);
            }
            Some(PlayerCmd::Toggle) => {
                let p = !core.playing.load(Ordering::Relaxed);
                core.playing.store(p, Ordering::Relaxed);
                if crate::live::active() {
                    if p {
                        crate::live::play();
                    } else {
                        crate::live::pause();
                    }
                }
                if st.lock().unwrap().streaming {
                    if let Some(sp) = stream::PLAYER.get() {
                        if p {
                            sp.play();
                        } else {
                            sp.pause();
                        }
                    }
                }
                set_status(&app, if p { "playing" } else { "paused" });
                write_now_playing(&app, &core, &st);
            }
            Some(PlayerCmd::Stop) => {
                ctx = None;
                crate::live::stop();
                core.ring.clear();
                core.playing.store(false, Ordering::Relaxed);
                core.position_ms.store(0, Ordering::Relaxed);
                if st.lock().unwrap().streaming {
                    if let Some(p) = stream::PLAYER.get() {
                        p.stop();
                    }
                    st.lock().unwrap().streaming = false;
                }
                set_status(&app, "stopped");
                write_now_playing(&app, &core, &st);
            }
            Some(PlayerCmd::Seek(ms)) => {
                if crate::live::active() {
                    crate::live::seek(ms);
                    core.position_ms.store(ms, Ordering::Relaxed);
                } else if st.lock().unwrap().streaming {
                    if let Some(p) = stream::PLAYER.get() {
                        p.seek(ms);
                    }
                    core.position_ms.store(ms, Ordering::Relaxed);
                } else if ctx.is_some() {
                    seek_req = Some(ms);
                }
            }
            Some(PlayerCmd::Next) => {
                ctx = advance(&app, &core, &lib, &st, 1);
                seek_req = None;
                write_now_playing(&app, &core, &st);
            }
            Some(PlayerCmd::Prev) => {
                let pos_ms = core.position_ms.load(Ordering::Relaxed);
                if pos_ms > 3000 {
                    seek_req = Some(0);
                } else {
                    ctx = advance(&app, &core, &lib, &st, -1);
                    seek_req = None;
                    write_now_playing(&app, &core, &st);
                }
            }
            Some(PlayerCmd::SetShuffle(s)) => {
                {
                    let mut s2 = st.lock().unwrap();
                    s2.shuffle = s;
                    if s {
                        reshuffle_keep_current(&mut s2);
                    } else {
                        // linear order from library, keep current position
                        let l = lib.lock().unwrap();
                        let cur_origin = s2
                            .current_id
                            .and_then(|c| l.tracks.iter().find(|t| t.id == c))
                            .map(|t| t.origin.clone())
                            .unwrap_or_else(|| String::from("local"));
                        let linear: Vec<usize> = l
                            .tracks
                            .iter()
                            .filter(|t| t.origin == cur_origin)
                            .filter(|t| match t.origin.as_str() {
                                "local" => !t.path.is_empty(),
                                _ => {
                                    !t.path.is_empty()
                                        || !t.web.is_empty()
                                        || (!t.uri.is_empty() && stream::available())
                                }
                            })
                            .map(|t| t.id)
                            .collect();
                        let cur = s2.current_id;
                        s2.queue = linear;
                        s2.pos = cur
                            .and_then(|c| s2.queue.iter().position(|&x| x == c))
                            .unwrap_or(0);
                    }
                }
                state::save_config(&app, &core, &st);
            }
            Some(PlayerCmd::SetRepeat(r)) => {
                st.lock().unwrap().repeat = r.min(2);
                state::save_config(&app, &core, &st);
            }
            None => {
                // a live stream has no decoder context: the pipe thread owns the
                // audio, so the loop only watches for the end of the song
                if ctx.is_none() && crate::live::active() {
                    core.position_ms.store(crate::live::position_ms(), Ordering::Relaxed);
                    if crate::live::ended() && core.playing.load(Ordering::Relaxed) {
                        crate::live::stop();
                        ctx = advance(&app, &core, &lib, &st, 1);
                        write_now_playing(&app, &core, &st);
                    } else {
                        std::thread::sleep(Duration::from_millis(30));
                    }
                    continue;
                }
                // decode step
                if let Some(ms) = seek_req.take() {
                    ctx = reopen_at(&app, &core, &st, ms);
                    continue;
                }
                let Some(c) = ctx.as_mut() else { continue };
                if !core.playing.load(Ordering::Relaxed) {
                    std::thread::sleep(Duration::from_millis(20));
                    continue;
                }
                // backpressure: keep about 2s of audio in the ring
                let mut waited = 0u32;
                while core.ring.len() > 44100 * 2 * 2 && waited < 600 {
                    std::thread::sleep(Duration::from_millis(15));
                    waited += 15;
                }
                match c.fmt.next_packet() {
                    Ok(packet) => {
                        if let Ok(abuf) = c.dec.decode(&packet) {
                            let frames = abuf.frames();
                            if frames > 0 {
                                let n = abuf.spec().channels.count().max(1);
                                let mut sbuf = symphonia::core::audio::SampleBuffer::<f32>::new(
                                    abuf.capacity() as u64,
                                    *abuf.spec(),
                                );
                                sbuf.copy_interleaved_ref(abuf);
                                let smp = sbuf.samples();
                                if n == 2 {
                                    core.ring.push(smp);
core.last_feed.store(
                                            (std::time::SystemTime::now()
                                                .duration_since(std::time::UNIX_EPOCH)
                                                .unwrap_or_default()
                                                .as_millis()) as u64,
                                            std::sync::atomic::Ordering::Relaxed);
                                } else {
                                    let mut stereo = Vec::with_capacity(frames * 2);
                                    for f in 0..frames {
                                        stereo.push(smp[f * n]);
                                        stereo.push(if n > 1 {
                                            smp[f * n + 1]
                                        } else {
                                            smp[f * n]
                                        });
                                    }
                                    core.ring.push(&stereo);
core.last_feed.store(
                                            (std::time::SystemTime::now()
                                                .duration_since(std::time::UNIX_EPOCH)
                                                .unwrap_or_default()
                                                .as_millis()) as u64,
                                            std::sync::atomic::Ordering::Relaxed);
                                }
                                c.frames += frames as u64;
                                let pos = c.base_ms + c.frames * 1000 / c.rate as u64;
                                core.position_ms.store(pos as u32, Ordering::Relaxed);
                                if pos > core.duration_ms.load(Ordering::Relaxed) as u64 {
                                    core.duration_ms.store(pos as u32, Ordering::Relaxed);
                                }
                            }
                        }
                    }
                    Err(_) => {
                        // EOF or unrecoverable decode error: auto-advance
                        ctx = advance(&app, &core, &lib, &st, 1);
                    }
                }
            }
        }
    }
}
