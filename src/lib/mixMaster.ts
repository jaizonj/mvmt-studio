/**
 * Mix & Master Stage 1 — JS side (the analysis and render are
 * native; see `prepareMixMasterSong` in modules/mvmt-compositor).
 *
 * The engine listens to the project's song in 1.0 s windows (50%
 * overlap), finds the harsh (2–8 kHz) and muddy (250/500 Hz)
 * frequencies in EACH window, and renders a copy of the FULL song
 * with those bands pulled down along a SMOOTHED gain curve — cuts
 * only, never boosts. The processed file has the exact same
 * duration as the original, so a composition built on it keeps
 * every region/start semantic. The smoothed profile (windows +
 * findings) is stored as JSON beside the render for the Stage 3 UI.
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

/** Session memo: one native preparation per song URI, ever. */
const preparations = new Map<string, Promise<string>>();

/**
 * Kick off (or recall) the native Mix & Master preparation for a
 * song. Resolves to the URI composition builds should use — the
 * dynamically-EQ'd copy when the song measured harsh or muddy
 * anywhere, the original otherwise (and on any failure). Never
 * rejects.
 */
export function prepareMixMasterSongUri(uri: string): Promise<string> {
  const existing = preparations.get(uri);
  if (existing) return existing;
  const promise = (async () => {
    if (!isCompositorAvailable()) return uri;
    return prepareMixMasterSong(uri);
  })();
  preparations.set(uri, promise);
  return promise;
}

/**
 * Best-effort warm-up (a track is set, a screen mounts): start the
 * analysis/render in the background so the processed copy is ready
 * by the time a composition is built. Fire and forget.
 */
export function warmUpMixMasterSong(uri: string | null | undefined): void {
  if (!uri) return;
  void prepareMixMasterSongUri(uri);
}

/**
 * The song URI a composition build should use right now: the
 * original until the Mix & Master render for it has landed, then
 * the processed copy. When Mix & Master is off for the project,
 * always the original. Callers put the result in their request
 * (the `audioUri` option of edlToCompositeRequest); when it
 * changes, their request key changes with it, which is what
 * rebuilds the preview on the processed song.
 */
export function useMixMasterSongUri(
  originalUri: string | null | undefined,
  enabled: boolean,
): string | null {
  const [resolved, setResolved] = useState<{ forUri: string; uri: string } | null>(null);

  useEffect(() => {
    if (!originalUri || !enabled) return;
    let alive = true;
    void prepareMixMasterSongUri(originalUri).then((uri) => {
      if (alive && uri !== originalUri) {
        setResolved({ forUri: originalUri, uri });
      }
    });
    return () => {
      alive = false;
    };
  }, [originalUri, enabled]);

  if (!originalUri) return null;
  if (!enabled) return originalUri;
  return resolved && resolved.forUri === originalUri ? resolved.uri : originalUri;
}
