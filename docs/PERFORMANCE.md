# AetherMix — performance notes

Measured on the user's machine (Windows, Qt 6.12 mingw 64, release build,
`target/x86_64-pc-windows-gnu/release/aethermix.exe`, window 1280×760, Aurora
theme, nothing playing).

These numbers are here so the next change can be judged instead of guessed.

---

## 1. How to measure

The app runs its own HTTP API on `127.0.0.1:3690`; the shell is a QML scene, so
"feels slow" usually means CPU/GPU, not the engine.

```bash
# RAM + CPU over N seconds (PowerShell)
powershell -NoProfile -ExecutionPolicy Bypass -File .scratch/mem.ps1 -Seconds 8

# minimise / restore (the 3D world pauses when hidden)
powershell -NoProfile -ExecutionPolicy Bypass -File .scratch/min.ps1 -Act min

# a screenshot without moving the mouse (PrintWindow, no focus steal)
powershell -NoProfile -ExecutionPolicy Bypass -File .scratch/shot.ps1 -Out ".scratch\shot.png"
```

`mem.ps1` reports working set, peak and **CPU as % of one core** over the window.

---

## 2. Baseline — what it costs

| State | CPU (one core) | RAM |
|---|---|---|
| Window visible, world alive, nothing playing | **~57–62%** (39% on Warp after the vault cleanup) | 300–335 MB (grows with decoded covers/wallpapers) |
| Window minimised (`awake` false → 3D paused) | **~10%** | same |
| Visible with the 3D world hidden (test hack) | **~35%** | 303 MB |
| Visible with all artwork masks disabled | ~57% (from 62%) | 309 MB |

Read that as:

- **the 3D world ≈ 27%** — a full-screen scene with transparent quads, glow
  quads and particles at 60 fps. This is the dominant cost.
- **the QML shell ≈ 35%** — the frame loop itself (animated world subtree, glass
  capture, blurs, shadows, ~600 items on a full page).
- **artwork masks ≈ 5%** — `MultiEffect` masked corners in `RoundImage`.
- Hiding the world does **not** stop its animations, so the 35% includes the
  scene's bookkeeping even when it is not painted.

Trying to render the 3D world into a 0.8-scale layer made it *worse* (+8% CPU):
the extra FBO pass costs more than the fill it saves. Do not retry that.

---

## 3. What was optimised

- **Level smoother timer** (`interval: 16`) now only runs when there is something
  to smooth: `playing || bassLevel > 0.002 || pageClock - enterStamp < 6`. It used
  to tick 60×/s forever.
- **Mini visualiser timer** (`interval: 33`) only runs while audio is playing.
- **`beatBloom`** (a screen-sized disc blurred at `blurMax: 140`) only builds its
  `layer` while `bassLevel > 0.03` instead of allocating a full-screen FBO for an
  invisible object.
- **Wallpaper decode cap**: `MediaBackdrop` sets `sourceSize.width ≈ window width`.
  A 4K wallpaper was decoding to 64 MB of texture for a blurred background; it is
  now ~4–6 MB.
- **Artwork decoding** was already capped in `RoundImage`
  (`sourceSize = 2× drawn size`) — that is why a 63-row list costs a fraction of
  what it used to.
- **Page cascade clock** freezes 6 s after a page arrives, so hundreds of row
  bindings stop recomputing every frame.
- **The 3D scene pauses while minimised** (`Background3D.awake` ← window visible
  and not minimised), which is where the 9.6% figure comes from.

Result: idle visible CPU 62.5% → **~57%** with the same visuals, and no measurable
regression in frame pacing.

### Vault cleanup (audit pass)

`scan_dir` used to walk every build/asset folder under Downloads
(`target`, `node_modules`, `assets`, `imported_assets`, `public`, …) to the depth
limit, so a dozen unzipped copies of one wallpaper mp3 produced a dozen rows and
a dozen artwork decodes. It now skips those folders and keeps one row per
`(filename, size)` pair. Result on this machine: library **124 → 80** tracks,
local rows **61 → 17**, boot RAM **~385 → ~295 MB**, and six genuinely artless
Downloads files left to the designed gradient fallback.

Theme churn was measured separately: 20 theme switches 292 → 328 MB, then
328 → 347, then 347 → 348. Every world's paintings/panels are decoded once and
kept for instant switches; there is no per-switch leak.

---

## 4. Knobs, if it needs to go further

All of these are theme-side and need no code change:

- `bg3d.planes` (veil family) — each plane is a full-screen transparent quad.
  Lowering 4 → 3 is roughly a 10% cut of the world's fill.
- `bg3d.count` (orb / bubbles / motes), `gearCount`, `bodies` — object counts.
- `bg3d.glow` / `glowI` / `bloom` — the `ExtendedSceneEnvironment` glow radius.
- `bg3d.speed` — slower motion does not lower cost per frame, but it makes a
  dropped frame far less visible.

Code-side levers, in order of value:

1. Fewer, larger `SoftGlow` quads instead of many small ones (fill-bound scene).
2. `glassCapture.textureSize` is already `width/3`; raising the 400 ms capture
   timer is a cheap win if the frosted panels ever feel expensive.
3. `RoundImage` masks: if a row count grows past ~100 visible, replace the masked
   `MultiEffect` with a pre-rounded thumbnail from the engine
   (`/thumb?u=…&r=…`) — one decode instead of one mask pass per row.

---

## 5. Things that look free but are not

- `RectangularShadow` on every card: it is a GPU pass each, fine per card, not
  fine per row in a long list.
- `Behavior on color` on dozens of hover targets is cheap, but `ColorAnimation`
  on a `MultiEffect`'s `opacity` forces a re-blend of that layer every frame.
- Any always-running `Timer` under 30 ms keeps the render loop awake; gate them on
  a condition (`playing`, `visible`, `page transition in flight`).
- `layer.enabled` on a 3D subtree (see §2).
- `Canvas` repaints: `FilmGrain` and the fallback grooves only repaint on
  size/palette change — keep it that way.

---

## 6. Verification checklist for future work

1. `cargo build --release --target x86_64-pc-windows-gnu`, `windeployqt`, launch.
2. `grep -iE "error|Cannot|Unable|is not" .scratch/run.log` — QML failures are
   printed, not thrown.
3. Screenshot each page: Playlist (0), Local (1), Vibe (2), Queue (3), Themes (4),
   Home (5), Settings (6). Look for overlap and stray rules.
4. `mem.ps1` before/after: visible idle, minimised, and with audio playing.
5. Import one small playlist and watch `failed[]` — the honest list is part of the
   feature, not a debug view.

---

## 7. Frame pacing (smoothness pass)

The shell measures its own frame time honestly: `FrameAnimation` fires once per
presented frame, so the number is what the compositor actually did, not what a
16 ms timer hoped for.

```
curl -s localhost:3690/frame
{"fps":121,"worst":13,"q":100,"slow":0,"vslow":0}
```

- `fps` - smoothed presented frames per second
- `worst` - slowest frame of the last ~3 s window (a 60 fps average hides a
  40 ms hitch just fine; `worst` is what the eye reads as stutter)
- `slow` / `vslow` - frames over 20 ms / 40 ms in that window
- `q` - world quality from the governor, 100 / 58 / 30
- `d` (write-only, `?d=`) - a diagnostic trail for QML work; QML runtime errors
  never reach `.scratch/run.log`, so this is the only channel back out

**Measured, steady state, all twenty themes:** 114-122 fps, worst 10-20 ms,
`slow: 0`, `vslow: 0`. With MSAA on: silk 102, vitrail 107, the rest 119-121.

**Measured, at a theme switch:** 50-66 ms hitches (5-10 frames over 40 ms in
the 3 s window) on the texture-heavy rooms - clockwork, firefly, frutiger,
gameboy, silk, vapor, vitrail, warp. That is first-paint upload of the world
image and the panel textures. It lands inside the change-of-world curtain, so
it is masked visually; the governor is the fallback if a machine cannot take
it.

**Why it looked jittery at 120 fps:** the room's lighting and accents were
advanced by fixed-rate timers (80 / 33 / 30 / 16 ms) while frames presented at
120 Hz, so audio-reactive light held for a frame and stepped. Everything
continuous now advances once per presented frame - see UI_AND_MOTION.md,
"Smoothness pass".

**Correction to §6 step 2:** QML load and runtime failures do **not** reliably
reach `.scratch/run.log`. An unavailable type (`FrameAnimation` under
`import QtQuick 2.15`) produced a completely white window and an empty log.
Check the window itself, and if a page is blank suspect a type resolution
before suspecting the renderer.
## 8. Cadence, third pass (2026-10-25)

### The panel is 120 Hz, and the loop was free-running

`QSG_RENDER_LOOP` diagnostics report `VREFRESH=120` and Qt's animation driver
`using vsync: 8.33 ms`, but under `windows` / `d3d11` the default `basic` loop
used `Present(0, DXGI_PRESENT_DO_NOT_WAIT)` - it never waited for the vertical
blank. So the loop emitted frames whenever it finished one: a 100-128 fps
average that swings between 8 ms and 16 ms presents. In devtools that looks
like "120 fps, worst 18, fine". In the ear and the eye it is the *rhythm* that
is wrong: the trail (`root.trail`) fills alternately with short and long bars.

Reading the trail is the actual verification:

- an even trail with a steady `fps` near the panel rate and `slow: 0` means the
  loop is holding cadence;
- a trail that alternates 8/16 ms bars at 120 "fps" means free-running, not
  smooth;
- `slow` (frames over 33 ms) and `vslow` (over 50 ms) count the visible hitches,
  and each one should be explainable by a page change or a theme load.

The frame probe (`frameProbe`, 1000 ms window, trail of 96 frames) is what the
devtools panel shows; `frameProbe.d` reports it to `GET /frame`. The probe only
runs while a page needs it (`winProbe` for the open-transition fade,
`deepProbe` for the whole time a lyric column with its eq warp is on screen, and
always while the devtools panel is open), so measuring costs nothing in normal
use.

### Where the time actually went

Measured on the 1280x760 window, non-maximised, `aurora`:

| cost | how it was found | before -> after |
| --- | --- | --- |
| two live pages during a transition | `pageIndex` visibility joined with `leavingPage` | one live page; 50 ms hitches gone |
| CircEQ canvas repaint x3 | `Timer{interval:16}` under a `Canvas`, on hidden pages too | 30 fps, `live` gated, stops when hidden |
| clipped twin `Text` karaoke fill | 60 Hz clip-width change = a second text layout per frame | colour ramp, no second text |
| `MultiEffect` frost over the world | full-window blur of a live capture, every frame | removed; the 1/4-res capture *is* the frost |
| 3D world at 45 fps with MSAA + transmission | `fgCount` over 2 s | 100-128 fps, quality governor now actually works |

### After the fixes

Frame probe, 3 s windows, `aurora`, MSAA 4, `/env` flat: 105-128 fps, `worst`
15-23 ms, `slow` 0-3, `vslow` 0-1 - and the slow frames land exactly on a page
change (the incoming page's first paint plus the world's quality step), not
during idle.

### Known leftovers

- First paint of a page is the one honest spike (50-66 ms on the heaviest
  pages). It happens under the curtain and the entrance fade.
- A theme switch still loads textures on the frame it is requested. Warm
  switching inside the picker (the common case) is cached; a cold switch from
  the settings list can hitch once.
- On a 120 Hz panel, "fps" over 60 already means frames are being dropped. Read
  `slow`/`vslow` and the trail, not the average.
