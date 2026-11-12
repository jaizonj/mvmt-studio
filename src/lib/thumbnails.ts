import { createVideoPlayer, type VideoPlayer, type VideoThumbnail } from 'expo-video';

/**
 * Filmstrip thumbnails for the timeline editor (CapCut-style strips).
 *
 * Uses expo-video's built-in `generateThumbnailsAsync` on a throwaway
 * player per source video — no extra native dependency. Results are
 * cached module-wide keyed by (uri, time) so re-renders and
 * re-edits don't regenerate frames; a cached `null` means "generation failed /
 * no frame there" and the strip falls back to its colour placeholder.
 *
 * Players are kept alive in a small LRU (takes are few) and released
 * when evicted — createVideoPlayer instances are NOT auto-disposed.
 */

const cache = new Map<string, VideoThumbnail | null>();
const inflight = new Map<string, Promise<void>>();
const players = new Map<string, VideoPlayer>();
const MAX_PLAYERS = 6;

export function thumbnailKey(uri: string, timeSeconds: number): string {
  return `${uri}|${timeSeconds.toFixed(2)}`;
}

/** undefined = not requested yet, null = unavailable, otherwise the frame. */
export function getCachedThumbnail(uri: string, timeSeconds: number): VideoThumbnail | null | undefined {
  return cache.get(thumbnailKey(uri, timeSeconds));
}

function waitForReady(player: VideoPlayer, timeoutMs = 6000): Promise<boolean> {
  if (player.status === 'readyToPlay') return Promise.resolve(true);
  return new Promise((resolve) => {
    const started = Date.now();
    const timer = setInterval(() => {
      if (player.status === 'readyToPlay') {
        clearInterval(timer);
        resolve(true);
      } else if (player.status === 'error' || Date.now() - started > timeoutMs) {
        clearInterval(timer);
        resolve(false);
      }
    }, 100);
  });
}

async function playerFor(uri: string): Promise<VideoPlayer | null> {
  const existing = players.get(uri);
  if (existing) {
    // Refresh LRU order.
    players.delete(uri);
    players.set(uri, existing);
    return existing;
  }
  let player: VideoPlayer;
  try {
    player = createVideoPlayer(uri);
  } catch {
    return null;
  }
  player.muted = true;
  players.set(uri, player);
  if (players.size > MAX_PLAYERS) {
    const oldestUri = players.keys().next().value as string;
    const oldest = players.get(oldestUri);
    players.delete(oldestUri);
    try {
      oldest?.release();
    } catch {
      /* already released */
    }
  }
  const ready = await waitForReady(player);
  return ready ? player : null;
}

/**
 * Generate (and cache) thumbnails for `timesSeconds` in `uri`. Safe to
 * call repeatedly — cached and in-flight requests are skipped. Never
 * throws; failures cache as null so the UI can fall back gracefully.
 */
export async function loadThumbnails(uri: string, timesSeconds: number[]): Promise<void> {
  const wanted = timesSeconds.filter((t) => getCachedThumbnail(uri, t) === undefined);
  if (wanted.length === 0) return;
  const flightKey = `${uri}|${wanted.map((t) => t.toFixed(2)).join(',')}`;
  const existing = inflight.get(flightKey);
  if (existing) return existing;

  const job = (async () => {
    try {
      const player = await playerFor(uri);
      if (!player) {
        wanted.forEach((t) => cache.set(thumbnailKey(uri, t), null));
        return;
      }
      const thumbs = await player.generateThumbnailsAsync(wanted, { maxWidth: 192, maxHeight: 192 });
      for (const t of wanted) {
        // Match each requested time to the closest returned frame.
        let best: VideoThumbnail | null = null;
        let bestDelta = Number.POSITIVE_INFINITY;
        for (const thumb of thumbs) {
          const delta = Math.abs((thumb.requestedTime ?? t) - t);
          if (delta < bestDelta) {
            bestDelta = delta;
            best = thumb;
          }
        }
        cache.set(thumbnailKey(uri, t), bestDelta <= 0.6 ? best : null);
      }
    } catch {
      wanted.forEach((t) => {
        if (getCachedThumbnail(uri, t) === undefined) cache.set(thumbnailKey(uri, t), null);
      });
    } finally {
      inflight.delete(flightKey);
    }
  })();
  inflight.set(flightKey, job);
  return job;
}
