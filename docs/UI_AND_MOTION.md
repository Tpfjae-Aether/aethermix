# AetherMix — UI, motion and background notes

Working notes for the shell. Everything below is true of the code as it stands
(`qml/Main.qml`, `qml/Background3D.qml`, `qml/MediaBackdrop.qml`, `src/server.rs`).
Written so the next person (or the next session) can change the look without
re-discovering the traps.

---

## 1. Where things live

| File | What it owns |
|---|---|
| `qml/Main.qml` | The window, the shell, the top bar, the dock, the nav rail, every page, every overlay (Watch, Import, Find, Studio, Immersive), every component (`Art`, `RoundImage`, `ScrubBar`, `GlassSurface`, `GlideWheel`, `AField`, `GlowButton`, `AChip`, `NavIcon`, `ThemeMark`) |
| `qml/Background3D.qml` | The live 3D world behind the UI. One scene per archetype, parameterised from the theme JSON |
| `qml/MediaBackdrop.qml` | User wallpapers: still, gif, film, YouTube clip, or the playing cover. Grade shader lives in `qml/shaders/grade.frag` (`.`qsb`) |
| `src/server.rs` | Local HTTP API on `127.0.0.1:3690` — the QML shell talks to the Rust engine only through this |
| `themes/*.json` | 20 worlds. Palette, type scale hints, 3D parameters, transition type and depth |
| `assets/` | `glow.png`, `haze.png`, `shaft.png`, `feather.png` (plane edge fade), `themes/*` paintings and panel textures |

QML is loaded from disk at start-up; editing `qml/*.qml` only needs a restart, not a rebuild.

---

## 2. Layout grammar

```
Window (frameless, 16px shell radius)
├── shell            Rectangle, th.bg, ColorAnimation 460ms on colour change
├── bg3d             Loader → Background3D, opacity = root.worldFade
├── mediaBackdrop    user wallpaper, z 0.5
├── atmosphere       two linear grades (rail side + floor), z 0.9, enabled:false
├── pages            z 1 (leaving) / 2 (current)
├── topbar           z 5
├── dock             z 6
├── toast            floats above the dock
├── overlays         Watch z 97 · Import z 96 · Find z 95 · Studio · Immersive
└── themeCurtain     z 88, only alive during a change of world
```

Rule that keeps the whole thing from looking like a dashboard: **nothing owns a
panel**. There are no full-width rules, no card borders on pages, no dividers in
lists. Separation is done with space, opacity and gradients. The two exceptions
are deliberate: sheets (`GlassSurface`) and the video frame.

### Type

- `root.tf` — the family (theme can override), `root.ts` — the scale multiplier.
- Page titles sit at `(27..54) * ts`, body at `8..11 * ts`, micro-labels at `7 * ts`
  with `letterSpacing 1.2–2.2`. Micro-labels are always uppercase.
- Colour comes from `th.text`, `th.dim`, `th.accent`, `th.bar`, `root.accent2()`.
  Use `root.rgba(c, a)` instead of hard-coded alpha colours so every theme grades
  correctly (light themes need different alphas — `tc.light`).

---

## 3. Motion grammar

The house rule: **nothing snaps**. Every state change is either an opacity
cross-fade, a short transform, or a dissolve. No element may appear at full
strength without arriving.

### Page changes

`gotoPage(i)` → `pageTransition` (ParallelAnimation) drives two numbers:

- `pageEnter` 0→1, `trDur()` ms (clamped 280–520), easing from the theme
  (`OutCubic`, `OutBack` for `dolly`, `Linear` for `snap`/`glitch`)
- `pageExit` 1→0, 80% of that duration, `InCubic` (the old room leaves faster
  than the new one arrives so they never fight)

`trEnterOf(p)` / `trExitOf(p)` return `{x,y,s,ry,rz,o}` per transition type
(`dolly`, `tilt`, `parallax`, `warp`, `glitch`, `snap`, `ripple`, `veil`, `slide`).
Rows additionally cascade via `cascFor(idx, page)` on a `pageClock` that only
advances for 6 seconds after a page arrives, then freezes so hundreds of row
bindings stop recomputing.

### Change of world (theme swap)

A palette, a wallpaper and a 3D scene cannot be interpolated. `dissolveWorld(oldBg)`
hides the cut:

1. `worldFade` 0→1 over 760 ms (`OutCubic`) — the new scene rises from the dark.
2. `curtainAmt` 0.88→0 over 660 ms — the outgoing room's `bg` colour washes over
   the whole window (z 88) and dissolves.
3. If the swap happens **as part of a page change** the curtain is skipped
   (`curtainAmt = 0`, rise shortened to 540 ms) — the page transition is already
   carrying the eye and two transitions read as lag.

`dissolveWorld` is only called when the palette actually differs (`bg`+`accent`),
so re-applying the same theme does not flash.

### Artwork

`RoundImage` fades each sleeve in over 340 ms on `source` change (`ri.fade`).
A track change therefore reads as a record being replaced, not a redraw.

### Wallpapers

`MediaBackdrop` keeps `shownSource` separate from `mediaSource`. A new wallpaper
fades the stage to 0 in 150 ms, swaps behind the dark, and rises in 560 ms.

### Scrolling

`GlideWheel` + `glideScroll()` animate `contentY` toward an accumulating target
(320 ms `OutCubic`), so repeated notches stack instead of restarting. Every list
uses `Flickable.StopAtBounds` with `flickDeceleration` 1100–1200.

### Durations used everywhere

| Action | Duration | Easing |
|---|---|---|
| hover tint | 120–180 ms | linear-ish |
| press / scale | 140–220 ms | `OutBack` |
| panel open | 380 ms (200 close) | `OutQuint` |
| page arrive | 280–520 ms | theme |
| world dissolve | 660–760 ms | `OutCubic` |
| wallpaper swap | 150 + 560 ms | `InCubic` / `OutCubic` |
| toast | 240 ms | `OutCubic` |

---

## 4. Themes

`themes/<id>.json` keys that matter to the UI:

```jsonc
{
  "bg": "#050508", "panel": "#0a0a0c", "panel_alpha": 0.52,
  "text": "#e8e2d8", "dim": "#8a8578",
  "accent": "#d7d7d2", "bar": "#d4a017", "accent2": "#ff5a4d",
  "light": false,
  "transition": { "type": "veil", "dur": 520 },
  "bg3d": { "archetype": "veil", "planes": 4, "panelTex": "...", "backdrop": "...", "op": 0.4 },
  "depth": { "shadow": 0.45, "rim": 0.2, "grain": 0.36, "vignette": 0.5 },
  "tag": "SUMI INK", "scene": "a single stroke", "line": "one brushstroke…"
}
```

`depth.vignette` now drives the atmosphere layer, so a theme can ask for more or
less air between the world and the type.

### 3D archetypes (`qml/Background3D.qml`)

`bubbles · veil · rain · orbit · drift · sunrings · prims · embers · grid · gyro ·
orb · silk · stained · streaks · vapor · gears · motes`

The rule of the file: **nothing may look placed**. Every object gets a halo, a
contact shadow of light or an atmospheric wash.

The `veil` family (aurora, ink, silk, vitrail) used flat `#Rectangle` planes with
hard edges. They now carry `opacityMap: feather.png` — a 512px feathered alpha
plate — so the cloth fades at every border instead of reading as a translucent
card laid over the screen. `opacity` is scaled by `bg.breath` so the whole room
inhales together.

Per-tab themes live in `appearance.json` (`tabs["<page>"].theme`); the app's own
theme is only rewritten when the change comes from the Themes room (`quiet=false`).

---

## 5. Flows worth knowing

### Playlist import (`/playlist/import/*`)

- `preview` → name, source, real cover URL, count, first tracks.
- `start` → writes `library/playlists/<slug>.json` immediately (unique name, never
  overwrites), caches the playlist cover to `cache/covers/import_<slug>.jpg`,
  then a worker thread ingests each track through `ytcvt::ingest_url`.
- `status` → `{running, done, total, failed:[{title,error}]}`. The QML panel lists
  every failure by name **and reason**.
- The worker always bumps `library.version` at the end, so the shelf redraws and
  the new collection appears without a restart.

### Watch (ad-free video)

`watchThis(url)` → `/backdrop/prepare` → yt-dlp → `cache/backdrops/bg_<hash>.mp4`
→ `MediaPlayer` + `VideoOutput`.

- yt-dlp is pinned to **H.264** (`bv*[height<=720][vcodec^=avc1]+ba[ext=m4a]`).
  This Qt's FFmpeg backend has no AV1 decoder: an AV1 pick plays audio over a
  black frame, which looked like a broken player.
- The film is masked into the panel's 26px corner via `MultiEffect.maskSource`
  (`watchStageMask`), so no square black card ever sits on the room.
- No browser, no player chrome, no ad segments: the file is the whole video.

### Local vs playlist

`applyFilter()` splits the library: rows with `origin === "playlist"` go to the
Playlist page, everything else to Local Vault. The two lists never mix.

---

## 6. Traps hit in this codebase

- **`x:` binding inside a `Row`/`Column`**: positioners own child positions. The
  top-bar page label was re-evaluated to `x = 0`, parking "LOCAL VAULT" on top of
  the logo. Fix: wrap the label in an `Item` and animate `x` inside that box.
- **Right-anchored clusters that grow**: a long theme name pushed the swatch past
  the window edge. Fix: fixed-width box + `elide`.
- **Hard clipping at the right edge** reads as a broken card. Use a 92px gradient
  of `th.bg` (0 → 0.92) pinned to the viewport, not a `clip: true` edge.
- **A 0-progress `ScrubBar` is a rule across the page.** Its track is now fully
  transparent until hovered.
- **`MultiEffect` masks are ~5% CPU** across a screenful of artwork. Fine, but do
  not add more per row.
- **`layer.enabled` on the 3D Loader costs more than it saves** (+8% CPU measured
  at 0.8 scale) — do not "optimise" the world that way.
- Files mix LF/CRLF; `str_replace` handles it, ad-hoc Python edits must read with
  `newline=''` and match `\r` explicitly.

---

## 7. Change log — this pass

- Top bar: page label no longer overlaps the logo/brand; theme chip fixed-width
  with elision (was clipped at the window edge).
- Theme rail: hairline marker replaced with a hover pill and a haloed two-tone
  swatch — the list reads as buttons, not as a table.
- Theme changes now **dissolve** (`dissolveWorld`) instead of popping.
- Wallpapers **fade through** on change instead of cutting (`MediaBackdrop.shownSource`).
- Artwork **fades in** (340 ms) wherever `RoundImage` is used.
- Atmosphere layer added (two linear grades, driven by `depth.vignette`): text has
  a readable ground on busy themes, world edges melt into the room.
- Playlist import: end-to-end verify (182-track YouTube list previewed; 1-track
  import downloaded, cover cached, `failed: []`), plus an empty state in the panel.
- Watch: H.264 pin, rounded mask, `VIDEO` button beside `IMMERSIVE` that opens the
  watcher pre-searched for the current song.
- Removed the last list dividers and the always-on seek rules.
- Rebuilt the world dissolve so a page change gets only the rise (no double
  transition).

### Audit pass (layout de-collision)

- Top bar: the centred identity row no longer carries the material name. With
  a long page title (`PLAYLIST`, `SETTINGS`) it used to run under the `CTRL K`
  pill on every page. The atmosphere is already named at the far right; the row
  now ends at the room name. Verified on Playlist, Local, Vibe, Queue, Themes,
  Home, Settings at 1280×760.
- Home doors: the hover affordance was the transport `next` glyph (skip-track),
  parked half outside the hover pill. New `chev` NavIcon, positioned inside the
  82 % pill (`rightMargin = 9 % of width + 9`).
- Home hero under a stopped deck: the lyric quote is gated on a real `track_id`,
  so "nothing playing" shows the room's line, not the previous song's words.
- Local vault: the scan skips build/asset folders and de-duplicates identical
  files, so the list no longer repeats one wallpaper mp3 a dozen times.

See `docs/AUDIT.md` for the endpoint-by-endpoint checks and the stress numbers.

### Smoothness pass (frame clock, reference study, watcher)

- **Reference**: `Screen Recordings/Recording 2026-10-24 182805.mp4` (56 s,
  1004x648) sampled every 1.5 s into `.scratch/ref_*.jpg`. What was taken from
  it: nothing is outlined - hairlines appear only as accents; chips and buttons
  are translucent fills that deepen under the cursor; section labels are
  uppercase and tracked; separation comes from fill contrast and space, never
  from a rule.
- **One clock for the room.** `frameProbe` (a `FrameAnimation`) now advances
  every continuous value once per *presented* frame: `cardPhase`, the camera
  kick, the level smoother, `bassLevel` / `eqPhase` / `brandPulse`. The three
  fixed-rate timers that used to drive them (80 / 30 / 16 ms) held a value for
  a frame and then jumped on a 120 Hz panel - that stepping was the jitter in
  the backgrounds. Coefficients were converted to per-millisecond exponentials
  (`1 - (1 - k)^(dt / 16)`) so attack, release and decay feel identical at any
  refresh rate. Timers remain only for network polling.
- **MSAA** on the world (`antialiasingMode: MSAA`, quality Medium). Spheres,
  rings and gears crawl along their silhouettes as they turn, which reads as
  shimmer even at a steady frame rate. Cost measured: silk 120 -> 102 fps,
  vitrail -> 107, every other room unchanged.
- **Quality governor**: `q` steps 1 -> 0.58 -> 0.3 only after the room fails to
  hold 40 fps for 2.2 s, and never steps back up - at most one scene change per
  session, no oscillation. It has not fired on this machine; it is the safety
  net for slower GPUs.
- **Lyrics**: the index gained hysteresis (it never steps back a line until the
  voice is 350 ms past that line's start - the clock is slewed toward the
  server every 200 ms and used to bounce exactly on a boundary, taking the
  column with it). The auto-scroll now aims after layout has settled
  (`Timer { interval: 0 }`) and re-aims while the active row resizes, so it
  lands on the words instead of the pre-resize geometry, and it yields
  completely while the reader is flicking.
- **Watch**: `source` is a `url`, and a url has no `.length` - `source.length >
  8` evaluated to `undefined > 8` = **false** in every handler, so the whole
  play-intent chain was dead and only the old unconditional `play()` ever
  started a film. Now `source.toString().length`, plus `wantPlay` /
  `userPaused`: a re-buffer may resume only a film that is meant to be playing,
  never one the viewer just paused (verified: pause holds 30 s+). `show()` no
  longer replays the entrance animation on an already-open sheet - that restart
  snapped the panel to 0 for a frame and tore the film down underneath it.
  Teardown runs only on a real close. The film's rounded corners come from a
  12 px inset inside the shell's rounding instead of a per-frame `MultiEffect`
  mask (the mask re-rendered the whole video through a shader while the panel
  was animating its opacity - the flash). `pollWatch` ignores any status whose
  `url` is not this film's, because the fetch slot is shared with the room's
  moving wallpaper.
- **Chrome**: `AChip` and `GlowButton` are borderless - fill, hover depth and
  the specular sweep carry them - and the lyric calibration nudges are fills.
  Two components, so every screen changed at once.
- `import QtQuick 2.15` -> `import QtQuick`: version 2.15 hides every type
  introduced in Qt 6, which is why `FrameAnimation` failed to resolve (see
  PERFORMANCE.md - that failure is silent in the log).

## Smoothness pass 3 - the four real causes (2026-10-25)

The previous pass fixed clocks and rates and still the room looked wrong in
motion. The recording (73 s, 1280x760 window on a 1920x1080 desktop) was
sampled at 30 fps and at full rate; these are the things it showed, in the
order they hurt.

**1. A page change rendered two entire pages, live, at once.** Every page was
`visible: pageIndex === currentPage || pageIndex === leavingPage`, and the exit
animation kept the old page lit for its whole 0.8 x duration. Two full pages
means two 3D-bearing layouts, two sets of cards, two lyric columns - and the
frame time collapsed while they cross-faded, so the 620 ms fade took *seconds*
of wall clock and the user watched both rooms at 50 % opacity. That is the
"transitions are no longer smooth at all". Pages now render only while they are
the current page. The room change is carried by the arriving page's own
entrance (fade + settle), the world rising underneath it and the dye wash - not
by a dissolve of two live layouts.

**2. The dye transition never ran at all.** `DyeWash.qml` passed its GLSL to
`fragmentShader` as an inline string. Qt 6 treats that property as a URL: it
tried to open the source text as a file, failed, and logged
`Failed to find shader "C:/.../qml/
 varying highp vec2 qt_TexCoord0..."`.
The wash - the whole "a drop of ink in water" idea - was simply not drawn; what
was left of a theme change was a 0.88 black curtain, which read as a cut to
black. The shader now lives in `qml/shaders/dye.frag` and is baked with Qt's
own tool (`qsb --glsl 100es,120,150 --hlsl 50 --msl 12`), and the curtain is
0.62 so the ink is what carries the change.

**3. Three equalisers were painting at 60 fps, always.** `CircEQ` is a Canvas,
and a Canvas rasterises on the GUI thread. It carried
`Timer { interval: 16; running: ce.visible && root.s.playing }` - and `visible`
is the item's own property, which stays true when the page around it is hidden.
So the stage's 660 px / 80-bar ring, the playlist hero's 196 px ring and the
immersive overlay's 360 px / 84-bar ring all repainted ~60 times a second for as
long as a song played, on every page. Each now has a `live` flag its page sets,
runs at 30 fps, and stops when the window is not visible.

**4. The lyrics had three separate problems.** The karaoke fill was a clipped
twin `Text` whose clip width changed every frame (a second text layout plus a
clipped repaint, 60 times a second); the active line changed font *size*, which
re-flowed the whole column and made the scroll aim at stale geometry (it then
re-aimed on every height change, restarting the glide mid-flight); and the fill
was computed from `posMs` while the line index was computed from
`posMs + lyric_offset_ms`, so the two disagreed whenever the offset was not 0.
Now: one clock (`clockTick`, driven by `frameProbe`), one offset, a colour ramp
instead of the clipped twin, one uniform type size per row (so the column never
re-flows), and a single aim per line that is skipped when the target has not
moved. The scroll is 560 ms OutCubic.

**Also fixed in this pass**

- The frosted "breath" over the world was a full-window `MultiEffect` blurring
  the live capture every frame. It is gone; the quarter-res capture itself is
  the frost (see PERFORMANCE.md).
- `Main.qml:7098` anchored a Rectangle inside a `Flickable` to the flickable
  (it is parented to the content item, so it silently sat at 0,0 as a 92 px
  band). It is gone - on a moving 3D room an opaque scrim reads as a dark box.
- `Connections { function onTcChanged() { requestPaint(); } }` called
  `requestPaint` without a scope (`ReferenceError: requestPaint is not
  defined`); it now goes through `parent`.
- A `Column` managed by a `ColumnLayout` carried `anchors.horizontalCenter`
  (undefined behaviour, logged on every load); it uses `Layout.alignment`.
- The world quality governor wrote `item.quality` on `Background3D`, which did
  not declare it: `Cannot assign to non-existent property "quality"`, so the
  whole governor was decorative. The property exists now and gates MSAA, the
  bubble count and the transmission pass.

## Watch sheet: the one-way door (2026-10-25)

The sheet has two states - the browser (search field, results, chips) and the
film (stage + transport) - and the browser was `visible: root.watch.path.length
<= 3`. Once a film was in the slot there was no way back to the browser at all:
reopening the sheet from the top bar or the deck's VIDEO button landed on the
same film, and the only exit was closing and reopening, which landed on it
again. The sheet read as "stuck on whichever video it loaded last".

What is there now:

- **`watchBrowse()`** clears the film slot, stops the poll, refocuses the field
  and restores the last text query (never the URL - searching the URL would
  immediately re-fetch the film that was just cleared, which is exactly how the
  first version of this fix looked like it did nothing).
- **`‹ BROWSE`** sits in the film transport next to CLOSE, so a loaded film is
  never a dead end.
- The deck's **VIDEO** button clears the slot before it searches, so it opens
  on the *current song's* results rather than the previous film.
- The results list stays visible while a new film is fetching (`pct` and the
  stage label show the download), instead of being replaced by a blank stage.

Verified by driving the running app: WATCH -> paste a link -> film plays ->
BROWSE returns to the browser -> search "bonobo kerala" -> results -> WATCH on
a different row fetched and played that video.

## Every source in the add sheet (2026-10-25)

The add sheet was a YouTube sheet with a "paste a link" afterthought, and
`addLink()` sent anything containing a slash that was not YouTube or Spotify
down the **local path** branch - which is where every `soundcloud.com` link
went, so pasting a SoundCloud track always failed with a local-file error.

- `searchYoutube()` now queries **YouTube and SoundCloud** through
  `/sources/search` and merges the rows as they answer (a sequence guard drops
  late answers from an older query). Each row shows its origin next to the
  duration.
- `addLink()` has an explicit SoundCloud branch that goes through the same
  yt-dlp ingest as YouTube.
- SoundCloud's licensed catalogue is **DRM protected** and yt-dlp refuses it
  outright. For those tracks `soundcloud_twin()` asks SoundCloud's oEmbed what
  the track is, asks YouTube for it, and downloads the first match, so the row
  still lands - logged as `[add] soundcloud refused (...) - taking the youtube
  twin: ...` instead of failing silently.

## Lyrics travel with the song (2026-10-25)

A freshly added row used to be lyric-less until the vibe page asked for it, and
a cold lrclib miss at that moment was cached for a week. `warm_lyrics()` (in
`src/ytcvt.rs`) runs right after the file lands, off-thread so the add queue
never waits on a network round trip, and writes the answer **twice**: the
shared `cache/lyrics/<song_key>.json` the `/lyrics` endpoint reads, and the
song's own `.lrc` beside the audio, which `Library::lyrics_for` prefers and
which survives a wiped cache. A lyric file that already exists is never
overwritten.

`ingest_url()` also stops storing the uploader prefix twice: YouTube's `track`
field carries "Billie Eilish, Khalid - lovely" for an uploader called
"Billie Eilish", which used to be saved as "Billie Eilish - Billie Eilish,
Khalid - lovely". Only a real dash/colon is stripped, so "Queen" + "Queen of
the Night" keeps its title. Cleaner titles also give the lyric ladder a much
better chance.

## 2026-10-25 — why the room changed abruptly, and the three traps behind it

**A dead id aborted `gotoPage()`.** The function restarted `kickDecay`, a Timer
that no longer exists. QML resolves that at run time, so every room change threw
`ReferenceError: kickDecay is not defined` **after** `leavingPage`, `pageExit`
and `hideTimer` had been set but **before** `pageTransition.restart()`. The
result: pages cut instead of moving, and the frame trail showed nothing wrong
because no animation was running. `pageTransition` now always runs; a
`/frame?d=NAV<i>` breadcrumb sits right after it so a future abort is visible in
`GET /frame` (the `diag` field) instead of silent. **Never hand-animate a value
that the frame clock already decays** — `kickTick()` is gone, and the camera
lean is `kickLean` (0 → 0.34 → 0 over 200/640 ms).

**A world change must never be a single-frame assignment.** `dissolveWorld()`
used to write `worldFade = 0` in one line; the present after it had no 3D room
in it at all, which reads as a flash. It now dips to **0.18** over 150–230 ms and
lifts back over 520–760 ms (`worldSwap`), and the old room's colour rises to
0.34 over 150 ms before it lifts (`curtainBeat`). The `worldFade` floor is
deliberate: the room's colour should always be under the page.

**The dye wash is retired.** It lifted the whole frame — title bar and dock
included — by ~35 luma for two frames on every room change, in the accent
colour: the "green jumpscare". Two things made it uncontrollable:
`%LOCALAPPDATA%/aethermix/cache/qtshadercache-*` and `qtpipelinecache-*` keep
serving the **old compiled program** after a `.frag` rebuild (delete both, then
restart, or your shader edits are invisible), and the shader's `strength`
uniform never reached the GPU here, so neither the QML strength nor the item
opacity could tame it. `DyeWash.qml` / `shaders/dye.frag` stay in the tree —
`dyeAt()` still fires — but the item is `visible: false`.

**A measured frame, not a remembered one.** `PrintWindow` grabs are reliable
for steady state (30.4 → 30.6 across eight frames) and were what caught the
flash; `gdigrab` on a GPU window is not (it repeats the first frame). Read
mean luma across title bar / page / dock: a layer that brightens *all three* is
above the bars, which narrows the suspect list to z ≥ 30 in one step.

## The no-seam rule

No panel in this app may end on a straight edge. Where a surface has to stop,
its **gradient keeps going past the edge** and thins to alpha 0 over ~50–100 px
of whatever is next to it — not a second strip laid on top, because a strip
that starts at a non-zero alpha just moves the seam.

* `topbar`'s shade rectangle: `anchors.bottomMargin: -52`. Without it there is
  a visible line at y = 58 on every page.
* `sidebar`'s ink is **not a linear fill at all**. A linear fill always ends
  somewhere, and that end is the line: the previous `anchors.fill: parent` +
  horizontal gradient stopped on x = 204 and started on y = 58, which drew a
  hard corner across the column's top and right. It is now a `Canvas` painting
  one radial gradient, stretched 1.3× vertically, laid out with
  `leftMargin: -70, topMargin: -80, rightMargin: -170, bottomMargin: -50` — so
  every point of the wash is 0 alpha well before it can meet an edge, and
  nothing in it lines up with the panel's geometry.
* Both are children of their panels, so they inherit the 420 ms fade when the
  theme world or the immersive stage takes the room.

Measured on the running window after the change: column at x = 60 across the
header boundary reads 18,18,19,19,18,17,19 (no step at y = 58); column at
x = 700 rises 36 → 46 across the same line; row at y = 300 across the rail
boundary reads 34,35,37,32,34,38 then the artwork — no edge at x = 204.

**The lesson from the first attempt:** a search-and-replace that "succeeded"
had landed on a *different* rectangle (`atmosphere`'s horizontal vignette,
which also starts with `anchors.fill: parent` + a horizontal gradient) and the
rail was untouched. Always anchor an edit on a line that is unique to the
element — the replacement reported success and changed nothing visible.

## The home hero is a record that comes out of its sleeve

`heroVinyl` sits behind `heroArt` at x = 42. Hovering the sleeve
(`heroHover`) slides it to x = 132 over 420 ms `OutQuint`, scale 1.035, plus a
2% pointer parallax. The clear half of the disc carries `vinylMa`
(`onClicked: np.open()`), so the sleeve keeps its own click and the drawn-out
record is the door into the immersive stage. No clip on `hero`: the disc must
be able to leave the box.

## Sound: two taps and a keyboard

The button voice is a *recording*, not a synth. Two files, both from the
material supplied for this app, normalised to mono 44.1 kHz and kept warm in
memory so a tap never waits on a decode:

* `assets/sounds/tap.wav` — a single mouse click, 0.37 s
* `assets/sounds/double.wav` — a fast double click, 0.46 s

`SoundEffect` for each is created once at the root (`sndTap`, `sndDouble`) and
`playPack()` only re-seeks and plays. Swapping the `source` on the fly costs a
load pause, so the first tap after a change went silent; that is why both are
alive from launch. The old synthesised voices (glass/drop/wood) are gone from
the picker; a store that still names one falls back to `tap` in `applyMotion()`.

The keyboard is the third file, `mixkit-typing-on-a-laptop-keyboard-2531.wav`,
cut at ten onset-detected 150 ms strikes (`type1…type10.wav`). A sentence picks
one at random, so it never sounds like one clip on repeat, and no 20 s file ever
has to be seeked while typing. `typeKey()` is wired to every `TextField` in the
file:

```qml
Keys.onPressed: function(ev) {
    if (!ev.isAutoRepeat && !(ev.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)))
        root.typeKey();
}
```

Auto-repeat is skipped (holding a key should not machine-gun) and so are
shortcut chords. In the palette field the handler is *merged* into the existing
one — a second `Keys.onPressed` on the same object is a hard QML error
("Property value set multiple times") that aborts the whole root component and
leaves the app running with no window at all.

`TYPING SOUND` is an `AToggle` of its own, stored as `motion.typing`: it
follows the pack (everything is silent at `OFF`) but can also be silenced alone.

## The collapsed window carries the room

`MiniBar.qml` is a separate 488×84 always-on-top window, shown while the main
window is minimized. Studio → WALLPAPER → **MINI BAR** chooses its floor,
stored as `mini.bg`:

* `theme` — a horizontal wash from the accent through `accent2` into the room's
  own bg, plus a vertical light so the card has a top and a bottom.
* `song` — the sleeve of what is playing, `PreserveAspectCrop` at scale 1.04,
  under a left-to-right scrim that is heaviest where the title and the
  transport sit.

Both live in one `Item` with `layer.enabled` + a `MultiEffect` mask whose
`maskSource` is a rounded `Rectangle`, so the artwork takes the card's corner
radius instead of being clipped by a square. `bgMix` cross-fades over 460 ms.
It is a plain `property real`, **not** `readonly`: a `Behavior` cannot animate a
read-only binding and the failure aborts the component, which shows up only as
"the mini bar never appears".

## Three bugs worth remembering

1. **A JS object in a `var` property does not notify on a member write.**
   `root.studio.page = p` changed the value but no binding re-evaluated, so the
   scope chip stayed on ALL TABS, the per-tab theme picker never appeared, and
   every Studio control looked "bugged" — the state was right and the screen
   was stale. Fix: assign the whole object (`root.studio = { page: p }`).
2. **A nested inline component cannot read the repeater's `index`.** The `EDIT
   / THEMES / OPEN` buttons on the per-tab cards passed `index` and got
   `undefined`. Copy it onto a real property of the delegate first
   (`readonly property int slot: index`) and pass that.
3. **`RESET LOOK` rebuilt `appearance` from scratch**, silently dropping
   `motion` (speed, pack, typing, volume) and `mini`. It now keeps both.
