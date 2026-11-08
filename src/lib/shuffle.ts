import type { MusicalSection } from '../types';

/**
 * Shuffle — candidate generation + whole-edit scoring.
 *
 * NOT naive random. Following the documented Triller/Spotify pattern:
 *  1. Takes are synced at capture (every take starts at the top of the
 *     track), so any take can fill any musical section without breaking
 *     sync. Shuffle is therefore a per-section selection problem.
 *  2. Generate MANY candidate edits (default 32) by weighted-random
 *     per-section take selection — weights favour energy match and
 *     disfavour repeating the previous slot / the previous shuffle.
 *  3. Score each WHOLE edit (energy match, cut alignment, shot-length
 *     variety, adjacency + repeat penalties, take variety) and keep the
 *     best. True randomness often *feels* broken; best-of-N feels random
 *     but lands well.
 *  4. Successive shuffles must differ: if a previous edit is supplied, a
 *     candidate identical to it can never win.
 *
 * Pure TypeScript, no React Native imports, table lookups only — a shuffle
 * tap is O(candidates x sections) arithmetic on cached analysis, with no
 * decoding or encoding. Unit-tested in tests/shuffle.test.cjs.
 */

export interface ShuffleTakeInput {
  id: string;
  /** Overall energy 0..1 (see analysis.ts). */
  energy: number;
  /** Optional per-section energy; overrides `energy` where present. */
  energyBySection?: number[];
}

export interface ShuffleOptions {
  /** Candidates to generate and score. Clamped to 24..48. */
  candidates?: number;
  /** No shot shorter than this, seconds. Short sections are merged. */
  minShotSeconds?: number;
  /** Take-id sequence of the previous edit/shuffle, to guarantee novelty. */
  previousSequence?: string[];
  /** Injectable RNG (tests use a seeded one). Defaults to Math.random. */
  random?: () => number;
}

export interface ShuffleSlot {
  takeId: string;
  startSeconds: number;
  endSeconds: number;
}

export interface ShuffleOutput {
  slots: ShuffleSlot[];
  /** 0..100, one decimal. */
  score: number;
  candidatesEvaluated: number;
  /** True only when differing from `previousSequence` was impossible (e.g. a single slot / take). */
  isRepeatOfPrevious: boolean;
}

interface ShotWindow {
  startSeconds: number;
  endSeconds: number;
  /** Energy of the (possibly merged) sections this shot covers. */
  energy: number;
  /** Index of the first section covered — used for per-section take energy + previous-edit comparison. */
  firstSectionIndex: number;
}

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

/** Deterministic RNG for tests (mulberry32). */
export function seededRandom(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function takeEnergyForSection(take: ShuffleTakeInput, sectionIndex: number): number {
  return take.energyBySection?.[sectionIndex] ?? take.energy;
}

/**
 * Build shot windows from sections: merge sections that are too short into
 * the previous shot (minimum shot length), then — per candidate — randomly
 * merge some adjacent windows so shot lengths vary between candidates
 * instead of cutting on every phrase like a metronome.
 */
function buildWindows(sections: MusicalSection[], minShotSeconds: number, random: () => number): ShotWindow[] {
  const base: ShotWindow[] = [];
  for (const section of sections) {
    const length = section.endSeconds - section.startSeconds;
    const last = base[base.length - 1];
    if (last && length < minShotSeconds) {
      // Too short to stand alone — extend the previous shot over it.
      const total = last.endSeconds - last.startSeconds + length;
      last.energy = (last.energy * (last.endSeconds - last.startSeconds) + section.energy * length) / total;
      last.endSeconds = section.endSeconds;
    } else if (last && last.endSeconds - last.startSeconds < minShotSeconds) {
      const total = last.endSeconds - last.startSeconds + length;
      last.energy = (last.energy * (last.endSeconds - last.startSeconds) + section.energy * length) / total;
      last.endSeconds = section.endSeconds;
    } else {
      base.push({
        startSeconds: section.startSeconds,
        endSeconds: section.endSeconds,
        energy: section.energy,
        firstSectionIndex: section.index,
      });
    }
  }
  // Randomly merge adjacent windows (never the result below min length —
  // merging only ever lengthens) for shot-length variety across candidates.
  const windows: ShotWindow[] = [];
  for (let i = 0; i < base.length; i++) {
    const prev = windows[windows.length - 1];
    if (prev && random() < 0.22) {
      prev.endSeconds = base[i].endSeconds;
    } else {
      windows.push({ ...base[i] });
    }
  }
  return windows;
}

function pickWeighted(takes: ShuffleTakeInput[], weights: number[], random: () => number): number {
  const total = weights.reduce((a, b) => a + b, 0);
  let roll = random() * total;
  for (let i = 0; i < takes.length; i++) {
    roll -= weights[i];
    if (roll <= 0) return i;
  }
  return takes.length - 1;
}

function generateCandidate(
  windows: ShotWindow[],
  takes: ShuffleTakeInput[],
  previousSequence: string[] | undefined,
  random: () => number,
): string[] {
  const sequence: string[] = [];
  for (let slot = 0; slot < windows.length; slot++) {
    const weights = takes.map((take, i) => {
      const energyMatch = 1 - Math.abs(windows[slot].energy - takeEnergyForSection(take, windows[slot].firstSectionIndex));
      let weight = 0.3 + 1.6 * energyMatch;
      if (slot > 0 && sequence[slot - 1] === take.id) weight *= 0.12; // avoid back-to-back same take
      if (previousSequence && previousSequence[slot] === take.id) weight *= 0.4; // differ from last shuffle
      if (sequence.filter((id) => id === take.id).length >= Math.ceil(windows.length / takes.length) + 1) weight *= 0.5;
      return weight;
    });
    sequence.push(takes[pickWeighted(takes, weights, random)].id);
  }
  return sequence;
}

function scoreSequence(
  windows: ShotWindow[],
  sequence: string[],
  takesById: Map<string, ShuffleTakeInput>,
  previousSequence: string[] | undefined,
): number {
  if (windows.length === 0) return 0;

  // Energy match (40 pts): does each shot's energy suit its music section?
  let energyTotal = 0;
  for (let i = 0; i < windows.length; i++) {
    const take = takesById.get(sequence[i]);
    if (!take) continue;
    energyTotal += 1 - Math.abs(windows[i].energy - takeEnergyForSection(take, windows[i].firstSectionIndex));
  }
  const energyScore = (energyTotal / windows.length) * 40;

  // Cut alignment (15 pts): every window starts on a section/phrase
  // boundary by construction; score drops if shots are uniformly tiny
  // (flickery) — windows below the min length were already merged, so this
  // rewards edits whose shortest shot still breathes.
  const lengths = windows.map((w) => w.endSeconds - w.startSeconds);
  const minLength = Math.min(...lengths);
  const alignmentScore = clamp(minLength / 3, 0, 1) * 15;

  // Shot-length variety (15 pts): uniform lengths read as mechanical.
  const mean = lengths.reduce((a, b) => a + b, 0) / lengths.length;
  const variance = lengths.reduce((a, b) => a + (b - mean) ** 2, 0) / lengths.length;
  const cv = mean > 0 ? Math.sqrt(variance) / mean : 0;
  const varietyScore = clamp(cv / 0.6, 0, 1) * 15;

  // Take variety (15 pts): use the cast, don't loop one take.
  const distinct = new Set(sequence).size;
  const varietyTakesScore = (distinct / Math.min(takesById.size, windows.length)) * 15;

  // Penalties.
  let penalty = 0;
  for (let i = 1; i < sequence.length; i++) {
    if (sequence[i] === sequence[i - 1]) penalty += 9; // adjacent same take reads as a jump-cut glitch
  }
  if (previousSequence) {
    let sameSlots = 0;
    for (let i = 0; i < Math.min(sequence.length, previousSequence.length); i++) {
      if (sequence[i] === previousSequence[i]) sameSlots += 1;
    }
    penalty += sameSlots * 3;
    if (sequence.join('|') === previousSequence.join('|')) penalty += 100; // identical edit — effectively disqualifying
  }
  // Usage imbalance: one take hogging the edit.
  const counts = new Map<string, number>();
  sequence.forEach((id) => counts.set(id, (counts.get(id) ?? 0) + 1));
  const maxShare = Math.max(...counts.values()) / sequence.length;
  if (maxShare > 0.6) penalty += (maxShare - 0.6) * 30;

  return clamp(Math.round((energyScore + alignmentScore + varietyScore + varietyTakesScore - penalty) * 10) / 10, 0, 100);
}

export function generateShuffle(
  sections: MusicalSection[],
  takes: ShuffleTakeInput[],
  options: ShuffleOptions = {},
): ShuffleOutput | null {
  if (sections.length === 0 || takes.length < 2) return null;
  const random = options.random ?? Math.random;
  const candidates = Math.round(clamp(options.candidates ?? 32, 24, 48));
  const minShotSeconds = options.minShotSeconds ?? 2.5;
  const previousSequence = options.previousSequence;
  const takesById = new Map(takes.map((t) => [t.id, t]));

  let best: { sequence: string[]; windows: ShotWindow[]; score: number } | null = null;
  let evaluated = 0;

  for (let c = 0; c < candidates; c++) {
    const windows = buildWindows(sections, minShotSeconds, random);
    if (windows.length === 0) continue;
    const sequence = generateCandidate(windows, takes, previousSequence, random);
    const score = scoreSequence(windows, sequence, takesById, previousSequence);
    evaluated += 1;
    if (!best || score > best.score) best = { sequence, windows, score };
  }
  if (!best) return null;

  const isRepeatOfPrevious =
    !!previousSequence && best.sequence.join('|') === previousSequence.join('|');

  return {
    slots: best.windows.map((w, i) => ({
      takeId: best!.sequence[i],
      startSeconds: w.startSeconds,
      endSeconds: w.endSeconds,
    })),
    score: best.score,
    candidatesEvaluated: evaluated,
    isRepeatOfPrevious,
  };
}
