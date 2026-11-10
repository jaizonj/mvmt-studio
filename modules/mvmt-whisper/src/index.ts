import { requireOptionalNativeModule } from 'expo';

/**
 * MvmtWhisper — MVMT Studio's on-device lyrics detection engine
 * (iOS only): whisper.cpp running the Whisper **small** model
 * (multilingual) with DTW word-level timestamps. Detection only —
 * there is no lyrics lookup anywhere in this module.
 *
 * This is a LOCAL Expo module with custom native code: it only exists
 * in development / sideload builds. In Expo Go the module is not
 * linked — `isWhisperAvailable()` is false and the async functions
 * throw. App code should go through `src/lib/whisper.ts`, which adds
 * the typed `WhisperUnavailableError` on top of this binding.
 *
 * The model (~488 MB) is NOT bundled with the app. `ensureModel`
 * downloads it once into app storage; `transcribe` throws until
 * `modelState()` reports 'ready'.
 */

export interface WhisperWord {
  /** The word (no surrounding whitespace). */
  text: string;
  /** Song-absolute seconds. */
  startSeconds: number;
  /** Song-absolute seconds, always >= startSeconds. */
  endSeconds: number;
}

export interface WhisperSegment {
  /** The segment's full text (a sung phrase, roughly a line). */
  text: string;
  /** Song-absolute seconds. */
  startSeconds: number;
  /** Song-absolute seconds. */
  endSeconds: number;
  /** Word timings inside the segment — powers karaoke highlighting. */
  words: WhisperWord[];
}

export interface WhisperTranscription {
  /** Detected language code (e.g. 'en'). */
  language: string;
  segments: WhisperSegment[];
}

export type WhisperModelState = 'absent' | 'downloading' | 'ready' | 'failed';

export interface WhisperProgressEvent {
  /** 0...1 */
  progress: number;
}

type Listener<T> = (event: T) => void;
interface Subscription {
  remove(): void;
}

interface NativeMvmtWhisperModule {
  ensureModel(): Promise<void>;
  modelState(): Promise<WhisperModelState>;
  transcribe(audioUri: string): Promise<WhisperTranscription>;
  addListener(
    eventName: 'onModelDownloadProgress',
    listener: Listener<WhisperProgressEvent>,
  ): Subscription;
  addListener(
    eventName: 'onTranscribeProgress',
    listener: Listener<WhisperProgressEvent>,
  ): Subscription;
}

// Optional require: null (never throws) in Expo Go or any build where
// the native module was not linked.
const nativeModule = requireOptionalNativeModule<NativeMvmtWhisperModule>('MvmtWhisper');

/**
 * True only when the native MvmtWhisper module is linked into the
 * running binary — i.e. in a development/sideload build, never in
 * Expo Go.
 */
export function isWhisperAvailable(): boolean {
  return nativeModule != null;
}

function requireModule(): NativeMvmtWhisperModule {
  if (!nativeModule) {
    throw new Error(
      'MvmtWhisper is not available in this build. On-device lyrics detection needs a ' +
        'development or sideload build of MVMT Studio — it cannot run in Expo Go.',
    );
  }
  return nativeModule;
}

/**
 * Downloads the Whisper small model (~488 MB) unless it is already on
 * disk. Subscribe with `addModelDownloadProgressListener` for 0...1
 * progress. Rejects when the download fails (state becomes 'failed').
 */
export async function ensureModel(): Promise<void> {
  return requireModule().ensureModel();
}

/** The model's on-disk state. */
export async function modelState(): Promise<WhisperModelState> {
  return requireModule().modelState();
}

/**
 * Transcribes a local audio file (`file://` URI or plain path) into
 * word-timed segments, in song-absolute seconds. Throws when the
 * model is not downloaded yet — call `ensureModel` first.
 */
export async function transcribe(audioUri: string): Promise<WhisperTranscription> {
  return requireModule().transcribe(audioUri);
}

export function addModelDownloadProgressListener(
  listener: Listener<WhisperProgressEvent>,
): Subscription {
  if (!nativeModule) return { remove: () => {} };
  return nativeModule.addListener('onModelDownloadProgress', listener);
}

export function addTranscribeProgressListener(
  listener: Listener<WhisperProgressEvent>,
): Subscription {
  if (!nativeModule) return { remove: () => {} };
  return nativeModule.addListener('onTranscribeProgress', listener);
}
