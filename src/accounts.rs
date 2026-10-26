// lang: Rust, file: accounts.rs
// who is singing along: youtube sources are identified by the browser (or
// cookie file) their session lives in, because that is exactly what yt-dlp
// already knows how to read. one active account at a time, switchable.

use serde_json::{json, Value};
use std::process::Command;

const STORE: &str = concat!(env!("AETHER_ROOT"), "/accounts.json");
const YTDLP: &str = concat!(env!("AETHER_ROOT"), "/bin/yt-dlp.exe");

fn windowless(c: &mut Command) -> &mut Command {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        c.creation_flags(0x0800_0000);
    }
    c
}

pub fn ytdlp() -> Command {
    let mut c = Command::new(YTDLP);
    windowless(&mut c);
    c
}

fn defaults() -> Value {
    json!({
        "accounts": [
            {
                "id": "local",
                "provider": "youtube",
                "label": "This machine",
                "cookies": "",
                "active": true,
                "note": "no sign-in - public youtube search and downloads"
            }
        ],
        "next_id": 2
    })
}

fn sanitize(mut v: Value) -> Value {
    let mut base = defaults();
    if let (Some(d), Some(s)) = (base.as_object_mut(), v.as_object()) {
        for (k, val) in s {
            d.insert(k.clone(), val.clone());
        }
    }
    // exactly one active youtube account, always
    let mut seen_active = false;
    if let Some(arr) = base.get_mut("accounts").and_then(|a| a.as_array_mut()) {
        for a in arr.iter_mut() {
            let active = a.get("active").and_then(|x| x.as_bool()).unwrap_or(false);
            if active && !seen_active {
                seen_active = true;
            } else if let Some(obj) = a.as_object_mut() {
                obj.insert("active".into(), json!(false));
            }
        }
        if !seen_active {
            if let Some(first) = arr.first_mut().and_then(|a| a.as_object_mut()) {
                first.insert("active".into(), json!(true));
            }
        }
    }
    v = base;
    v
}

pub fn load() -> Value {
    let raw = std::fs::read_to_string(STORE).unwrap_or_default();
    if raw.trim().is_empty() {
        return defaults();
    }
    serde_json::from_str::<Value>(&raw)
        .map(sanitize)
        .unwrap_or_else(|_| defaults())
}

pub fn save(v: &Value) -> Result<(), String> {
    let clean = sanitize(v.clone());
    let body = serde_json::to_string_pretty(&clean).map_err(|e| e.to_string())?;
    let tmp = format!("{STORE}.tmp");
    std::fs::write(&tmp, body).map_err(|e| format!("write accounts: {e}"))?;
    std::fs::rename(&tmp, STORE).map_err(|e| format!("commit accounts: {e}"))?;
    Ok(())
}

pub fn active_account() -> Option<Value> {
    let store = load();
    store
        .get("accounts")
        .and_then(|a| a.as_array())
        .and_then(|a| {
            a.iter()
                .find(|x| {
                    x.get("provider").and_then(|p| p.as_str()) == Some("youtube")
                        && x.get("active").and_then(|v| v.as_bool()).unwrap_or(false)
                })
                .cloned()
        })
}

/// yt-dlp arguments that carry the session of the active account.
pub fn cookie_args() -> Vec<String> {
    let Some(acc) = active_account() else {
        return Vec::new();
    };
    let raw = acc.get("cookies").and_then(|c| c.as_str()).unwrap_or("").trim();
    if raw.is_empty() {
        return Vec::new();
    }
    if raw.starts_with("browser:") {
        let spec = &raw[8..];
        if spec.is_empty() {
            return Vec::new();
        }
        vec!["--cookies-from-browser".into(), spec.into()]
    } else if raw.starts_with("file:") {
        vec!["--cookies".into(), raw[5..].into()]
    } else {
        // a bare path or a bare browser name: accept both, the field is typed
        if raw.ends_with(".txt") || raw.contains('/') || raw.contains('\\') {
            vec!["--cookies".into(), raw.into()]
        } else {
            vec!["--cookies-from-browser".into(), raw.into()]
        }
    }
}

pub fn status_json(spotify_ready: bool, spotify_name: &str) -> String {
    let store = load();
    json!({
        "accounts": store.get("accounts").cloned().unwrap_or(json!([])),
        "active": active_account()
            .and_then(|a| a.get("id").and_then(|x| x.as_str()).map(|s| s.to_string()))
            .unwrap_or_default(),
        "cookies": cookie_args(),
        "spotify": { "granted": spotify_ready, "name": spotify_name }
    })
    .to_string()
}

/// Open the real sign-in page in the real browser. The app never asks for the
/// password: it reads the session the browser already holds.
pub fn open_signin(provider: &str) -> Result<(), String> {
    let url = match provider {
        "spotify" => "https://accounts.spotify.com/login",
        _ => "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fwww.youtube.com%2F",
    };
    let mut c = Command::new("cmd");
    windowless(&mut c);
    c.args(["/C", "start", "", url])
        .spawn()
        .map(|_| ())
        .map_err(|e| format!("could not open the browser: {e}"))
}

/// Trial load of the active cookies through a harmless search. This is not a
/// login probe (youtube has no public one); it reports whether yt-dlp can
/// read the session at all, which is where imports actually fail.
pub fn test_active() -> String {
    let (ok, detail) = crate::ytcvt::probe_session();
    json!({ "ok": ok, "detail": detail }).to_string()
}
