import { requireNativeView, requireOptionalNativeModule } from 'expo';
import { createElement, type ComponentType } from 'react';
import type { ViewStyle } from 'react-native';

/**
 * MvmtCompositor — MVMT Studio's native media engine (iOS only).
 *
 * ONE AVFoundation composition builder powers BOTH the native preview
 * player and the exporter, so what you preview is exactly what renders
 * (Overhaul Phase 1 contract — see modules/mvmt-compositor/README.md
 * for the full v2 spec the Swift side implements).
 *
 * This is a LOCAL Expo module with custom native code: it only exists in
 * development / EAS / sideload builds. In Expo Go the module is not
 * linked — `isCompositorAvailable()` is false and every function throws
 * or no-ops with a clear error instead of crashing.
 */

export interface CompositeClipInput {
  /** Clip source: a `file://` URI or an absolute file path. */
  uri: string;
  /** Where the used range starts inside the source clip, in seconds. */
  startSeconds: number;
  /** How much of the clip to use, in seconds. */
  durationSeconds: number;
  /**
   * Playback rate of the clip's VIDEO (0.25–2, default 1): 0.5 plays
   * the source at half speed (twice as long on the timeline), 2 at
   * double speed. The native builder re-times the range with
   * `scaleTimeRange`, so preview and export honour it identically.
   * The master song is untouched — it always plays at 1x over the
   * whole cut. When the clip's own audio is included it is retimed
   * with the video, so A/V stay in sync (pitch follows the rate,
   * as in any slow-mo/fast-mo).
   */
  speed?: number;
  /** When true, the clip's own audio is dropped entirely. */
  muted: boolean;
  /** Volume of the clip's own audio when not muted (0–1). */
  volume: number;
}

/** One timed word inside a composite lyric line (composition seconds). */
export interface CompositeLyricWord {
  text: string;
  startSeconds: number;
  endSeconds: number;
}

/** One lyric line in COMPOSITION seconds (already song→timeline mapped). */
export interface CompositeLyricLine {
  text: string;
  startSeconds: number;
  endSeconds: number;
  words?: CompositeLyricWord[];
  /**
   * Stored lyric intelligence (Styles Redesign Stage 2) — only
   * emitted when an Extra Style template is active. Renderers read
   * these, they never compute them.
   */
  emoji?: string;
  tone?: 'joy' | 'sad' | 'anger' | 'love' | 'hype';
  /** Word indices (into `words`, or into the line's whitespace
   *  tokens when it has none) to emphasize. */
  emphasisWordIndices?: number[];
}

/**
 * The animation parameters a lyric style resolves to — the full
 * parametric model from src/lib/lyricAnimations.ts, whose header is
 * the shared renderer spec both the JS overlay and the native text
 * renderer implement. The native side applies these generically; it
 * has no preset catalog.
 */
export interface LyricAnimationParams {
  enterSecs: number;
  exitSecs: number;
  fromOpacity: number;
  fromXOffsetFrac: number;
  fromYOffsetFrac: number;
  fromScale: number;
  fromRotateDeg: number;
  wordMode: 'none' | 'stagger' | 'karaoke' | 'typewriter';
  wordStaggerSecs: number;
  emphasisScale: number;
}

/**
 * A lyric style with every choice RESOLVED: the font is a PostScript
 * name (the native renderer looks it up directly; bold already folded
 * in when the family has a real bold face), and the animation is the
 * parameter set above.
 */
export interface ResolvedLyricStyle {
  fontPostScriptName: string;
  /** Font size as a fraction of the canvas WIDTH. */
  sizeRatio: number;
  color: string;
  strokeColor?: string;
  /** Outline width as a fraction of the font size. */
  strokeWidthRatio?: number;
  background: 'none' | 'pill';
  backgroundColor?: string;
  position: 'top' | 'center' | 'bottom';
  /** Fine vertical nudge, fraction of the canvas height,
   * positive = up. Always emitted (0 when unset). */
  verticalOffsetRatio: number;
  /** Maximum line width, fraction of the canvas width.
   * Always emitted (0.88 when unset). */
  maxWidthRatio: number;
  bold: boolean;
  animation: LyricAnimationParams;
}

/**
 * An Extra Style template's decor, RESOLVED (Styles Redesign
 * Stage 2): every field present, defaults folded in by
 * `resolveLyricDecor`. The native side applies it generically —
 * one CALayer-subtree builder per `kind` — it has no template
 * catalog. Absent = classic style, no decor.
 */
export interface ResolvedLyricDecor {
  kind:
    | 'emoji-row'
    | 'chat-bubble'
    | 'comic-burst'
    | 'sticker-frame'
    | 'scanlines'
    | 'glow'
    | 'cursor'
    | 'burst'
    | 'pill';
  /** Accent colour (#RRGGBB or rgba()). */
  color: string;
  /** Second colour. */
  secondaryColor: string;
  /** 0..1. */
  opacity: number;
  /** Size multiplier. */
  scale: number;
  /** Free text (e.g. the comic burst word). */
  text: string;
}

/** The lyrics payload of a composite request (composition seconds). */
export interface CompositeLyrics {
  lines: CompositeLyricLine[];
  style: ResolvedLyricStyle;
  /** Extra Style decor — present only when a template is active. */
  decor?: ResolvedLyricDecor;
}

export interface CompositeRequest {
  /** The timeline: clips are laid end-to-end in array order. */
  clips: CompositeClipInput[];
  /** Master audio track (music) laid over the whole cut. Optional. */
  audioUri?: string | null;
  /** Where to start inside the master track, in seconds. Default 0. */
  audioStartSeconds?: number;
  /** Master track volume (0–1). Default 1. */
  audioVolume?: number;
  /** Output canvas width in pixels. Default 1080 (9:16 portrait). */
  canvasWidth?: number;
  /** Output canvas height in pixels. Default 1920. */
  canvasHeight?: number;
  /**
   * Requested frame rate. Default 30 (the EDL grid); the native
   * builder floors the composition's render grid at 60fps, so this
   * never lowers the render cadence below 60.
   */
  frameRate?: number;
  /** Caller-chosen id for progress events + cancellation. Optional. */
  exportId?: string;
  /**
   * Watermark overlay (the MVMT studio logo lockup) on the rendered
   * video: semi-transparent, flipping between the top-left and
   * bottom-right corners every 5 seconds. Applies to preview and
   * export identically. Default off.
   */
  watermarkEnabled?: boolean;
  /**
   * `file://` URI or path of the transparent watermark PNG. Only used
   * when `watermarkEnabled` is true; if the image cannot be loaded
   * the video renders without a watermark rather than failing.
   */
  watermarkImageUri?: string | null;
  /**
   * Lyrics burned into the EXPORT render (timed text layers in the
   * same animation tool as the watermark). Like the watermark, this
   * is EXPORT-ONLY: preview compositions are built tool-free (a
   * composition carrying the tool throws when assigned to a player
   * item), and previews draw the identical payload through the JS
   * LyricsOverlay instead. Null/absent = no lyrics.
   */
  lyrics?: CompositeLyrics | null;
  /**
   * A resolved video look (src/lib/looks.ts — preset + intensity +
   * overrides already folded into ONE numeric param set by the JS
   * side; the engine applies the numbers blindly as a CI filter
   * chain). Unlike the watermark/lyrics this DOES apply to previews:
   * the grade is part of the composition itself, so the editor
   * preview and the export render show the same picture. Null/absent
   * (or the identity set) = no filtering.
   */
  look?: ResolvedLookParams | null;
  /**
   * EXPORT SIZE CONTROL — render-only fields: they never touch the
   * composition, so the preview built from this same request stays a
   * truthful picture of the cut; they only change how the rendered
   * FILE is encoded. AVAssetExportSession can't take a bitrate, so
   * when either field is set the engine renders as usual and then
   * transcodes the finished file (reader → writer) at an explicit
   * video bitrate: `exportVideoBitrate` directly, or one computed
   * from `exportTargetSizeMB` and the measured duration. Absent =
   * the render is delivered exactly as the export session wrote it.
   */
  exportVideoBitrate?: number | null;
  /** Target TOTAL file size in MB (1 MB = 1,000,000 bytes). */
  exportTargetSizeMB?: number | null;
  /** Codec for the size-control transcode. Default 'h264'. */
  exportCodec?: 'h264' | 'hevc' | null;
  /**
   * Auto volume: when true, the engine measures the master song's
   * loudness (K-weighted LUFS + sample peak, BS.1770-style) and gains
   * the song inside the composition to the platform level (−14 LUFS,
   * peaks capped at −1 dBFS). Part of the composition, so previews
   * and exports agree. Absent/false = unity gain, the historical
   * behaviour. Measurement failure or silence leaves the gain at
   * unity, silently. Record-time playback and sync measurement are
   * never affected — only the built composition.
   */
  normalizeVolume?: boolean;
}

/**
 * A video look with every choice RESOLVED to numbers (src/lib/looks.ts
 * does the resolving; this mirrors types.ts LookParams). The native
 * side maps the set onto a Core Image chain: CIExposureAdjust →
 * CITemperatureAndTint → CIColorControls → CIVibrance →
 * CISharpenLuminance → CIVignette, skipping stages at identity.
 */
export interface ResolvedLookParams {
  brightness: number;
  contrast: number;
  saturation: number;
  exposureEV: number;
  /** Warmth offset on the 6500K CI neutral (positive = warmer). */
  temperature: number;
  vibrance: number;
  sharpen: number;
  vignette: number;
}

export interface CompositeResult {
  /** `file://` URI of the rendered mp4 (in the app caches directory). */
  uri: string;
  /**
   * MEASURED duration of the written file, in seconds — read back from
   * the rendered asset, never the requested duration.
   */
  durationSeconds: number;
  /** Measured frame width of the written file (display size). */
  width: number;
  /** Measured frame height of the written file (display size). */
  height: number;
  /**
   * MEASURED byte size of the delivered file (after any size-control
   * transcode). Optional: absent in older native builds.
   */
  fileSizeBytes?: number;
  /**
   * The video bitrate (bps) the size-control transcode actually
   * applied, when one ran — including a corrective second pass.
   * Null/absent when the file is the untouched export-session render.
   */
  appliedVideoBitrate?: number | null;
  /**
   * The loudness gain (dB) auto volume applied to the song inside
   * the composition, when the request asked for normalization and a
   * measurement produced one. Null/absent when the toggle was off,
   * the song couldn't be measured, or it counted as silence.
   */
  appliedGainDb?: number | null;
}

/** Measured facts about a media file, from the native inspector. */
export interface AssetInfo {
  durationSeconds: number;
  /** Display size (rotation applied). 0 when the file has no video track. */
  width: number;
  height: number;
  /** Nominal frame rate of the first video track, 0 when unknown. */
  frameRate: number;
  hasVideo: boolean;
  hasAudio: boolean;
  /**
   * Start time of the first video track inside the file, in seconds (its
   * timeRange start — where the first frame sits on the asset timeline).
   * Optional: absent in older native builds; 0 when there is no video track.
   */
  videoStartSeconds?: number;
  /**
   * Start time of the first audio track inside the file, in seconds.
   * Optional: absent in older native builds; 0 when there is no audio track.
   */
  audioStartSeconds?: number;
  /**
   * Duration of the first video track's timeRange, in seconds.
   * Optional: absent in older native builds; 0 when there is no video track.
   */
  videoDurationSeconds?: number;
  /**
   * Duration of the first audio track's timeRange, in seconds.
   * Optional: absent in older native builds; 0 when there is no audio track.
   */
  audioDurationSeconds?: number;
}

/**
 * Outcome of a native per-take sync measurement (`measureTakeSync`).
 *
 * - `measured` — the mic audio correlated confidently with the master
 *   song; `songPositionAtFirstFrameSeconds` is set.
 * - `noSongInMic` — the take has no audio track, or its audio is too
 *   quiet to contain the song (e.g. recorded with earbuds).
 * - `lowConfidence` — a best alignment was found but failed the
 *   confidence gates; the numbers are diagnostics only and
 *   `songPositionAtFirstFrameSeconds` is null so callers cannot
 *   accidentally apply the correction.
 * - `outOfWindow` — the best alignment falls outside the search window
 *   around the expected position.
 * - `error` — the measurement could not run (missing/unreadable file,
 *   decode failure).
 */
export type TakeSyncStatus = 'measured' | 'noSongInMic' | 'lowConfidence' | 'outOfWindow' | 'error';

/** Result of measuring a take's true sync offset from its recorded file. */
export interface TakeSyncMeasurement {
  status: TakeSyncStatus;
  /**
   * Song position (seconds into the master song) at the take's first
   * VIDEO frame. Only set when `status` is `'measured'`.
   */
  songPositionAtFirstFrameSeconds: number | null;
  /**
   * Intra-file A/V offset δ = audioTrack.start − videoTrack.start, in
   * seconds — a pure file fact, set whenever both tracks exist, even
   * when the correlation itself was not confident.
   */
  intraFileAvOffsetSeconds: number | null;
  /** Normalised correlation ρ ∈ [0, 1] at the refined peak. */
  confidence: number | null;
  /** Peak / second-peak ratio (second peak ≥ 50 ms from the winner). */
  peakRatio: number | null;
}

/** Result of `waveformPeaks` — real decoded waveform peaks. */
export interface WaveformPeaks {
  /**
   * Normalised per-bucket peak amplitudes (0..1, floored natively at
   * ~0.06 so quiet sections still render), evenly spaced across the
   * track's duration.
   */
  peaks: number[];
  /** Track duration in seconds — the span the buckets cover. */
  durationSeconds: number;
}

/** Arguments for `startCapture` (the native song-synced recorder). */
export interface CaptureStartArgs {
  /**
   * Master song file (`file://` URI or absolute path), or null to
   * record without a song clock (video + mic only — the result's
   * `firstFrameSongPositionSeconds` will be null).
   */
  songUri: string | null;
  /** Where to start inside the master song, in seconds. */
  songStartSeconds: number;
  /**
   * Native safety stop: the capture finishes itself at this duration
   * so a hung JS side can never record forever. <= 0 = no limit.
   */
  maxDurationSeconds: number;
}

/** Result of `stopCapture` — measured from the written file. */
export interface CaptureResult {
  /** `file://` URI of the recorded mp4 (app caches directory). */
  uri: string;
  /** MEASURED duration of the written file, in seconds. */
  durationSeconds: number;
  /** Measured frame width of the written file (display size). */
  width: number;
  /** Measured frame height of the written file (display size). */
  height: number;
  /**
   * The master song's position (seconds, same timeline as
   * `CaptureStartArgs.songStartSeconds`) at the FIRST captured video
   * frame — measured natively: the coordinator owns both clocks (an
   * AVPlayer for the song and the capture session), and converts the
   * first frame's host-clock presentation timestamp through the
   * player item's host-time mapping. Null when no song was supplied
   * or the player wasn't ready/playing when the first frame landed.
   */
  firstFrameSongPositionSeconds: number | null;
  /**
   * Intra-file A/V offset of the written file:
   * audioTrack.start − videoTrack.start, in seconds. Null when the
   * file has no audio track.
   */
  intraFileAvOffsetSeconds: number | null;
}

/** Props for the `CapturePreview` native view. */
export interface CapturePreviewProps {
  facing: 'front' | 'back';
  torch: boolean;
  /**
   * Expo-style zoom 0..1 — mapped natively to a device zoom factor of
   * 1 + zoom × 5, clamped to the device's maximum.
   */
  zoom: number;
  /**
   * Front-camera mirroring, applied consistently to the preview and
   * the recorded file (matching expo-camera's mirror preference).
   */
  mirrored: boolean;
  /** Keeps the capture session running (live preview) while true. */
  active: boolean;
  style?: ViewStyle;
}

export interface ExportProgressEvent {
  exportId: string;
  /** 0..1 */
  progress: number;
}

export type PreviewStatus = 'loading' | 'ready' | 'playing' | 'paused' | 'ended' | 'error';

export interface PreviewProgressEvent {
  previewId: string;
  positionSeconds: number;
  durationSeconds: number;
  playing: boolean;
}

export interface PreviewStatusEvent {
  previewId: string;
  status: PreviewStatus;
  message?: string;
}

type Listener<T> = (event: T) => void;
interface Subscription {
  remove(): void;
}

interface NativeMvmtCompositorModule {
  renderVideo(request: CompositeRequest): Promise<CompositeResult>;
  cancelExport(exportId: string): Promise<void>;
  inspectAsset(uri: string): Promise<AssetInfo>;
  measureTakeSync(
    takeUri: string,
    songUri: string,
    expectedSongPositionAtTakeStartSeconds: number,
    searchWindowSeconds: number,
  ): Promise<TakeSyncMeasurement>;
  waveformPeaks(uri: string, buckets: number): Promise<WaveformPeaks | null>;
  prepareEqSong(uri: string): Promise<string>;
  prepareMixMasterSong(uri: string): Promise<string>;
  isCaptureAvailable(): boolean;
  startCapture(args: CaptureStartArgs): Promise<void>;
  stopCapture(): Promise<CaptureResult>;
  prepareSong(songUri: string | null): Promise<void>;
  setCaptureQuality(quality: string): Promise<void>;
  setCaptureStabilization(enabled: boolean): Promise<void>;
  setCaptureExposureLock(enabled: boolean): Promise<void>;
  createPreview(request: CompositeRequest): Promise<string>;
  setPreviewPaused(previewId: string, paused: boolean): Promise<void>;
  seekPreview(previewId: string, seconds: number): Promise<void>;
  releasePreview(previewId: string): Promise<void>;
  addListener(eventName: 'onExportProgress', listener: Listener<ExportProgressEvent>): Subscription;
  addListener(eventName: 'onPreviewProgress', listener: Listener<PreviewProgressEvent>): Subscription;
  addListener(eventName: 'onPreviewStatus', listener: Listener<PreviewStatusEvent>): Subscription;
}

// Optional require: null (never throws) in Expo Go or any build where the
// native module was not linked.
const nativeModule = requireOptionalNativeModule<NativeMvmtCompositorModule>('MvmtCompositor');

/**
 * True only when the native MvmtCompositor module is linked into the
 * running binary — i.e. in a development/EAS/sideload build, never in
 * Expo Go.
 */
export function isCompositorAvailable(): boolean {
  return nativeModule != null;
}

function requireModule(): NativeMvmtCompositorModule {
  if (!nativeModule) {
    throw new Error(
      'MvmtCompositor is not available in this build. The native media engine needs a ' +
        'development or sideload build of MVMT Studio — it cannot run in Expo Go.',
    );
  }
  return nativeModule;
}

/**
 * Render the timeline described by `request` into a single mp4.
 * The result's duration/size are MEASURED from the written file.
 * Progress arrives via `addExportProgressListener` (keyed by the
 * request's `exportId`); `cancelExport(exportId)` aborts the render.
 */
export async function renderVideo(request: CompositeRequest): Promise<CompositeResult> {
  const mod = requireModule();
  if (!request.clips || request.clips.length === 0) {
    throw new Error('MvmtCompositor.renderVideo requires at least one clip.');
  }
  return mod.renderVideo(request);
}

export async function cancelExport(exportId: string): Promise<void> {
  if (!nativeModule) return;
  return nativeModule.cancelExport(exportId);
}

/** Measure a media file natively (true duration, display size, fps, tracks). */
export async function inspectAsset(uri: string): Promise<AssetInfo> {
  return requireModule().inspectAsset(uri);
}

/**
 * Measure a take's TRUE sync offset from the recorded file itself —
 * the replacement for the JS player-position estimate sampled before
 * `recordAsync` (which misses the camera's variable spin-up time).
 *
 * Natively: the take's per-track timeRanges give the intra-file A/V
 * offset, and the take's mic audio (which captured the song playing
 * aloud) is cross-correlated against the master song — a coarse
 * envelope pass over the search window, then a sample-accurate raw-PCM
 * refinement. The result is the song position at the take's first
 * video frame.
 *
 * Expected failure modes (no song in the mic track, low correlation
 * confidence, alignment outside the window, unreadable files) are
 * reported via `TakeSyncMeasurement.status`, NOT thrown. Only call
 * this when `isCompositorAvailable()` — like `inspectAsset`, it throws
 * the "not available in this build" error when the module is missing.
 *
 * @param takeUri  The recorded take (`file://` URI or absolute path).
 * @param songUri  The master song file.
 * @param expectedSongPositionAtTakeStartSeconds  The existing JS
 *   estimate of the song position at the take's audio-track start —
 *   the centre of the search window.
 * @param searchWindowSeconds  ± window around the estimate to search.
 *   Default 2. Local searches clamp at ±10s. A request BEYOND 10
 *   switches the engine to a full-song search (for imported videos,
 *   whose song can begin anywhere): pass the song's duration as both
 *   this and the expected position — the engine recentres the search
 *   on the whole song. The confidence gates are unchanged.
 */
export async function measureTakeSync(
  takeUri: string,
  songUri: string,
  expectedSongPositionAtTakeStartSeconds: number,
  searchWindowSeconds = 2,
): Promise<TakeSyncMeasurement> {
  return requireModule().measureTakeSync(
    takeUri,
    songUri,
    expectedSongPositionAtTakeStartSeconds,
    searchWindowSeconds,
  );
}

/**
 * Decode a track's REAL waveform peaks: per-bucket max-abs amplitudes
 * (normalised, small floor applied), streamed natively through
 * AVAssetReader at 8kHz mono so even long songs never sit fully
 * decoded in memory.
 *
 * Unlike `measureTakeSync` this NEVER throws: every failure — the
 * module not being linked (Expo Go), an older build without the
 * function, or an unreadable/undecodable file — resolves to null, and
 * callers fall back to deterministic stand-in bars (src/lib/waveform).
 *
 * @param uri     The audio file (`file://` URI or absolute path).
 * @param buckets How many evenly spaced buckets to return.
 */
export async function waveformPeaks(uri: string, buckets: number): Promise<WaveformPeaks | null> {
  if (!nativeModule || typeof nativeModule.waveformPeaks !== 'function') return null;
  try {
    const result = await nativeModule.waveformPeaks(uri, Math.round(buckets));
    if (!result || !Array.isArray(result.peaks) || result.peaks.length === 0) return null;
    return result;
  } catch {
    return null;
  }
}

/**
 * Auto EQ: asks the engine to analyze the song and, when its harsh
 * bands (2–8 kHz) measure hot against the song's own average band
 * level, render a copy with those bands pulled down (cuts only,
 * never boosts). Resolves to the URI composition builds should use:
 * the processed copy (full song, exact same duration, cached on
 * disk across launches) or — for a balanced song, an unreadable
 * file, Expo Go, or any failure — the ORIGINAL uri. Never rejects:
 * EQ must never block a preview or an export.
 *
 * Only composition builds consume the result. The recording path
 * (capture, record-time playback, sync measurement) always keeps
 * the original file.
 *
 * @param uri The original song file (`file://` URI or absolute path).
 */
export async function prepareEqSong(uri: string): Promise<string> {
  if (!nativeModule || typeof nativeModule.prepareEqSong !== 'function') return uri;
  try {
    const result = await nativeModule.prepareEqSong(uri);
    return typeof result === 'string' && result.length > 0 ? result : uri;
  } catch {
    return uri;
  }
}

/**
 * Mix & Master Stage 1: asks the engine to analyze the song in
 * 1.0 s windows (50% overlap) and render a copy with the harsh /
 * muddy bands pulled down per window, the gains smoothed across
 * windows (cuts only, never boosts). Resolves to the URI
 * composition builds should use: the processed copy (full song,
 * exact same duration, cached on disk across launches) or — for a
 * balanced song, an unreadable file, Expo Go, or any failure — the
 * ORIGINAL uri. Never rejects: Mix & Master must never block a
 * preview or an export. The smoothed profile (windows + findings)
 * is stored as JSON beside the render for the Stage 3 UI.
 *
 * Only composition builds consume the result. The recording path
 * (capture, record-time playback, sync measurement) always keeps
 * the original file.
 *
 * @param uri The original song file (`file://` URI or absolute path).
 */
export async function prepareMixMasterSong(uri: string): Promise<string> {
  if (!nativeModule || typeof nativeModule.prepareMixMasterSong !== 'function') return uri;
  try {
    const result = await nativeModule.prepareMixMasterSong(uri);
    return typeof result === 'string' && result.length > 0 ? result : uri;
  } catch {
    return uri;
  }
}

// ---------------------------------------------------------------------------
// Native capture (song-synced recorder)
//
// The capture coordinator owns BOTH clocks during recording — an
// AVPlayer playing the master song and the AVCaptureSession — so the
// result reports the song position at the first captured frame as a
// native measurement instead of a JS estimate. The preview surface is
// the `CapturePreview` view below, bound to the same capture session:
// configure it (facing/torch/zoom/mirrored) first, then startCapture
// records with that configuration.
// ---------------------------------------------------------------------------

/**
 * True when the native module is linked AND the capture stack is
 * usable on this device. False in Expo Go, in older builds without
 * the capture functions, and on devices with no camera.
 */
export function isCaptureAvailable(): boolean {
  if (!nativeModule) return false;
  return typeof nativeModule.isCaptureAvailable === 'function'
    ? nativeModule.isCaptureAvailable()
    : false;
}

/**
 * Starts a native capture with the CURRENT `CapturePreview`
 * configuration (facing/torch/zoom/mirrored). Seeks the internal song
 * player to `songStartSeconds` with zero tolerances and plays it in
 * step with capture start. Resolves once capture is actually rolling
 * (the first video frame has been written). Rejects with a clear
 * error on permission/session/writer failure so the caller can fall
 * back to expo-camera.
 */
export async function startCapture(args: CaptureStartArgs): Promise<void> {
  const mod = requireModule();
  if (typeof mod.startCapture !== 'function') {
    throw new Error(
      'Native capture is not available in this build — it needs a newer development or sideload build of MVMT Studio.',
    );
  }
  return mod.startCapture({
    songUri: args.songUri ?? null,
    songStartSeconds: args.songStartSeconds,
    maxDurationSeconds: args.maxDurationSeconds,
  });
}

/**
 * Stops the running capture, finishes the file, and resolves with
 * the measured result. If the capture already auto-finished (the
 * native max-duration safety stop), resolves with that capture's
 * stored result. Rejects when no capture is in progress or no usable
 * file was written.
 */
export async function stopCapture(): Promise<CaptureResult> {
  const mod = requireModule();
  if (typeof mod.stopCapture !== 'function') {
    throw new Error(
      'Native capture is not available in this build — it needs a newer development or sideload build of MVMT Studio.',
    );
  }
  return mod.stopCapture();
}

/**
 * Pre-warms the native song player for a track (or tears the warm
 * player down when passed null). The coordinator keeps ONE standing
 * AVPlayer+item for the song, loaded and prerolled paused, so the
 * next `startCapture` adopts it instead of paying the cold
 * item-load/preroll cost inside the record press — the first takes
 * of a session used to lag until the pipeline "caught up". Call it
 * when the Record screen is focused with a track set, and whenever
 * the track changes. Playback never starts from this call.
 *
 * Best-effort: silently no-ops in Expo Go and in older builds
 * without the function — capture creates its player on demand
 * exactly as before.
 */
export async function prepareSong(songUri: string | null): Promise<void> {
  if (!nativeModule || typeof nativeModule.prepareSong !== 'function') {
    return;
  }
  return nativeModule.prepareSong(songUri ?? null);
}

/**
 * Capture quality for the native recorder, chosen in Settings:
 * - `'1080p30'` — 1920×1080 at 30fps via session-preset steering (the
 *   default; no device format is forced).
 * - `'1080p60'` — 1920×1080 at 60fps via a ranked exact-dimension
 *   device format.
 * - `'4k60'` — 3840×2160 at 60fps, same mechanism.
 * Qualities whose format the current camera doesn't offer fall back
 * to the preset path natively — recording never breaks over a
 * preference. A change made mid-capture applies from the next take.
 */
export type CaptureQuality = '1080p30' | '1080p60' | '4k60';

/**
 * Sets the native recorder's capture quality. The value is stored on
 * the capture coordinator's configuration and the session is
 * reconfigured in place when it is already configured.
 *
 * Best-effort like `prepareSong`: silently no-ops in Expo Go and in
 * older builds without the function — capture then runs at the
 * native default ('1080p30' preset steering).
 */
export async function setCaptureQuality(quality: CaptureQuality): Promise<void> {
  if (!nativeModule || typeof nativeModule.setCaptureQuality !== 'function') {
    return;
  }
  return nativeModule.setCaptureQuality(quality);
}

/**
 * Video stabilization for the native recorder (Settings toggle,
 * default ON): when enabled the capture connections run with
 * `preferredVideoStabilizationMode = .auto` (the device picks the
 * strongest mode the active format supports); disabled = `.off`.
 * Best-effort like `setCaptureQuality`: silently no-ops in Expo Go
 * and in older builds without the function.
 */
export async function setCaptureStabilization(enabled: boolean): Promise<void> {
  if (!nativeModule || typeof nativeModule.setCaptureStabilization !== 'function') {
    return;
  }
  return nativeModule.setCaptureStabilization(enabled);
}

/**
 * Exposure lock for the native recorder (Settings toggle, default
 * ON): while a take records, the camera's exposure and white balance
 * are locked at their armed values so the picture can't breathe
 * mid-performance (walking past a window, stage lights sweeping);
 * continuous auto resumes when the take ends. A device that refuses
 * the lock simply records unlocked. Best-effort like
 * `setCaptureQuality`.
 */
export async function setCaptureExposureLock(enabled: boolean): Promise<void> {
  if (!nativeModule || typeof nativeModule.setCaptureExposureLock !== 'function') {
    return;
  }
  return nativeModule.setCaptureExposureLock(enabled);
}

type NativeCaptureViewComponent = ComponentType<CapturePreviewProps>;
let cachedCaptureView: NativeCaptureViewComponent | null | undefined;

function captureViewComponent(): NativeCaptureViewComponent | null {
  if (cachedCaptureView !== undefined) return cachedCaptureView;
  try {
    cachedCaptureView = nativeModule
      ? (requireNativeView('MvmtCompositor', 'MvmtCaptureView') as NativeCaptureViewComponent)
      : null;
  } catch {
    cachedCaptureView = null;
  }
  return cachedCaptureView;
}

/**
 * Live camera preview for native capture, bound to the same capture
 * session `startCapture` records from — what you see is exactly what
 * records. Renders nothing when the native view is unavailable (gate
 * rendering on `isCaptureAvailable()`).
 */
export function CapturePreview(props: CapturePreviewProps) {
  const Component = captureViewComponent();
  if (!Component) return null;
  return createElement(Component, props);
}

/**
 * Build the composition for `request` and create a native preview
 * player for it. Returns the previewId used by the MvmtPreviewView
 * (`previewId` prop) and the control functions below. Playback position
 * arrives via `addPreviewProgressListener` — informational only; the
 * native player owns timing and cut boundaries.
 */
export async function createPreview(request: CompositeRequest): Promise<string> {
  const mod = requireModule();
  if (!request.clips || request.clips.length === 0) {
    throw new Error('MvmtCompositor.createPreview requires at least one clip.');
  }
  return mod.createPreview(request);
}

export async function setPreviewPaused(previewId: string, paused: boolean): Promise<void> {
  if (!nativeModule) return;
  return nativeModule.setPreviewPaused(previewId, paused);
}

export async function seekPreview(previewId: string, seconds: number): Promise<void> {
  if (!nativeModule) return;
  return nativeModule.seekPreview(previewId, Math.max(0, seconds));
}

export async function releasePreview(previewId: string): Promise<void> {
  if (!nativeModule) return;
  return nativeModule.releasePreview(previewId);
}

export function addExportProgressListener(listener: Listener<ExportProgressEvent>): Subscription {
  if (!nativeModule) return { remove: () => {} };
  return nativeModule.addListener('onExportProgress', listener);
}

export function addPreviewProgressListener(listener: Listener<PreviewProgressEvent>): Subscription {
  if (!nativeModule) return { remove: () => {} };
  return nativeModule.addListener('onPreviewProgress', listener);
}

export function addPreviewStatusListener(listener: Listener<PreviewStatusEvent>): Subscription {
  if (!nativeModule) return { remove: () => {} };
  return nativeModule.addListener('onPreviewStatus', listener);
}
