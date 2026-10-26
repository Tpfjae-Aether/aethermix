# AetherMix — feature audit, stress test and optimisation pass

Window 1280×760, release build (`target/x86_64-pc-windows-gnu/release/aethermix.exe`),
theme **Warp**, library 63 playlist rows + 17 local files. The engine exposes its
whole surface on `127.0.0.1:3690`, so the audit drives the app the same way the QML
does and then checks the *effect*, not the `{"ok":true}`.

Run it with:

```bash
PYTHONIOENCODING=utf-8 python .scratch/audit.py
```

The script restores everything it touches (playlist switch, theme, volume, viz
mode, appearance, queue, lyric offset) before it exits.

---

## 1. Result of this pass

`FAILS=0`, 47 checks. The only informational line is:

```
info  artless local files   6 (gradient fallback in Art)
```

Those six Downloads files have no embedded ID3 art and no sidecar image, so the
list row and hero use the designed seeded gradient (`Art`). This is a data fact,
not a UI hole — the check now fails only for **playlist** rows, which must always
carry the cached import cover.

Covered by checks:

- library ids unique; `total = local + stream`; `playable` count honest; every
  playable local path resolves on disk
- play / pause / resume / seek / volume / viz mode / shuffle / repeat / next /
  prev / queue add & remove & play-next
- lyrics: text returned, timestamps ascend, first line inside the song, synced
  flag, per-song offset persisted
- playlists: create, list, switch (deck changes), append, remove, switch back
- all 20 themes switch; theme restored; appearance round-trip unchanged
- per-tab theme write + clear
- accounts payload shape; remote cover proxy (none loaded remotely right now)

## 2. Bugs found and fixed

1. **Local vault ate Downloads junk.** `scan_dir` walked every build/asset folder
   (`target`, `node_modules`, `assets`, `imported_assets`, `public`, …) up to the
   depth limit, so a dozen copies of the same wallpaper mp3 became a dozen rows.
   It now skips those folders and collapses identical `(filename, size)` pairs.
   Library: **124 tracks → 80**, local rows **61 → 17**, boot RAM **~385 → ~295 MB**.
2. **Top-bar collision.** The centred identity row carried the material name
   ("WARP GLASS"); on longer page titles it ran under the `CTRL K` search pill on
   every page. The material name was redundant (the atmosphere is named at the
   far right of the bar) and is gone; the row now stops at the room name.
3. **Portal hover glyph.** The five home doors showed the transport `next` glyph
   (a skip-track icon) as their hover arrow, hanging half outside the hover pill.
   Added a `chev` NavIcon and tucked it inside the pill.
4. **Ghost lyric on a stopped deck.** Home under "nothing playing" still quoted the
   last song's current lyric. The quote is now gated on a real `track_id`; the
   room's own line (`tc.line`) is shown instead.

## 3. Stress test

- 21 page switches (Home → Playlist → Local → Vibe → Queue → Themes → Settings ×3)
  interleaved with all 20 theme changes: **no QML error, warning or binding loop**
  in `run.err`, UI still painting afterwards.
- Theme churn alone, three full cycles: RAM 292 → 328 → 347 → 348 MB. It plateaus
  once every world's paintings/panels have been decoded (instant switches after
  that); it is not an unbounded leak.
- Playback churn: play + 25 `next` + 5 seeks: no deadlock, position/underrun
  counters sane, RAM stable within the same band.
- Idle visible cost on Warp: **~39% of one core, ~340 MB**, matching
  `docs/PERFORMANCE.md`. Minimised pauses the 3D room.

## 4. Optimisation notes from this pass

- The local scan is cached (`Library.local_cache`) and now much smaller, which
  removes row delegates, `RoundImage` decodes and artwork masks — the cheapest
  memory win in the app.
- Theme textures plateau rather than leak (see §3). No new caches were added.
- The HTTP bridge still spawns one short-lived thread per request; with a 200 ms
  state poll while playing that is ~5 threads/s, all joined. Thread stacks are
  ~16 KB committed each, so it is CPU noise, not the memory story. If the poll is
  ever tightened, add `Connection: close` or a tiny worker pool first.
- Cover decoding is already capped at 2× drawn size and 768 px
  (`RoundImage.sourceSize`), so 34 px row thumbs never decode a 1000 px sleeve.

## 5. Not covered here (needs network / an account)

- YouTube add & playlist import end-to-end were verified earlier (H.264 backdrop
  pin, real cover cached, honest `failed[]` list). Re-running them spends
  bandwidth and depends on YouTube not rate-limiting.
- Spotify / SoundCloud sign-in and account switching: API shape checked, live
  OAuth not exercised in this pass.
- Apple Music: deliberately out of scope (no public playback API for this shell).

## 6. Screenshot set

`.scratch/aud_p{0..6}.png`, `.scratch/fin_p4.png`, `.scratch/fin_p5.png`,
`.scratch/fin2_home.png` — Playlist shelf, Local, Vibe, Queue, Themes, Home,
Settings. All top bars clean after fix 2; lists fade at the dock, no rules.
