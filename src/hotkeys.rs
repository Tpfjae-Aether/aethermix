// lang: Rust, file: hotkeys.rs
// System-wide transport keys.
//
// A player is expected to answer while another app has the focus, so these are
// real Windows hotkeys (RegisterHotKey) rather than QML shortcuts, which only
// fire when the window is active. The thread owns a message queue and lives for
// the process; the `hotkeys` config flag decides whether an event is acted on,
// so the switch in Settings needs no thread management.
#![allow(non_snake_case)]
use crate::audio::Core;
use crate::player::{PlayerCmd, PlayerState};
use crate::state::{self, AppState};
use std::sync::atomic::Ordering;
use std::sync::{mpsc::Sender, Arc, Mutex};

const HK_TOGGLE: i32 = 1;
const HK_NEXT: i32 = 2;
const HK_PREV: i32 = 3;
const HK_VOL_UP: i32 = 4;
const HK_VOL_DOWN: i32 = 5;

pub fn enabled() -> bool {
    state::config_str("hotkeys").map(|v| v == "1").unwrap_or(false)
}

pub fn start(
    core: Arc<Core>,
    app: Arc<Mutex<AppState>>,
    pst: Arc<Mutex<PlayerState>>,
    tx: Sender<PlayerCmd>,
) {
    let _ = std::thread::Builder::new()
        .name("hotkeys".into())
        .spawn(move || unsafe { run(core, app, pst, tx) });
}

unsafe fn run(
    core: Arc<Core>,
    app: Arc<Mutex<AppState>>,
    pst: Arc<Mutex<PlayerState>>,
    tx: Sender<PlayerCmd>,
) {
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{
        RegisterHotKey, MOD_ALT, MOD_CONTROL, MOD_NOREPEAT, VK_DOWN, VK_LEFT, VK_RIGHT, VK_SPACE,
        VK_UP,
    };
    use windows_sys::Win32::UI::WindowsAndMessaging::{GetMessageW, MSG, WM_HOTKEY};

    let mods = MOD_CONTROL | MOD_ALT | MOD_NOREPEAT;
    let combos: [(i32, u32); 5] = [
        (HK_TOGGLE, VK_SPACE as u32),
        (HK_NEXT, VK_RIGHT as u32),
        (HK_PREV, VK_LEFT as u32),
        (HK_VOL_UP, VK_UP as u32),
        (HK_VOL_DOWN, VK_DOWN as u32),
    ];
    let mut bound = 0;
    for (id, vk) in combos {
        if RegisterHotKey(std::ptr::null_mut(), id, mods, vk) != 0 {
            bound += 1;
        }
    }
    eprintln!("[hotkeys] {bound}/5 global combos bound (ctrl+alt+space/←/→/↑/↓)");

    let mut msg: MSG = std::mem::zeroed();
    while GetMessageW(&mut msg, std::ptr::null_mut(), 0, 0) > 0 {
        if msg.message != WM_HOTKEY || !enabled() {
            continue;
        }
        match msg.wParam as i32 {
            HK_TOGGLE => {
                let _ = tx.send(PlayerCmd::Toggle);
            }
            HK_NEXT => {
                let _ = tx.send(PlayerCmd::Next);
            }
            HK_PREV => {
                let _ = tx.send(PlayerCmd::Prev);
            }
            HK_VOL_UP | HK_VOL_DOWN => {
                let step: i32 = if msg.wParam as i32 == HK_VOL_UP { 5 } else { -5 };
                let v = (core.volume.load(Ordering::Relaxed) as i32 + step).clamp(0, 100) as u32;
                core.volume.store(v, Ordering::Relaxed);
                app.lock().unwrap().volume = v;
                state::save_config(&app, &core, &pst);
            }
            _ => {}
        }
    }
}
