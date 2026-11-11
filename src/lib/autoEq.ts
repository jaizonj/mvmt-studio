/**
 * Auto EQ — JS side (the analysis and render are native; see
 * `prepareEqSong` in modules/mvmt-compositor).
 *
 * The engine listens to the project's song, finds the harsh
 * frequencies (the 2–8 kHz bands measuring hot against the song's
 * own average band level) and renders a copy of the FULL song with
 * those bands pulled down — cuts only, never boosts. The processed
 * file has the exact same duration as the original, so a
 * composition built on it keeps every region/start semantic.
 *
 * This module is the swap point: composition builds (the editor /
 * export previews and the export render) ask `useEqSongUri` for the
 * song URI to put in their request. Until the native preparation
 * resolves — and whenever the project has Auto EQ off, the engine
 * is unavailable, or anything fails — that URI is the ORIGINAL.
 * Nothing here ever blocks a preview or an export.
 *
 * The recording path never comes through here: capture, record-time
 * playback (prepareSong) and the take sync measurement keep using
 * the project's original song file, always.
 */
import { useEffect, useState } from 'react';

import { isCompositorAvailable, prepareEqSong } from './compositor';

/** Session memo: one native preparation per song URI, ever. */
const preparations = new Map<string, Promise<string>>();

/**
 * Kick off (or recall) the native Auto EQ preparation for a song.
 * Resolves to the URI composition builds should use — the
 * EQ-rendered copy when the song measured harsh, the original
 * otherwise (and on any failure). Never rejects.
 */
export function prepareEqSongUri(uri: string): Promise<string> {
  const existing = preparations.get(uri);
  if (existing) return existing;
  const promise = (async () => {
    if (!isCompositorAvailable()) return uri;
    return prepareEqSong(uri);
  })();
  preparations.set(uri, promise);
  return promise;
}

/**
 * Best-effort warm-up (a track is set, a screen mounts): start the
 * analysis/render in the background so the processed copy is ready
 * by the time a composition is built. Fire and forget.
 */
export function warmUpEqSong(uri: string | null | undefined): void {
  if (!uri) return;
  void prepareEqSongUri(uri);
}

/**
 * The song URI a composition build should use right now: the
 * original until the EQ render for it has landed, then the
 * processed copy. When Auto EQ is off for the project, always the
 * original. Callers put the result in their request (the
 * `audioUri` option of edlToCompositeRequest); when it changes,
 * their request key changes with it, which is what rebuilds the
 * preview on the processed song.
 */
export function useEqSongUri(
  originalUri: string | null | undefined,
  enabled: boolean,
): string | null {
  const [resolved, setResolved] = useState<{ forUri: string; uri: string } | null>(null);

  useEffect(() => {
    if (!originalUri || !enabled) return;
    let alive = true;
    void prepareEqSongUri(originalUri).then((uri) => {
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
