// lang: Rust, file: main.rs
// console build for diagnostics
// A release build is a desktop app: no console window behind it. Debug builds
// keep the console so a panic and its backtrace stay readable.
#![cfg_attr(all(windows, not(debug_assertions)), windows_subsystem = "windows")]
// orchestrator: library + player engine + viz + http bridge + Qt shell
mod accounts;
mod appearance;
mod audio;
mod catalog;
mod hotkeys;
mod library;
mod live;
mod player;
mod playlist_import;
mod room_edit;
mod server;
mod shell;
mod ytcvt;
mod state;
mod stream;
mod viz;

use state::AppState;
use std::path::Path;
use std::sync::{Arc, Mutex};

#[cfg(target_os = "windows")]
mod round {
    // OS-level window rounding: SetWindowRgn clips the whole surface,
    // desktop shows at the corners. Re-applied when the size changes.
    pub fn apply() {
        std::thread::spawn(|| {
            use windows_sys::Win32::UI::WindowsAndMessaging::{FindWindowA, GetWindowRect};
            use windows_sys::Win32::Graphics::Gdi::{CreateRoundRectRgn, SetWindowRgn, HRGN};
            use windows_sys::Win32::Foundation::{HWND, RECT};
            let mut hwnd: HWND = std::ptr::null_mut();
            for _ in 0..120 {
                unsafe {
                    hwnd = FindWindowA(std::ptr::null(), c"AetherMix".as_ptr() as *const u8);
                }
                if !hwnd.is_null() {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(250));
            }
            if hwnd.is_null() {
                return;
            }
            let mut last = (0i32, 0i32);
            loop {
                unsafe {
                    let mut r = RECT { left: 0, top: 0, right: 0, bottom: 0 };
                    if GetWindowRect(hwnd, &mut r) != 0 {
                        let w = r.right - r.left;
                        let h = r.bottom - r.top;
                        if w > 0 && h > 0 && (w, h) != last {
                            let rgn = CreateRoundRectRgn(0, 0, w + 1, h + 1, 36, 36);
                            SetWindowRgn(hwnd, rgn, 1);
                            last = (w, h);
                        }
                    }
                }
                std::thread::sleep(std::time::Duration::from_millis(400));
            }
        });
    }
}

fn boot(msg: &str) {
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(concat!(env!("AETHER_ROOT"), "/.scratch/boot.log")) {
        let _ = writeln!(f, "{msg}");
    }
}

fn main() {
    let _ = std::fs::write(concat!(env!("AETHER_ROOT"), "/boot.txt"), b"main entered");
    boot("main enter");
    // Basic style: the native Windows style forbids custom control styling
    std::env::set_var("QT_QUICK_CONTROLS_STYLE", "Basic");
    println!("AetherMix v0.5 - sovereign engine + opt-in streaming");

    boot("before AppState");
    eprintln!("[boot] app start");
    let app = Arc::new(Mutex::new(AppState::default()));
    let core = Arc::new(audio::Core::new());

    // optional internal logging: set RUST_LOG=librespot=info to see session detail
    let _ = env_logger::Builder::from_env(env_logger::Env::default()).try_init();
    #[cfg(target_os = "windows")]
    round::apply();
    state::stats_init();
    // config: theme, volume, viz mode, shuffle/repeat
    let (shuffle, repeat) = state::load_config(&app, &core);

    // library: playlist catalog + local files
    let lib = Arc::new(Mutex::new(library::Library::new()));
    {
        let mut l = lib.lock().unwrap();
        l.load_all();
        app.lock().unwrap().library_version = l.version;
        println!(
            "[library] {} tracks, {} playable",
            l.tracks.len(),
            l.tracks.iter().filter(|t| !t.path.is_empty()).count()
        );
    }

    boot("library ready");
    eprintln!("[boot] library ready");
    // playlist auto-sync: startup + every 15 min while streaming
    catalog::spawn_sync_worker(lib.clone(), app.clone());

    // rows added before the art pass (or whose thumbnail arrived as webp) heal
    // themselves once, in the background, without blocking the shell
    ytcvt::repair_covers(lib.clone(), app.clone());

    // player engine
    let pst = Arc::new(Mutex::new(player::PlayerState::default()));
    pst.lock().unwrap().shuffle = shuffle;
    pst.lock().unwrap().repeat = repeat;
    let tx = player::start(app.clone(), core.clone(), lib.clone(), pst.clone());
    let _ = server::PLAYER_TX.set(tx.clone());

    hotkeys::start(core.clone(), app.clone(), pst.clone(), tx.clone());

    // "where the room was left": a tiny file, written at most every 8 s while
    // something plays, so the next launch can offer to continue instead of
    // sitting on an empty deck.
    {
        let core = core.clone();
        let pst = pst.clone();
        let lib = lib.clone();
        std::thread::Builder::new()
            .name("resume".into())
            .spawn(move || loop {
                std::thread::sleep(std::time::Duration::from_secs(8));
                if !core.playing.load(std::sync::atomic::Ordering::Relaxed) {
                    continue;
                }
                let pos = core.position_ms.load(std::sync::atomic::Ordering::Relaxed);
                if pos < 4000 {
                    continue;
                }
                let cid = pst.lock().unwrap().current_id;
                if let Some(id) = cid {
                    let meta = lib
                        .lock()
                        .unwrap()
                        .tracks
                        .get(id)
                        .map(|t| (t.title.clone(), t.artist.clone()));
                    if let Some((title, artist)) = meta {
                        state::save_resume(id, pos, &title, &artist);
                    }
                }
            })
            .ok();
    }
    stream::start(app.clone(), core.clone(), lib.clone(), pst.clone(), tx.clone());
    audio::start_output(core.clone(), app.clone());
    viz::start(app.clone(), core.clone());
    server::start(app.clone(), core.clone(), lib.clone(), pst.clone());

    // Loaded by URL, not by value: the shell now has sibling components
    // (MediaBackdrop.qml, its baked shader) and a raw byte load has no base
    // directory to resolve them against.
    boot("server up");
    eprintln!("[boot] server up, loading qml");
    let qml_path = Path::new(env!("CARGO_MANIFEST_DIR")).join("qml/Main.qml");
    let qml_url = format!("file:///{}", qml_path.to_string_lossy().replace('\\', "/"));
    qtbridge::QApp::new()
        .load_qml_from_file(&qml_url)
        .run();
}
