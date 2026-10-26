# Feature pass - eight additions and what they cost

Window 1280x760, release build. Every item below was driven through the running
app (or its HTTP bridge) and the *effect* was checked, not just `{"ok":true}`.
Numbers in the last section come from `GET /frame` and `tasklist`.

---

## 1. Liked songs

- Stored in `cache/favorites.json` keyed by **song identity** (`state::song_key`,
  title + artist), never by the playlist id: ids move when a playlist is
  re-synced and a like must survive that.
- `GET /favorite?id=&on=` toggles (no `on` = flip). `GET /favorites` lists keys.
- Every `/library` row now carries `key`, `liked` and `plays`; the header
  carries `liked` and `total_ms`, so the list can draw hearts and the toolbar
  can show a real count without a request per row.
- UI: a heart on every playlist row (faint when unliked, solid when liked), a
  `♥ n LIKED` chip that filters the list, and a heart entry in the row menu.

**Trap:** `rowMa` (the row's click surface) is declared *after* the row layout,
so it sits on top of anything inside the layout. The heart's own `MouseArea`
had to win by stacking, not by order - `rowMa` now carries `z: -1`, which puts
every control inside the row above it while empty space still plays the song.
The first version also failed silently because it only mutated the row object;
`liked` is server-owned, so `lastLibVer = -1` now forces a real reload (the
counter and the liked-only filter read the library, not the row).

## 2. Sort and filter the playlist

Pure view state - the playlist file keeps the order songs were added in.

- `SORT` cycles added → title → artist → plays → length. `plays` comes from
  `playstats.json`, `length` from the row durations.
- `LIKED` narrows to liked songs; text search still composes with both.
- The toolbar's count and total duration describe the *view* (`73 · 2h 29m`),
  so a filter can never leave a count and a duration that disagree.

## 3. Resume where the room was left

- A small thread writes `cache/resume.json` (`id`, `pos_ms`, `title`, `artist`)
  every 8 s while something plays, and only past 4 s.
- `/state` exposes it as `resume` (read per poll: a 5 s cache went stale the
  moment a song started and hid the chip for a whole track).
- Home shows a `RESUME <title> <position>` chip while the deck is stopped, but
  only when the saved **key** still matches a row in this playlist. Clicking it
  calls `/play?id=..&pos=..`; the route waits ~900 ms for the decoder to open,
  then seeks.

**Trap:** the saved `id` is an index into the active playlist file. The chip
matches on `key` and uses the current row's id, so a re-synced playlist cannot
resume the wrong song.

## 4. Sleep timer v2 - fade, countdown, and a restored volume

`GET /sleep?s=SECONDS|m=MINUTES&fade=MS` (default fade 20 s, clamped to the
wait). The engine ramps `Core::volume` down inside the device callback during
the last `fade` milliseconds, pauses, then **puts the user's volume back** both
in the engine and in `AppState` (the slider reads AppState; a ramp that only
touched the engine left the ui showing the faded value for good).

A generation counter retires the old thread on every new request, and
`sleep_cancel_restore` undoes a ramp that had already started. Settings shows a
live `m:ss` countdown from `state.sleep_ms`.

## 5. Export / import playlists (.m3u8)

- `GET /playlist/export` writes `library/exports/<name>.m3u8` (`#EXTM3U` +
  `#EXTINF`), rows without a file keep their `spotify:` uri.
- `GET /playlist/import/m3u?path=` resolves absolute, `file://` and relative
  entries against the playlist's own folder, skips `spotify:` lines and adds
  what exists, reporting `added` / `missing`.
- Both buttons live in the import sheet, next to "read a link".

**Trap:** the slug is ASCII-only. The playlist is called `𝒆𝒏𝑻𝒑𝑭彡`, and
`char::is_alphanumeric` happily accepted the mathematical-bold codepoints,
producing a file name nobody can type. Anything without two plain ASCII
alphanumerics now becomes `playlist.m3u8`. Also: `add_track` de-duplicates, so
the import counts `tracks.len()` before/after instead of counting attempts.

## 6. Track info sheet

`GET /track/info?id=` returns title, artist, album, duration, path, size,
format, plays, liked, streamable. `GET /track/reveal?id=` opens Explorer with
the file selected (via `explorer /select,`, hidden process window).

The sheet shows the tags, the play count, the format and the real path, with
SHOW IN FOLDER / LIKE / PLAY / CLOSE. Escape closes it (also wired into the
global key catcher, so it works even when the sheet has no focus).

## 7. System-wide keys

`src/hotkeys.rs`: a thread that registers `ctrl+alt+space` (play/pause),
`ctrl+alt+←/→` (prev/next) and `ctrl+alt+↑/↓` (volume ±5) with
`RegisterHotKey`, then pumps its own message queue. The `hotkeys` config flag
decides whether an event is acted on, so the Settings toggle needs no thread
management. Bound at boot: `[hotkeys] 5/5 global combos bound`.

## 8. Honest totals

`/library` now carries `total_ms`; the playlist toolbar and the queue header
use it. Small, but it is the kind of number that is obviously wrong when it is
wrong.

---

## Verification

| what | how | result |
| --- | --- | --- |
| like a row | clicked the heart in the running app | `/favorites` 0 → 1 → 0 |
| sort | clicked `SORT` | chip cycles, list reorders (title order verified) |
| track info | right-click row → TRACK INFO → LIKE | sheet shows 1:31 · 31 plays · M4A · 1.4 MB |
| resume | played 25 s, quit, relaunched, `/play?...&pos=25356` | position 25.3 s → 32.5 s after 6 s |
| sleep | `/sleep?s=6&fade=3000` while playing | countdown 2891 ms, paused at 0, volume 64 restored |
| hotkeys | sent `ctrl+alt+right` with the app focused | track changed `poison` → `clueless` |
| export | `/playlist/export` | `library/exports/playlist.m3u8`, 102 rows |
| import | m3u of a song already in the list | `{"added":0}`, no duplicate row |
| frame pacing | `/frame` on Vibe and Playlist | 120 fps, worst 10 ms, slow 0, vslow 0 |
| memory | `tasklist` | 343 MB with the wallpaper + full list |

## What is deliberately not here

- Crossfade and playback speed: both are engine-level (resampling / two
  decoders) and belong in `player.rs`, not in a ui pass.
- Media-key handling via SMTC: `RegisterHotKey` covers the same need without a
  COM interop layer, at the cost of being explicit combos rather than the
  hardware play button.
