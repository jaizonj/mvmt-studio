/**
 * Mix & Master Stage 4 — export (pure half).
 *
 * The processed song is a normal audio file, so exporting it is
 * file work, not DSP: the WAV is the Float32 master render itself
 * (copied, never re-encoded), the AAC is a transcode of that render
 * (native `exportMixMasterAac`, AVAssetExportPresetAppleM4A —
 * 256 kbps .m4a). The render cache is NOT the export home: exports
 * live in Documents/exports, outside the cache, so they survive
 * cache eviction and show up in Files.
 *
 * "Use in project" is a project patch, deliberately NOT setTrack:
 * setTrack resets the region to the full song and clears the lyrics
 * (right for a NEW song, wrong here — the render is the SAME song
 * at the EXACT same length, so the region, the EDL, the takes and
 * the lyrics all carry over untouched). The patch turns Mix &
 * Master off (the processing is baked into the file now — leaving
 * it on would process the processed song) and Auto EQ off for the
 * same reason, and records the original song in
 * `Project.mixMasterSource` so the user can switch back. A second
 * "use in project" never overwrites that record: Restore always
 * goes back to the real original, not to an intermediate render.
 *
 * Zero runtime imports (only the curve module + types): the Node
 * tests in tests/mixmaster.test.cjs load this file directly.
 */
import type { AudioTrack, Project } from '../types';

/** Export formats for the processed song. */
export type MixMasterExportFormat = 'wav' | 'aac';

/**
 * The exports folder under Documents (same convention as
 * media.ts's 'tracks' / 'takes'): user-visible in Files, outside
 * the render cache.
 */
export const MM_EXPORT_FOLDER = 'exports';

/** The original song a "use in project" replaced — the way back. */
export interface MixMasterSourceRef {
  uri: string;
  name: string;
}

/** File extension for an export format (AAC ships as .m4a). */
export function mixMasterExportExtension(format: MixMasterExportFormat): string {
  return format === 'wav' ? 'wav' : 'm4a';
}

/** MIME type for the share sheet. */
export function mixMasterExportMimeType(format: MixMasterExportFormat): string {
  return format === 'wav' ? 'audio/wav' : 'audio/mp4';
}

/**
 * The display name stripped down to a safe file stem: the last
 * extension is dropped, characters a file must not carry
 * (`/ \ : * ? " < > |` and control characters) are removed,
 * whitespace collapses, and the stem is capped at 100 characters.
 * A name that sanitises to nothing reads as "Song".
 */
export function mixMasterExportBaseName(trackName: string): string {
  const withoutExt = trackName.replace(/\.[^./\\]+$/, '');
  const cleaned = withoutExt
    .replace(/[\\/":*?<>|\u0000-\u001f\u007f]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  if (cleaned.length === 0) return 'Song';
  return cleaned.slice(0, 100);
}

/**
 * The export file name for a track: "<Song> (MVMT Mix &
 * Master).wav" / ".m4a". The suffix says what the file is — and
 * keeps it from ever colliding with (or overwriting) the original.
 */
export function mixMasterExportFileName(
  trackName: string,
  format: MixMasterExportFormat,
): string {
  return `${mixMasterExportBaseName(trackName)} (MVMT Mix & Master).${mixMasterExportExtension(format)}`;
}

/**
 * Make an export file name unique inside the exports folder: the
 * first free name wins, appending " 2", " 3", … before the
 * extension. `exists` is the caller's folder lookup, so the rule
 * is testable without a filesystem.
 */
export function resolveMixMasterExportFileName(
  fileName: string,
  exists: (name: string) => boolean,
): string {
  if (!exists(fileName)) return fileName;
  const dot = fileName.lastIndexOf('.');
  const stem = dot === -1 ? fileName : fileName.slice(0, dot);
  const ext = dot === -1 ? '' : fileName.slice(dot);
  for (let n = 2; ; n++) {
    const candidate = `${stem} ${n}${ext}`;
    if (!exists(candidate)) return candidate;
  }
}

/**
 * The "use in project" patch: the track becomes the exported
 * processed file, Mix & Master and Auto EQ turn off (the full
 * chain is baked into the file — re-running either stage would
 * process the processed song), and the original song is recorded
 * for Restore. The duration carries over — the render is the exact
 * frame count of the original, so every song-time position (the
 * region, the EDL, each take's sync offset) stays valid.
 */
export function mixMasterUseInProjectPatch(
  currentTrack: AudioTrack,
  processedUri: string,
  processedFileName: string,
  existingSource?: MixMasterSourceRef | null,
): Partial<Project> {
  return {
    track: {
      uri: processedUri,
      name: processedFileName,
      ...(currentTrack.durationSeconds !== undefined
        ? { durationSeconds: currentTrack.durationSeconds }
        : {}),
    },
    mixMasterEnabled: false,
    autoEqEnabled: false,
    mixMasterSource: existingSource ?? { uri: currentTrack.uri, name: currentTrack.name },
  };
}

/**
 * The "restore original song" patch: the track goes back to the
 * recorded original (same duration — the render never changed the
 * song's length), Mix & Master turns back on (it was on when the
 * processed file was made, so the original plays mastered again),
 * and the source record clears. Auto EQ is left alone: Mix &
 * Master replaces it while on.
 */
export function mixMasterRestoreOriginalPatch(
  source: MixMasterSourceRef,
  currentDurationSeconds?: number,
): Partial<Project> {
  return {
    track: {
      uri: source.uri,
      name: source.name,
      ...(currentDurationSeconds !== undefined
        ? { durationSeconds: currentDurationSeconds }
        : {}),
    },
    mixMasterEnabled: true,
    mixMasterSource: undefined,
  };
}
