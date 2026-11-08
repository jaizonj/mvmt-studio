import type { CompositeRequest } from '../../modules/mvmt-compositor/src/index';

/**
 * Canonical Edit Decision List (EDL) — the ONE timeline representation
 * for the whole app (Overhaul Phase 1 contract; see docs/IMPLEMENTATION.md).
 *
 * Rules:
 * - INTEGER FRAMES are the editing source of truth. Seconds exist only
 *   at the native boundary (converted to CMTime by the Swift engine).
 * - Segments are sequential and gapless: segment N starts exactly where
 *   segment N-1 ended. `timelineStartFrame` is stored explicitly (not
 *   just implied by order) so partial selections, exports and native
 *   instructions never re-derive it differently.
 * - Every segment's source range is expressed in frames INSIDE its take,
 *   with the take's synchronization offset already applied by
 *   `sourceFrameForTimelineFrame` — the single shared mapping, so the
 *   shuffle, the editor, the preview and the exporter can never disagree
 *   about where a cut's footage comes from.
 * - The EDL is validated against MEASURED asset durations before it is
 *   allowed anywhere near a player or an exporter (`validateEdl`).
 * - Audio policy lives here too: by default the EDL renders the master
 *   song ONLY (take audio muted). Take audio is an explicit opt-in.
 */

export const EDL_VERSION = 1 as const;
/** Project frame rate — editing grid and native frameDuration. */
export const DEFAULT_FPS = 30;

export interface EdlSegment {
  id: string;
  takeId: string;
  /** First frame of this segment on the project timeline. */
  timelineStartFrame: number;
  /** First frame inside the source take (sync offset already applied). */
  sourceStartFrame: number;
  /** Length of the segment, in frames. Always > 0 in a valid EDL. */
  durationFrames: number;
}

export interface EdlAudio {
  /** Master track file URI, or null for a silent project. */
  uri: string | null;
  /** Frame (on the track's own timeline, at the project fps) where the used region starts. */
  regionStartFrame: number;
  /** 0..1, default 1. */
  volume: number;
}

export interface Edl {
  version: typeof EDL_VERSION;
  fps: number;
  /** Project output canvas — every segment is normalised into it natively. */
  canvas: { width: number; height: number };
  segments: EdlSegment[];
  /** Sum of segment durations; kept explicit and checked by validateEdl. */
  totalFrames: number;
  audio: EdlAudio;
}

/** Measured facts about one source asset (from native inspectAsset). */
export interface AssetMeasure {
  takeId: string;
  durationFrames: number;
}

export const secondsToFrames = (seconds: number, fps: number): number => Math.round(seconds * fps);
export const framesToSeconds = (frames: number, fps: number): number => frames / fps;

export const DEFAULT_CANVAS = { width: 1080, height: 1920 } as const;

export function emptyEdl(fps: number = DEFAULT_FPS): Edl {
  return {
    version: EDL_VERSION,
    fps,
    canvas: { ...DEFAULT_CANVAS },
    segments: [],
    totalFrames: 0,
    audio: { uri: null, regionStartFrame: 0, volume: 1 },
  };
}

/**
 * The single timeline→source mapping for synced takes.
 *
 * A take was recorded while the song played from the region start. If the
 * camera's first frame actually landed when the song was at
 * (regionStart + syncOffsetSeconds) — the MEASURED offset, positive when
 * capture started late — then timeline frame F shows song position
 * regionStart + F/fps, which lives at take frame F − syncOffset·fps.
 * Callers pass the take's measured values; nobody else does this math.
 */
export function sourceFrameForTimelineFrame(
  timelineFrame: number,
  syncOffsetSeconds: number,
  fps: number,
): number {
  return timelineFrame - secondsToFrames(syncOffsetSeconds, fps);
}

/** Lay out segments back-to-back from frame 0, assigning timeline starts. */
export function layoutSegments(
  partials: { id: string; takeId: string; sourceStartFrame: number; durationFrames: number }[],
  base: Edl,
): Edl {
  let cursor = 0;
  const segments: EdlSegment[] = partials
    .filter((p) => p.durationFrames > 0)
    .map((p) => {
      const segment: EdlSegment = { ...p, timelineStartFrame: cursor };
      cursor += p.durationFrames;
      return segment;
    });
  return { ...base, segments, totalFrames: cursor };
}

export interface EdlValidation {
  ok: boolean;
  errors: string[];
  /** The EDL with out-of-range source ranges clamped; empty segments dropped. */
  edl: Edl;
}

/**
 * Validate an EDL against measured asset durations. This is the gate
 * between editing-land and the native engine: ranges are clamped to what
 * actually exists in each take file, segments that clamp to nothing are
 * dropped (and reported), and timeline starts are re-laid-out so the
 * result is always gapless and self-consistent.
 */
export function validateEdl(edl: Edl, assets: AssetMeasure[]): EdlValidation {
  const errors: string[] = [];
  const byId = new Map(assets.map((a) => [a.takeId, a.durationFrames]));
  const kept: { id: string; takeId: string; sourceStartFrame: number; durationFrames: number }[] = [];

  for (const segment of edl.segments) {
    const assetFrames = byId.get(segment.takeId);
    if (assetFrames === undefined) {
      errors.push(`Segment ${segment.id}: unknown take ${segment.takeId} — dropped.`);
      continue;
    }
    const start = Math.max(0, Math.floor(segment.sourceStartFrame));
    const end = Math.min(assetFrames, Math.floor(segment.sourceStartFrame + segment.durationFrames));
    if (end - start <= 0) {
      errors.push(
        `Segment ${segment.id}: source range [${segment.sourceStartFrame}, +${segment.durationFrames}f) ` +
          `falls outside take ${segment.takeId} (${assetFrames}f) — dropped.`,
      );
      continue;
    }
    if (start !== segment.sourceStartFrame || end - start !== segment.durationFrames) {
      errors.push(`Segment ${segment.id}: source range clamped to the take's real length.`);
    }
    kept.push({ id: segment.id, takeId: segment.takeId, sourceStartFrame: start, durationFrames: end - start });
  }

  const laidOut = layoutSegments(kept, edl);
  return { ok: errors.length === 0, errors, edl: laidOut };
}

/**
 * Convert a validated EDL into the native engine's request shape
 * (seconds at the boundary; the engine builds CMTime from them).
 * Preview and export MUST both go through this function — identical
 * input is what makes preview and export the same edit.
 *
 * Audio policy: master song only, unless `includeTakeAudio` is set —
 * takes are muted by default (Overhaul directive §2.5).
 */
export function edlToCompositeRequest(
  edl: Edl,
  takeUri: (takeId: string) => string | undefined,
  options: { includeTakeAudio?: boolean } = {},
): CompositeRequest {
  const clips = edl.segments.map((segment) => {
    const uri = takeUri(segment.takeId);
    if (!uri) throw new Error(`EDL segment ${segment.id} references take ${segment.takeId}, which has no file URI.`);
    return {
      uri,
      startSeconds: framesToSeconds(segment.sourceStartFrame, edl.fps),
      durationSeconds: framesToSeconds(segment.durationFrames, edl.fps),
      muted: !options.includeTakeAudio,
      volume: 1,
    };
  });
  return {
    clips,
    audioUri: edl.audio.uri,
    audioStartSeconds: framesToSeconds(edl.audio.regionStartFrame, edl.fps),
    audioVolume: edl.audio.volume,
    canvasWidth: edl.canvas.width,
    canvasHeight: edl.canvas.height,
    frameRate: edl.fps,
  };
}

/** The segment under a timeline frame, or null past the end. */
export function segmentAtFrame(edl: Edl, frame: number): EdlSegment | null {
  for (const segment of edl.segments) {
    if (frame >= segment.timelineStartFrame && frame < segment.timelineStartFrame + segment.durationFrames) {
      return segment;
    }
  }
  return null;
}

export const edlDurationSeconds = (edl: Edl): number => framesToSeconds(edl.totalFrames, edl.fps);
