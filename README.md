# MVMT Studio — React Native (Expo)

A music-video studio for iPhone: pick a track, choose the part you want,
record takes while that part plays (so every take is in sync), then build
your cut — shuffle it automatically, fine-tune it by hand, or both — and
export a finished video.

This is the **native** version of MVMT Studio (the web version is parked).
It exists because the web version hit a wall that could not be designed
around — see “Why native? (the pause-glyph problem)” below.

> **Status: the overhaul is shipped.** The complete rebuild — native Swift
> compositing engine, frame-based EDL timeline, rebuilt Editor — is done
> on the **`overhaul`** branch and delivered as an unsigned IPA (GitHub
> Actions run **42470406509**, green). It is awaiting Jaizon’s device
> pass before merging to `master`. The Expo Go phase is over: the app
> now contains custom native code, so it ships as a sideloadable build —
> see “Build & install” below.

---

## Why native? (the pause-glyph problem)

In the web version, adding music eventually worked, but a **pause glyph
kept appearing over the camera preview**. Root cause: the web app runs
inside a **webview**, where the “camera” is an HTML `<video>` element fed
by `getUserMedia`. When that element is paused or its stream stalls
(which webviews do aggressively), the browser draws its native
**paused-video glyph** over the preview. No CSS/autoplay fix removes a
browser-chrome UI element.

This app has no webview and no `<video>` element for the camera:

- The preview is **`expo-camera`'s `CameraView`** — a true native
  `AVCaptureSession` preview layer on iOS. There is no paused-video state
  and no browser glyph to show.
- iOS **camera-session interruptions are handled explicitly** on the
  Record screen: an `AppState` listener drives the `CameraView` `active`
  prop, and when the app becomes active again the screen calls
  `resumePreview()` so the preview restarts cleanly after an interruption
  (phone call, Siri, Control Centre) instead of sitting on a frozen
  frame. Camera mount errors surface as a visible notice.

---

## Architecture — one engine, one timeline

- **React Native owns**: UI, navigation, project management, editing
  controls, displaying playback state.
- **Swift owns the media**: the local Expo module in
  `modules/mvmt-compositor` (AVFoundation) builds **one composition** that
  feeds **both** the native preview player and the exporter — what you
  preview is what you export, by construction. It also normalises every
  clip to the project canvas, inspects assets, and reports measured
  export results with progress/cancel.
- **One canonical timeline**: the frame-based **EDL** in
  `src/lib/edl.ts` (30 fps, integer frames) is the only timeline. JS
  never swaps preview players per cut and never polls for sync; seconds
  exist only at the native boundary.
- **Audio policy**: the master song only, by default. Canvas is
  **1080×1920, aspect-fill centre-crop** — never stretched.
- **Sync is measured, not assumed.** Each take stores the song position
  at capture start/end and its natively measured duration (plus a drift
  estimate). Every edit goes through `commitEdl`, which re-derives each
  cut’s source start from its position on the timeline using those
  measured offsets — so trimming, splitting, reordering, duplicating or
  swapping a take **keeps every clip in sync with the song
  automatically**. There is deliberately no per-clip slip control:
  auto-sync always wins.
- **Projects persist on disk** (`src/lib/persistence.ts`) — a project
  survives an app restart.

Programme record for the overhaul: `docs/IMPLEMENTATION.md`. Design
system: `docs/DESIGN_SYSTEM.md`. Device-test matrix: `docs/TEST_MATRIX.md`.

---

## The flow

Tabs: **Studio / Projects / Settings**. Inside a project, the workspace
is a straight line:

```
Record → Editor → Export
```

Later steps stay locked until there is something to work on — Export is
unreachable before anything is recorded, and Record’s Next goes to the
Editor (or straight to Export once a cut exists).

- **Record** — full-screen camera (below). Takes live here now, not on a
  separate screen.
- **Editor** — one workspace, two modes on the same EDL:
  - **Auto** — Shuffle. Tap it and the takes rearrange into a cut:
    Chill / Normal / Fast / Rapid pacing, deterministic seeds, and
    **no visible score or reason chips, ever** — it should feel like
    magic. Tap any cut in the timeline and you land in Manual with
    **that exact edit** selected, ready to refine — nothing is lost
    switching modes.
  - **Manual** — a simplified professional editor: selectable cuts with
    thumbnail filmstrips, timeline zoom (15–90 px/s), ruler scrubbing,
    drag-to-trim handles plus fine steppers, split at playhead,
    duplicate, move earlier/later, delete, per-cut take switching, and
    undo/redo. Every change updates the canonical EDL and the native
    preview.
  - One honest limitation: the **first cut’s start handle is inert** —
    it starts at frame 0 with no previous cut to trade time with, and
    the sync anchor forbids slipping its content. Its end handle,
    steppers and split all work.
- **Export** — a near-fullscreen black stage: the finished cut fills the
  screen with just the back button, title and transport overlaid on the
  video, and compact options below. Rendering runs on the same
  composition as the preview, with progress and cancel.

### Creative tools live in the Editor — Settings is configuration only

A hard design rule: creative tools (everything that is part of making
the art) belong in the Editor, placed on the timeline. **Settings**
holds configuration and defaults only.

---

## What’s in the app

**Camera (Record)**
- Full-screen native camera: front/back flip, torch, mirror, collapsible
  zoom pill; bottom-centre video-length chips (**15s / 30s / 1 min /
  3 min / Full**).
- Recording is **hard-locked to the selected audio part** and plays that
  part from its start, so takes are born in sync. Track energy (RMS) is
  sampled while recording.
- **Timer + count-in** share one icon-only pill (timer: Off/3s/5s/10s
  with beeps; count-in: Off/4/8 beats with clicks) — **both default
  OFF**.
- **Front-facing flash**: the front camera has no torch LED, so with
  torch on it lights the **screen** instead — warm-white overlay at full
  brightness while recording, restored afterwards. The back camera uses
  the real torch.
- **Takes rail down the left side**: real thumbnail frames for every
  take, newest in reach. Tap one for a preview card — native preview,
  sync status in plain words (“In sync”, “Off sync — check before
  export”), rename, delete.
- The **Add-a-track pill** sits up top level with the flash and settings
  buttons, on the green accent; the **record button is teal blue**.
- Settings guides honoured on the preview: thirds grid, level line.

**Track & audio-part picker**
- Add audio via the system document picker (Files/iCloud — MP3/M4A/WAV…);
  the file is copied into the app sandbox.
- Duration preset chips **15s / 30s / 1 min / 3 min / Full** and an easy
  way to pick which part of the track to use. The selected region is the
  single source of truth: recording, Shuffle sectioning and previews all
  read it.

**Analysis** (`src/lib/analysis.ts`): phrase sections are 8 beats at an
**assumed 120 BPM (TODO: real beat tracking)**; section energy is the
**real RMS** sampled from the track; take energy is a **v1 heuristic**.
Better analysers slot in without touching the engine.

**Design**
- Deep graphite `#101114`, warm white `#F4F1E9`, acid-lime accent
  `#C9F36B` — Apple-style minimal hierarchy and spacing, native-feeling
  sheets, no gradients or glassmorphism clutter. Portrait, **iPhone
  only** (no Android, no desktop), safe-area aware throughout.

---

## Project structure

```
app.json / eas.json        App + EAS config
modules/
  mvmt-compositor/         Swift/AVFoundation engine (Expo module):
                           composition builder, native preview, export,
                           asset inspection — spec in its README.md
src/
  app/
    _layout.tsx            Root stack + StudioProvider + gesture/safe-area roots
    (tabs)/                Studio · Projects · Settings
    project/
      record.tsx           Record — camera + takes rail
      editor.tsx           Editor — Auto (shuffle) + Manual on the EDL
      export.tsx           Export — near-fullscreen stage + render
  components/
    NativePreview.tsx      The one native preview (preview == export)
    TimelineStrip.tsx      EDL timeline: filmstrips, zoom, scrub, trim handles
    RecordButton / IconButton / SegmentedControl / Sheet
    TrackSheet / AudioRegionPicker   Track + audio-part picker
    ui/                    Shared design primitives (buttons, cards, headers)
  lib/
    edl.ts                 Canonical frame-based timeline (30 fps)
    shuffle.ts / shuffleEdl.ts   Shuffle engine + its EDL bridge
    analysis.ts            Sections, RMS energy, take-energy heuristic
    compositor.ts          JS facade over the native engine
    media.ts               Document picker, file persistence, Photos, sharing
    persistence.ts         Project store on disk
    thumbnails.ts          Filmstrip frame sampling
  store/StudioContext.tsx  Projects, track, region, takes, EDL, camera prefs
  theme.ts                 Design tokens (graphite / warm white / lime)
  types.ts                 AudioTrack, AudioRegion, Take, settings types
tests/
  shuffle.test.cjs         Shuffle + analysis tests (npm run test:shuffle)
  edl.test.cjs             EDL tests (npm run test:edl)
.github/workflows/
  build-unsigned-ipa.yml   Manual-dispatch unsigned IPA build (below)
```

---

## Build & install (the current delivery route)

Jaizon has an **iPhone and a Windows PC — no Mac**, and no paid Apple
Developer Program account. So the app is delivered as an **unsigned
IPA**, sideloaded from the PC:

1. **GitHub Actions** — the `Build unsigned IPA (for Sideloadly)`
   workflow (manual dispatch, `.github/workflows/build-unsigned-ipa.yml`)
   builds on a cloud Mac (`macos-26` + Xcode 26.6 — required for Expo
   SDK 58). The job first **gates** on unit tests + `tsc` + lint + an
   `expo export` bundle smoke test, then archives and uploads
   `MVMTStudio-unsigned.ipa` as the `MVMTStudio-unsigned-ipa` artifact.
2. **Sideloadly** (Windows) signs the IPA with Jaizon’s free Apple ID at
   install time and puts it on the iPhone. Free signing expires after
   **7 days** — re-sideload to renew. **Muse never receives his Apple
   password or 2FA codes** — Sideloadly asks him directly.
3. The native engine is compiled in, so the sideloaded app runs its full
   media pipeline — preview and export included.

**Expo Go is parked**: custom native modules (the compositor) can’t run
in Expo Go. **TestFlight** remains a future option only if Jaizon enrols
in the Apple Developer Program (paid) — nothing submitted anywhere yet.

---

## Scripts

```bash
npm start                        # Expo dev server
npm run typecheck                # tsc --noEmit
npm run lint                     # expo lint (`npx eslint .` is the same check)
npm run doctor                   # expo-doctor
npm run test:shuffle             # shuffle + analysis Node tests
npm run test:edl                 # EDL Node tests
npx expo export --platform ios   # bundle smoke-test (JS only, not a native build)
```

## Verification performed

Done here (Linux VM + macOS CI — no physical iPhone available to Muse):

- `npx tsc --noEmit` — **clean**. `npx expo lint` — **clean, zero
  problems**.
- `npm run test:shuffle` + `npm run test:edl` — **22/22 pass**
  (11 each).
- `npx expo export --platform ios` — **bundles successfully**.
- **CI run 42470406509 — green**: full gate, then the unsigned IPA built
  on the cloud Mac with all Swift compiled in; `main.jsbundle` verified
  inside the delivered IPA (16.6 MB).

**Not verified here — Jaizon’s device pass is the gate** (see
`docs/TEST_MATRIX.md`): scrolling the entire Editor top-to-bottom on the
phone is check #1, then selecting every cut, take changes staying in
sync, drag-trim + steppers, split at playhead, duplicate, reorder,
delete, undo/redo, Auto→Manual refining without losing the edit,
preview updating after every edit, export matching the final EDL, the
takes rail + preview card, and the near-fullscreen Export over real
video. The `overhaul` → `master` merge waits on that pass.

## Known follow-ups

1. **Merge `overhaul` → `master`** once Jaizon’s device pass is green.
2. **Lock-a-cut** — pinning a cut so Shuffle keeps it: not implemented
   (the engine has no pinning yet; it won’t be faked in the UI).
3. **Real beat/downbeat detection** to replace the assumed-120 BPM grid,
   and **real waveform peaks** for the audio-part picker.
4. Reduced-motion sweep suppression; app icon / splash artwork before
   any store build.
