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

import { isCompositorAvailable, prepareMixMasterSong } from './compositor';
import {
  mixMasterStageSettingsKey,
  resolveMixMasterStageSettings,
  type MixMasterStageSettings,
} from './mixMasterCurve';

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
