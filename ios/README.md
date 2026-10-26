# AetherMix Pocket — iPhone client

A native SwiftUI app that turns the phone into a second window onto the desktop
AetherMix: it streams the PC's files over the LAN, plays files imported into its
own Documents folder, keeps playing with the screen off, and wears the desktop's
themes (all twenty of them, plus any you make).

Full research, constraints and the Sideloadly walkthrough: [`../docs/IOS_PORT.md`](../docs/IOS_PORT.md).

---

## What it does

| Room | What is there |
|---|---|
| HOME | spinning vinyl that slides out of the sleeve, transport, quick doors, the room's first rows |
| LIBRARY | every desktop song searchable, **ON PHONE** for imported files; tap streams on the phone, long-press for "play on the desktop" |
| ROOMS | playlist shelf (desktop rooms with 4-up cover mosaics, phone rooms with their own covers); `+` creates either; remove songs and rooms |
| VIBE | full-screen room: blurred artwork backdrop, synced words with per-song offset, smooth scrubber, transport |
| STUDIO | **THE DESKTOP** address + LINK, full theme grid, bloom/tint/word-size, imports, about |

**Streaming.** A tap on a desktop row opens `/audio?id=N` and plays it on the
phone through AVPlayer — seeking works because the bridge serves HTTP byte
ranges. Nothing is downloaded permanently. Phone-owned files play through
AVAudioPlayer and work with no desktop at all.

**Words.** `/lyrics` returns the same LRC the desktop uses; the phone reads the
mode from the bridge (polled 1.3×/s) and interpolates the position on the frame
clock, so the highlighted line tracks the audio instead of stepping. The ±
buttons write `/lyricoffset` for that one song.

**Themes.** `/themes` + `/theme?name=…&preview=1` are decoded into the same
document the desktop writes; choosing one also sets it on the desktop.

**Lock screen.** `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` (play, pause,
toggle, next, previous, scrub) and `UIBackgroundModes: audio`.

---

## Build the IPA

The phone cannot compile Swift; one of these three routes produces the archive.

### A. On a Mac (fastest, ~2 minutes)

```bash
brew install xcodegen        # once
cd ios
./scripts/build_ipa.sh
# -> ios/dist/AetherMix-unsigned.ipa
```

The script generates the project, builds for `generic/platform=iOS` with
`CODE_SIGNING_ALLOWED=NO`, asserts the bundle is arm64 with background audio and
the local-network key, and zips `Payload/AetherMix.app`.

### B. On a GitHub macOS runner (no Mac needed)

```bash
cd ios
./scripts/setup_github_build.sh            # creates a private repo, runs the build
```

It stages **only** `ios/` and the workflow into a temporary repo — the music
library, caches and desktop sources are never uploaded — then downloads the
artifact to `ios/dist/`. Needs `gh auth login` once. You can also push the
project yourself and run **Actions → iOS IPA** manually.

A ready-to-upload copy of just this project (sources, plist, assets, scripts and
the workflow) is kept at `ios/dist/AetherMix-ios-source.zip` for drag-and-drop
into GitHub's web uploader or any cloud Mac. Rebuild it with `python ios/scripts/make_source_zip.py`; the script stages the workflow and dotfiles GitHub's uploader otherwise drops, and refuses to write a bundle that is missing a file the build reads.

### C. Any cloud Mac

Run `ios/scripts/build_ipa.sh` there; nothing else is required.

### Check the archive before Sideloadly

```bash
python ios/scripts/verify_ipa.py ios/dist/AetherMix-unsigned.ipa
```

It verifies the failures that actually stop an install: `Payload/<App>.app`
layout, an **arm64** Mach-O (not a simulator slice), the plist keys, background
audio, the local-network description, ATS, file sharing and the icon.

---

## Install with Sideloadly

1. Windows: install **standalone** iTunes + iCloud (not the Microsoft Store
   builds), connect the phone, trust the computer.
2. Phone: **Settings → Privacy & Security → Developer Mode → on**, then restart.
   The toggle only appears after the phone has been connected once.
3. Sideloadly: drag the `.ipa`, enter your Apple ID, Start.
4. Phone: **Settings → General → VPN & Device Management** → trust your Apple ID.
5. First launch: allow **Local Network** (the app talks to your PC on port 3690).

Free Apple ID: the app is valid **7 days**, up to **3 apps** at a time, and
Sideloadly can re-sign over USB (or Wi-Fi with its refresh helper) before it
expires. A paid account is only needed for 1-year profiles, not for any feature
this app uses.

---

## Point it at the desktop

1. Start AetherMix on the PC. Its log prints
   `[http] phone: http://192.168.x.x:3690` at boot.
2. Phone → **STUDIO → THE DESKTOP** → type that address (`192.168.1.240:3690` is
   pre-filled because it was this network's address) → **LINK**.
3. Both devices on the same Wi-Fi/Ethernet. If Windows Firewall asks, allow
   AetherMix on **private** networks.

The bridge listens on `0.0.0.0:3690` by default. Non-loopback callers may only
use the phone's routes (`/state`, `/library`, `/playlists`, `/lyrics`,
`/lyricoffset`, `/themes`, `/theme`, `/theme/current`, `/audio`, `/art`,
`/cover`, transport, playlist switch/append/remove/create, `/track/save`).
Everything that writes files, spawns yt-dlp, swaps accounts or shuts the app
down answers `that route is local only` to the LAN. Set `AETHER_LAN=0` to keep
the old loopback-only behaviour.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| OFFLINE pill, "No answer from the desktop" | wrong IP, different network, desktop not running, or Windows Firewall blocking port 3690 |
| Connects but playback is silent | phone on silent? Check the volume; audio session is `.playback` so the mute switch does not matter |
| App stops launching after a week | free-signing expiry — re-run Sideloadly |
| "Unable to install" in Sideloadly | the 3-app limit, Developer Mode off, or a mismatched bundle id; change Sideloadly's bundle id field |
| Local Network prompt never appeared | Settings → Privacy & Security → Local Network → enable AetherMix |
| Icons blank on the home screen | archive built without the asset catalog; run `verify_ipa.py` |

---

## Test the wire (no Mac needed)

`python ios/tools/contract_test.py` validates the live desktop bridge against
the Swift `Codable` models and streams a real byte range. `python
scripts/verify_ipa.py <ipa>` checks an archive is the kind Sideloadly can sign.

## Layout

```
ios/
  project.yml                  XcodeGen manifest (iOS 16, iPhone only)
  AetherMix/Info.plist         background audio, LAN, file sharing, ATS
  AetherMix/Resources/         Assets.xcassets (AppIcon 1024, AccentColor)
  AetherMix/Sources/
    AetherMixApp.swift         @main
    RootView.swift             AppModel (forwards nested publishers), top bar, mini player, dock, sheets
    Atmosphere.swift           gradient light fields, motes, vinyl, equalizer, glass dock
    HomeView.swift             vinyl room
    LibraryView.swift          search + DESKTOP / ON PHONE
    PlaylistsView.swift        room shelf, remote and local room detail
    NowPlayingView.swift       immersive room, self-timed lyrics panel
    SettingsView.swift         connection, theme grid, atmosphere, shelf
    Bridge.swift               HTTP client (4 s default timeout)
    PlayerEngine.swift         AVPlayer + AVAudioPlayer, session, lock screen, lyric clock
    Store.swift                Documents shelf + library store
    Theme.swift                theme document, palette, glass surface
    Models.swift               bridge payloads
  scripts/
    build_ipa.sh               Mac / CI build + package
    setup_github_build.sh      no-Mac route through a private GitHub repo
    verify_ipa.py              portable archive checker
```
