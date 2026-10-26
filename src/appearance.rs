// lang: Rust, file: appearance.rs
// the look of the room, per tab if you want it that way: type, backdrop
// media, grading, and a theme override for every page. Stored as one small
// json file next to the app so a hand edit is always possible.

use serde_json::{json, Value};

const STORE: &str = concat!(env!("AETHER_ROOT"), "/appearance.json");

pub const TAB_COUNT: usize = 7;

fn defaults() -> Value {
    json!({
        "font": {
            "family": "Segoe UI",
            "scale": 1.0,
            "color": "",
            "weight": 400,
            "tracking": 0.0
        },
        "backdrop": {
            "kind": "theme",
            "source": "",
            "opacity": 0.75,
            "blur": 0.22,
            "tint": "#050f1c",
            "tintAmt": 0.0,
            // the equaliser's two colours. an empty string means "draw with
            // whatever this room's palette already gives me", which is what
            // every meter did before this existed, so the default look is
            // unchanged. they live here, in the look document, so they are
            // per tab like the rest of the grading.
            "eqA": "",
            "eqB": "",
            "hue": 0.0,
            "sat": 1.0,
            "bright": 1.0,
            "zoom": 1.0,
            "drift": 0.35
        },
        // motion + sound are preferences, not theme data: the reference
        // settings surface exposes speed, feel and a chosen tap voice.
        "motion": {
            "enabled": true,
            "speed": 1.0,
            "style": "smooth",
            "sound": "tap",
            "typing": true,
            "volume": 0.35
        },
        // the collapsed window: which part of the room travels with it
        "mini": {
            "bg": "theme"
        },
        // library habits: how a song found on the web joins the playlist
        "library": {
            "add_mode": "stream"
        },
        "tabs": {}
    })
}

fn merge(dst: &mut Value, src: &Value) {
    if let (Some(d), Some(s)) = (dst.as_object_mut(), src.as_object()) {
        for (k, v) in s {
            match d.get_mut(k) {
                Some(slot) if slot.is_object() && v.is_object() => merge(slot, v),
                _ => {
                    d.insert(k.clone(), v.clone());
                }
            }
        }
    }
}

fn sanitize(mut v: Value) -> Value {
    // every stored field is read by QML as a number/string; keep the types
    // honest so a hand-edited file cannot poison the whole surface.
    let mut base = defaults();
    merge(&mut base, &v);
    if let Some(tabs) = base.get("tabs").and_then(|t| t.as_object()) {
        let mut clean = serde_json::Map::new();
        for (k, val) in tabs {
            if k.parse::<usize>().map(|n| n < TAB_COUNT).unwrap_or(false) {
                clean.insert(k.clone(), val.clone());
            }
        }
        v = json!(clean);
        base["tabs"] = v;
    }
    base
}

pub fn load() -> Value {
    let raw = std::fs::read_to_string(STORE).unwrap_or_default();
    if raw.trim().is_empty() {
        return defaults();
    }
    match serde_json::from_str::<Value>(&raw) {
        Ok(v) => sanitize(v),
        Err(e) => {
            eprintln!("[appearance] unreadable store ({e}) - using defaults");
            defaults()
        }
    }
}

pub fn save(v: &Value) -> Result<(), String> {
    let clean = sanitize(v.clone());
    let body = serde_json::to_string_pretty(&clean).map_err(|e| e.to_string())?;
    // write beside the real file, then rename: a crash mid-write cannot leave
    // a half file that resets the whole look
    let tmp = format!("{STORE}.tmp");
    std::fs::write(&tmp, body).map_err(|e| format!("write appearance: {e}"))?;
    std::fs::rename(&tmp, STORE).map_err(|e| format!("commit appearance: {e}"))?;
    Ok(())
}

pub fn get_json() -> String {
    load().to_string()
}

/// The tab override for a page, or the global backdrop when the page has none.
pub fn effective_backdrop_for(page: usize) -> Value {
    let store = load();
    let global = store.get("backdrop").cloned().unwrap_or_default();
    let tab = store
        .get("tabs")
        .and_then(|t| t.get(page.to_string()))
        .cloned()
        .unwrap_or(Value::Null);
    let enabled = tab.get("enabled").and_then(|x| x.as_bool()).unwrap_or(false);
    if !enabled {
        return global;
    }
    let mut out = global;
    if let Some(obj) = tab.as_object() {
        for (k, v) in obj {
            if k == "theme" || k == "enabled" {
                continue;
            }
            out[k] = v.clone();
        }
    }
    out
}
