import * as DocumentPicker from 'expo-document-picker';
import * as ImagePicker from 'expo-image-picker';

import { inspectAsset, isCompositorAvailable } from './compositor';
import { measureTakeDurationSeconds, persistTake } from './media';

/**
 * Imported videos — "add whatever video you want and sync it to the
 * audio" (Jaizon, 2026-11-10).
 *
 * A picked video becomes a first-class TAKE: it is copied into the
 * app's own takes folder (same stewardship as a recorded take, so it
 * survives picker-cache cleanup), probed for its real duration and
 * frame size, and from then on is indistinguishable from a recorded
 * take to the shuffle, the editor and the exporter — except for its
 * `source: 'imported'` marker, which keeps it out of the EDL canvas
 * vote (canvasForTakes) and drives its sync wording. The actual
 * sound-matching lives in record.tsx (`syncImportedTake`), beside the
 * recorded takes' file-correlation refinement it mirrors.
 */

/**
 * Sanity cap on import length. The sync measurement decodes the
 * video's whole audio track, and the shuffle treats takes as
 * song-scale material — an hour is already far beyond any song.
 * Longer files get a plain "trim it" message instead of a hang.
 */
export const MAX_IMPORT_DURATION_SECONDS = 3600;

/** A video chosen in a picker, before it is copied into the sandbox. */
export interface PickedVideo {
  /** Picker URI (photo-library passthrough copy or document-picker cache). */
  uri: string;
  /** Original file name, when the picker reports one (display only). */
  name?: string;
  fileSizeBytes?: number;
  /** Picker-reported duration in seconds, when known (library picks). */
  durationSeconds?: number;
  /** Picker-reported display size, when known (library picks). */
  width?: number;
  height?: number;
}

export type VideoPickResult =
  | { status: 'picked'; video: PickedVideo }
  | { status: 'cancelled' }
  /** Photo-library permission was refused (library picks only). */
  | { status: 'denied' };

/**
 * Pick a video from the photo library. Media-library permission is
 * requested FIRST: with the default Passthrough export the picker
 * returns the ORIGINAL file (HEVC/ProRes included), and iOS otherwise
 * shows its permission dialog after the selection instead of before.
 * No picker editing UI — the whole file is imported as-is.
 */
export async function pickVideoFromLibrary(): Promise<VideoPickResult> {
  const permission = await ImagePicker.requestMediaLibraryPermissionsAsync();
  if (!permission.granted) return { status: 'denied' };
  const result = await ImagePicker.launchImageLibraryAsync({
    mediaTypes: ['videos'],
    allowsEditing: false,
    // Passthrough (the default) returns the original asset untouched.
    videoExportPreset: ImagePicker.VideoExportPreset.Passthrough,
  });
  if (result.canceled || result.assets.length === 0) return { status: 'cancelled' };
  const asset = result.assets[0];
  return {
    status: 'picked',
    video: {
      uri: asset.uri,
      name: asset.fileName ?? undefined,
      fileSizeBytes: asset.fileSize ?? undefined,
      // The picker's video duration is in MILLISECONDS.
      durationSeconds: asset.duration != null && asset.duration > 0 ? asset.duration / 1000 : undefined,
      width: asset.width > 0 ? asset.width : undefined,
      height: asset.height > 0 ? asset.height : undefined,
    },
  };
}

/**
 * Pick a video from Files / iCloud / downloads via the system
 * document picker (the photo-library picker cannot browse those).
 * `copyToCacheDirectory` gives expo-file-system a readable copy,
 * exactly like the audio-track pick in media.ts.
 */
export async function pickVideoFromFiles(): Promise<VideoPickResult> {
  const result = await DocumentPicker.getDocumentAsync({
    type: ['video/*', 'public.movie'],
    multiple: false,
    copyToCacheDirectory: true,
  });
  if (result.canceled || result.assets.length === 0) return { status: 'cancelled' };
  const asset = result.assets[0];
  return {
    status: 'picked',
    video: {
      uri: asset.uri,
      name: asset.name,
      fileSizeBytes: asset.size ?? undefined,
    },
  };
}

/** Measured facts about an imported file, ready to become a Take. */
export interface ImportedVideoProbe {
  /** Take id (the same id scheme recorded takes get in persistTake). */
  id: string;
  /** file:// URI inside the app's takes folder. */
  uri: string;
  durationSeconds: number;
  width?: number;
  height?: number;
  fileSizeBytes?: number;
}

export type ImportProbeResult =
  | { ok: true; probe: ImportedVideoProbe }
  | { ok: false; message: string };

/**
 * Copy a picked video into the app's takes folder and measure it.
 * The probe runs on the COPIED file (what the app actually keeps):
 * the native inspector when the compositor is linked (duration,
 * display size, and a real has-video check — AVFoundation reads
 * HEVC/ProRes originals natively), otherwise the JS player probe for
 * duration plus whatever the picker reported. A file with no video
 * track, an unreadable/zero duration, or a length past the sanity
 * cap is rejected with a plain message and never becomes a take.
 */
export async function importPickedVideo(picked: PickedVideo): Promise<ImportProbeResult> {
  const saved = await persistTake(picked.uri);

  let durationSeconds: number | null = null;
  let width = picked.width;
  let height = picked.height;

  if (isCompositorAvailable()) {
    try {
      const info = await inspectAsset(saved.uri);
      if (!info.hasVideo) {
        return { ok: false, message: "That file doesn't seem to contain video." };
      }
      if (info.durationSeconds > 0) durationSeconds = info.durationSeconds;
      if (info.width > 0 && info.height > 0) {
        width = info.width;
        height = info.height;
      }
    } catch {
      // Native inspection failed — fall through to the JS probe.
    }
  }
  if (durationSeconds === null) {
    durationSeconds = (await measureTakeDurationSeconds(saved.uri)) ?? picked.durationSeconds ?? null;
  }
  if (durationSeconds === null || durationSeconds <= 0) {
    return {
      ok: false,
      message: "Couldn't read that video — it may be in a format this app can't open yet.",
    };
  }
  if (durationSeconds > MAX_IMPORT_DURATION_SECONDS) {
    return {
      ok: false,
      message: "That video is over an hour long — trim it to the part you need, then add it again.",
    };
  }
  return {
    ok: true,
    probe: {
      id: saved.id,
      uri: saved.uri,
      durationSeconds,
      ...(width ? { width } : {}),
      ...(height ? { height } : {}),
      ...(saved.fileSizeBytes ?? picked.fileSizeBytes
        ? { fileSizeBytes: saved.fileSizeBytes ?? picked.fileSizeBytes }
        : {}),
    },
  };
}
