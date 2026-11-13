import type { CameraType } from 'expo-camera';

import type { ExtraStyleState } from './lib/extra-styles/types';
import type { MixMasterStageSettings } from './lib/mixMasterCurve';

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
 * preset). Absent on a project = the effective default (Original —
 * no grade; the Auto Enhance auto-apply was removed 2026-11-13);
 * picking the Original preset stores explicitly and means "no grade".
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
/**
 * Deterministic lyric intelligence for one line (Styles Redesign
 * Stage 2): computed ONCE at Detect time (and re-computed on manual
 * line edits) in src/lib/lyrics.ts, then stored here — renderers
 * never analyse, they only read. Every field is optional: a line
 * with no keyword match has no emoji, a line with no tone word has
 * no tone, and a line with nothing to emphasize has no indices.
 * Never guessed — absence means "no match".
 */
export interface LyricLineDecor {
  /** Relevant emoji for this line, from the keyword dictionary. */
  emoji?: string;
  /** Emotional tone tag from the tone word lists. */
  tone?: 'joy' | 'sad' | 'anger' | 'love' | 'hype';
  /**
   * Word indices (into line.words, or into the line's whitespace
   * tokens when it has no timed words) to emphasize: ALL-CAPS
   * words, or words that repeat within the line.
   */
  emphasisWordIndices?: number[];
}

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
  /** Stored lyric intelligence (emoji / tone / emphasis) — see above. */
  decor?: LyricLineDecor;
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
  /** Fine vertical nudge as a fraction of the canvas HEIGHT,
   * applied on top of the position anchor (positive = up) —
   * Jaizon, 2026-11-11: move all the words up or down slightly
   * while keeping the Top/Center/Bottom choice. Undefined = 0. */
  verticalOffsetRatio?: number;
  /** Maximum line width as a fraction of the canvas WIDTH.
   * Lines wider than this WRAP onto more rows instead of
   * running off the frame's edges (Jaizon, 2026-11-12: lyrics
   * were cutting off the screen in TikTok/Instagram posts).
   * Undefined = 0.88. */
  maxWidthRatio?: number;
  /** Animation preset id (src/lib/lyricAnimations.ts). */
  animationId: string;
  bold: boolean;
}

/** A project's detected/edited lyrics plus their style. */
export interface ProjectLyrics {
  lines: LyricLine[];
  style: LyricStyle;
  /**
   * Style-tab favorites (Styles Redesign Stage 1): font / animation
   * ids hearted in the picker. Persisted with the project (and its
   * song-library copy) so they survive restarts; favorites sort to
   * the top of their lists. Undefined = none.
   */
  favoriteFontIds?: string[];
  favoriteAnimationIds?: string[];
  /**
   * RETIRED v1 Extra Style template id (Jaizon, 2026-11-13). The
   * field is kept ONLY so the load-time migration can read it:
   * StudioContext retires a stored id one-shot via
   * migrateV1Template (2.0 successor or classic) and clears it.
   * Nothing in the app sets it any more — undefined = classic.
   */
  templateId?: string;
  /**
   * RETIRED v1 Extra Styles favorites: template ids hearted in the
   * (removed) Extra tab. Kept only so old persisted projects still
   * typecheck; nothing reads or writes it any more.
   */
  favoriteTemplateIds?: string[];
  /**
   * Global fine offset, in song-timeline frames, applied to EVERY
   * line (and word) when the lyrics are rendered — the Lyrics
   * panel's drag bar (Jaizon, 2026-11-11: "if they seem off by half
   * a second you can just drag it"). Non-destructive: the authored
   * line timings never change, preview and export both read the
   * offset through buildCompositeLyrics. Undefined = 0.
   */
  offsetFrames?: number;
}

/**
 * One song in the song library: the audio (a sandbox copy that
 * outlives any single project) plus the lyrics Jaizon fixed for
 * it, so picking the song again — in any project — brings the
 * corrected lyrics with it (Jaizon, 2026-11-11). Entries are
 * keyed by songLibraryKey(name, duration) (src/lib/songLibrary.ts).
 */
export interface SongLibraryEntry {
  key: string;
  /** Display name (the track's file name when it was saved). */
  name: string;
  /** file:// URI of the library's audio copy in the sandbox. */
  uri: string;
  durationSeconds?: number;
  lyrics: ProjectLyrics;
  updatedAt: number;
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
   * (Original — no grade); the store exposes the effective value
   * (`look` in StudioContext). A creative choice, so it is NOT
   * cleared when the track changes.
   */
  look?: ProjectLook;
  /**
   * Extra Styles 2.0: the project's chosen scene style + parameter
   * values (src/lib/extra-styles/types.ts — ExtraStyleState).
   * Undefined = no 2.0 style (classic lyrics render, as before);
   * a state with an empty `styleId` is the favorites-only shell —
   * the project has hearted styles but none selected (see
   * toggleFavoriteExtraStyle in StudioContext). A creative choice,
   * so it is NOT cleared when the track changes. The lyric
   * interpretation, audio automation, subject masks, and card
   * previews are derived caches, NOT project fields.
   */
  extraStyle?: ExtraStyleState;
  /**
   * Auto EQ: the engine analyzes this project's song and renders a
   * copy with the harsh frequencies pulled down (cuts only), which
   * composition builds — editor/export preview AND the export
   * render — then use in place of the original file
   * (src/lib/autoEq.ts). Undefined = ON: projects persisted before
   * the flag existed behave as enabled, and the store exposes the
   * effective value (`autoEqEnabled` in StudioContext). Recording,
   * record-time playback and sync measurement always use the
   * original song regardless of this flag.
   */
  autoEqEnabled?: boolean;
  /**
   * Mix & Master Stage 1: the engine analyzes this project's song
   * in 1.0 s windows and renders a copy with the harsh/muddy bands
   * pulled down along a smoothed curve (cuts only), which
   * composition builds then use in place of the original file
   * (src/lib/mixMaster.ts). Undefined = OFF: Stage 1 is
   * engine-only and no UI exposes the flag yet (the toggle comes
   * with the Stage 3 screen). When on, Mix & Master REPLACES Auto
   * EQ for the song (the dynamic curve already contains the
   * per-window version of Auto EQ's static cut — running both
   * would cut twice). Recording, record-time playback and sync
   * measurement always use the original song regardless.
   */
  mixMasterEnabled?: boolean;
  /**
   * Mix & Master Stage 2: per-stage controls for the corrective
   * and master EQ stages (each stage's toggle + intensity,
   * 0–100%). Undefined = both stages ON at 100% (see
   * resolveMixMasterStageSettings in src/lib/mixMasterCurve.ts).
   * Only matters while `mixMasterEnabled` is on; the toggles and
   * intensities come with the Stage 3 screen. The native cache
   * key includes the resolved settings, so a settings change
   * re-renders the processed song.
   */
  mixMasterStages?: MixMasterStageSettings;
  /**
   * Mix & Master Stage 4: when the processed song is saved as the
   * project's track ("Use in project"), the ORIGINAL song is
   * recorded here so the user can switch back. Undefined = the
   * track was never replaced by a Mix & Master render (or it was
   * restored). The track itself stays a plain AudioTrack — the
   * render is the same song at the exact same length, so the
   * region, the EDL, the takes and the lyrics all carry over.
   */
  mixMasterSource?: { uri: string; name: string };
  /** When the project's video was last successfully rendered (Export stamps it). */
  exportedAt?: number;
}
