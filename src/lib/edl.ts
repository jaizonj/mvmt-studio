import type { CompositeRequest, ResolvedLookParams } from '../../modules/mvmt-compositor/src/index';

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

/** Playback-rate bounds for a segment's video (Edit Modes Stage 1). */
export const MIN_SEGMENT_SPEED = 0.25;
export const MAX_SEGMENT_SPEED = 2;

export interface EdlSegment {
  id: string;
  takeId: string;
  /** First frame of this segment on the project timeline. */
  timelineStartFrame: number;
  /** First frame inside the source take (sync offset already applied). */
  sourceStartFrame: number;
  /** Length of the segment IN SOURCE FRAMES. Always > 0 in a valid EDL.
   *  The length it occupies ON THE TIMELINE is
   *  `segmentTimelineDurationFrames` — source frames divided by speed. */
  durationFrames: number;
  /**
   * Playback rate of the segment's VIDEO (0.25–2, undefined = 1):
   * 0.5 plays the source at half speed (twice as long on the
   * timeline), 2 at double speed. Video-only — the master song
   * always plays at 1x over the whole cut, so speed never touches
   * audio sync. The source range (`sourceStartFrame`,
   * `durationFrames`) is unchanged; only the mapping stretches.
   */
  speed?: number;
}

/**
 * Sanitised playback rate for a segment: finite, clamped to
 * [0.25, 2], default 1. The single sanitisation point — every
 * consumer (layout, validation, the composition request) reads
 * speed through here, so a stale or out-of-range stored value can
 * never break the timeline math.
 */
export function segmentSpeed(segment: { speed?: number }): number {
  const s = segment.speed;
  // Non-positive speeds are meaningless (0x = an infinitely long
  // cut) — they fall back to 1x, not up to the 0.25 minimum.
  if (typeof s !== 'number' || !Number.isFinite(s) || s <= 0) return 1;
  return Math.min(MAX_SEGMENT_SPEED, Math.max(MIN_SEGMENT_SPEED, s));
}

/**
 * Length of a segment ON THE TIMELINE, in frames — what the cut
 * actually occupies. Slow segments stretch (source / 0.5 = 2× the
 * frames), fast segments compress. Always ≥ 1.
 */
export function segmentTimelineDurationFrames(segment: EdlSegment): number {
  return Math.max(1, Math.round(segment.durationFrames / segmentSpeed(segment)));
}

/**
 * Source frame inside `segment` shown at timeline frame `frame`
 * (which must lie inside the segment): the source advances `speed`
 * frames per timeline frame, starting at `sourceStartFrame`. The
 * segment's START still comes from the shared absolute mapping
 * (`sourceFrameForTimelineFrame` at `timelineStartFrame`) — speed
 * only changes how fast the source runs on from there.
 */
export function sourceFrameForSegmentFrame(segment: EdlSegment, timelineFrame: number): number {
  return segment.sourceStartFrame + (timelineFrame - segment.timelineStartFrame) * segmentSpeed(segment);
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
 *
 * This mapping holds at SEGMENT STARTS (the shuffle bridge, the
 * editor's re-anchor): a segment's first frame is its take's
 * performance at that song position. INSIDE a segment the source
 * advances at the segment's speed — see `sourceFrameForSegmentFrame`.
 */
export function sourceFrameForTimelineFrame(
  timelineFrame: number,
  syncOffsetSeconds: number,
  fps: number,
): number {
  return timelineFrame - secondsToFrames(syncOffsetSeconds, fps);
}

/**
 * THE one shared per-take sync offset, in seconds:
 *
 *   takeSyncOffsetSeconds
 *     = take.trackOffsetSeconds − regionStartSeconds
 *       + (take.syncOffsetSeconds ?? 0)
 *       + framesToSeconds(take.syncAdjustFrames ?? 0, fps)
 *
 * i.e. where the take's recording window sat relative to the region
 * start, corrected by the take's MEASURED capture error
 * (syncOffsetSeconds — player-sampled or file-correlated) and by
 * Jaizon's manual frame calibration (syncAdjustFrames). Positive =
 * capture started late, so the footage for a given timeline frame
 * lives earlier inside the file (see sourceFrameForTimelineFrame).
 *
 * The shuffle→EDL bridge, the editor's sync anchor and the calibration
 * UI all read THIS function; record.tsx is the write side only (it
 * produces the measured fields, it never maps with them). Nobody else
 * does this math. `syncDriftSeconds` deliberately never enters here:
 * it is a diagnostic dominated by capture-start latency, not clock
 * drift (2026-11-09 audit).
 */
export function takeSyncOffsetSeconds(
  take: { trackOffsetSeconds: number; syncOffsetSeconds?: number; syncAdjustFrames?: number },
  regionStartSeconds: number,
  fps: number,
): number {
  return (
    take.trackOffsetSeconds -
    regionStartSeconds +
    (take.syncOffsetSeconds ?? 0) +
    framesToSeconds(take.syncAdjustFrames ?? 0, fps)
  );
}

/**
 * Lay out segments back-to-back from frame 0, assigning timeline
 * starts. The cursor advances by each segment's TIMELINE length
 * (`segmentTimelineDurationFrames`) — a slowed segment pushes the
 * cuts after it later, a sped-up one pulls them earlier. `speed`
 * rides along on the partials (undefined = 1x).
 */
export function layoutSegments(
  partials: {
    id: string;
    takeId: string;
    sourceStartFrame: number;
    durationFrames: number;
    speed?: number;
  }[],
  base: Edl,
): Edl {
  let cursor = 0;
  const segments: EdlSegment[] = partials
    .filter((p) => p.durationFrames > 0)
    .map((p) => {
      const segment: EdlSegment = { ...p, timelineStartFrame: cursor };
      cursor += segmentTimelineDurationFrames(segment);
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
  const kept: {
    id: string;
    takeId: string;
    sourceStartFrame: number;
    durationFrames: number;
    speed?: number;
  }[] = [];

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
    // Speed rides through validation untouched: it changes only the
    // timeline length, never which source frames exist. The key is
    // only set when present, so a 1x edit stays byte-identical
    // through validation (the contract tests assert deepEqual).
    kept.push({
      id: segment.id,
      takeId: segment.takeId,
      sourceStartFrame: start,
      durationFrames: end - start,
      ...(segment.speed !== undefined ? { speed: segment.speed } : {}),
    });
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
/**
 * The output canvas a cut should render at: the largest recorded
 * frame among the takes (their measured display sizes), so a project
 * shot at 4K exports at 4K instead of silently downscaling to the
 * 1080×1920 default. Takes without measured dimensions (expo path,
 * legacy) simply don't vote. Never shrinks the EDL's stored canvas.
 *
 * IMPORTED takes never vote: the canvas follows what was SHOT for
 * the project, and an imported video (landscape, 4K, anything)
 * conforms to it — the native builder aspect-fills every clip into
 * the canvas, so an import can fill the frame but never redefine it.
 */
export function canvasForTakes(
  takes: readonly import('../types').Take[],
): { width: number; height: number } | null {
  let best: { width: number; height: number } | null = null;
  for (const t of takes) {
    if (t.source === 'imported') continue;
    if (!t.width || !t.height) continue;
    if (!best || t.width * t.height > best.width * best.height) {
      best = { width: t.width, height: t.height };
    }
  }
  return best;
}

/** `edl` with its canvas raised to the takes' canvas when larger. */
export function edlWithTakeCanvas(edl: Edl, takes: readonly import('../types').Take[]): Edl {
  const canvas = canvasForTakes(takes);
  if (!canvas) return edl;
  if (canvas.width * canvas.height <= edl.canvas.width * edl.canvas.height) return edl;
  return { ...edl, canvas };
}

export function edlToCompositeRequest(
  edl: Edl,
  takeUri: (takeId: string) => string | undefined,
  options: {
    includeTakeAudio?: boolean;
    /** Stamp the MVMT studio logo watermark on the composition. */
    watermarkEnabled?: boolean;
    /** On-device file URI of the watermark image (see src/lib/watermark.ts). */
    watermarkImageUri?: string | null;
    /**
     * Render frame rate for the composition (Jaizon, 2026-11-09:
     * export High = 60fps; Balanced/Small = 30fps so files stay
     * small enough to share, e.g. Discord <20MB). Defaults to the
     * EDL's own fps. Cut boundaries live on the EDL's 30-grid and 30
     * divides 60, so they land exactly at either rate — only the
     * sampling of 60fps-shot takes differs.
     */
    frameRate?: number;
    /**
     * The project's resolved video look (src/lib/looks.ts), or null
     * for no grade. Unlike the watermark this rides BOTH preview and
     * export requests: the grade is part of the composition, so the
     * editor preview must carry it to stay truthful.
     */
    look?: ResolvedLookParams | null;
    /**
     * Auto volume: the engine measures the song and gains it to the
     * platform loudness (−14 LUFS) inside the composition. Like the
     * look it rides preview AND export — what you hear is what ships.
     */
    normalizeVolume?: boolean;
    /**
     * Override for the master song URI (composition builds only).
     * Auto EQ passes the EQ-rendered copy of the song here once it
     * has been prepared (src/lib/autoEq.ts); the EDL itself always
     * keeps the original URI, so recording, record-time playback and
     * sync measurement are never affected. The processed file is the
     * full song at the identical duration, so every region/start
     * semantic of the request is unchanged.
     */
    audioUri?: string | null;
  } = {},
): CompositeRequest {
  const clips = edl.segments.map((segment) => {
    const uri = takeUri(segment.takeId);
    if (!uri) throw new Error(`EDL segment ${segment.id} references take ${segment.takeId}, which has no file URI.`);
    return {
      uri,
      startSeconds: framesToSeconds(segment.sourceStartFrame, edl.fps),
      durationSeconds: framesToSeconds(segment.durationFrames, edl.fps),
      // The native builder re-times this source range to
      // durationSeconds / speed on the composition timeline — the
      // SAME request feeds preview and export, so the speed is
      // honoured identically in both. The master song is untouched.
      speed: segmentSpeed(segment),
      muted: !options.includeTakeAudio,
      volume: 1,
    };
  });
  return {
    clips,
    audioUri: options.audioUri ?? edl.audio.uri,
    audioStartSeconds: framesToSeconds(edl.audio.regionStartFrame, edl.fps),
    audioVolume: edl.audio.volume,
    canvasWidth: edl.canvas.width,
    canvasHeight: edl.canvas.height,
    frameRate: options.frameRate ?? edl.fps,
    // Watermark: passed through untouched — the native engine decides
    // how to stamp it. Only the Editor preview and the Export render
    // set these; other callers (e.g. the Record screen's per-take
    // calibration preview) omit them and stay unwatermarked.
    watermarkEnabled: options.watermarkEnabled ?? false,
    watermarkImageUri: options.watermarkImageUri ?? null,
    // Look: passed through untouched — null (the default for callers
    // that don't grade, like the Record screen's calibration preview)
    // renders unfiltered.
    look: options.look ?? null,
    normalizeVolume: options.normalizeVolume ?? false,
  };
}

/** The segment under a timeline frame, or null past the end. Spans
 *  are TIMELINE spans — a slowed segment covers more frames. */
export function segmentAtFrame(edl: Edl, frame: number): EdlSegment | null {
  for (const segment of edl.segments) {
    if (
      frame >= segment.timelineStartFrame &&
      frame < segment.timelineStartFrame + segmentTimelineDurationFrames(segment)
    ) {
      return segment;
    }
  }
  return null;
}

export const edlDurationSeconds = (edl: Edl): number => framesToSeconds(edl.totalFrames, edl.fps);
