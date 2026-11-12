/**
 * Region helper (used by the song/part picker, the Record screen and
 * the Editor).
 *
 * This module used to also hold the Shuffle engine's analysis: phrase
 * sectioning, per-section energy sampling and the take-energy
 * heuristic. That whole pipeline went away with the Shuffle
 * (2026-11-12, Jaizon: "auto edit is out") — the only analysis the
 * app still does is resolving the selected song part against the
 * track's real duration, which lives here.
 */

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
