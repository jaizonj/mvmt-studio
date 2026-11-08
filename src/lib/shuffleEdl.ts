import type { MusicalSection, ShuffleFrequency } from '../types';
import { SHUFFLE_FREQUENCY_LENGTHS } from '../types';
import { buildSections, subdivideSections } from './analysis';
import {
  DEFAULT_FPS,
  emptyEdl,
  layoutSegments,
  secondsToFrames,
  sourceFrameForTimelineFrame,
  validateEdl,
  type AssetMeasure,
  type Edl,
  type EdlValidation,
} from './edl';
import { generateShuffle, seededRandom } from './shuffle';

/**
 * Shuffle → EDL bridge (Overhaul Wave 1).
 *
 * The shuffle engine (src/lib/shuffle.ts) works in SECONDS and musical
 * sections; the rest of the overhauled app works on the canonical EDL
 * (src/lib/edl.ts) in INTEGER FRAMES. This module is the only place the
 * two meet:
 *
 *   sections ──subdivide──▶ generateShuffle ──slots──▶ frame conversion ──▶ Edl
 *
 * The engine path mirrors src/app/shuffle.tsx's handleShuffle exactly
 * (same subdivision, same minShotSeconds = frequency length, same 32
 * candidates, same previousSequence novelty input) so the screen and any
 * future caller produce identical edits from identical inputs. When a
 * `seed` is supplied the whole pipeline is deterministic: same inputs ⇒
 * byte-for-byte identical EDL (segment ids are positional, no clocks,
 * no Math.random).
 *
 * This module produces an UNVALIDATED edit — run it through
 * `validateAgainstAssets` (or validateEdl with native measures) before
 * handing it to a player or the exporter, per the EDL contract.
 */

/**
 * The take shape this bridge needs. Structurally compatible with the
 * app's `Take` (src/types.ts) plus the analysis energy the screen
 * currently computes separately — the store integration wave adapts.
 */
export interface ShuffleEdlTake {
  id: string;
  /** Overall energy 0..1 for the shuffle engine. Defaults to 0.5. */
  energy?: number;
  /** Optional per-section energy; overrides `energy` where present. */
  energyBySection?: number[];
  /**
   * Absolute track time (seconds) at which this take's recording window
   * began — `Take.trackOffsetSeconds`. The base of the sync mapping.
   */
  trackOffsetSeconds: number;
  /**
   * Optional MEASURED sync correction in seconds (positive = capture
   * actually started late). `Take` does not carry this field yet; it is
   * read defensively so measured-sync work can land without changing
   * this bridge's signature.
   */
  syncOffsetSeconds?: number;
  /**
   * Recorded length in seconds. Only used to size the fallback section
   * grid when the caller supplies no sections.
   */
  durationSeconds?: number;
}

export interface BuildEdlFromShuffleInput {
  /** Base (phrase-length) sections over the region, in absolute track time. May be empty — see fallback below. */
  sections: MusicalSection[];
  takes: ShuffleEdlTake[];
  frequency: ShuffleFrequency;
  /** Deterministic seed. When provided, the same inputs reproduce the same EDL byte-for-byte. */
  seed?: number;
  /** Take-id sequence of the previous edit, so successive shuffles differ. */
  previousSequence?: string[];
  /** Absolute track time (seconds) where the used region starts. Slot times are made relative to this. */
  regionStartSeconds: number;
  /** Master track URI for the EDL's audio (null = silent project). */
  audioUri: string | null;
  /** Project output canvas. Defaults to the EDL default (1080×1920). */
  canvas?: { width: number; height: number };
}

export interface ShuffleEdlInfo {
  /** Engine score of the winning candidate (internal — the UI never shows it). */
  score: number;
  candidatesEvaluated: number;
  isRepeatOfPrevious: boolean;
  /** Winning take-id sequence, in slot order — feed back as `previousSequence` next time. */
  takeSequence: string[];
}

export interface BuildEdlFromShuffleResult {
  edl: Edl;
  /** Null when no shuffle could be generated (no sections, or fewer than 2 takes). The EDL is then empty. */
  shuffleInfo: ShuffleEdlInfo | null;
}

export function buildEdlFromShuffle(input: BuildEdlFromShuffleInput): BuildEdlFromShuffleResult {
  const { sections, takes, frequency, seed, previousSequence, regionStartSeconds, audioUri, canvas } = input;
  const fps = DEFAULT_FPS;
  const targetLength = SHUFFLE_FREQUENCY_LENGTHS[frequency];

  // Engine path — mirrors the Shuffle screen: sampled sections are
  // phrase-length, so subdivide them to the frequency's cut length
  // (energies inherited); with no sampled sections, build the grid at
  // the target length directly, sized by the longest take (takes were
  // recorded over this region, so their length bounds it).
  const engineSections =
    sections.length > 0
      ? subdivideSections(sections, targetLength)
      : buildSections(
          Math.max(0, ...takes.map((t) => t.durationSeconds ?? 0)),
          120,
          regionStartSeconds,
          targetLength,
        );

  const result = generateShuffle(
    engineSections,
    takes.map((t) => ({ id: t.id, energy: t.energy ?? 0.5, energyBySection: t.energyBySection })),
    {
      candidates: 32,
      // The chosen frequency IS the minimum shot length (the screen's
      // 2026-11-08 fix — the engine default silently swallowed it).
      minShotSeconds: targetLength,
      previousSequence,
      ...(seed !== undefined ? { random: seededRandom(seed) } : {}),
    },
  );

  const base: Edl = {
    ...emptyEdl(fps),
    ...(canvas ? { canvas: { width: canvas.width, height: canvas.height } } : {}),
    audio: { uri: audioUri, regionStartFrame: secondsToFrames(regionStartSeconds, fps), volume: 1 },
  };

  if (!result) return { edl: base, shuffleInfo: null };

  const takeById = new Map(takes.map((t) => [t.id, t]));

  // Slot → segment conversion. Slots are contiguous in absolute track
  // time; converting both endpoints through secondsToFrames (monotonic)
  // keeps them contiguous in frames, so layoutSegments' cumulative
  // timeline starts equal each slot's own start frame exactly.
  const partials = result.slots.map((slot, i) => {
    const take = takeById.get(slot.takeId);
    const startFrame = secondsToFrames(Math.max(0, slot.startSeconds - regionStartSeconds), fps);
    const endFrame = secondsToFrames(Math.max(0, slot.endSeconds - regionStartSeconds), fps);
    // SYNC OFFSET DEFINITION — the value handed to
    // sourceFrameForTimelineFrame for this take:
    //
    //   takeSyncOffsetSeconds
    //     = take.trackOffsetSeconds − regionStartSeconds
    //       + (take.syncOffsetSeconds ?? 0)
    //
    // i.e. where the take's recording window sat relative to the region
    // start, corrected by the take's MEASURED capture error (positive =
    // capture started late, so the footage for a given timeline frame
    // lives earlier inside the file). This is the single definition;
    // preview, export and the editor all inherit it via the EDL.
    const takeSyncOffsetSeconds = take
      ? take.trackOffsetSeconds - regionStartSeconds + (take.syncOffsetSeconds ?? 0)
      : 0;
    return {
      // Positional ids: stable across identical runs (determinism) and
      // unique within the edit.
      id: `seg-${i + 1}`,
      takeId: slot.takeId,
      sourceStartFrame: Math.max(
        0,
        sourceFrameForTimelineFrame(startFrame, takeSyncOffsetSeconds, fps),
      ),
      durationFrames: endFrame - startFrame,
    };
  });

  const edl = layoutSegments(partials, base);
  return {
    edl,
    shuffleInfo: {
      score: result.score,
      candidatesEvaluated: result.candidatesEvaluated,
      isRepeatOfPrevious: result.isRepeatOfPrevious,
      takeSequence: result.slots.map((s) => s.takeId),
    },
  };
}

/**
 * Novelty key for an EDL: its take ids in segment order, joined with
 * '|'. Compare keys (or feed `shuffleInfo.takeSequence` back as
 * `previousSequence`) to guarantee successive shuffles differ.
 */
export function sequenceKey(edl: Edl): string {
  return edl.segments.map((s) => s.takeId).join('|');
}

/**
 * Validate an EDL against take durations known on the JS side
 * (seconds → frames at `fps`), via the canonical validateEdl.
 *
 * These durations are an approximation (record-time measurement /
 * best-effort probe). Native `inspectAsset` measures SUPERSEDE them:
 * when native measures are available, build AssetMeasure[] from those
 * and call validateEdl directly instead. A take with no known duration
 * is treated as zero-length — its segments are dropped with errors
 * rather than passed through unchecked.
 */
export function validateAgainstAssets(
  edl: Edl,
  takes: { id: string; durationSeconds?: number }[],
  fps: number,
): EdlValidation {
  const assets: AssetMeasure[] = takes.map((t) => ({
    takeId: t.id,
    durationFrames: Math.max(0, secondsToFrames(t.durationSeconds ?? 0, fps)),
  }));
  return validateEdl(edl, assets);
}
