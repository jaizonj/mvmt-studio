import type { MusicalSection, Take } from '../types';

/**
 * Analysis — cached, computed once, read many times.
 *
 * The Triller lesson (see README): analyse at selection/capture time and
 * cache the tables, so editing/shuffling is a cheap lookup, not an analysis
 * pass. This module is pure TypeScript (no React Native imports) so it can
 * be unit-tested in Node — see tests/.
 *
 * v1 signals, honestly labelled:
 * - Section boundaries: phrase-aligned. Without a beat-tracking library in
 *   the scaffold, phrases are assumed to be 8 beats (2 bars of 4/4) at an
 *   assumed tempo (DEFAULT_BPM). TODO(product): replace with real beat /
 *   downbeat detection (e.g. an on-device analyser over the decoded track)
 *   — only this function changes; sections are MusicalSection[] either way.
 * - Section energy: REAL when it comes from SectionEnergyAccumulator fed by
 *   expo-audio's audio sampling during playback (RMS of the actual track).
 *   If a section was never sampled, its energy falls back to the mean of the
 *   sampled sections (marked by callers, not hidden).
 * - Take energy: HEURISTIC v1 — bytes-per-second of the recorded file,
 *   normalised across the take set. At a fixed encoder setting, busier
 *   frames compress larger, so this correlates with motion. It is a proxy,
 *   not motion analysis. TODO(product): per-section frame-difference motion
 *   scoring over thumbnails; Take.energy / energyBySection is the only
 *   interface the shuffle engine depends on.
 */

export const DEFAULT_BPM = 120;
/** Beats per musical phrase used for section boundaries (2 bars of 4/4). */
export const PHRASE_BEATS = 8;

export function phraseLengthSeconds(bpm: number = DEFAULT_BPM): number {
  return (60 / bpm) * PHRASE_BEATS;
}

/** Split a track (or a region of it) into phrase-aligned sections. Energy starts neutral (0.5). */
export function buildSections(
  durationSeconds: number,
  bpm: number = DEFAULT_BPM,
  startOffsetSeconds = 0,
  sectionLengthSeconds?: number,
): MusicalSection[] {
  if (!durationSeconds || durationSeconds <= 0) return [];
  const length = sectionLengthSeconds && sectionLengthSeconds > 0 ? sectionLengthSeconds : phraseLengthSeconds(bpm);
  const sections: MusicalSection[] = [];
  let start = startOffsetSeconds;
  const stop = startOffsetSeconds + durationSeconds;
  let index = 0;
  while (start < stop - 0.05) {
    const end = Math.min(stop, start + length);
    sections.push({ index, startSeconds: start, endSeconds: end, energy: 0.5 });
    start = end;
    index += 1;
  }
  return sections;
}

/**
 * Subdivide existing sections (e.g. phrase-length sampled sections) into
 * shorter sections of about `targetLengthSeconds`, each inheriting its
 * parent section's energy. Used by Shuffle frequency: the sampled energy
 * table stays valid, only the cut granularity changes.
 */
export function subdivideSections(sections: MusicalSection[], targetLengthSeconds: number): MusicalSection[] {
  if (!sections.length || !targetLengthSeconds || targetLengthSeconds <= 0) return sections;
  const out: MusicalSection[] = [];
  let index = 0;
  for (const section of sections) {
    const length = section.endSeconds - section.startSeconds;
    if (length <= targetLengthSeconds * 1.05) {
      out.push({ ...section, index: index++ });
      continue;
    }
    let start = section.startSeconds;
    while (start < section.endSeconds - 0.05) {
      const end = Math.min(section.endSeconds, start + targetLengthSeconds);
      out.push({ index: index++, startSeconds: start, endSeconds: end, energy: section.energy });
      start = end;
    }
  }
  return out;
}

/** Resolve an AudioRegion against a known track duration, with clamping. */
export function effectiveRegion(
  region: { startSeconds: number; durationSeconds: number | null },
  trackDurationSeconds: number | undefined,
): { startSeconds: number; endSeconds: number; lengthSeconds: number } | null {
  if (!trackDurationSeconds || trackDurationSeconds <= 0) return null;
  const start = Math.min(Math.max(0, region.startSeconds), Math.max(0, trackDurationSeconds - 1));
  const wanted = region.durationSeconds ?? trackDurationSeconds;
  const end = Math.min(trackDurationSeconds, start + Math.max(1, wanted));
  return { startSeconds: start, endSeconds: end, lengthSeconds: end - start };
}

/**
 * Accumulates RMS energy per section from expo-audio audio samples while
 * the track plays. Feed it (timestampSeconds, rms) pairs; call finish()
 * when playback/recording stops to get normalised MusicalSection[].
 */
export class SectionEnergyAccumulator {
  private sums: number[] = [];
  private counts: number[] = [];

  constructor(
    private readonly durationSeconds: number,
    private readonly bpm: number = DEFAULT_BPM,
    /** Absolute track time the analysed region starts at (0 for a full track). */
    private readonly startOffsetSeconds = 0,
  ) {
    const count = buildSections(durationSeconds, bpm).length;
    this.sums = new Array(count).fill(0);
    this.counts = new Array(count).fill(0);
  }

  addSample(timestampSeconds: number, rms: number): void {
    const relative = timestampSeconds - this.startOffsetSeconds;
    if (relative < 0 || relative >= this.durationSeconds) return;
    const idx = Math.min(this.sums.length - 1, Math.floor(relative / phraseLengthSeconds(this.bpm)));
    this.sums[idx] += rms;
    this.counts[idx] += 1;
  }

  /** How many sections have at least one real sample (for honest UI copy). */
  get sampledSectionCount(): number {
    return this.counts.filter((c) => c > 0).length;
  }

  finish(): MusicalSection[] {
    const sections = buildSections(this.durationSeconds, this.bpm, this.startOffsetSeconds);
    const means = this.sums.map((sum, i) => (this.counts[i] > 0 ? sum / this.counts[i] : null));
    const sampledMeans = means.filter((m): m is number => m !== null);
    const fallback = sampledMeans.length > 0 ? sampledMeans.reduce((a, b) => a + b, 0) / sampledMeans.length : 0;
    const max = Math.max(0.0001, ...sampledMeans);
    return sections.map((section, i) => {
      const mean = means[i];
      // Normalise against the loudest sampled section; sqrt softens the
      // dynamic range so quiet-but-present sections don't collapse to 0.
      const energy = mean === null ? (fallback > 0 ? Math.sqrt(fallback / max) * 0.8 : 0.5) : Math.sqrt(mean / max);
      return { ...section, energy: Math.min(1, Math.max(0, energy)) };
    });
  }
}

/** RMS of one audio sample's channels (frames are normalised -1..1). */
export function rmsOfFrames(frames: ArrayLike<number>): number {
  if (frames.length === 0) return 0;
  let sum = 0;
  for (let i = 0; i < frames.length; i++) sum += frames[i] * frames[i];
  return Math.sqrt(sum / frames.length);
}

/**
 * v1 take-energy heuristic: normalise bytes-per-second across the take set
 * into 0..1. Takes with missing data get the set median (or 0.5). Returns a
 * Map keyed by take id. Pure — callers decide whether to persist the result
 * onto Take.energy.
 */
export function estimateTakeEnergies(takes: Pick<Take, 'id' | 'fileSizeBytes' | 'durationSeconds'>[]): Map<string, number> {
  const rates = takes
    .map((t) => (t.fileSizeBytes && t.durationSeconds ? t.fileSizeBytes / t.durationSeconds : null))
    .filter((r): r is number => r !== null && r > 0);
  const result = new Map<string, number>();
  if (rates.length === 0) {
    takes.forEach((t) => result.set(t.id, 0.5));
    return result;
  }
  const min = Math.min(...rates);
  const max = Math.max(...rates);
  const medianRate = [...rates].sort((a, b) => a - b)[Math.floor(rates.length / 2)];
  const normalise = (rate: number) => (max === min ? 0.5 : 0.1 + 0.8 * ((rate - min) / (max - min)));
  takes.forEach((t) => {
    const rate = t.fileSizeBytes && t.durationSeconds ? t.fileSizeBytes / t.durationSeconds : medianRate;
    result.set(t.id, normalise(rate));
  });
  return result;
}
