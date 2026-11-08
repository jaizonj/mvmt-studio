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

- [x] Phase 1: audit reviewed; contracts written (EDL, native v2, theme).
- [ ] Wave 1: Swift engine v2 · EDL/shuffle bridge + tests · design spec · QA audit.
- [ ] Wave 2: projects store + navigation (lead) · record/sync · takes · editor · export.
- [ ] Wave 3: integration, dead-code removal, full verification, CI build.
- [ ] Final: delivery report + device-test matrix for Jaizon.

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

### Wave 2 (in progress, lead summary)
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

### Wave 3 cleanup inventory (lead, from live greps)
- TimelinePreview.tsx: zero importers remain — delete the component.
- SettingsSheet/SettingsSheetConnected: only record.tsx remains (gear →
  Settings tab navigation replaces it) — then delete both.
- Legacy seconds-based store timeline: only record.tsx nav-gating still
  reads it (switch to EDL presence), then remove the legacy timeline state
  + ops from the store and any orphaned TimelineClip helpers.
