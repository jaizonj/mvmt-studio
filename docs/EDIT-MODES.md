# Edit Modes & Clip Speed

Authorised by Jaizon, 2026-11-12. Programme doc — the working plan.
This is the replacement for what Auto Edit was FOR (making a cut feel
edited) without being Auto Edit: everything here is an explicit,
user-applied action in Edit mode, with undo. Nothing auto-generates
a cut on open, and nothing re-runs by itself.

## 1. What exists today (audit, 2026-11-12)

- **EDL** (`src/lib/edl.ts`): segments are `{ id, takeId,
  sourceStartFrame, durationFrames }` — timeline duration equals
  source duration. There is NO speed/rate anywhere in the EDL, the
  store, or the native compositor (grep: no `speed`, `timeScale`,
  or playback-rate in `edl.ts`, `types.ts`, or the compositor).
  Every clip plays at 1x.
- **Chronological EDL** (commit 618cb49): takes laid end-to-end in
  recording order, clipped to the song region. Edit mode trims,
  swaps, duplicates, reorders segments through `commitEdl`.
- **Audio rule**: takes are muted under the master song in the cut
  (audio = master song only). So clip speed is a VIDEO-ONLY
  operation — no pitch shifting, no audio sync problem. The
  song keeps playing straight through at 1x while the video
  slows down, speeds up, or repeats under it.
- **Sync mapping**: `sourceFrameForTimelineFrame` maps a timeline
  frame to a take's source frame via the take's sync offset.
  Speed changes that mapping (see Stage 1).

## 2. Per-segment speed (the foundation)

`EdlSegment` gains `speed?: number` (0.25–2x, default 1).
- Timeline duration = `durationFrames / speed` — slow-mo stretches
  the segment on the timeline; fast compresses it. The segment's
  SOURCE range (`sourceStartFrame`, `durationFrames`) does not
  change; the mapping does: `source = sourceStart + (timeline −
  start) × speed`.
- The composition builder (`edlToCompositeRequest` → Swift) maps
  each segment's video time range with `scaleTimeRange` on the
  composition track, so preview and export share the one mapping.
  The audio track is untouched (master song, 1x).
- `validateAgainstAssets` still clamps source ranges; speed never
  changes what source frames exist.
- Lip-sync calibration (`syncAdjustFrames`, per-take, source
  frames) is applied in SOURCE space, before the speed mapping —
  so it survives speed changes untouched.
- Contract tests: segment duration math + the source↔timeline
  mapping at 0.5x/2x + a slow segment's export request round-trip.

## 3. Edit Modes (apply-on-demand, in Edit mode)

Each mode is a function `Edl → Edl` applied once when the user
taps it, fully undoable via the existing undo. A modes row sits
in Edit mode; tapping a mode previews the result immediately in
the native preview.

1. **Slow Motion** — set the selected segment (or all) to 0.5x
   (0.25x option). The stretched segment pushes later segments
   later on the timeline; the cut is re-clipped to the region.
2. **Fast Cuts** — split the timeline into short segments
   (0.5–1 s) alternating takes, rapid-fire.
3. **Fast–Slow–Fast** — rhythm pattern: quick cuts, then one long
   slow stretch (0.5x), then quick cuts again. The "little
   transitions" feel comes from the speed change itself.
4. **Repeat / Loop** — a short clip (e.g. 1 s of a take) repeats
   3–4 times in a row, same source range looped — the aesthetic
   repeat Jaizon asked for.
5. **Stutter** — a 0.3 s slice repeats 2–3 times, then the cut
   continues. Same mechanism as Repeat, shorter slice.
6. **Transitions** — between segments: quick fade-to-black dip
   (v1, opacity animation on the composition — cheap and safe);
   true cross-dissolve (v2, needs overlapping video tracks in the
   composition — feasibility check in Stage 3).
7. **Arrange modes** ("shuffle modes", Jaizon's words — but
   on-demand, never automatic): **Alternate** (cycle takes
   A-B-A-B across the timeline), **Randomize order** (shuffle the
   segment order once, keeping each segment's length),
   **Reverse** (play the segment order backwards). These replace
   the old auto-shuffle's job with explicit, one-tap actions.

## 4. Interface

- Segment editor: speed chips (0.25x / 0.5x / 1x / 1.5x / 2x) on
  the selected segment, plus a fine slider.
- Modes row in Edit mode: horizontally scrollable mode cards
  (name + one-line description), tap to apply, undo to revert.
- The timeline shows speed on each segment (a small "0.5x" badge
  and a stretched/wider block for slow segments).

## 5. Staging (one build per stage)
- **Stage 1 — Speed**: `EdlSegment.speed` + native `scaleTimeRange`
  mapping + preview/export parity + segment speed UI + tests.
- **Stage 2 — Rhythm modes**: Fast Cuts, Fast–Slow–Fast, Repeat /
  Loop, Stutter (all built on Stage 1's speed + the existing
  split/duplicate segment ops).
- **Stage 3 — Transitions**: dip/fade v1; cross-dissolve
  feasibility + implementation if the composition supports it.
- **Stage 4 — Arrange modes**: Alternate, Randomize order,
  Reverse (on-demand only).

## 6. Acceptance
- Any segment can play slow or fast, in preview and export,
  with the song still in sync (song is 1x, video speed is
  independent).
- Modes are one-tap, visible in the preview immediately, and
  undoable. No mode runs automatically.
- No regression to recording, sync, lyrics, looks, or export.
