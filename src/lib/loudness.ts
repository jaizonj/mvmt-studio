/**
 * Auto volume — automatic loudness normalization of the master song.
 *
 * The engine measures the song region used by the composition
 * (K-weighted integrated loudness + sample peak, BS.1770-style) and
 * gains the composition's song track so the delivered video lands at
 * the level the short-form platforms normalize to: content already
 * at −14 LUFS passes through their processing untouched.
 *
 * This module is the JS MIRROR of the gain decision the engine makes
 * (MvmtCompositorEngine.normalizationGainDb in the compositor) — the
 * measurement itself is native-only (it needs decoded PCM), but the
 * decision is pure math, so it lives here where it can be unit
 * tested. Keep the two implementations in step.
 */

/** Integrated-loudness target (LUFS) — the platforms' level. */
export const LOUDNESS_TARGET_LUFS = -14;
/** True-peak ceiling (dBFS): applied gain never pushes past this. */
export const LOUDNESS_PEAK_CEILING_DBFS = -1;
/** At or below this the track counts as silence: never gained. */
export const LOUDNESS_SILENCE_LUFS = -60;
/** Gain is clamped to ±15 dB either way. */
export const LOUDNESS_MAX_GAIN_DB = 15;

/**
 * The gain (dB) to apply to a song measured at `measuredLufs` with
 * sample peak `peakDbfs`: enough to reach the target, capped so the
 * peak stays under the ceiling, clamped to ±15 dB. Returns null for
 * "apply nothing" — non-finite measurements (decode failure) and
 * silence, which must never be amplified into audibility.
 */
export function normalizationGainDb(measuredLufs: number, peakDbfs: number): number | null {
  if (!Number.isFinite(measuredLufs) || !Number.isFinite(peakDbfs)) return null;
  if (measuredLufs < LOUDNESS_SILENCE_LUFS) return null;
  const gain = Math.min(
    LOUDNESS_TARGET_LUFS - measuredLufs,
    LOUDNESS_PEAK_CEILING_DBFS - peakDbfs,
  );
  return Math.min(LOUDNESS_MAX_GAIN_DB, Math.max(-LOUDNESS_MAX_GAIN_DB, gain));
}
