import { isCompositorAvailable, waveformPeaks } from './compositor';

/**
 * Waveform peaks for the Record screen's track strip and the
 * audio-region picker — ONE source for both consumers.
 *
 * Real peaks are decoded natively (the compositor's `waveformPeaks`:
 * AVAssetReader → per-bucket max-abs, normalised). When the native
 * engine isn't available (Expo Go, older builds) or a file can't be
 * decoded, consumers fall back to `standinPeaks` — the deterministic
 * name-hash bars the picker originally shipped with — so the UI never
 * renders empty while waiting, or when decoding is impossible.
 */

/** How many buckets the loader asks the native decoder for. */
const PEAK_BUCKETS = 120;

/**
 * Deterministic stand-in peaks from the track name — the generator the
 * region picker originally shipped with, moved here verbatim (same
 * math) so both consumers share it. Values land in ~[0.25, 1].
 */
export function standinPeaks(name: string, count: number): number[] {
  const seed = name.split('').reduce((a, c) => a + c.charCodeAt(0), 0);
  return Array.from({ length: count }, (_, i) => {
    const v = Math.abs(Math.sin(seed * 0.13 + i * 0.9)) * 0.6 + Math.abs(Math.sin(seed + i * 0.37)) * 0.4;
    return 0.25 + v * 0.75;
  });
}

/**
 * Resample any peaks array to exactly `count` bars, taking the MAXIMUM
 * within each source slice — a loud moment must survive downsampling,
 * or the waveform would lie about where the drops are. Upsampling
 * repeats the covering source bucket.
 */
export function samplePeaks(peaks: number[], count: number): number[] {
  if (count <= 0) return [];
  if (peaks.length === 0) return Array.from({ length: count }, () => 0);
  const out: number[] = [];
  for (let i = 0; i < count; i++) {
    const start = Math.floor((i * peaks.length) / count);
    const end = Math.max(start + 1, Math.floor(((i + 1) * peaks.length) / count));
    let max = 0;
    for (let j = start; j < end && j < peaks.length; j++) {
      if (peaks[j] > max) max = peaks[j];
    }
    out.push(max);
  }
  return out;
}

const peaksCache = new Map<string, number[]>();
const peaksInFlight = new Map<string, Promise<number[]>>();

/**
 * Load a track's peaks at PEAK_BUCKETS resolution: real decoded peaks
 * when the native engine is available, the stand-in otherwise. Cached
 * per uri for the app session (concurrent callers share one decode).
 * NEVER rejects.
 */
export function loadTrackPeaks(track: { uri: string; name: string }): Promise<number[]> {
  const cached = peaksCache.get(track.uri);
  if (cached) return Promise.resolve(cached);
  const inFlight = peaksInFlight.get(track.uri);
  if (inFlight) return inFlight;
  const promise = (async (): Promise<number[]> => {
    let peaks: number[] | null = null;
    if (isCompositorAvailable()) {
      const result = await waveformPeaks(track.uri, PEAK_BUCKETS);
      if (result && result.peaks.length > 0) peaks = result.peaks;
    }
    const resolved = peaks ?? standinPeaks(track.name, PEAK_BUCKETS);
    peaksCache.set(track.uri, resolved);
    peaksInFlight.delete(track.uri);
    return resolved;
  })();
  peaksInFlight.set(track.uri, promise);
  return promise;
}
