import { requireOptionalNativeModule } from 'expo';

/**
 * MvmtCompositor — MVMT Studio's native video compositing engine (iOS only).
 *
 * Renders a timeline of trimmed video clips into ONE mp4 file with the
 * master audio track laid over it, using AVFoundation on the device.
 *
 * This is a LOCAL Expo module with custom native code, so it only exists
 * in development / EAS builds of the app. Inside Expo Go the native module
 * is not linked: `isCompositorAvailable()` returns false and
 * `renderVideo()` throws a clear error instead of crashing.
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
}

export interface CompositeResult {
  /** `file://` URI of the rendered mp4 (in the app caches directory). */
  uri: string;
  /** Total duration of the rendered video, in seconds. */
  durationSeconds: number;
  /** Rendered frame width in pixels (display size, rotation applied). */
  width: number;
  /** Rendered frame height in pixels (display size, rotation applied). */
  height: number;
}

interface NativeMvmtCompositorModule {
  renderVideo(request: CompositeRequest): Promise<CompositeResult>;
}

// Optional require: null (never throws) in Expo Go or any build where the
// native module was not linked.
const nativeModule = requireOptionalNativeModule<NativeMvmtCompositorModule>('MvmtCompositor');

/**
 * True only when the native MvmtCompositor module is linked into the
 * running binary — i.e. in a development/EAS build, never in Expo Go.
 */
export function isCompositorAvailable(): boolean {
  return nativeModule != null;
}

/**
 * Render the timeline described by `request` into a single mp4.
 *
 * Rejects with a clear Error when the native module is unavailable
 * (Expo Go), when the request has no clips, or when the native render
 * itself fails (unreadable source, missing track, export failure).
 */
export async function renderVideo(request: CompositeRequest): Promise<CompositeResult> {
  if (!nativeModule) {
    throw new Error(
      'MvmtCompositor is not available in this build. Native video compositing needs a ' +
        'development or EAS build of MVMT Studio — it cannot run in Expo Go.',
    );
  }
  if (!request.clips || request.clips.length === 0) {
    throw new Error('MvmtCompositor.renderVideo requires at least one clip.');
  }
  return nativeModule.renderVideo(request);
}
