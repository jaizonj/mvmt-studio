import {
  layoutSegments,
  segmentSpeed,
  segmentTimelineDurationFrames,
  type Edl,
  type EdlSegment,
} from './edl';

/**
 * Edit Modes Stage 2 — rhythm modes (docs/EDIT-MODES.md §3).
 *
 * Pure functions `Edl → Edl`, applied ONCE when the user taps a mode
 * card in Edit mode, through the editor's normal `commitEdl` path
 * (undo snapshot → re-layout → re-anchor → validate → store), so a
 * mode is undoable and preview/export stay identical by construction:
 * modes only change the EDL, and both sides build from the same one.
 *
 * Rules every mode follows:
 * - A segment's SOURCE range is never changed except by splitting it
 *   (a split divides a source range at the cut point); splits keep
 *   source continuity — concatenated pieces cover the original range
 *   exactly.
 * - The audio track is never touched (master song, 1x).
 * - `syncAdjustFrames` lives in source space and survives splits:
 *   each piece keeps its take + source start, and the editor's
 *   re-anchor re-derives the same value for song-anchored pieces.
 * - Repeat / Stutter are the one exception to re-anchoring: a looped
 *   slice replays the SAME source range at a later song position, so
 *   its pieces (and the remainder after them) carry `fixedSource`
 *   and the anchor leaves them pinned — see `EdlSegment.fixedSource`.
 * - Transitions (Edit Modes Stage 3) are STRIPPED by every mode: a
 *   mode re-cuts the timeline, so the boundaries a transition was
 *   set on may not exist afterwards — carrying one onto a rebuilt
 *   boundary would put a dip/dissolve somewhere the user never
 *   chose. Transitions are a finishing touch: set them after the
 *   cut's shape is settled. (`partialOf` below copies only the
 *   listed fields, so a mode's rebuild drops `transitionIn`.)
 */

export type RhythmModeId = 'fast-cuts' | 'fast-slow-fast' | 'repeat' | 'stutter';

export interface RhythmMode {
  id: RhythmModeId;
  name: string;
  description: string;
  /** Needs a target cut (the selected one, or the one under the playhead). */
  needsTarget: boolean;
  /** Needs 2+ takes to alternate between. */
  needsTwoTakes: boolean;
}

export const RHYTHM_MODES: RhythmMode[] = [
  {
    id: 'fast-cuts',
    name: 'Fast Cuts',
    description: 'Rapid-fire cuts, alternating takes.',
    needsTarget: false,
    needsTwoTakes: true,
  },
  {
    id: 'fast-slow-fast',
    name: 'Fast–Slow–Fast',
    description: 'Quick cuts, one long slow stretch, quick cuts again.',
    needsTarget: false,
    needsTwoTakes: true,
  },
  {
    id: 'repeat',
    name: 'Repeat',
    description: 'Loop the first second of a cut — it plays four times.',
    needsTarget: true,
    needsTwoTakes: false,
  },
  {
    id: 'stutter',
    name: 'Stutter',
    description: 'The first 0.3 seconds plays three times, then it continues.',
    needsTarget: true,
    needsTwoTakes: false,
  },
];

/** Repeat: 1 s slice, 3 extra plays (4 total). */
export const REPEAT_MODE = { sliceSeconds: 1, repeatCount: 3 } as const;
/** Stutter: 0.3 s slice, 2 extra plays (3 total). */
export const STUTTER_MODE = { sliceSeconds: 0.3, repeatCount: 2 } as const;

/** Target piece length for Fast Cuts, seconds of timeline. */
export const FAST_CUT_PIECE_SECONDS = 0.75;
/** A tail shorter than this merges into the previous piece instead
 *  of becoming a sliver cut (design system §3.5 UI floor, ~0.33 s). */
const MIN_FAST_CUT_TAIL_FRAMES = 10;

export interface RepeatOptions {
  /** Length of the looped slice, in seconds of SOURCE footage. */
  sliceSeconds: number;
  /** Extra plays beyond the first (3 → the slice plays 4 times). */
  repeatCount: number;
}

/** The layoutSegments input shape for one existing segment.
 *  Deliberately no `transitionIn`: modes re-cut the timeline and
 *  strip transitions (see the header) — a rebuilt boundary must
 *  never inherit a dip/dissolve set on the old one. */
type Partial = {
  id: string;
  takeId: string;
  sourceStartFrame: number;
  durationFrames: number;
  speed?: number;
  fixedSource?: boolean;
};

function partialOf(s: EdlSegment): Partial {
  return {
    id: s.id,
    takeId: s.takeId,
    sourceStartFrame: s.sourceStartFrame,
    durationFrames: s.durationFrames,
    ...(s.speed !== undefined ? { speed: s.speed } : {}),
    ...(s.fixedSource ? { fixedSource: true } : {}),
  };
}

/**
 * Split one segment at the given ABSOLUTE timeline frames. Points
 * outside the segment are ignored; a point that would create a
 * zero-length source piece (a boundary inside the first source
 * frame of a slowed segment) is skipped. Pieces keep the segment's
 * take, speed and pinned flag; the first piece keeps the segment's
 * id, later pieces get `-s1`, `-s2`, … Source continuity is exact:
 * piece N's source end is piece N+1's source start.
 */
function splitSegmentAt(segment: EdlSegment, timelinePoints: number[]): Partial[] {
  const segStart = segment.timelineStartFrame;
  const segTimeline = segmentTimelineDurationFrames(segment);
  const speed = segmentSpeed(segment);
  const offsets = timelinePoints
    .map((b) => b - segStart)
    .filter((d) => d > 0 && d < segTimeline)
    .sort((a, b) => a - b);
  const cuts: { dTimeline: number; dSource: number }[] = [];
  let prevSource = 0;
  for (const d of offsets) {
    const dSource = Math.round(d * speed);
    if (dSource <= prevSource) continue;
    cuts.push({ dTimeline: d, dSource });
    prevSource = dSource;
  }
  if (cuts.length === 0) return [partialOf(segment)];
  const pieces: Partial[] = [];
  let cursorSrc = 0;
  cuts.forEach((cut, i) => {
    pieces.push({
      ...partialOf(segment),
      id: i === 0 ? segment.id : `${segment.id}-s${i}`,
      sourceStartFrame: segment.sourceStartFrame + cursorSrc,
      durationFrames: cut.dSource - cursorSrc,
    });
    cursorSrc = cut.dSource;
  });
  const tailSource = segment.durationFrames - cursorSrc;
  if (tailSource > 0) {
    pieces.push({
      ...partialOf(segment),
      id: `${segment.id}-s${cuts.length}`,
      sourceStartFrame: segment.sourceStartFrame + cursorSrc,
      durationFrames: tailSource,
    });
  }
  return pieces;
}

/**
 * Cut `edl` to at most `maxFrames` of timeline: segments are kept
 * whole until the budget runs out, then the last one is truncated
 * (its source range shrinks so its timeline length fits exactly —
 * floored, so a slowed segment never overshoots by a frame) and
 * everything after it is dropped. A non-positive budget means "no
 * region known" and leaves the cut untouched.
 */
export function clipEdlToFrames(edl: Edl, maxFrames: number): Edl {
  if (maxFrames <= 0 || edl.totalFrames <= maxFrames) return edl;
  const kept: Partial[] = [];
  let used = 0;
  for (const segment of edl.segments) {
    if (used >= maxFrames) break;
    const timeline = segmentTimelineDurationFrames(segment);
    const remaining = maxFrames - used;
    if (timeline <= remaining) {
      kept.push(partialOf(segment));
      used += timeline;
    } else {
      const sourceFrames = Math.max(1, Math.floor(remaining * segmentSpeed(segment)));
      kept.push({
        ...partialOf(segment),
        durationFrames: Math.min(segment.durationFrames, sourceFrames),
      });
      used += remaining;
    }
  }
  return layoutSegments(kept, edl);
}

/**
 * The Fast Cuts treatment, shared by applyFastCuts and the outer
 * thirds of applyFastSlowFast: split each segment into ~0.75 s
 * pieces and hand them round-robin to the takes in recording order,
 * continuing `startCounter` so the cycle runs across the whole cut.
 * A piece that keeps its take keeps its pinned source; a piece
 * handed to a different take re-anchors to that take's performance
 * at its timeline position.
 */
function fastCutPartials(
  segments: EdlSegment[],
  takeIds: string[],
  startCounter: number,
  fps: number,
): { partials: Partial[]; counter: number } {
  const pieceFrames = Math.max(1, Math.round(FAST_CUT_PIECE_SECONDS * fps));
  let counter = startCounter;
  const partials: Partial[] = [];
  for (const segment of segments) {
    const segStart = segment.timelineStartFrame;
    const segEnd = segStart + segmentTimelineDurationFrames(segment);
    const points: number[] = [];
    let p = segStart + pieceFrames;
    while (p < segEnd) {
      if (segEnd - p < MIN_FAST_CUT_TAIL_FRAMES) break;
      points.push(p);
      p += pieceFrames;
    }
    for (const piece of splitSegmentAt(segment, points)) {
      const takeId = takeIds[counter % takeIds.length];
      counter += 1;
      partials.push({
        id: piece.id,
        takeId,
        sourceStartFrame: piece.sourceStartFrame,
        durationFrames: piece.durationFrames,
        ...(piece.speed !== undefined ? { speed: piece.speed } : {}),
        ...(piece.fixedSource && takeId === segment.takeId ? { fixedSource: true } : {}),
      });
    }
  }
  return { partials, counter };
}

/**
 * FAST CUTS — split the timeline into ~0.75 s pieces, alternating
 * takes. The round-robin starts at the first segment's take so the
 * opening shot doesn't change, then cycles through the take list in
 * recording order; with 2+ takes consecutive pieces always differ.
 * Pieces keep their source positions (no re-timing) and their speed,
 * so the total timeline length is unchanged. Returns null when there
 * is nothing to alternate between (fewer than 2 takes) or no cut.
 */
export function applyFastCuts(edl: Edl, takeIds: string[]): Edl | null {
  if (edl.segments.length === 0 || takeIds.length < 2) return null;
  const startCounter = Math.max(0, takeIds.indexOf(edl.segments[0].takeId));
  const { partials } = fastCutPartials(edl.segments, takeIds, startCounter, edl.fps);
  return layoutSegments(partials, edl);
}

/**
 * FAST–SLOW–FAST — first third fast cuts, middle third one long
 * 0.5x stretch, final third fast cuts again. The speed change itself
 * is the transition. The middle third is the segment(s) covering it,
 * each set to 0.5x — they play consecutively as one slow stretch
 * (segments of different takes can't merge into one). Slowing
 * stretches the timeline, so the cut is re-clipped to the region
 * length afterwards; the final third may shrink or vanish when the
 * slow stretch eats the budget. Returns null when there is nothing
 * to alternate between (fewer than 2 takes) or no cut.
 */
export function applyFastSlowFast(edl: Edl, takeIds: string[], regionFrames: number): Edl | null {
  if (edl.segments.length === 0 || takeIds.length < 2) return null;
  const total = edl.totalFrames;
  const third = Math.floor(total / 3);
  const split = layoutSegments(
    edl.segments.flatMap((s) => splitSegmentAt(s, [third, 2 * third])),
    edl,
  );
  const startCounter = Math.max(0, takeIds.indexOf(split.segments[0].takeId));
  const first = split.segments.filter((s) => s.timelineStartFrame < third);
  const middle = split.segments.filter((s) => s.timelineStartFrame >= third && s.timelineStartFrame < 2 * third);
  const last = split.segments.filter((s) => s.timelineStartFrame >= 2 * third);
  // First third — fast cuts; the round-robin then runs on through
  // the final third (the middle keeps its takes, so it doesn't
  // consume the cycle).
  const firstCut = fastCutPartials(first, takeIds, startCounter, edl.fps);
  const lastCut = fastCutPartials(last, takeIds, firstCut.counter, edl.fps);
  const partials: Partial[] = [
    ...firstCut.partials,
    // Middle third — the slow stretch, each segment at 0.5x.
    ...middle.map((s) => ({ ...partialOf(s), speed: 0.5 })),
    ...lastCut.partials,
  ];
  return clipEdlToFrames(layoutSegments(partials, edl), regionFrames);
}

/**
 * REPEAT / STUTTER — loop a short slice of one segment: the first
 * `sliceSeconds` of SOURCE footage plays `repeatCount + 1` times in
 * a row (same take, same source range), then the remainder of the
 * segment continues from where the slice ends. If the segment is
 * shorter than the slice, its whole length is looped. Every piece
 * is pinned (`fixedSource`): the copies replay the same range at
 * later song positions, and the remainder is pinned so it continues
 * from the slice's end instead of skipping ahead to the footage at
 * its new timeline position. The cut is re-clipped to the region.
 * Returns null when the segment isn't in the cut.
 */
export function applyRepeat(edl: Edl, segmentId: string, regionFrames: number, options: RepeatOptions): Edl | null {
  const index = edl.segments.findIndex((s) => s.id === segmentId);
  if (index < 0) return null;
  const segment = edl.segments[index];
  const sliceFrames = Math.min(segment.durationFrames, Math.max(1, Math.round(options.sliceSeconds * edl.fps)));
  const totalPlays = options.repeatCount + 1;
  const partials: Partial[] = [];
  for (let i = 0; i < index; i += 1) partials.push(partialOf(edl.segments[i]));
  for (let play = 0; play < totalPlays; play += 1) {
    partials.push({
      id: play === 0 ? segment.id : `${segment.id}-r${play + 1}`,
      takeId: segment.takeId,
      sourceStartFrame: segment.sourceStartFrame,
      durationFrames: sliceFrames,
      ...(segment.speed !== undefined ? { speed: segment.speed } : {}),
      fixedSource: true,
    });
  }
  const restFrames = segment.durationFrames - sliceFrames;
  if (restFrames > 0) {
    partials.push({
      id: `${segment.id}-rest`,
      takeId: segment.takeId,
      sourceStartFrame: segment.sourceStartFrame + sliceFrames,
      durationFrames: restFrames,
      ...(segment.speed !== undefined ? { speed: segment.speed } : {}),
      fixedSource: true,
    });
  }
  for (let i = index + 1; i < edl.segments.length; i += 1) partials.push(partialOf(edl.segments[i]));
  return clipEdlToFrames(layoutSegments(partials, edl), regionFrames);
}
