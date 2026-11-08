import type { CameraType } from 'expo-camera';

/** An audio file the user picked to perform to. Kept in the app's documents folder. */
export interface AudioTrack {
  /** file:// URI inside the app sandbox (copied there on pick). */
  uri: string;
  /** Original file name, for display. */
  name: string;
  /** Duration in seconds once the player has loaded it, if known. */
  durationSeconds?: number;
}

/** One recorded performance of (part of) the track. */
export interface Take {
  id: string;
  /** file:// URI inside the app sandbox (copied out of the camera cache). */
  uri: string;
  createdAt: number;
  /** Which camera this take was shot on. */
  facing: CameraType;
  /** Recorded length in seconds, measured by the camera screen timer. */
  durationSeconds?: number;
  /** Size of the recorded file in bytes (used by the v1 energy heuristic). */
  fileSizeBytes?: number;
  /**
   * Overall motion/energy estimate for this take, 0 (calm/static) to 1
   * (intense movement). v1 heuristic — see src/lib/analysis.ts. The shuffle
   * engine only reads this number, so a real motion analyser can replace
   * the heuristic without touching the engine.
   */
  energy?: number;
  /**
   * Offset (seconds) into the track at which this take was meant to start.
   * MVMT always records from the top of the track in this scaffold, so this
   * is 0 today — the field exists so section-recording can set it later
   * without changing the timeline model.
   */
  trackOffsetSeconds: number;
}

export type TransitionType = 'cut' | 'crossfade' | 'dip';
export type ClipLook = 'none' | 'warm' | 'cool' | 'mono' | 'vivid';
export type TextPosition = 'top' | 'bottom';

/** One placement of a take on the editor timeline. The same take can appear more than once. */
export interface TimelineClip {
  /** Unique per placement (a take can be placed twice). */
  id: string;
  takeId: string;
  /** Trim in-point inside the take, seconds. Default 0. */
  trimStartSeconds?: number;
  /** Trim out-point inside the take, seconds. Undefined = play to the end of the take. */
  trimEndSeconds?: number;

  // ---- Creative tools (Edit stage only — never Settings) ----
  /** Playback/render speed multiplier for this clip. Default 1. */
  speed?: number;
  /** Clip audio volume 0..1. Default 1. Ignored when `muted`. */
  volume?: number;
  muted?: boolean;
  fadeInSeconds?: number;
  fadeOutSeconds?: number;
  /** Colour look for this clip, applied when the video is rendered. */
  look?: ClipLook;
  /** Text drawn over this clip, if set. */
  textOverlay?: string;
  textPosition?: TextPosition;
  /**
   * The join BETWEEN this clip and the next one (the transition lives on
   * the earlier clip because it describes how it hands over). Edited from
   * the join control between the two clips on the timeline.
   */
  transitionType?: TransitionType;
  transitionDurationSeconds?: number;
}

/**
 * A musical section of the track (phrase-aligned), with an energy estimate.
 * Built by src/lib/analysis.ts and cached in the studio store — the shuffle
 * engine is a pure table lookup over these, never a re-analysis.
 */
export interface MusicalSection {
  index: number;
  startSeconds: number;
  endSeconds: number;
  /** 0 (silence/intro) to 1 (loudest phrase), RMS-derived when sampled. */
  energy: number;
}

/** Record of the last shuffle, shown as the "Best of N · score X" caption. */
export interface ShuffleResultInfo {
  score: number;
  candidatesEvaluated: number;
  /** Take ids in timeline order — used to guarantee the next shuffle differs. */
  takeSequence: string[];
}

export type CountdownSeconds = 0 | 3 | 5 | 10;

/**
 * How often Shuffle changes clip — the target length of each shuffled
 * section. At the assumed 120 BPM grid: chill = a full 8-beat phrase
 * (~4s), normal = half a phrase (~2s), fast = 2 beats (~1s),
 * rapid = every beat (~0.5s).
 */
export type ShuffleFrequency = 'chill' | 'normal' | 'fast' | 'rapid';

export const SHUFFLE_FREQUENCY_LENGTHS: Record<ShuffleFrequency, number> = {
  chill: 4,
  normal: 2,
  fast: 1,
  rapid: 0.5,
};

/** Settings-only configuration types (no creative tools — see SettingsSheet). */
export type FrameRatePref = 30 | 60;
export type CountInBeats = 0 | 4 | 8;
export type ExportQualityPref = 'high' | 'balanced' | 'small';

/**
 * The selected part of the track — THE single source of truth for "which
 * bit of the song are we performing". Recording plays exactly this region,
 * shuffle sections are built inside it, and the editor previews it.
 * durationSeconds = null means "to the end of the track".
 */
export interface AudioRegion {
  startSeconds: number;
  durationSeconds: number | null;
}
