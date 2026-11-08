# MVMT Studio — Overhaul Implementation Programme

Lead: Muse (chief architect / integration). Branch: `overhaul`.
Source inputs: Jaizon's overhaul directive (2026-11-08) and
`mvmt-media-architecture-audit.md` (goal files). This document is the
shared programme record required by the directive (§7): contracts,
ownership, status, and each agent's report summary.

## Target architecture (one coherent media engine)

- **React Native owns**: UI, navigation, project management, editing
  controls, displaying playback state.
- **Swift owns**: composition building, preview playback, export,
  asset inspection. (Recording stays on expo-camera for now — see
  Sync below — with measured offsets; a custom AVCaptureSession module
  is a later, evidence-gated decision.)
- **One canonical timeline**: the frame-based EDL in `src/lib/edl.ts`.
  Integer frames are the editing source of truth; seconds exist only
  at the native boundary, where the engine builds CMTime.
- **One composition builder** in the Swift engine feeds BOTH the
  native preview player and the exporter (`edlToCompositeRequest` is
  the only way EDLs cross into native requests). JS never detects cut
  boundaries, never swaps players, never polls for sync.
- **Audio policy**: master song only by default; take audio is an
  explicit opt-in (`includeTakeAudio`), muted by default in the EDL
  conversion.
- **Framing policy**: project canvas 1080×1920 @ 30fps by default;
  aspect-fill centre-crop normalisation in the native builder; never
  stretch; rotation honoured via preferredTransform.
- **Sync**: measured, not assumed. Each take stores the song position
  when capture actually started/ended (from the audio player) plus its
  natively measured duration; the drift estimate (song elapsed vs take
  duration) is stored on the take. `edl.sourceFrameForTimelineFrame`
  is the single mapping that consumes the offset.

## Contracts (Phase 1 — DONE, lead)

1. `src/lib/edl.ts` — EDL types, layout, validation against measured
   assets, EDL→CompositeRequest conversion, sync mapping helper.
2. `modules/mvmt-compositor/src/index.ts` — native v2 TS API:
   renderVideo (progress events + cancel + measured result),
   inspectAsset, createPreview/setPreviewPaused/seekPreview/
   releasePreview + preview events. Spec for the Swift side:
   `modules/mvmt-compositor/README.md` §v2.
3. `src/theme.ts` — design tokens: graphite #101114, warm white
   #F4F1E9, acid lime #C9F36B (single accent), stable token names.

## File ownership (no two agents edit the same files)

| Area | Owner | Files |
| --- | --- | --- |
| Swift engine v2 | Agent Swift | `modules/mvmt-compositor/ios/**` |
| EDL/shuffle bridge + tests | Agent EDL | `src/lib/shuffleEdl.ts` (new), `tests/**`, small adapter in `src/lib/shuffle.ts` if needed |
| Design system spec | Agent Design | `docs/DESIGN_SYSTEM.md` only |
| QA audit + test matrix | Agent QA | `docs/QA_AUDIT.md`, `docs/TEST_MATRIX.md` only |
| Projects store + navigation spine | Lead | `src/store/**`, `src/app/_layout.tsx`, route moves |
| Record screen + sync | Agent Record | `src/app/index.tsx` (camera), `src/lib/media.ts` |
| Takes screen | Agent Takes | `src/app/takes.tsx` |
| Editor workspace | Agent Editor | `src/app/shuffle.tsx` → editor, `src/components/TimelineStrip.tsx`, `src/components/TimelinePreview.tsx` (removal/replacement) |
| Export screen | Agent Export | `src/app/export.tsx` |
| Integration, cleanup, build | Lead | everything else |

## Programme status

**SHIPPED (2026-11-08).** The overhaul and the follow-up editor rebuild
are complete on branch `overhaul`: CI run **42470406509** green,
unsigned IPA (16.6 MB) delivered to Jaizon for Sideloadly. The branch
awaits Jaizon's device pass (`docs/TEST_MATRIX.md`) before merging to
`master` — that pass is the last open gate.

- [x] Phase 1: audit reviewed; contracts written (EDL, native v2, theme).
- [x] Wave 1: Swift engine v2 · EDL/shuffle bridge + tests · design spec · QA audit.
- [x] Wave 2: projects store + navigation (lead) · record/sync · takes · editor · export.
- [x] Wave 3: integration, dead-code removal, full verification, CI build.
- [x] Final: delivery report + device-test matrix for Jaizon.
- [x] Post-overhaul round: takes rail on Record + camera polish, Editor
  rebuild (scrolling, drag-trim, duplicate/reorder, sync anchor),
  near-fullscreen Export — shipped in CI run 42470406509.
- [ ] Jaizon's device pass → merge `overhaul` into `master`.

## Verification reality (read before claiming anything)

- Available here: `tsc`, ESLint, Node unit tests, `expo export`,
  and the macOS CI build (compiles ALL Swift + bundles the app).
- NOT available here: a physical iPhone, Instruments, simulator runs.
  Anything about on-device behaviour is a DEVICE TEST for Jaizon,
  listed in `docs/TEST_MATRIX.md` — never report it as verified.
- Swift compiles for the first time in CI: expect one fix-up round.

## Agent reports

(Each wave's reports are appended here by the lead after review.)

### Wave 1 (complete, lead summary)
- Agent Swift: engine v2 implemented (shared composition builder, canvas
  normalisation, measured export results, inspectAsset, preview registry +
  view, progress/cancel). CI needed three fixes: type-checker timeout on a
  chained transform (broke into steps), one CGAffineTransform label
  (translationX:y:), and the CI gate's own clean-checkout test bug
  (deterministic --rootDir). Gate steps (tests/tsc/lint) pass on the runner.
- Agent EDL: shuffleEdl bridge + 11 tests; all 22 unit tests pass.
- Agent Design: docs/DESIGN_SYSTEM.md (IA, per-screen specs, 26-item cull).
- Agent QA: docs/QA_AUDIT.md + docs/TEST_MATRIX.md; top findings (no
  persistence, doubled audio in the old build, placebo settings, CI without
  gates) all acted on in Wave 2.

### Wave 2 (complete, lead summary)
- Lead: projects store + disk persistence (src/lib/persistence.ts), tab IA +
  project workspace routes, NativePreview component, CI quality gate, store
  exportedAt stamp + stable take sequence numbers.
- Agent Record: measured sync on every new take (player-position samples at
  record start/stop, native-measured durations, drift, 2s sanity guard).
- Agent Takes: filmstrip rows, sync status in words, rename + confirmed
  delete, native single-take preview, shared ui/ components.
- Agent Export: EDL-driven render with progress/cancel, measured results,
  preview == export by construction (one shared request memo).
- Agent UI: tab screens redesigned + src/components/ui/ primitives
  (PrimaryButton, SectionHeader, ProjectCard, EmptyState, GroupCard).
- Agent Editor: rebuilding the workspace on EDL + NativePreview (running).

### Wave 3 (complete, lead summary)
- Integration done; cleanup inventory below fully actioned (JS
  TimelinePreview, both SettingsSheets, and the legacy seconds-based
  store timeline + TimelineClip type deleted; Record's gear navigates to
  the Settings tab; Record navigation gates on the EDL).
- Headless gate green: tsc clean, lint clean (0 warnings), 22/22 unit
  tests, expo export OK. CI archive green (run 42466978730); unsigned
  IPA delivered and device-tested by Jaizon — shuffle approved, Editor
  rejected (no vertical scrolling; preview oversized), which opened the
  post-overhaul round below.

### Post-overhaul round (shipped 2026-11-08, CI run 42470406509)
- Takes rail (commit 955d5a4): the separate Takes screen is
  decommissioned — takes live as a left-side rail on Record with real
  thumbnail frames and a preview card (native preview, sync in words,
  rename/delete). Record's Next goes Record → Editor (or Export when an
  EDL exists); bottom-bar lock icons removed (plain arrows always).
- Camera polish (commit 9e416f5): front-facing flash = screen flash
  (expo-brightness warm-white overlay + full brightness while recording
  on the front camera with torch on); timers pill icon-only; top bar
  raised level with flash/settings; Add-a-track pill on the green
  accent; record button centre teal blue (#0CA6B5).
- Editor rebuild + near-fullscreen Export (commit 4e98684): fixed
  header + one vertical ScrollView (scroll bug fixed structurally);
  compact preview (clamp 248–312pt); timeline in both modes with zoom
  15–90 px/s, ruler scrubbing, drag-to-trim handles, Duplicate + Move
  earlier/later. Binding SYNC ANCHOR inside commitEdl: every mutation
  re-derives each segment's sourceStartFrame from its timeline position
  via the measured take offsets, so clips stay in sync; a duplicate
  anchors at its new position (not a replay). First cut's start handle
  is inert by design (nothing to ripple against; the anchor forbids
  slipping). Auto→Manual refine keeps the identical EDL. Export ready
  state is a near-fullscreen black stage with overlay back/title/
  transport; render logic untouched (verified by diff scan).
- Verification at ship time: tsc clean, lint clean, 22/22 tests, expo
  export OK, CI green, main.jsbundle verified inside the IPA.
  Device-only checks (Jaizon): whole-Editor scrolling first, then
  sync-after-edit behaviour and Export legibility — TEST_MATRIX.md.

### Wave 3 cleanup inventory (lead, from live greps — all actioned)
- TimelinePreview.tsx: zero importers remain — delete the component.
- SettingsSheet/SettingsSheetConnected: only record.tsx remains (gear →
  Settings tab navigation replaces it) — then delete both.
- Legacy seconds-based store timeline: only record.tsx nav-gating still
  reads it (switch to EDL presence), then remove the legacy timeline state
  + ops from the store and any orphaned TimelineClip helpers.
