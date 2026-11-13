/**
 * Extra Styles 2.0 — audio automation sampling (Phase 2 core engine).
 *
 * The native analysis (docs §9.2) decodes the song once and writes
 * the AudioAutomation artifact; this module only SAMPLES the curves
 * at a frame — onset strength, beat phase, band energies, loudness.
 * No analysis at render time, ever. All sampling is pure and
 * deterministic, so the same frame always reads the same values.
 *
 * Confidence gating (docs §9.2): styles gate beat reactions on
 * `beatConfidence`. Low confidence → fall back to the onset
 * envelope (any strong onset still triggers a reaction) → fall
 * back to the section energy. A style never renders a wrong beat
 * as if it were confident.
 */

import type { AudioAutomation, AudioAutomationBeat } from './types';
import { AUDIO_AUTOMATION_HOP_SECONDS, AUDIO_AUTOMATION_VERSION } from './types';

export const BEAT_CONFIDENCE_THRESHOLD = 0.5;

export interface BeatPhase {
  /** Is there a beat grid at all (confidence-gated)? */
  hasBeat: boolean;
  /** Frames since the nearest beat at or before this frame. */
  framesSinceBeat: number | null;
  /** Frames until the next beat after this frame. */
  framesUntilBeat: number | null;
  /** The nearest beat is a downbeat. */
  isDownbeat: boolean;
  /** Strength of the nearest beat (0..1). */
  beatStrength: number;
  /** 0..1 phase inside the current beat interval (0 = on the beat). */
  phase: number | null;
}

/** Linear interpolation of a hop-sampled curve at a time. */
function sampleCurve(values: number[], hopSeconds: number, timeSeconds: number): number {
  if (values.length === 0) return 0;
  if (values.length === 1) return values[0];
  const pos = timeSeconds / hopSeconds;
  const i = Math.floor(pos);
  if (i <= 0) return values[0];
  if (i >= values.length - 1) return values[values.length - 1];
  const f = pos - i;
  return values[i] + (values[i + 1] - values[i]) * f;
}

function frameToSeconds(frame: number, fps: number): number {
  return frame / fps;
}

/** Onset strength (0..1) at a frame — spectral flux, hop-sampled. */
export function sampleOnset(automation: AudioAutomation | null, frame: number, fps = 30): number {
  if (!automation) return 0;
  return sampleCurve(
    automation.onsetEnvelope.values,
    automation.onsetEnvelope.hopSeconds || AUDIO_AUTOMATION_HOP_SECONDS,
    frameToSeconds(frame, fps),
  );
}

/** Per-band energies (0..1, one per band in AUDIO_BAND_CENTERS_HZ order) at a frame. */
export function sampleBandEnergies(
  automation: AudioAutomation | null,
  frame: number,
  fps = 30,
): number[] {
  if (!automation) return [];
  const hop = automation.bandEnergies.hopSeconds || AUDIO_AUTOMATION_HOP_SECONDS;
  const time = frameToSeconds(frame, fps);
  const values = automation.bandEnergies.values;
  if (values.length === 0) return [];
  const pos = time / hop;
  const i = Math.floor(pos);
  const at = (idx: number): number[] => values[Math.max(0, Math.min(values.length - 1, idx))];
  if (i <= 0) return [...at(0)];
  if (i >= values.length - 1) return [...at(values.length - 1)];
  const f = pos - i;
  const a = at(i);
  const b = at(i + 1);
  return a.map((v, band) => v + ((b[band] ?? v) - v) * f);
}

/** Short-term loudness (K-weighted, LUFS-like) at a frame. */
export function sampleLoudness(automation: AudioAutomation | null, frame: number, fps = 30): number {
  if (!automation) return 0;
  return sampleCurve(
    automation.loudnessCurve.values,
    automation.loudnessCurve.hopSeconds || AUDIO_AUTOMATION_HOP_SECONDS,
    frameToSeconds(frame, fps),
  );
}

/** Nearest beat at or before a time (binary search — beats are sorted). */
function nearestBeatAtOrBefore(beats: AudioAutomationBeat[], timeSeconds: number): number {
  let lo = 0;
  let hi = beats.length - 1;
  let best = -1;
  while (lo <= hi) {
    const mid = Math.floor((lo + hi) / 2);
    if (beats[mid].timeSeconds <= timeSeconds) {
      best = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return best;
}

/**
 * Beat phase at a frame (docs §9.3): frames since/until the
 * nearest beat, downbeat flag, strength, and 0..1 phase inside
 * the beat interval. When confidence is below the threshold the
 * grid is reported as absent (hasBeat = false) — callers fall
 * back to the onset envelope instead of rendering a wrong beat.
 */
export function beatPhaseAtFrame(
  automation: AudioAutomation | null,
  frame: number,
  fps = 30,
): BeatPhase {
  const absent: BeatPhase = {
    hasBeat: false,
    framesSinceBeat: null,
    framesUntilBeat: null,
    isDownbeat: false,
    beatStrength: 0,
    phase: null,
  };
  if (!automation || automation.beats.length === 0) return absent;
  if (automation.beatConfidence < BEAT_CONFIDENCE_THRESHOLD) return absent;
  const time = frameToSeconds(frame, fps);
  const idx = nearestBeatAtOrBefore(automation.beats, time);
  const prev = idx >= 0 ? automation.beats[idx] : null;
  const next = idx + 1 < automation.beats.length ? automation.beats[idx + 1] : null;
  if (!prev && !next) return absent;
  if (!prev) {
    return {
      ...absent,
      hasBeat: true,
      framesUntilBeat: Math.max(0, Math.round((next!.timeSeconds - time) * fps)),
      beatStrength: next!.strength,
    };
  }
  const since = Math.max(0, Math.round((time - prev.timeSeconds) * fps));
  let until: number | null = null;
  let phase: number | null = null;
  if (next) {
    until = Math.max(0, Math.round((next.timeSeconds - time) * fps));
    const interval = next.timeSeconds - prev.timeSeconds;
    phase = interval > 0 ? (time - prev.timeSeconds) / interval : 0;
  }
  return {
    hasBeat: true,
    framesSinceBeat: since,
    framesUntilBeat: until,
    isDownbeat: prev.isDownbeat,
    beatStrength: prev.strength,
    phase,
  };
}

/** Should beat reactions use the grid, or fall back to onsets? */
export function automationHasConfidentBeat(automation: AudioAutomation | null): boolean {
  return !!automation && automation.beats.length > 0 && automation.beatConfidence >= BEAT_CONFIDENCE_THRESHOLD;
}

/**
 * A zeroed artifact for when analysis is unavailable (Expo Go,
 * undecodable file, silence): styles render their non-reactive
 * behaviour. Never throws, never blocks a preview or export.
 */
export function emptyAutomation(songKey: string, durationSeconds: number): AudioAutomation {
  const hops = Math.max(1, Math.ceil(durationSeconds / AUDIO_AUTOMATION_HOP_SECONDS));
  return {
    version: AUDIO_AUTOMATION_VERSION,
    songKey,
    sampleRate: 0,
    durationSeconds,
    onsetEnvelope: { hopSeconds: AUDIO_AUTOMATION_HOP_SECONDS, values: new Array(hops).fill(0) },
    tempoBpm: 0,
    beats: [],
    beatConfidence: 0,
    bandEnergies: {
      hopSeconds: AUDIO_AUTOMATION_HOP_SECONDS,
      bandsHz: [],
      values: Array.from({ length: hops }, () => []),
    },
    loudnessCurve: { hopSeconds: AUDIO_AUTOMATION_HOP_SECONDS, values: new Array(hops).fill(0) },
  };
}
