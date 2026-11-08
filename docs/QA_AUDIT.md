# MVMT Studio — Independent QA Audit (Wave 1)

**Auditor:** Agent QA (independent — challenge, don't confirm).
**Date:** 2026-11-08. **Branch:** `overhaul`.
**Inputs:** full repo inspection; `docs/IMPLEMENTATION.md` (overhaul
contracts); `mvmt-media-architecture-audit.md` (architecture audit,
goal files).
**Method:** source reads + importer/consumer greps for every claim of
"unused" or "dead" (evidence stated per finding), plus the headless
checks in §1, actually run.

> **Snapshot caveat:** the working tree was LIVE during this audit —
> other Wave 1 agents were writing concurrently (`src/lib/shuffleEdl.ts`,
> `tests/edl.test.cjs`, `docs/DESIGN_SYSTEM.md` and a `test:edl` script
> appeared mid-audit; Agent Swift's work had not landed). Findings are
> accurate for the tree as inspected; §8 is written as a migration
> checklist precisely because several items are scheduled Wave 2 work.
> Nothing in this audit was "fixed" — QA modified no code.

---

## 1. Headless verification — ACTUAL results (run 2026-11-08)

| Check | Command | Result |
| --- | --- | --- |
| Typecheck | `npx tsc --noEmit` | ✅ PASS (exit 0, no errors) |
| Lint | `npx expo lint` | ✅ PASS (exit 0, no findings) |
| Shuffle unit tests | `npm run test:shuffle` | ✅ PASS — 11 tests, 11 pass, 0 fail |
| EDL bridge unit tests | `npm run test:edl` | ✅ PASS — 11 tests, 11 pass, 0 fail |
| iOS JS bundle | `npx expo export --platform ios` | ✅ PASS (exit 0, exported to `dist`) |
| Swift compile | CI (`build-unsigned-ipa.yml`) | ⚠️ NOT RUN by QA — requires push/dispatch. Last known green: run 42464377582 (pre-overhaul `master`). The overhauled tree has never been through CI. |
| `expo-doctor` | `npm run doctor` | Not run by QA; listed in TEST_MATRIX (A5). |

**What these results do NOT prove:** tsc passing does not mean the
TS↔Swift contract matches (§2.1 — the mismatch is invisible to tsc
because the native module is reached through a hand-written TS
interface). Test scope is narrow: `test:shuffle` compiles ONLY
`src/lib/shuffle.ts` + `src/lib/analysis.ts` with `--ignoreConfig`
(bypassing the project tsconfig); `test:edl` compiles only the EDL
bridge chain. No test touches the store, any screen, the compositor
request builder in `export.tsx`, or `TimelinePreview`.

**CI never runs the tests.** `.github/workflows/build-unsigned-ipa.yml`
steps are: checkout → Node → `npm ci` → `expo prebuild` → Xcode select
→ archive → package. There is no `test:*`, `tsc`, or `lint` step, so a
red test suite cannot fail a build. (Finding F-10.)

---

## 2. Critical contract findings

### 2.1 The native v2 API is declared in TypeScript and DOES NOT EXIST in Swift

`modules/mvmt-compositor/src/index.ts` (Phase 1 contract) declares:
`renderVideo` (with `canvasWidth`, `canvasHeight`, `frameRate`,
`exportId`), `cancelExport`, `inspectAsset`, `createPreview`,
`setPreviewPaused`, `seekPreview`, `releasePreview`, and three event
streams (`onExportProgress`, `onPreviewProgress`, `onPreviewStatus`).

`modules/mvmt-compositor/ios/MvmtCompositorModule.swift` (290 lines)
registers **exactly one** function: `AsyncFunction("renderVideo")`.
There is no `inspectAsset`, no preview, no cancellation, no events, no
`MvmtPreviewView`. `CompositeRequestRecord` has only
`clips/audioUri/audioStartSeconds/audioVolume` — the v2 fields
`canvasWidth/canvasHeight/frameRate/exportId` have no Swift counterpart.

Worse, the one function that does exist **violates its own TS contract**:

- TS doc on `CompositeResult.durationSeconds`: *"MEASURED duration of
  the written file — read back from the rendered asset, never the
  requested duration."* Swift returns
  `CMTimeGetSeconds(totalDuration)` where `totalDuration` is the
  **cursor sum of requested clip durations** (engine, end of `render`).
  The written file is never re-opened or measured.
- `width`/`height` are likewise the *canvas* (first clip's display
  size), not measured output dimensions.

**Blast radius today: zero — by accident.** No production code calls
any v2-only function: `src/lib/edl.ts`'s only consumer chain is
`src/lib/shuffleEdl.ts`, whose only importer is `tests/edl.test.cjs`;
`src/app/export.tsx` calls only `renderVideo` + `isCompositorAvailable`.
The moment Wave 2 wires the editor or export to the documented v2 API
against this Swift build, those calls fail at runtime. **This is the
#1 blocker for Wave 2 integration** until Agent Swift's v2 lands and
is CI-compiled.

### 2.2 The EDL exists, is tested — and is connected to nothing

- `src/lib/edl.ts`: zero importers in `src/` outside the bridge.
- `src/lib/shuffleEdl.ts`: only importer is its test file.
- Every screen still runs on the seconds-based `TimelineClip[]` in
  `StudioContext`. There are therefore **two timeline models in the
  repo**: the canonical frame EDL (contract, unused) and the live
  seconds model (used everywhere). Until Wave 2 cuts over, any
  "EDL" claim about the shipped app is false.

### 2.3 The bridge expects sync data the recorder never writes

`shuffleEdl.ts` computes the sync mapping from
`take.trackOffsetSeconds − regionStart + (take.syncOffsetSeconds ?? 0)`.
`syncOffsetSeconds` **does not exist on the `Take` type**
(`src/types.ts`) and nothing writes it. `trackOffsetSeconds` itself is
written exactly once (`src/app/index.tsx:353`, = the region start —
i.e. where the take was *supposed* to start) and read by **no
production code**: v1 shuffle, preview and export all silently assume
every take starts exactly at the region start. The measured-sync
contract (§Sync in IMPLEMENTATION.md) is unimplemented in the record
path: at `index.tsx:279-280` the song is seeked and played, and
`recordAsync` is only invoked at line 322 — the gap between "song
started" and "camera's first frame" is neither measured nor stored,
and no drift estimate exists anywhere.

---

## 3. Dead code & unused files/components

Evidence standard: "no importers/callers" = grep across `src/`,
`modules/`, `tests/` for the symbol, excluding its definition site.

### 3.1 Orphaned Edit-stage API in the store (all of it)

`src/store/StudioContext.tsx` exports the following with **zero
callers anywhere in `src/app` or `src/components`** (the Edit stage
that used them was deleted 2026-11-08; the API was never cleaned up):

`addToTimeline`, `removeFromTimeline`, `moveTimelineClip`,
`swapTimelineClips`, `clearTimeline`, `updateClipTrim`, `updateClip`,
`duplicateTimelineClip`, `splitTimelineClip`, `coverClipId` +
`setCoverClipId`, and `undoTimeline` + `canUndoTimeline`.

Consequences beyond dead weight:

- **There is no working undo in the shipped app**, even though
  `applyTimeline` dutifully pushes a snapshot onto `undoStack` on
  every shuffle (capped at 10). State is maintained for a feature no
  UI can reach — and any future reader will assume undo works.
- `coverClipId` is pure fiction: nothing sets it, nothing reads it.

### 3.2 Dead styles in `src/app/shuffle.tsx`

The StyleSheet still defines the deleted Edit UI's styles with zero
JSX references: `card`, `row`, `rowSeparator`, `rowSelected`, `rowMain`,
`rowBadge`, `rowBadgeText`, `rowTitle`, `rowSubtitle`, `trimBar`,
`trimLabel`, `trimButton`, `trimButtonText`, `undoButton`, `undoText`,
`disclosureRow`, `disclosureText`, `keepNoteStrong` (verified:
`grep -c "styles.<name>"` = 0 in JSX for each).

### 3.3 Zombie route

`src/app/_layout.tsx` still registers a `Stack.Screen name="editor"`
and `src/app/editor.tsx` is a `<Redirect href="/shuffle" />`. Harmless,
but it is a permanent route whose only job is redirecting — and it
lands on Shuffle even with zero takes (Shuffle's locked state handles
it, acceptably). Remove the screen registration with the route in
Wave 3 cleanup, or keep deliberately — but decide.

### 3.4 NOT dead (checked, do not delete)

- `src/components/Sheet.tsx` and `AudioRegionPicker.tsx` look unused
  if you only grep `components/<name>` paths — they are imported
  relatively (`./Sheet`, `./AudioRegionPicker`) by `SettingsSheet.tsx`
  and `TrackSheet.tsx`. Both live.
- `src/lib/media.ts` helpers (`pickAudioTrack`,
  `probeVideoDurationSeconds`, `persistTake`, `saveToPhotoLibrary`,
  `shareFile`) all have real callers.
- `src/lib/thumbnails.ts` is used by `TimelineStrip`.

---

## 4. Dormant / half-implemented features

### 4.1 `TimelineClip` creative fields — the full truth table

Fields from `src/types.ts`. "Settable" = a store function exists
(`updateClip`); note `updateClip` itself has **no callers**, so in the
shipped UI *none* of these can be set at all.

| Field | Honoured in preview (`TimelinePreview`) | Honoured in export (`export.tsx` → Swift) | Verdict |
| --- | --- | --- | --- |
| `speed` | No | No (no Swift field) | **Dormant** |
| `fadeInSeconds` / `fadeOutSeconds` | No | No | **Dormant** |
| `look` | No | No | **Dormant** |
| `textOverlay` / `textPosition` | No | No | **Dormant** |
| `transitionType` / `transitionDurationSeconds` | No | No | **Dormant** |
| `volume` | Yes (player volume) | Yes (passed through; Swift audio-mix) | Live but **unreachable** (no UI sets it) |
| `muted` | Yes | Yes | Live but **unreachable** (no UI sets it) |

Per the directive these are to be *deferred*, and the overhaul EDL
correctly omits them. The risk is the type itself: `TimelineClip`
advertises eight creative properties that silently do nothing. Any
Wave 2 code that carries `TimelineClip` forward instead of cutting
over to the EDL inherits the lie.

### 4.2 Audio policy violation in the CURRENT export path

Because `muted` is unreachable and defaults unset, `export.tsx` builds
clips with `muted: clip.muted ?? false` — i.e. **every take's recorded
audio is inserted by the Swift engine alongside the master song**
(engine inserts clip audio for any `!muted && volume > 0` clip).
Preview has the same doubling (`TimelinePreview` plays take audio
through the video player while the song plays through a separate
audio player). The overhaul audio policy ("master song only by
default") is not a future nicety — the current build actively violates
it on every export. The EDL conversion gets this right
(`muted: !options.includeTakeAudio`) but, per §2.2, is not wired in.

### 4.3 `frameRate` camera preference — stored, displayed, never applied

`frameRate` (30/60) is a Settings value with no consumer beyond the
Settings sheet itself. Nothing passes it to `CameraView` (the camera
gets `videoQuality={resolution}` only). The store comment claims "the
camera picks the closest the device supports" — no code does any
picking. Placebo setting.

### 4.4 `exportQuality` — a setting that cannot affect the export

`exportQuality` (`high|balanced|small`) is editable in Settings
(wired through `SettingsSheetConnected` on Takes/Shuffle and directly
on the camera screen) and read by **nothing** in the render path:
`export.tsx` never reads it, the `renderVideo` request built there has
no quality field, and the Swift engine hardcodes
`AVAssetExportPresetHighestQuality`. Three quality choices, one
identical output.

### 4.5 `autosave` — a toggle for a system that doesn't exist

See §5. The store's own comment concedes it: *"persistence itself is a
README TODO; the default is honoured when it lands."* It has not
landed. The toggle changes a boolean and nothing else.

---

## 5. State & persistence findings

**Nothing is persisted. At all.** `StudioContext` is 100% `useState`.
There is no AsyncStorage, no state file, no project index anywhere in
the repo (grep: no persistence imports in `src/`).

Concretely, on app restart (or crash, or iOS killing the sideloaded
app):

- Track selection, region, takes list, timeline, shuffle state, and
  **every setting** reset to defaults.
- The take *video files* survive in the app sandbox
  (`persistTake` copies them out of the camera cache) but with no
  index pointing at them, they are **orphaned bytes** the app can
  never show again. Same for the copied track file.
- The compositor's rendered MP4s go to `cachesDirectory` — iOS may
  purge them at any time; the Export screen's `rendered` state is
  also in-memory only.

The directive's new IA (Studio / Projects / Continue Project / Recent
Projects) is **impossible on this foundation**. A persistence layer
(project index + EDL serialisation) is a hard prerequisite for
Wave 2's navigation work, and it is currently nobody's landed code —
flagged as a Wave 2 blocker in §9.

---

## 6. Broken / dead controls & navigation risks

| Control | Location | Finding |
| --- | --- | --- |
| Settings → Frame rate 30/60 | SettingsSheet (all screens) | Dead — §4.3 |
| Settings → Export quality | SettingsSheet (all screens) | Dead — §4.4 |
| Settings → Autosave | SettingsSheet | Dead — §4.5 |
| Delete take (trash icon) | `takes.tsx:128` | **One tap, no confirmation**, and it silently strips the take from the cut (`removeTake` filters the timeline). Destructive + surprising. |
| Take rows | `takes.tsx` | No preview/playback of an individual take, no thumbnail (icon only), no rename, no sync status — vs directive §3.6's take-review requirements. Gaps, not bugs — listed so they aren't assumed done. |
| `/editor` route | `_layout.tsx`, `editor.tsx` | Redirect zombie — §3.3 |
| Export screen preview | `export.tsx` | `previewKey` omits the clip `uri` (Shuffle's key includes it; the two screens' duplicated mapping has already diverged). Switching a cut's take and going to Export can leave the preview player holding the previous take's source until play is pressed and `startClip` replaces it. Minor, real. |
| Settings sheet "Export" action | camera screen | Delegates to a caller-supplied `onExportAction`; behaviour differs per screen (guarded by timeline length on Takes/Shuffle). Inconsistent affordance for the same menu item. |

Navigation structure today is still the pre-overhaul 4-screen stack
(Record → Takes → Shuffle → Export) with sheets. The directive's
Studio/Projects/Settings tabs and project workspace **do not exist
yet** (Wave 2, lead). Not a Wave 1 failure — a checklist item (§8).

---

## 7. Duplicate / competing implementations

1. **Two timeline models** — seconds-based `TimelineClip[]` (live)
   vs frame-based `Edl` (contract, unused). §2.2.
2. **Two timeline→preview mappings** — `shuffle.tsx` and `export.tsx`
   each hand-build `PreviewClip[]` from the timeline with duplicated
   logic and already-divergent `previewKey`s (§6). A third mapping
   (timeline→render request) lives in `export.tsx`'s `handleRender`,
   and a fourth (EDL→request) in `edl.ts` — unused. Four places that
   must agree about what the cut is.
3. **Two (three) duration sources for a take** — wall-clock at stop
   time → replaced by `probeVideoDurationSeconds` (a 2.5s-timeout
   best-effort probe in `media.ts`) → and, per contract, eventually
   `inspectAsset`. Shuffle windowing, preview ends and export ranges
   all consume `Take.durationSeconds` today, i.e. the probe's answer,
   with no validation that trims fit inside it (the Swift engine does
   not clamp either — an out-of-range `insertTimeRange` throws and
   the whole render fails; `validateEdl` exists to prevent exactly
   this and is not in the path).
4. **Two sync offsets, neither measured** — `audioOffsetMs` (manual,
   user-set; applied to preview + export seeks) and
   `Take.trackOffsetSeconds` (written, never read). A third
   (`syncOffsetSeconds`) exists only in the bridge's imagination (§2.3).
5. **Two playback systems** — `TimelinePreview` (expo-video +
   expo-audio, JS-driven) is the only preview; the native preview in
   the v2 spec would be the second. Until the JS one is deleted there
   will be pressure to "just fix" it instead of cutting over.
6. **Competing palettes** — `theme.ts` carries the new tokens, but the
   pre-overhaul iridescent palette is still hardcoded in
   `TimelineStrip.tsx` (4 refs: segment colours),
   `src/app/index.tsx` (2 refs: level guide), `src/app/shuffle.tsx`
   (1 ref: shimmer gradient). `app.json` splash `backgroundColor`
   is `#0B0B10`, not the theme base `#101114`. The redesign is
   token-deep only where files have been touched.

---

## 8. Migration checklist — current code vs the new contracts

For Wave 2/3 acceptance. Status as inspected:

- [ ] **EDL is the one timeline** — screens/store still on
  `TimelineClip` seconds. `edl.ts` + `shuffleEdl.ts` built and tested
  but unconnected (§2.2).
- [ ] **Native v2 implemented in Swift** — TS spec only; Swift is v1
  (§2.1).
- [ ] **Export result is measured** — Swift returns requested values
  (§2.1).
- [ ] **Canvas normalisation (1080×1920, aspect-fill)** — Swift uses
  first-clip canvas + raw `preferredTransform` per segment; no
  scaling/centring, so mixed-size/orientation takes are mis-framed.
  Frame duration is hardcoded 1/30 regardless of request.
- [ ] **Preview is composition-based** — `TimelinePreview` still
  polls every 200 ms (`setInterval` at `TimelinePreview.tsx:140`),
  detects trim ends in JS, `replaceAsync`-swaps sources per clip,
  and runs the song on a separate `expo-audio` player that free-runs
  during swaps. This is precisely the architecture the directive
  orders replaced.
- [ ] **Sync is measured** — not started in the record path (§2.3).
- [ ] **Audio policy: master only by default** — violated today by
  both preview and export (§4.2).
- [ ] **Range validation before render** — `validateEdl` exists;
  export path doesn't use it (§7.3).
- [ ] **Persistence / projects** — absent (§5).
- [ ] **New navigation (Studio/Projects/Settings + workspace)** —
  absent; still the 4-screen stack (§6).
- [ ] **Design system applied app-wide** — tokens updated in
  `theme.ts`; hardcoded old palette remains (§7.6); full screen
  redesigns are Wave 2.
- [ ] **CI runs tests + typecheck + lint** — it runs none (§1).
- [ ] **Dead store API + dead styles removed** — §3.1, §3.2.
- [x] **Shuffle honours frequency** — fixed pre-overhaul; regression
  tests pass (§1).
- [x] **EDL + bridge unit-tested** — 11/11 (§1).

---

## 9. Severity-ranked findings (summary)

| # | Severity | Finding |
| --- | --- | --- |
| F-1 | **Blocker (Wave 2)** | Native v2 API doesn't exist in Swift; the one existing function returns requested, not measured, results (§2.1) |
| F-2 | **Blocker (Wave 2)** | Zero persistence — projects/continue/recent are impossible; all work lost on restart; take files orphaned (§5) |
| F-3 | High | Current export + preview double the audio (master + unmuted take audio) on every render (§4.2) |
| F-4 | High | Preview is still the JS-polled two-player design the overhaul exists to replace (§8) |
| F-5 | High | Sync remains assumed; bridge expects a `syncOffsetSeconds` field nothing writes (§2.3) |
| F-6 | High | Export ranges unvalidated + unclamped in Swift; one bad trim fails the whole render (§7.3) |
| F-7 | Medium | Three placebo Settings controls: frameRate, exportQuality, autosave (§4.3–4.5) |
| F-8 | Medium | 11+ orphaned store functions incl. a fake undo; `coverClipId` fiction (§3.1) |
| F-9 | Medium | Eight dormant `TimelineClip` creative fields advertise features that do nothing (§4.1) |
| F-10 | Medium | CI runs no tests/typecheck/lint; overhauled tree has never been CI-built (§1) |
| F-11 | Low | Dependency excess (§10) |
| F-12 | Low | Dead styles, stale comments ("Best of N · score" doc on `ShuffleResultInfo` although score display was removed; "auto-plays" claims in shuffle.tsx comments — the preview does not autoplay), palette leftovers (§3.2, §7.6) |

## 10. Dependencies — package.json vs actual imports

Zero references in `src/` + `modules/` (import or require) unless noted:

| Dependency | Refs | Assessment |
| --- | --- | --- |
| `@react-native-community/slider` | 0 | **Unused.** No Slider component anywhere. Remove. |
| `react-native-reanimated` | 0 | **Unused by app code.** Present only via the babel chain (`react-native-worklets/plugin` in babel.config.js). If gesture-handler needs the worklets plugin, keep worklets — but Reanimated itself is imported nowhere. Justify or remove. |
| `expo-font` | 0 | Unused — no custom fonts loaded; UI is system font. Remove. |
| `expo-asset` | 0 | Unused directly. Remove (transitives handle themselves). |
| `expo-constants` | 0 | Unused. Remove. |
| `expo-linking` | 0 direct | Only a transitive need of expo-router. Remove from direct deps. |
| `react-dom` | 0 | Pinned solely to keep `npm ci` lockfile-valid (SDK 58 template residue). The `web` npm script also survives although `app.json` is `platforms: ["ios"]` and there is no web target. Remove both or document why they stay. |
| `@expo/ngrok` | 0 | Dev-tunnel convenience only (Expo Go testing, now parked). Dev-tool, not an app dependency. |
| `expo-dev-client` | 0 imports | **Justified** — build-time package for dev builds; not imported by design. Keep. |
| `expo-splash-screen` | 0 imports | Config-plugin only; nothing calls `preventAutoHideAsync`/`hideAsync`. Splash dismissal is left to defaults — **unverified behaviour** (device check D-14 in the test matrix). |
| `babel-preset-expo` | config string | Used (babel.config.js preset). Keep. |

Every unused *native* dependency still compiles into the sideload
binary and lengthens CI. Individually small; collectively this is how
the build got fragile historically (the lockfile/react-dom incident).

---

*End of audit. Companion document: `docs/TEST_MATRIX.md`.*
