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
  /** Which camera this take was shot on. Meaningless for imported
   *  takes (they carry a neutral value) — the UI keys off `source`. */
  facing: CameraType;
  /**
   * Where this take came from: 'recorded' (shot in the app — the
   * default when the field is absent, so every pre-import take reads
   * as recorded) or 'imported' (picked from Photos/Files and synced
   * to the song after the fact). Imported takes are first-class takes
   * for the shuffle/editor/export, but two things treat them
   * specially: they never vote on the EDL canvas (canvasForTakes —
   * a landscape or 4K import conforms to the project's canvas instead
   * of hijacking it), and their sync offset may legitimately be
   * LARGE (the song can begin anywhere inside the file), so their
   * sync status copy is worded differently.
   */
  source?: 'recorded' | 'imported';
  /** Recorded length in seconds, measured by the camera screen timer. */
  durationSeconds?: number;
  /** Measured display size of the recorded file (native path) — the
   * EDL canvas follows the largest take so 4K takes export at 4K. */
  width?: number;
  height?: number;
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
   * Offset (seconds) into the track at which this take was meant to start
   * (the region start it was recorded against).
   */
  trackOffsetSeconds: number;
  /**
   * MEASURED synchronization offset, seconds: where the song actually
   * was (relative to the intended region start) when this take's first
   * frames were captured — measured, not assumed (see `syncSource`
   * for how: player sample, file correlation, or the native capture
   * module's first-frame report). Positive = the camera effectively
   * started late. Consumed by the EDL bridge (src/lib/shuffleEdl.ts)
   * via the single mapping in src/lib/edl.ts. Undefined = not
   * measured (older takes).
   */
  syncOffsetSeconds?: number;
  /**
   * Manual per-take sync calibration, in INTEGER frames at the project
   * fps (30) — Jaizon's by-ear/eye correction when automatic sync is
   * still imperfect. Added to the measured offset inside the ONE shared
   * offset function (`takeSyncOffsetSeconds` in src/lib/edl.ts), so the
   * shuffle bridge, the editor's sync anchor, preview and export all
   * honour it identically. Same sign convention as syncOffsetSeconds:
   * positive = the capture is treated as having started later (the
   * footage for a given song position is read earlier in the file).
   * Undefined = no correction (0). Optional — never required.
   */
  syncAdjustFrames?: number;
  /**
   * Provenance of `syncOffsetSeconds`: 'playerSample' = the audio
   * player's position sampled at record start/stop (the original
   * estimate); 'fileCorrelation' = measured after the fact from the
   * recorded file itself (native correlation of the take's mic audio
   * against the master track); 'nativeCapture' = measured AT record
   * time by the native capture module, which owned both the camera
   * and the song player on one host clock and reported the song
   * position at the first real frame. 'nativeCapture' is the
   * highest-precedence measurement: automatic refinement
   * (file correlation) must never overwrite it. Undefined for older
   * takes.
   */
  syncSource?: 'playerSample' | 'fileCorrelation' | 'nativeCapture';
  /**
   * Confidence (0..1) of a 'fileCorrelation' measurement — peak
   * prominence of the correlation match. Only meaningful when
   * syncSource is 'fileCorrelation'; low-confidence measurements must
   * not silently replace a playerSample value.
   */
  syncConfidence?: number;
  /**
   * Measured drift over the take, seconds: (song elapsed between the
   * record-start and record-stop samples) − (the take's measured
   * duration). Diagnostic only — never consumed by the sync mapping:
   * dominated by capture-start latency, not clock drift (2026-11-09
   * audit).
   */
  syncDriftSeconds?: number;
  /** User-facing name for the take (Takes screen rename). Default: "Take N". */
  displayName?: string;
  /**
   * Stable per-project sequence number, assigned by the store in
   * addTake (max existing + 1) — "Take N" numbering must not renumber
   * surviving takes when one is deleted (design spec Appendix B).
   * Older takes have none; the UI falls back to chronological order.
   */
  seq?: number;
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

/** Settings-only configuration types (no creative tools — they live in the Editor). */
export type FrameRatePref = 30 | 60;
export type CountInBeats = 0 | 4 | 8;
export type ExportQualityPref = 'high' | 'tiktok' | 'balanced' | 'small';

/**
 * The numeric grade a "look" resolves to — ONE parametric set, in the
 * spirit of the lyric animation params: presets in src/lib/looks.ts
 * are just named points in this space, the JS side resolves a stored
 * ProjectLook (preset + intensity + per-param overrides) into these
 * numbers, and the native engine applies them blindly (a CI filter
 * chain in the compositor). Identity (no visible change) is
 * brightness 0, contrast 1, saturation 1, exposureEV 0, temperature 0,
 * vibrance 0, sharpen 0, vignette 0 — see IDENTITY_LOOK_PARAMS.
 */
export interface LookParams {
  /** CIColorControls brightness, -0.15..0.15. */
  brightness: number;
  /** CIColorControls contrast, 0.85..1.2. */
  contrast: number;
  /** CIColorControls saturation, 0..1.6 (0 = black & white). */
  saturation: number;
  /** CIExposureAdjust EV, -0.7..0.7. */
  exposureEV: number;
  /**
   * Warmth, -30..30 — an offset on the 6500K neutral the engine's
   * CITemperatureAndTint converts from (positive = warmer picture).
   */
  temperature: number;
  /** CIVibrance amount, -1..1. */
  vibrance: number;
  /** CISharpenLuminance sharpness, 0..1.2. */
  sharpen: number;
  /** CIVignette intensity, 0..1.2. */
  vignette: number;
}

/**
 * A project's chosen look, as STORED: a preset id, a master intensity
 * (0..1, scales the preset from identity toward its full values at
 * resolve time), and optional per-param overrides forked by the Edit
 * screen's Adjust sliders (absolute values that win over the lerped
 * preset). Absent on a project = the effective default (Auto Enhance
 * at full intensity — looks are auto-applied); picking the Original
 * preset stores explicitly and means "no grade".
 */
export interface ProjectLook {
  presetId: string;
  intensity: number;
  overrides?: Partial<LookParams>;
}

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

/**
 * One word of a lyric line with its own timing (from Whisper). Frames
 * are on the SONG timeline at the project fps (30), song-absolute —
 * the same clock the EDL's `audio.regionStartFrame` lives on.
 */
export interface LyricWord {
  text: string;
  startFrame: number;
  endFrame: number;
}

/**
 * One lyric line, timed on the SONG timeline (NOT the composition
 * timeline): `startFrame`/`endFrame` are song-absolute frames at the
 * EDL fps. Because the master song plays continuously through every
 * cut, pinning lines to the song clock means shuffle edits can never
 * knock lyrics out of sync — the song↔timeline mapping happens once,
 * at the native boundary (src/lib/lyrics.ts).
 */
export interface LyricLine {
  id: string;
  text: string;
  startFrame: number;
  endFrame: number;
  /**
   * Per-word timings from detection. Optional: manual lines and lines
   * whose text was edited into a different word count carry none, and
   * word-level animations fall back to line-level for them.
   */
  words?: LyricWord[];
}

/** How a project's lyrics are drawn — one style per project (v1). */
export interface LyricStyle {
  /** Font catalog id (src/lib/lyricFonts.ts). */
  fontId: string;
  /** Font size as a fraction of the canvas WIDTH (0.04–0.16). */
  sizeRatio: number;
  /** #RRGGBB text colour. */
  color: string;
  /** #RRGGBB outline colour; undefined = no outline. */
  strokeColor?: string;
  /** Outline width as a fraction of the font size (0–0.25). */
  strokeWidthRatio?: number;
  /** Backing plate behind the line. */
  background: 'none' | 'pill';
  /** #RRGGBB or rgba() pill colour; undefined = default dark pill. */
  backgroundColor?: string;
  position: 'top' | 'center' | 'bottom';
  /** Animation preset id (src/lib/lyricAnimations.ts). */
  animationId: string;
  bold: boolean;
}

/** A project's detected/edited lyrics plus their style. */
export interface ProjectLyrics {
  lines: LyricLine[];
  style: LyricStyle;
}

/**
 * A project — the unit the new IA is built around (Studio / Projects /
 * workspace). Everything creative lives here and is persisted as JSON;
 * media FILES live in the app sandbox and are referenced by URI.
 * The canonical edit is the frame-based EDL (src/lib/edl.ts).
 */
export interface Project {
  id: string;
  name: string;
  createdAt: number;
  updatedAt: number;
  track: AudioTrack | null;
  trackRegion: AudioRegion;
  takes: Take[];
  /** The canonical edit. Null until the first shuffle/manual edit. */
  edl: import('./lib/edl').Edl | null;
  /** Take-id sequence of the current EDL — guarantees the next shuffle differs. */
  lastShuffleSequence: string[] | null;
  shuffleFrequency: ShuffleFrequency;
  /**
   * Whether the MVMT studio logo watermark (assets/logo-lockup.png) is
   * stamped onto this project's videos — preview and export alike,
   * toggled on the Edit screen. Undefined = ON: projects persisted
   * before the flag existed behave as enabled, and the store exposes
   * the effective value (`watermarkEnabled` in StudioContext).
   */
  watermarkEnabled?: boolean;
  /**
   * Lyrics for this project's song (Whisper-detected, then edited in
   * the Editor's Lyrics panel). Timings are song-absolute frames —
   * see LyricLine. Undefined = no lyrics yet.
   */
  lyrics?: ProjectLyrics;
  /**
   * Whether lyrics are drawn on preview/export. Undefined = ON when
   * the project has lines, OFF when it has none (the store exposes
   * the effective value, like `watermarkEnabled`).
   */
  lyricsEnabled?: boolean;
  /**
   * The project's video look (an edit/export-stage grade — see
   * LookParams / src/lib/looks.ts). Undefined = the effective default
   * (Auto Enhance); the store exposes the effective value (`look` in
   * StudioContext). A creative choice, so it is NOT cleared when the
   * track changes.
   */
  look?: ProjectLook;
  /** When the project's video was last successfully rendered (Export stamps it). */
  exportedAt?: number;
}
