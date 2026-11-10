/**
 * Whisper bridge — the JS side of the on-device transcription
 * contract, backed by the local native module in
 * `modules/mvmt-whisper` (whisper.cpp + the Whisper small model, DTW
 * word timestamps, fully on-device).
 *
 * Contract the UI codes against:
 * - Whisper SMALL runs fully on-device. The model (~488MB) is NOT
 *   bundled: `ensureModel` downloads it into app storage on first
 *   use; `modelState` reports where that stands.
 * - `transcribe(audioUri)` resolves with segments whose word timings
 *   are SONG-ABSOLUTE seconds (the audio file's own clock, from 0).
 *   Grouping them into lyric lines is src/lib/lyrics.ts's job.
 * - DETECTION ONLY — no lyrics lookup anywhere (Jaizon's scope).
 *
 * The native module only exists in development / sideload builds. In
 * Expo Go (or any build where it is not linked), `ensureModel` and
 * `transcribe` throw `WhisperUnavailableError` and `modelState`
 * reports 'absent' — the Lyrics panel surfaces that as a plain error
 * instead of pretending to detect.
 */
import {
  addModelDownloadProgressListener,
  addTranscribeProgressListener,
  ensureModel as nativeEnsureModel,
  isWhisperAvailable,
  modelState as nativeModelState,
  transcribe as nativeTranscribe,
} from '../../modules/mvmt-whisper/src/index';

export interface WhisperWordTiming {
  text: string;
  /** Song-absolute seconds. */
  startSeconds: number;
  endSeconds: number;
}

export interface WhisperSegment {
  text: string;
  /** Song-absolute seconds. */
  startSeconds: number;
  endSeconds: number;
  words: WhisperWordTiming[];
}

export type WhisperModelState = 'absent' | 'downloading' | 'ready' | 'error';

/** Thrown when the native whisper module is not linked into this build. */
export class WhisperUnavailableError extends Error {
  constructor(message = 'Whisper is not available in this build yet.') {
    super(message);
    this.name = 'WhisperUnavailableError';
  }
}

function assertAvailable(): void {
  if (!isWhisperAvailable()) {
    throw new WhisperUnavailableError();
  }
}

const clamp01 = (value: number): number => Math.min(1, Math.max(0, value));

// `modelState()` is synchronous (the UI renders from it), while the
// native state query is async — so this module keeps a cache: it
// starts at 'absent', and every async entry point below (plus an
// explicit `refreshModelState()`) keeps it truthful. The native
// module's 'failed' maps to this contract's 'error'.
let cachedState: WhisperModelState = 'absent';

export function modelState(): WhisperModelState {
  if (!isWhisperAvailable()) {
    return 'absent';
  }
  return cachedState;
}

/** Queries the native module and refreshes the cached `modelState()`. */
export async function refreshModelState(): Promise<WhisperModelState> {
  assertAvailable();
  const state = await nativeModelState();
  cachedState = state === 'failed' ? 'error' : state;
  return cachedState;
}

export async function ensureModel(onProgress?: (fraction: number) => void): Promise<void> {
  assertAvailable();
  const subscription = onProgress
    ? addModelDownloadProgressListener(({ progress }) => {
        cachedState = 'downloading';
        onProgress(clamp01(progress));
      })
    : null;
  try {
    // Prime the cache with the real state first, so `modelState()`
    // reads 'downloading' (not a stale 'absent') during a long fetch.
    const before = await refreshModelState();
    if (before !== 'ready') {
      cachedState = 'downloading';
    }
    await nativeEnsureModel();
    cachedState = 'ready';
  } catch (error) {
    cachedState = 'error';
    throw error;
  } finally {
    subscription?.remove();
  }
}

export async function transcribe(
  audioUri: string,
  onProgress?: (fraction: number) => void,
): Promise<WhisperSegment[]> {
  assertAvailable();
  if (!audioUri) {
    throw new Error('transcribe requires an audio file URI.');
  }
  const subscription = onProgress
    ? addTranscribeProgressListener(({ progress }) => {
        onProgress(clamp01(progress));
      })
    : null;
  try {
    const result = await nativeTranscribe(audioUri);
    return result.segments;
  } finally {
    subscription?.remove();
  }
}
