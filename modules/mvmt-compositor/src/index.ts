import { requireOptionalNativeModule } from 'expo';

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
  /** When true, the clip's own audio is dropped entirely. */
  muted: boolean;
  /** Volume of the clip's own audio when not muted (0–1). */
  volume: number;
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
  /** Output frame rate / composition frameDuration. Default 30. */
  frameRate?: number;
  /** Caller-chosen id for progress events + cancellation. Optional. */
  exportId?: string;
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
