import { Asset } from 'expo-asset';

/**
 * The MVMT studio logo watermark (assets/logo-lockup.png — the brand
 * lockup: Jaizon's mvmt wordmark over a lowercase "studio", stretched
 * to the same width, on transparency).
 *
 * The native compositor stamps the image onto the composition, so it
 * needs a real on-device file URI, not a Metro module id. This module
 * resolves the bundled asset to its local file URI once and caches
 * the promise — the Editor preview and the Export render share it.
 *
 * Resolution NEVER throws: any failure resolves to null, and callers
 * pass the flag through regardless — a missing image must never block
 * an edit or an export.
 */

let cached: Promise<string | null> | null = null;

export function resolveWatermarkUri(): Promise<string | null> {
  if (!cached) {
    cached = (async () => {
      try {
        const asset = Asset.fromModule(require('../../assets/logo-lockup.png'));
        await asset.downloadAsync();
        return asset.localUri ?? null;
      } catch {
        return null;
      }
    })();
  }
  return cached;
}
