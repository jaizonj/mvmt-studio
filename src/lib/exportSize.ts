/**
 * Export size control — the pure math behind the Export screen's
 * bitrate / target-file-size tiers (Balanced quality update).
 *
 * AVAssetExportSession cannot be told a bitrate, so controlled tiers
 * render as today and then pass through a native transcode
 * (AVAssetReader → AVAssetWriter) at an explicit video bitrate. The
 * formulas here are mirrored EXACTLY by the engine
 * (MvmtCompositorEngine.videoBitrate(forTargetSizeMB:durationSeconds:)
 * in the compositor module) so the size the UI promises is the size
 * the engine aims at — keep the two in step.
 */

/** Audio bitrate of a transcoded export: AAC stereo at 192 kbps. */
export const EXPORT_AUDIO_BITRATE_BPS = 192_000;

/**
 * Video bitrate floor for target-size computations: below ~800 kbps
 * a 1080p frame falls apart, so a target that would need less is met
 * as closely as the floor allows and the UI reports the real size.
 */
export const MIN_VIDEO_BITRATE_BPS = 800_000;

/** Headroom in the target-size formula for mux/encoder overshoot. */
export const TARGET_SIZE_SAFETY = 0.94;

/**
 * Default video bitrates for the controlled quality tiers when no
 * explicit file-size target is chosen — wired as the request's
 * `exportVideoBitrate`, so every non-High tier renders at a KNOWN
 * bitrate. TikTok's figure is the community-verified sweet spot for
 * 1080×1920 at 60fps; Balanced/Small are sized for easy sharing.
 */
export const TIER_DEFAULT_VIDEO_BITRATE_BPS = {
  tiktok: 16_000_000,
  balanced: 8_000_000,
  small: 4_500_000,
} as const;

/**
 * The video bitrate that makes a render of `durationSeconds` land at
 * `targetMB` total file size: the target's bits are split between
 * audio (a fixed AAC allowance) and video, with a safety factor for
 * encoder/mux overshoot, floored at MIN_VIDEO_BITRATE_BPS. 1 MB =
 * 1,000,000 bytes (8,000,000 bits), matching the engine.
 */
export function videoBitrateForTargetSize(
  targetMB: number,
  durationSeconds: number,
  audioBitrateBps: number = EXPORT_AUDIO_BITRATE_BPS,
): number {
  if (!(durationSeconds > 0) || !(targetMB > 0)) return MIN_VIDEO_BITRATE_BPS;
  const raw = ((targetMB * 8_000_000) / durationSeconds - audioBitrateBps) * TARGET_SIZE_SAFETY;
  return Math.max(MIN_VIDEO_BITRATE_BPS, Math.floor(raw));
}

/** Estimated total file size (bytes) of a render at the given rates. */
export function estimateExportBytes(
  videoBitrateBps: number,
  durationSeconds: number,
  audioBitrateBps: number = EXPORT_AUDIO_BITRATE_BPS,
): number {
  if (!(durationSeconds > 0)) return 0;
  return Math.round(((videoBitrateBps + audioBitrateBps) * durationSeconds) / 8);
}

/** "18.4 MB" / "812 KB" — the one formatter for estimates and results. */
export function formatFileSize(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return '0 KB';
  if (bytes >= 1_000_000) return `${(bytes / 1_000_000).toFixed(1)} MB`;
  return `${Math.max(1, Math.round(bytes / 1000))} KB`;
}
