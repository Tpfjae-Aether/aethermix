// lang: Rust, file: shell.rs, runs on: Windows 11, target: official Spotify client
// shell mode: AetherMix keeps its entire UI and drives the OFFICIAL Spotify
// desktop client as the sound engine via the Web API player endpoints.
// The audio-key denial never applies: we never decode anything - the official
// client plays, we command and mirror its state.

use crate::stream::access_token;
use std::sync::Mutex;
use std::time::{Duration, Instant};

static LAST_DEVICE_FETCH: Mutex<Option<Instant>> = Mutex::new(None);

enum Patience {
    Fast,     // state queries: fail immediately on 429
    Retry,    // control commands: honor Retry-After, bounded to 2 attempts
}

fn api(method: &str, path: &str, body: Option<String>) -> Result<Option<String>, String> {
    api_inner(method, path, body, Patience::Fast)
}

fn api_retry(method: &str, path: &str, body: Option<String>) -> Result<Option<String>, String> {
    api_inner(method, path, body, Patience::Retry)
}

fn api_inner(
    method: &str,
    path: &str,
    body: Option<String>,
    patience: Patience,
) -> Result<Option<String>, String> {
    let mut last_err = String::new();
    for attempt in 0..2 {
        if attempt == 1 {
            match patience {
                Patience::Fast => return Err(last_err),
                Patience::Retry => {
                    // wait out the throttle once, bounded to 30s
                    std::thread::sleep(Duration::from_secs(30));
                }
            }
        }
        let Some(tok) = access_token() else {
            return Err("no access token".into());
        };
        let url = format!("https://api.spotify.com/v1{path}");
        let resp = ureq::AgentBuilder::new()
            .timeout(Duration::from_secs(12))
            .build()
            .request(method, &url)
            .set("Authorization", &format!("Bearer {tok}"))
            .set("Content-Type", "application/json");
        let resp = match body {
            Some(ref b) => resp.send_string(b),
            None => resp.call(),
        };
        // 429: swallow and retry once when patient
        if let Err(ureq::Error::Status(429, _)) = &resp {
            last_err = "429 rate limited".into();
            continue;
        }
        let resp = resp.map_err(|e| format!("{e}"))?;
        if resp.status() == 204 {
            return Ok(None);
        }
        let text = resp
            .into_string()
            .map_err(|e| format!("read body: {e}"))?;
        return Ok(Some(text));
    }
    Err(last_err)
}

pub struct ShellDevice {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub active: bool,
}

pub fn devices() -> Result<Vec<ShellDevice>, String> {
    // light throttle: the devices call is small but polled; 2s min interval
    {
        let g = LAST_DEVICE_FETCH.lock().unwrap();
        if let Some(t) = *g {
            if t.elapsed().as_secs() < 2 {
                return Ok(Vec::new()); // caller uses cached list
            }
        }
    }
    *LAST_DEVICE_FETCH.lock().unwrap() = Some(Instant::now());
    let Some(body) = api("GET", "/me/player/devices", None)? else {
        return Ok(Vec::new());
    };
    let v: serde_json::Value = serde_json::from_str(&body).map_err(|e| format!("{e}"))?;
    let mut out = Vec::new();
    if let Some(devs) = v.get("devices").and_then(|d| d.as_array()) {
        for d in devs {
            out.push(ShellDevice {
                id: d.get("id").and_then(|x| x.as_str()).unwrap_or("").into(),
                name: d.get("name").and_then(|x| x.as_str()).unwrap_or("?").into(),
                kind: d.get("type").and_then(|x| x.as_str()).unwrap_or("?").into(),
                active: d.get("is_active").and_then(|x| x.as_bool()).unwrap_or(false),
            });
        }
    }
    Ok(out)
}

fn pick_device(prefer_computer: bool) -> Result<String, String> {
    let devs = devices()?;
    if devs.is_empty() {
        return Err("no Connect devices visible - open the official Spotify desktop app".into());
    }
    if prefer_computer {
        if let Some(d) = devs.iter().find(|d| d.kind == "Computer") {
            return Ok(d.id.clone());
        }
    }
    if let Some(d) = devs.iter().find(|d| d.active) {
        return Ok(d.id.clone());
    }
    Ok(devs[0].id.clone())
}

pub fn play_track_uri(uri: &str) -> Result<(), String> {
    let dev = pick_device(true)?;
    let body = serde_json::json!({ "uris": [uri], "position_ms": 0 }).to_string();
    api_retry("PUT", &format!("/me/player/play?device_id={dev}"), Some(body))?;
    Ok(())
}

pub fn pause() -> Result<(), String> {
    api("PUT", "/me/player/pause", None)?;
    Ok(())
}

pub fn resume() -> Result<(), String> {
    api("PUT", "/me/player/play", None)?;
    Ok(())
}

pub fn toggle() -> Result<(), String> {
    if let Some(np) = now_playing_raw()? {
        if np.get("is_playing").and_then(|x| x.as_bool()).unwrap_or(false) {
            return pause();
        }
    }
    resume()
}

pub fn next() -> Result<(), String> {
    api("POST", "/me/player/next", None)?;
    Ok(())
}

pub fn prev() -> Result<(), String> {
    api("POST", "/me/player/previous", None)?;
    Ok(())
}

pub fn seek(ms: u32) -> Result<(), String> {
    api("PUT", &format!("/me/player/seek?position_ms={ms}"), None)?;
    Ok(())
}

pub fn volume(pct: u32) -> Result<(), String> {
    api("PUT", &format!("/me/player/volume?volume_percent={pct}"), None)?;
    Ok(())
}

fn now_playing_raw() -> Result<Option<serde_json::Value>, String> {
    match api("GET", "/me/player", None) {
        Ok(Some(body)) => {
            if body.trim().is_empty() {
                return Ok(None);
            }
            serde_json::from_str(&body).map(Some).map_err(|e| format!("{e}"))
        }
        Ok(None) => Ok(None),
        Err(e) => Err(e),
    }
}

// mirror the official client's state into the same shape the QML transport reads
pub fn now_playing() -> serde_json::Value {
    match now_playing_raw() {
        Ok(Some(v)) => {
            let item = v.get("item").cloned().unwrap_or(serde_json::Value::Null);
            let artists = item
                .get("artists")
                .and_then(|a| a.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|x| x.get("name").and_then(|n| n.as_str()))
                        .collect::<Vec<_>>()
                        .join(", ")
                })
                .unwrap_or_default();
            serde_json::json!({
                "is_playing": v.get("is_playing").and_then(|x| x.as_bool()).unwrap_or(false),
                "position_ms": v.get("progress_ms").and_then(|x| x.as_u64()).unwrap_or(0),
                "duration_ms": item.get("duration_ms").and_then(|x| x.as_u64()).unwrap_or(0),
                "title": item.get("name").and_then(|x| x.as_str()).unwrap_or(""),
                "artist": artists,
                "cover_url": item.pointer("/album/images/0/url").and_then(|x| x.as_str()).unwrap_or(""),
                "uri": item.get("uri").and_then(|x| x.as_str()).unwrap_or(""),
                "device": v.pointer("/device/name").and_then(|x| x.as_str()).unwrap_or(""),
            })
        }
        _ => serde_json::json!({ "is_playing": false }),
    }
}
