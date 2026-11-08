# MVMT Studio — React Native (Expo)

A music-video studio for iPhone: pick a track, choose the part you want,
record takes while that part plays (so every take is in sync), then build
your cut two ways — arrange it yourself in **Edit**, or let **Shuffle**
remix it for you — and export.

This is the **native** version of MVMT Studio (the web version is parked).
It exists because the web version hit a wall that could not be designed
around — see “Why native? (the pause-glyph problem)” below.

> **Status: the final Expo Go build.** The full flow works in code:
> Record → Takes → **Edit *or* Shuffle** → Export. Video **export
> (compositing) is a labelled TODO** on the Export screen, and a few
> analyses are v1 heuristics, each marked as such where it lives.
> Nothing here fakes a result.

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
- iOS **camera-session interruptions are handled explicitly** in
  `src/app/index.tsx`: an `AppState` listener drives the `CameraView`
  `active` prop, and when the app becomes active again the screen calls
  `resumePreview()` so the preview restarts cleanly after an interruption
  (phone call, Siri, Control Centre) instead of sitting on a frozen
  frame. Camera mount errors surface as a visible notice.

---

## The flow

TikTok-style guided flow with a branch in the middle:

```
        ┌── Edit (build it yourself) ──┐
Record → Takes                          → Export
        └── Shuffle (remix it for you) ┘
```

- **Record** — the camera (below). Also where you pick the track/part.
- **Takes** — review everything you shot; keep, save, share or delete.
  Deleting takes/cut re-locks later steps.
- **The branch** — with at least one take, **both** Edit and Shuffle
  unlock. They are alternatives, never a sequence: Export is reachable
  **directly from Edit** (a hand-built cut never has to visit Shuffle)
  and **directly from Shuffle** (a shuffled cut never has to visit
  Edit). Both operate on **the same shared cut**.
- **Export** — the final step, locked until the cut has at least one
  clip, and unreachable before anything is recorded (“Record a take
  first”). Going back always works and preserves takes + cut.
- A step indicator on every screen shows `Record → Takes → Edit /
  Shuffle → Export`, with the branch drawn as alternatives.
- **Settings** (gear icon, every screen) is **not** a flow step — see
  below.

### Creative tools live in Edit — Settings is configuration only

This distinction is a hard design rule:

- **Edit** (the timeline editor) holds everything that is part of
  making the art, placed contextually on the timeline:
  - Tap a clip for its tools: **trim, split, duplicate, delete, speed
    (0.5×/1×/2×), volume + mute, fade in/out, look (None/Warm/Cool/
    Mono/Vivid), text overlay (+ position), set as cover frame**.
  - **Transitions live on the join between two clips** — the pill
    between clip rows cycles Cut → Crossfade → Dip to black, with a
    duration stepper.
  - Tap a second clip to **swap**; chevrons reorder; undo for changes.
  - Speed/look/text/transitions/cover are stored on the cut and will be
    applied by the export renderer (TODO #1); trims and order affect
    the preview today.
- **Settings** holds only defaults and configuration, in the same iOS
  grouped tile style (never a long scroll): timer default, resolution,
  frame-rate preference, mirror, grid, level guide, audio offset
  (±500 ms, applied to recording *and* preview sync), count-in beats,
  metronome beat-flash, autosave preference, export-quality default,
  device info, and which track/part is loaded. No creative tool lives
  here, and nothing is removed — it just lives in the right place.

### Shuffle — magic, no score

Tap **Shuffle my cut** and the takes rearrange themselves: a brief
iridescent shimmer, then the new cut **auto-plays** in the preview.
Copy is minimal on purpose (“Your cut, remixed ✦”) — **no score, no
“best of N”, no analysis chips, ever**. Under the hood (never shown),
`src/lib/shuffle.ts` — pure TypeScript, unit-tested, unchanged —
generates 32 candidate edits and internally scores each whole edit
(energy match, cut alignment, variety, anti-repeat penalties) to pick
the winner. The thinking stays invisible; the result feels instant.

Analysis (`src/lib/analysis.ts`): phrase sections are 8 beats at an
**assumed 120 BPM (TODO: real beat tracking)**; section energy is the
**real RMS** sampled from the track during recording/playback; take
energy is a **v1 heuristic** (file bytes/sec normalised across takes).
Better analysers slot in without touching the engine.

---

## What’s in the app

**Camera (opens here, full-screen, Snapchat-style)**
- Native front/back camera, flip, torch, pinch + preset zoom, mirror.
- Countdown timer (Off / 3s / 5s / 10s) plus a separate musical
  **count-in** (Off / 4 / 8 beats) before the take starts.
- Big record button (thin iridescent ring — iridescent is an accent only).
- Recording plays the **selected track region from its start** (plus the
  Settings audio offset) and stops at the region end, so takes are
  synced at capture. Track energy (RMS) is sampled while recording.
- Settings guides honoured on the preview: thirds grid, level line.
- Minimal on-camera controls: track pill, gear, Takes / Next (both
  locked with a “Record a take first” notice until the first take).

**Track & audio-part picker**
- Add audio via the system document picker (Files/iCloud — MP3/M4A/WAV…);
  the file is copied into the app sandbox.
- Duration preset chips **15s / 30s / 1 min / 3 min / Full**, a waveform
  (stand-in bars for now — see TODO) with a **draggable highlighted
  window**, live start–end labels, and a preview that stops at the
  window end.
- The selected region (`AudioRegion` in the store) is the **single
  source of truth**: recording, Shuffle sectioning and previews all
  read it.

**Takes**
- Saved to the app’s Documents folder; list with duration and camera;
  add to cut, save to Photos, share, delete — then choose your path:
  **Edit my cut** or **Shuffle it**.

**Design**
- Native iOS / HIG: system font, large titles, grouped lists, bottom
  sheets with grab handles, segmented controls, switches, outline
  icons, translucent blur materials over the camera, restrained
  near-black palette with one violet accent and iridescent reserved
  for thin rings/hairlines (and the shuffle shimmer). Portrait, phone
  only, safe-area aware throughout.

---

## Project structure

```
app.json / eas.json        App + EAS config (placeholders — see below)
src/
  app/                     Expo Router routes (files = screens)
    _layout.tsx            Stack + StudioProvider + gesture/safe-area roots
    index.tsx              Record — camera screen (the app opens here)
    takes.tsx              Takes review → the Edit/Shuffle branch choice
    edit.tsx               Edit — timeline editor (all creative tools)
    shuffle.tsx            Shuffle — magic remix + its own Export action
    export.tsx             Export — final step (rendering is a TODO)
    editor.tsx             Legacy redirect to /edit
  components/
    FlowSteps.tsx          Step indicator (branch-aware) + shared gating
    SettingsSheet.tsx      Configuration-only grouped settings sheet
    SettingsSheetConnected.tsx  Same sheet, wired to the store
    Sheet / SegmentedControl / IconButton / RecordButton
    TrackSheet / AudioRegionPicker   Track + audio-part picker
    TimelinePreview        Sequential cut preview (auto-plays)
  lib/
    analysis.ts            Sections, RMS energy accumulator, take-energy heuristic
    media.ts               Document picker, file persistence, Photos, sharing
    shuffle.ts             Shuffle engine (candidate generation + internal scoring)
  store/StudioContext.tsx  Track, region, takes, timeline + undo, camera prefs,
                           settings, cover clip, last-shuffle (internal) state
  theme.ts                 iOS-style tokens (type scale, materials, spacing)
  types.ts                 AudioTrack, AudioRegion, Take, TimelineClip (with
                           creative fields), settings types
tests/shuffle.test.cjs     Node tests for shuffle + analysis (npm run test:shuffle)
```

State is **in-memory** (React context). Recorded/picked *files* persist
in the app’s Documents folder, but the project (track/takes/timeline)
does **not** yet survive an app restart — see TODO.

---

## Test it — Expo Go (Jaizon’s route, phone-only)

**Jaizon only has his iPhone — no Mac, no PC.** So this section is
split by who does what:

### What Jaizon does (iPhone only)

1. Install **Expo Go** from the App Store (free).
2. Wait for Muse to send the Expo Go link / QR code.
3. Tap the link (or point the iPhone Camera at the QR) **while Muse’s
   dev server is running** — MVMT Studio opens inside Expo Go,
   **straight into the full-screen camera**.
4. Allow camera/microphone/photos permissions when iOS asks (they’ll
   say “Expo Go” — that’s normal, see limitations).
5. Test away. If Muse updates the code while the server is running,
   the app on your phone reloads with the changes — nothing to reinstall.

### What Muse does (on Muse’s computer — not Jaizon’s job)

```bash
cd mvmt-studio
npm install --legacy-peer-deps   # upstream react patch papercut; expo-doctor is 20/20
npx expo start --tunnel
```

`--tunnel` is the reliable choice for a phone on a different network:
it prints a QR code and an `exp://…` link that work from anywhere while
the server runs. (Plain `npx expo start` on the same Wi-Fi also works.)
The npm peer-deps note: Expo Router’s web deps pull `react-dom@19.3.1`
while SDK 58 pins `react@19.3.0` — an upstream papercut, not a broken
tree.

### Expo Go compatibility — verified, with the gaps stated plainly

- ✅ **The whole app runs in Expo Go.** Every dependency is an Expo SDK
  58 bundled library that ships inside Expo Go (`expo-camera`,
  `expo-audio`, `expo-video`, `expo-document-picker`,
  `expo-media-library`, `expo-file-system`, `expo-sharing`,
  `expo-blur`, `expo-linear-gradient`, gesture-handler, reanimated,
  `@react-native-community/slider`, …). There are **no custom native
  modules, no `ios/`/`android/` folders, and nothing that requires a
  development build at runtime.** Config plugins in `app.json` only
  matter for standalone builds — Expo Go ignores them safely.
- ⚠️ **It runs *inside* the Expo Go app**: no MVMT Studio home-screen
  icon/name (it lives in Expo Go’s recents), and permission prompts say
  “Expo Go”. Cosmetic, but real.
- ⚠️ **The server must be running** (Muse’s computer, tunnel up) for
  the app to load. Close the server and the link stops working until
  it’s started again. There is no offline/installed copy in Expo Go.
- ⚠️ **Export rendering is still the labelled TODO** — that’s an app
  TODO, not an Expo Go limit; when it’s built it will likely use a
  native video library, and *that* future piece may need a development
  build. Everything that exists today works in Expo Go.
- ❌ **Not available to Jaizon:** the “free Mac + Xcode Personal Team”
  route (it needs a Mac — Jaizon doesn’t have one), and the iOS
  Simulator (also Mac-only, and it has no camera anyway). An
  **installable standalone build** (EAS) needs either that Mac route or
  Apple’s paid Developer Program for device registration/signing — so
  for now the free phone-only options are exactly two: **this Expo Go
  route**, and the parked web version.

---

## TestFlight — future, optional (only if Jaizon enrols)

Nothing below has been done. No Apple account exists, no build has been
submitted anywhere, and this is **not** needed for Expo Go testing.

1. **Enrol** in the Apple Developer Program (paid, yearly) via the
   Apple Developer app on iPhone; activation can take up to ~48 hours.
2. **Fix placeholders**: `app.json` bundle ID `com.mvmtstudio.app` must
   be registered under his team and globally unique; `eas.json`
   `submit.production.ios` contains `REPLACE_WITH_…` values (Apple ID,
   Team ID, App Store Connect app ID); `app.json`
   `extra.eas.projectId` likewise.
3. **Create the app record** in App Store Connect.
4. **Build/submit** (Muse, on a computer): `eas build --platform ios
   --profile production`, then `eas submit --platform ios`.
5. **TestFlight**: add testers under Internal Testing; testers install
   Apple’s free TestFlight app. Builds expire after 90 days.

---

## Scripts

```bash
npm start                        # Expo dev server (use --tunnel for Jaizon's phone)
npm run typecheck                # tsc --noEmit
npm run lint                     # expo lint (`npx eslint .` is the same check)
npm run doctor                   # expo-doctor
npm run test:shuffle             # shuffle + analysis Node tests
npx expo export --platform ios   # bundle smoke-test (JS only, not a native build)
```

## Verification performed

Done here (Linux VM, no Mac or iPhone available):
- `npm run test:shuffle` — **9/9 pass** (shuffle validity,
  no-repeat-vs-previous, energy matching, minimum shot length,
  adjacency, section building, RMS accumulator, take-energy heuristic).
- `npx tsc --noEmit` — **clean, no errors**.
- `npx eslint .` — **clean, no errors or warnings** (two documented,
  scoped rule disables in the source: the imperative expo-video player
  API and gesture callbacks closing over refs).
- `npx expo-doctor` — **20/20 checks passed**.
- `npx expo export --platform ios` — **bundles successfully** (~4.5 MB
  Hermes bytecode). This proves the JS/TS and Metro/Babel pipeline —
  **not** that the camera behaves on hardware.
- **Expo Go module audit** — dependency list checked against what ships
  in Expo Go for SDK 58 (above); no custom native code anywhere.

Not verified (needs Jaizon’s iPhone via Expo Go): camera recording and
torch/zoom on device, audio sampling while recording, document picking
from iCloud, Photos saving, interruption behaviour on a real call.
That first Expo Go session is the real device test.

## TODO for a full product

1. **Export / compositing** — render timeline + track (applying trims,
   speed, looks, text, transitions, cover) into one MP4. Realistic
   routes: a small custom Expo native module over
   `AVAssetExportSession`/`AVMutableComposition` (iOS-first), or a
   maintained video-processing library evaluated at the time.
   (`ffmpeg-kit` was retired upstream — don’t build on it.) Note this
   will likely need a **development build**, leaving Expo Go behind for
   that feature. Until then the Export screen stays labelled TODO with
   per-take Save/Share.
2. **Persistence** — rehydrate track/takes/timeline/region from a saved
   manifest (AsyncStorage + the Documents files that already persist)
   so a project survives restarts; makes the Settings autosave default
   real.
3. **Real beat/downbeat detection** to replace the assumed-120 BPM
   grid, and **real waveform peaks** to replace the stand-in bars.
4. **Per-section take motion analysis** to replace the bytes/sec energy
   heuristic.
5. **A single composition preview player** (gapless cuts, transitions
   and looks visible in preview) instead of the sequential player.
6. **App icon / splash artwork** — `assets/` still holds Expo template
   placeholders; design real MVMT artwork before any store build.
7. Android polish (iOS-first; nothing Android-blocked by design, but
   untested there).

