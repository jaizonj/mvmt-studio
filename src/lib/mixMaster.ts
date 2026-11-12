/**
 * Mix & Master Stages 1–2 — JS side (the analysis and render are
 * native; see `prepareMixMasterSong` in modules/mvmt-compositor).
 *
 * The engine listens to the project's song in 1.0 s windows (50%
 * overlap), finds the harsh (2–8 kHz) and muddy (250/500 Hz)
 * frequencies in EACH window, and renders a copy of the FULL song
 * with those bands pulled down along a SMOOTHED gain curve — cuts
 * only, never boosts — then runs the result through a second,
 * static Master EQ that drives the whole-song balance toward a
 * gentle target curve (slight low-end shelf, flat mids, gentle
 * high shelf; cuts and boosts up to ±3 dB). Each stage has its own
 * toggle + intensity (0–100%, scaling that stage's gains toward
 * 0). The processed file has the exact same duration as the
 * original, so a composition built on it keeps every region/start
 * semantic. The profile (windows + findings + master gains) is
 * stored as JSON beside the render for the Stage 3 UI.
 *
 * This module is the swap point, mirroring Auto EQ
 * (src/lib/autoEq.ts): composition builds (the editor / export
 * previews and the export render) ask `useMixMasterSongUri` for
 * the song URI to put in their request. Until the native
 * preparation resolves — and whenever the project has Mix & Master
 * off, the engine is unavailable, or anything fails — that URI is
 * the ORIGINAL. Nothing here ever blocks a preview or an export.
 *
 * Stage 1 is engine-only: the flag defaults OFF and no UI exposes
 * it yet (the toggle comes with the Stage 3 screen). When it is
 * on, Mix & Master REPLACES Auto EQ for the song — the dynamic
 * curve already contains the per-window version of Auto EQ's
 * static cut, so running both would cut twice. The recording path
 * never comes through here: capture, record-time playback
 * (prepareSong) and the take sync measurement keep using the
 * project's original song file, always.
 */
import { useEffect, useState } from 'react';
import { Directory, File, Paths } from 'expo-file-system';

import {
  exportMixMasterAac,
  getMixMasterProfile,
  isCompositorAvailable,
  prepareMixMasterSong,
} from './compositor';
import {
  mixMasterStageSettingsKey,
  parseMixMasterProfile,
  resolveMixMasterStageSettings,
  type MixMasterProfile,
  type MixMasterStageSettings,
} from './mixMasterCurve';
import {
  MM_EXPORT_FOLDER,
  mixMasterExportFileName,
  resolveMixMasterExportFileName,
  type MixMasterExportFormat,
} from './mixMasterExport';

/** Session memo: one native preparation per song URI + stage settings, ever. */
const preparations = new Map<string, Promise<string>>();

/**
 * Kick off (or recall) the native Mix & Master preparation for a
 * song with these stage settings. Resolves to the URI composition
 * builds should use — the processed copy when either stage has
 * anything to do, the original otherwise (and on any failure).
 * Never rejects.
 */
export function prepareMixMasterSongUri(
  uri: string,
  stages?: Partial<MixMasterStageSettings> | null,
): Promise<string> {
  const resolved = resolveMixMasterStageSettings(stages);
  const key = `${uri}|${mixMasterStageSettingsKey(resolved)}`;
  const existing = preparations.get(key);
  if (existing) return existing;
  const promise = (async () => {
    if (!isCompositorAvailable()) return uri;
    return prepareMixMasterSong(
      uri,
      resolved.correctiveEnabled,
      resolved.correctiveIntensity,
      resolved.masterEnabled,
      resolved.masterIntensity,
    );
  })();
  preparations.set(key, promise);
  return promise;
}

/** One exported processed song: the file the share sheet opens. */
export interface MixMasterExportResult {
  uri: string;
  fileName: string;
  format: MixMasterExportFormat;
}

/**
 * Export the processed song for the CURRENT stage settings
 * (Stage 4). Freshness is the preparation itself: it re-runs
 * `prepareMixMasterSongUri` for these settings — memoized, so it
 * is free when the render already exists and re-renders when the
 * settings changed — and never exports a stale render. Resolves
 * to null when there is nothing to export (the engine is
 * unavailable, the song needs no corrections so the "processed"
 * file IS the original, or the write/transcode failed). Never
 * rejects.
 *
 * WAV is the Float32 master render copied as-is (no re-encode);
 * AAC is a native transcode of that render (256 kbps .m4a). The
 * file lands in Documents/exports with a unique name, outside the
 * render cache — it survives cache eviction and shows up in Files.
 * The original song file is never touched.
 */
export async function exportMixMasterSongFile(
  originalUri: string,
  trackName: string,
  stages?: Partial<MixMasterStageSettings> | null,
  format: MixMasterExportFormat = 'wav',
): Promise<MixMasterExportResult | null> {
  try {
    const processedUri = await prepareMixMasterSongUri(originalUri, stages);
    if (!processedUri || processedUri === originalUri) return null;
    const dir = new Directory(Paths.document, MM_EXPORT_FOLDER);
    if (!dir.exists) dir.create();
    const fileName = resolveMixMasterExportFileName(
      mixMasterExportFileName(trackName, format),
      (name) => new File(dir, name).exists,
    );
    const destination = new File(dir, fileName);
    if (format === 'wav') {
      await new File(processedUri).copy(destination);
    } else {
      const transcoded = await exportMixMasterAac(processedUri, destination.uri);
      if (!transcoded) return null;
    }
    return { uri: destination.uri, fileName, format };
  } catch {
    return null;
  }
}

/**
 * Best-effort warm-up (a track is set, a screen mounts): start the
 * analysis/render in the background so the processed copy is ready
 * by the time a composition is built. Fire and forget.
 */
export function warmUpMixMasterSong(
  uri: string | null | undefined,
  stages?: Partial<MixMasterStageSettings> | null,
): void {
  if (!uri) return;
  void prepareMixMasterSongUri(uri, stages);
}

/**
 * Load the stored profile for a song + stage settings (Stage 3
 * UI): prepares first — memoized, the SAME preparation
 * composition builds use, so this never renders twice — then
 * reads the profile JSON the engine stored beside the render (or
 * built from a fresh analysis when no render was written, e.g. a
 * song that needs no corrections). Resolves to null when the
 * engine is unavailable, the song can't be analyzed, or the
 * profile is missing/malformed. Never rejects.
 */
export async function loadMixMasterProfile(
  uri: string,
  stages?: Partial<MixMasterStageSettings> | null,
): Promise<MixMasterProfile | null> {
  const resolved = resolveMixMasterStageSettings(stages);
  try {
    await prepareMixMasterSongUri(uri, resolved);
    const json = await getMixMasterProfile(
      uri,
      resolved.correctiveEnabled,
      resolved.correctiveIntensity,
      resolved.masterEnabled,
      resolved.masterIntensity,
    );
    if (!json) return null;
    return parseMixMasterProfile(JSON.parse(json));
  } catch {
    return null;
  }
}

/**
 * The profile for the screen: null + not loading while Mix &
 * Master is off (no analysis runs until the user turns it on),
 * loading while the analysis/render runs, then the profile. A
 * settings change re-loads but keeps the previous profile on
 * screen until the new one lands, so the curve never blanks
 * while a slider settles.
 *
 * The returned value is derived during render from the last
 * loaded result + the current inputs — the effect only ever
 * setStates in the load's async callback, never synchronously.
 */
export function useMixMasterProfile(
  originalUri: string | null | undefined,
  enabled: boolean,
  stages?: Partial<MixMasterStageSettings> | null,
): { profile: MixMasterProfile | null; loading: boolean } {
  const resolvedStages = resolveMixMasterStageSettings(stages);
  const settingsKey = mixMasterStageSettingsKey(resolvedStages);
  const key = `${originalUri ?? ''}|${settingsKey}`;
  const [loaded, setLoaded] = useState<{
    key: string;
    profile: MixMasterProfile | null;
  } | null>(null);

  useEffect(() => {
    if (!originalUri || !enabled) return;
    let alive = true;
    void loadMixMasterProfile(originalUri, resolvedStages).then((profile) => {
      if (!alive) return;
      setLoaded({ key, profile });
    });
    return () => {
      alive = false;
    };
    // key carries originalUri + the resolved stages; resolvedStages
    // is re-derived from `stages` above (same values, same key).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [originalUri, enabled, key]);

  if (!originalUri || !enabled) return { profile: null, loading: false };
  if (loaded && loaded.key === key) return { profile: loaded.profile, loading: false };
  // Loading for this key — keep the previous profile (if any) on
  // screen until the new one lands.
  return { profile: loaded?.profile ?? null, loading: true };
}

/**
 * The song URI a composition build should use right now: the
 * original until the Mix & Master render for it has landed, then
 * the processed copy. When Mix & Master is off for the project,
 * always the original. Callers put the result in their request
 * (the `audioUri` option of edlToCompositeRequest); when it
 * changes, their request key changes with it, which is what
 * rebuilds the preview on the processed song. A settings change
 * re-prepares (different memo key) and clears a stale processed
 * URI when the new settings render nothing.
 */
export function useMixMasterSongUri(
  originalUri: string | null | undefined,
  enabled: boolean,
  stages?: Partial<MixMasterStageSettings> | null,
): string | null {
  const resolvedStages = resolveMixMasterStageSettings(stages);
  const settingsKey = mixMasterStageSettingsKey(resolvedStages);
  const [resolved, setResolved] = useState<{
    forUri: string;
    forSettings: string;
    uri: string;
  } | null>(null);

  useEffect(() => {
    if (!originalUri || !enabled) return;
    let alive = true;
    void prepareMixMasterSongUri(originalUri, resolvedStages).then((uri) => {
      if (!alive) return;
      setResolved(
        uri !== originalUri ? { forUri: originalUri, forSettings: settingsKey, uri } : null,
      );
    });
    return () => {
      alive = false;
    };
    // settingsKey carries the resolved stages; resolvedStages is
    // re-derived from `stages` above (same values, same key).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [originalUri, enabled, settingsKey]);

  if (!originalUri) return null;
  if (!enabled) return originalUri;
  return resolved && resolved.forUri === originalUri && resolved.forSettings === settingsKey
    ? resolved.uri
    : originalUri;
}
