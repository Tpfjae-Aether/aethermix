// Editing rooms from the phone.
//
// The desktop's open room lives in memory, but every other room is just a json
// file on disk. These helpers write those files directly: one row at a time,
// never a full rewrite of the library, and never a change to the deck that is
// playing. `mode=stream` keeps the row pointing at the page; `mode=file` adds
// the row immediately and upgrades it to a local file once ffmpeg has the audio,
// so the song is listenable while it lands.

use serde_json::{json, Value};
use std::path::Path;

fn read_room(pl: &str) -> Option<Value> {
    let body = std::fs::read_to_string(pl).ok()?;
    serde_json::from_str::<Value>(&body).ok()
}

fn write_room(pl: &str, v: &Value) -> bool {
    let Some(body) = serde_json::to_string_pretty(v).ok() else {
        return false;
    };
    let tmp = format!("{pl}.tmp");
    if std::fs::write(&tmp, body).is_err() {
        return false;
    }
    std::fs::rename(&tmp, pl).is_ok()
}

fn rows_mut(v: &mut Value) -> Option<&mut Vec<Value>> {
    v.get_mut("tracks").and_then(|t| t.as_array_mut())
}

fn already_there(rows: &[Value], url: &str) -> bool {
    rows.iter().any(|t| {
        t.get("web").and_then(|x| x.as_str()).map(|w| w == url).unwrap_or(false)
            || t.get("uri").and_then(|x| x.as_str()).map(|w| w == url).unwrap_or(false)
    })
}

/// Add one page to a room. Returns the json body the phone reads.
pub fn add_web(pl: &str, url: &str, mode: &str) -> String {
    if !Path::new(pl).is_file() {
        return json!({"ok": false, "error": "no such room"}).to_string();
    }
    let Some(mut v) = read_room(pl) else {
        return json!({"ok": false, "error": "that room is not readable"}).to_string();
    };
    if let Some(rows) = v.get("tracks").and_then(|t| t.as_array()) {
        if already_there(rows, url) {
            return json!({"ok": true, "duplicate": true, "title": ""}).to_string();
        }
    }
    let meta = match crate::ytcvt::web_meta(url) {
        Ok(m) => m,
        Err(e) => return json!({"ok": false, "error": e}).to_string(),
    };
    let cover = crate::ytcvt::cache_cover(&meta.vid, &meta.thumb);
    let row = json!({
        "title": meta.title,
        "artist": meta.artist,
        "album": meta.album,
        "duration_ms": meta.duration_ms,
        "uri": "",
        "web": url,
        "cover": cover,
        "path": "",
    });
    {
        let Some(rows) = rows_mut(&mut v) else {
            return json!({"ok": false, "error": "that room has no track list"}).to_string();
        };
        rows.push(row);
    }
    let title = meta.title.clone();
    if !write_room(pl, &v) {
        return json!({"ok": false, "error": "could not write the room"}).to_string();
    }
    if mode == "file" {
        let pl2 = pl.to_string();
        let url2 = url.to_string();
        std::thread::Builder::new()
            .name("room-dl".into())
            .spawn(move || match crate::ytcvt::ingest_url(&url2) {
                Ok(got) => {
                    eprintln!("[room] downloaded {} -> {}", got.title, got.path);
                    if let Some(mut v) = read_room(&pl2) {
                        if let Some(rows) = rows_mut(&mut v) {
                            for t in rows.iter_mut() {
                                let web = t.get("web").and_then(|x| x.as_str()).unwrap_or("");
                                if web == url2 {
                                    t["path"] = json!(got.path);
                                    if !got.cover_url.is_empty() {
                                        t["cover"] = json!(got.cover_url);
                                    }
                                    break;
                                }
                            }
                        }
                        let _ = write_room(&pl2, &v);
                    }
                }
                Err(e) => eprintln!("[room] download failed for {url2}: {e}"),
            })
            .ok();
    }
    json!({
        "ok": true,
        "title": title,
        "mode": if mode == "file" { "file" } else { "stream" },
        "msg": if mode == "file" { "added, downloading for offline" } else { "added as a stream" },
    })
    .to_string()
}

/// Set - or clear - the cover of a room. The cover is a URL or a file path the
/// bridge can serve, exactly what a row's own cover is.
pub fn set_cover(pl: &str, cover: &str) -> bool {
    let Some(mut v) = read_room(pl) else {
        return false;
    };
    if !v.is_object() {
        return false;
    }
    v["cover"] = json!(cover);
    write_room(pl, &v)
}

/// The list a phone can pick from: the art already in the room, plus the app's
/// own generated faces, so a room is never stuck with no cover at all.
pub fn cover_choices(pl: &str) -> String {
    let mut out: Vec<String> = Vec::new();
    if let Some(v) = read_room(pl) {
        if let Some(rows) = v.get("tracks").and_then(|t| t.as_array()) {
            for t in rows {
                if let Some(c) = t.get("cover").and_then(|x| x.as_str()) {
                    if c.len() > 4 && !out.iter().any(|x| x == c) {
                        out.push(c.to_string());
                    }
                    if out.len() >= 24 {
                        break;
                    }
                }
            }
        }
    }
    json!({"ok": true, "covers": out}).to_string()
}
