import * as DocumentPicker from 'expo-document-picker';
import { Directory, File, Paths } from 'expo-file-system';
import * as MediaLibrary from 'expo-media-library/legacy';
import * as Sharing from 'expo-sharing';
import { createVideoPlayer } from 'expo-video';

import { inspectAsset, isCompositorAvailable } from './compositor';
import type { AudioTrack } from '../types';

function makeId(prefix: string): string {
  return `${prefix}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

function extensionOf(nameOrUri: string, fallback: string): string {
  const clean = nameOrUri.split('?')[0];
  const dot = clean.lastIndexOf('.');
  if (dot === -1 || dot === clean.length - 1) return fallback;
  return clean.slice(dot + 1).toLowerCase();
}

/**
 * Copy a file from a temporary location (camera cache / document-picker
 * cache) into the app's persistent documents folder, and return the new URI.
 * Falls back to the original URI if the copy fails — a take in cache is
 * still better than no take, it just may not survive an app restart.
 */
async function persistFile(sourceUri: string, folder: string, baseName: string, ext: string): Promise<string> {
  try {
    const dir = new Directory(Paths.document, folder);
    if (!dir.exists) dir.create();
    const destination = new File(dir, `${baseName}.${ext}`);
    await new File(sourceUri).copy(destination);
    return destination.uri;
  } catch {
    return sourceUri;
  }
}

/**
 * Open the system document picker for an audio file and copy the pick into
 * the app sandbox. Returns null if the user cancelled.
 *
 * Uses expo-document-picker (not a media-library browse) so audio from
 * Files / iCloud / downloads works, which is how most people will add a
 * track they produced or downloaded.
 */
export async function pickAudioTrack(): Promise<AudioTrack | null> {
  const result = await DocumentPicker.getDocumentAsync({
    type: ['audio/*', 'public.audio'],
    multiple: false,
    // copyToCacheDirectory lets expo-file-system read the file straight away
    // (required on iOS for files outside the sandbox).
    copyToCacheDirectory: true,
  });
  if (result.canceled || result.assets.length === 0) return null;

  const asset = result.assets[0];
  const id = makeId('track');
  const uri = await persistFile(asset.uri, 'tracks', id, extensionOf(asset.name, 'm4a'));
  return { uri, name: asset.name };
}

/**
 * Read a video file's TRUE duration (seconds) by loading it in a
 * throwaway expo-video player. Best-effort: resolves null on timeout or
 * error so callers can fall back to their measured duration. Added after
 * Jaizon's device test where saved takes reported durations that did
 * not match what was actually recorded — the file itself is the only
 * trustworthy source.
 */
export async function probeVideoDurationSeconds(uri: string, timeoutMs = 2500): Promise<number | null> {
  let player: ReturnType<typeof createVideoPlayer> | null = null;
  try {
    player = createVideoPlayer(uri);
    const activePlayer = player;
    const duration = await new Promise<number | null>((resolve) => {
      let settled = false;
      const finish = (value: number | null) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolve(value);
      };
      const timer = setTimeout(() => finish(null), timeoutMs);
      if (activePlayer.status === 'readyToPlay') {
        finish(activePlayer.duration > 0 ? activePlayer.duration : null);
        return;
      }
      const sub = activePlayer.addListener('statusChange', ({ status }) => {
        if (status === 'readyToPlay') {
          sub.remove();
          finish(activePlayer.duration > 0 ? activePlayer.duration : null);
        } else if (status === 'error') {
          sub.remove();
          finish(null);
        }
      });
    });
    return duration;
  } catch {
    return null;
  } finally {
    try {
      player?.release();
    } catch {
      /* already released */
    }
  }
}

/**
 * A take file's MEASURED duration (seconds) — the value the EDL and the
 * sync maths trust. Prefers the native engine's `inspectAsset`
 * (AVFoundation reads the file's own duration — the ground truth) when
 * the compositor module is linked; otherwise falls back to the JS
 * player probe above. Resolves null when neither can read the file, so
 * callers keep their wall-clock fallback AND know the take's sync drift
 * is unmeasurable rather than silently assuming a duration.
 */
export async function measureTakeDurationSeconds(uri: string): Promise<number | null> {
  if (isCompositorAvailable()) {
    try {
      const info = await inspectAsset(uri);
      if (info.durationSeconds > 0) return info.durationSeconds;
    } catch {
      // Native inspection failed — fall through to the JS probe.
    }
  }
  return probeVideoDurationSeconds(uri);
}

/** Move a freshly recorded take out of the camera cache into documents. */
export async function persistTake(
  cacheUri: string,
): Promise<{ id: string; uri: string; fileSizeBytes?: number }> {
  const id = makeId('take');
  const uri = await persistFile(cacheUri, 'takes', id, extensionOf(cacheUri, 'mov'));
  let fileSizeBytes: number | undefined;
  try {
    const size = new File(uri).size;
    if (size > 0) fileSizeBytes = size;
  } catch {
    // Size is only a heuristic input (take energy) — never block a take on it.
  }
  return { id, uri, fileSizeBytes };
}

/**
 * Save a video file to the user's photo library. Requests permission first.
 * Returns false (and does not throw) if the user declines — the caller
 * shows a message instead of crashing.
 */
export async function saveToPhotoLibrary(uri: string): Promise<boolean> {
  try {
    const permission = await MediaLibrary.requestPermissionsAsync(false, ['video']);
    if (!permission.granted) return false;
    await MediaLibrary.saveToLibraryAsync(uri);
    return true;
  } catch {
    return false;
  }
}

/** Open the system share sheet for a file, if sharing is available. */
export async function shareFile(uri: string, mimeType?: string): Promise<boolean> {
  try {
    if (!(await Sharing.isAvailableAsync())) return false;
    await Sharing.shareAsync(uri, mimeType ? { mimeType } : undefined);
    return true;
  } catch {
    return false;
  }
}
