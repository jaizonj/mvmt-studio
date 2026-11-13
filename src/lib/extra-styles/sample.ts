/**
 * Extra Styles 2.0 — card-preview sample data (Phase 3).
 *
 * Animated card previews (§12.2) render the ACTUAL composition
 * over the bundled sample clip — but a card has no project, no
 * song, and no takes. So the preview scene is built from FIXED
 * sample data: three generic lyric lines (with stored
 * intelligence — emoji, tone, emphasis — so emoji-driven styles
 * show their emoji on the card), a synthetic 120 BPM automation
 * artifact, and a synthetic mask index with a drifting face box.
 * All of it is deterministic: the same style renders the same
 * card on every device, every launch.
 *
 * Pure — covered by tests/extra-styles.test.cjs. The sample clip
 * itself (assets/extra-styles-sample-clip.mp4) is resolved by
 * sampleClip.ts, not here.
 */

import type { AudioAutomation, ExtraStyleParamValue, SubjectMaskIndex } from './types';
import { AUDIO_AUTOMATION_HOP_SECONDS, AUDIO_AUTOMATION_VERSION, AUDIO_BAND_CENTERS_HZ } from './types';
import type { SceneInputLine } from './scene';
import { fnv1a32 } from './interpretation';

/** Card preview geometry (§12.2, proposed starting point — the
 *  exact budget is a Phase 4 device measurement). */
export const CARD_PREVIEW_WIDTH = 540;
export const CARD_PREVIEW_HEIGHT = 960;
export const CARD_PREVIEW_FPS = 15;
export const CARD_PREVIEW_DURATION_SECONDS = 3;
/** Scene frames for a card (the scene grid is 30 fps). */
export const CARD_PREVIEW_DURATION_FRAMES = CARD_PREVIEW_DURATION_SECONDS * 30;

/** Sample lyric lines for a card: one second each, generic
 *  upbeat words with stored intelligence on every line — an
 *  emoji-driven style must show emoji on its card, and a
 *  tone-driven style must have a tone to read. */
export const SAMPLE_CARD_LINES: SceneInputLine[] = [
  {
    id: 'sample-line-1',
    text: 'We light up the night',
    startFrame: 0,
    endFrame: 30,
    words: [
      { text: 'We', startFrame: 0, endFrame: 7 },
      { text: 'light', startFrame: 7, endFrame: 14 },
      { text: 'up', startFrame: 14, endFrame: 18 },
      { text: 'the', startFrame: 18, endFrame: 22 },
      { text: 'night', startFrame: 22, endFrame: 30 },
    ],
    decor: { emoji: '🎉', tone: 'hype', emphasisWordIndices: [1, 4] },
  },
  {
    id: 'sample-line-2',
    text: 'Dancing till the morning light',
    startFrame: 30,
    endFrame: 60,
    words: [
      { text: 'Dancing', startFrame: 30, endFrame: 40 },
      { text: 'till', startFrame: 40, endFrame: 45 },
      { text: 'the', startFrame: 45, endFrame: 49 },
      { text: 'morning', startFrame: 49, endFrame: 55 },
      { text: 'light', startFrame: 55, endFrame: 60 },
    ],
    decor: { emoji: '💃', tone: 'joy', emphasisWordIndices: [0, 3] },
  },
  {
    id: 'sample-line-3',
    text: 'Forever young, forever free',
    startFrame: 60,
    endFrame: 90,
    words: [
      { text: 'Forever', startFrame: 60, endFrame: 68 },
      { text: 'young,', startFrame: 68, endFrame: 74 },
      { text: 'forever', startFrame: 74, endFrame: 82 },
      { text: 'free', startFrame: 82, endFrame: 90 },
    ],
    decor: { emoji: '✨', tone: 'love', emphasisWordIndices: [0, 3] },
  },
];

/**
 * Synthetic audio automation for a card: a steady 120 BPM grid
 * (a beat every 0.5 s, a downbeat every 4th), an onset envelope
 * that pulses on each beat and decays between them, band energies
 * that breathe per band, and a loudness curve that swells through
 * the 3 seconds. Deterministic formulas — no RNG, no audio file.
 * Confidence is 1: the grid is synthetic, so it is exactly right.
 */
export function buildSyntheticAutomation(
  durationSeconds: number = CARD_PREVIEW_DURATION_SECONDS,
  tempoBpm: number = 120,
): AudioAutomation {
  const hop = AUDIO_AUTOMATION_HOP_SECONDS;
  const hops = Math.max(1, Math.ceil(durationSeconds / hop));
  const beatInterval = 60 / tempoBpm;
  const beats: AudioAutomation['beats'] = [];
  for (let t = 0; t < durationSeconds; t += beatInterval) {
    const index = Math.round(t / beatInterval);
    beats.push({
      timeSeconds: Math.round(t * 1000) / 1000,
      isDownbeat: index % 4 === 0,
      strength: index % 4 === 0 ? 1 : 0.7,
    });
  }
  const onsetValues: number[] = [];
  const loudnessValues: number[] = [];
  const bandValues: number[][] = [];
  for (let i = 0; i < hops; i += 1) {
    const t = i * hop;
    // Onset: sharp pulse on each beat, exponential decay after.
    const sinceBeat = t % beatInterval;
    onsetValues.push(Math.max(0, 1 - sinceBeat / 0.18));
    // Loudness: a slow swell from -24 to -12 LUFS-like dB.
    loudnessValues.push(-24 + 12 * (0.5 + 0.5 * Math.sin((t / durationSeconds) * Math.PI)));
    // Bands: each band breathes at its own rate; bass follows the
    // beat, treble shimmers faster.
    bandValues.push(
      AUDIO_BAND_CENTERS_HZ.map((_, band) => {
        const phase = (t * (0.6 + band * 0.35)) % 1;
        const beatPulse = Math.max(0, 1 - sinceBeat / 0.25);
        const base = 0.25 + 0.35 * (0.5 + 0.5 * Math.sin(phase * Math.PI * 2));
        return Math.max(0, Math.min(1, base + (band < 3 ? beatPulse * 0.4 : 0)));
      }),
    );
  }
  return {
    version: AUDIO_AUTOMATION_VERSION,
    songKey: 'extra-styles-sample-clip',
    sampleRate: 0,
    durationSeconds,
    onsetEnvelope: { hopSeconds: hop, values: onsetValues },
    tempoBpm,
    beats,
    beatConfidence: 1,
    bandEnergies: { hopSeconds: hop, bandsHz: [...AUDIO_BAND_CENTERS_HZ], values: bandValues },
    loudnessCurve: { hopSeconds: hop, values: loudnessValues },
  };
}

/**
 * Synthetic subject-mask index for a card: no mask images (the
 * card clip is a still stage, not a segmented take), but a face
 * box drifting gently across the frame so face-aware styles have
 * a subject to track. The Swift parser accepts empty maskUris.
 */
export function buildSyntheticMaskIndex(
  durationSeconds: number = CARD_PREVIEW_DURATION_SECONDS,
): SubjectMaskIndex {
  const sampleTimesSeconds: number[] = [];
  const faces: SubjectMaskIndex['faces'] = [];
  for (let t = 0; t <= durationSeconds; t += 0.5) {
    const time = Math.round(t * 10) / 10;
    sampleTimesSeconds.push(time);
    // A centred portrait box, drifting ±4% horizontally.
    const drift = 0.04 * Math.sin((time / durationSeconds) * Math.PI * 2);
    faces.push({
      timeSeconds: time,
      boxes: [[0.35 + drift, 0.18, 0.3, 0.52]],
    });
  }
  return {
    version: 1,
    takeKey: 'extra-styles-sample-clip',
    sampleTimesSeconds,
    maskUris: [],
    faces,
  };
}

/**
 * Disk-cache key for a card preview clip: the style + its version
 * + its parameter values. A param change re-renders the card; the
 * same values reuse the cached mp4. Stable across launches.
 */
export function cardPreviewCacheKey(
  styleId: string,
  styleVersion: number,
  params: Record<string, ExtraStyleParamValue>,
): string {
  const canonical = JSON.stringify([styleId, styleVersion, params]);
  return fnv1a32(canonical).toString(16).padStart(8, '0');
}

/** File name for a cached card preview clip. */
export function cardPreviewFileName(cacheKey: string): string {
  return `extra-style-card-${cacheKey}.mp4`;
}
