# App Volume

A macOS menu-bar app that gives you a **per-app volume slider** for every
running app that's playing sound — the thing macOS itself doesn't provide.

Built with Core Audio **process taps** (macOS 14.4+). For each app you turn
away from 100%, it silences that app's normal output at the source, then
re-renders its audio to your speakers/headphones scaled to the volume you
picked. Apps left at 100% are never touched.

> Browsers show up as a single app (e.g. "Google Chrome"), so you control all
> their tabs together. True per-tab volume would need a browser extension —
> not included in this build.

## Build

Requires macOS 14.4+ and the Xcode Command Line Tools (no full Xcode needed).

```bash
./build-app.sh
```

This produces `AppVolume.app` in this folder, ad-hoc codesigned.

## Run

```bash
open ./AppVolume.app
```

A slider icon (􀟶) appears in your menu bar. Click it to see every app that's
currently playing audio, each with its own slider (0–150%).

### First launch — grant permission

The **first time** you actually turn an app's volume down, macOS asks for
audio-recording permission (process taps count as audio capture). Approve it:

- **System Settings → Privacy & Security → Microphone** (and/or
  **Screen & System Audio Recording**) → enable **AppVolume**.

If a slider shows a red error instead of changing the volume, it's almost
always this permission — grant it, then quit and reopen the app.

## How it works

```
App audio ──▶ [process tap, muted-when-tapped] ──▶ IO callback ×gain ──▶ [aggregate device] ──▶ your output device
```

- `AppVolumeController` — one process tap + one private aggregate device per
  controlled app; a realtime IO block multiplies samples by the current gain.
- `Mixer` — creates a controller when an app leaves 100%, tears it down when it
  returns to 100% (native passthrough), and refreshes the app list every 2s.
- `AudioProcessEnumerator` — lists processes currently outputting audio and
  resolves them to friendly names/icons.

## Notes & limits

- Volume above 100% boosts by scaling samples; extreme values can clip.
- Only apps *currently* producing output appear in the list.
- Helper processes without a GUI app may appear under their bundle-id name.
- Ad-hoc signing is per-machine; the permission grant is tied to this build.
  Rebuilding re-signs it, which can reset the permission — re-grant if needed.
