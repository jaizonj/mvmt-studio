/**
 * Extra Styles 2.0 — the bundled sample clip (Phase 3, §12.2).
 *
 * Catalog cards render the actual composition over ONE shared
 * 3-second portrait clip (assets/extra-styles-sample-clip.mp4 —
 * a generated stage + spotlight + performer silhouette, made
 * with ffmpeg; a real performance clip can replace the file with
 * no code change). The native preview-clip renderer needs a real
 * on-device file URI, not a Metro module id — same pattern as
 * the watermark resolver (src/lib/watermark.ts).
 *
 * Resolution NEVER throws: any failure resolves to null, and
 * card previews fall back to a black background (the plain
 * renderExtraStylePreviewFrame path) — a missing clip must never
 * block the catalog.
 */

import { Asset } from 'expo-asset';

let cached: Promise<string | null> | null = null;

export function resolveSampleClipUri(): Promise<string | null> {
  if (!cached) {
    cached = (async () => {
      try {
        const asset = Asset.fromModule(require('../../../assets/extra-styles-sample-clip.mp4'));
        await asset.downloadAsync();
        return asset.localUri ?? null;
      } catch {
        return null;
      }
    })();
  }
  return cached;
}
