/**
 * Extra Styles 2.0 — card preview clips (Phase 3, §12.2).
 *
 * A card's animated preview is a short looping mp4: the style's
 * scene (at its default parameters, or the caller's params)
 * rendered over the bundled sample clip by the native
 * renderExtraStylePreviewClip, then played back looping with
 * expo-video. Renders happen on demand, when a card becomes
 * visible; the mp4 is cached on disk under a key of
 * (styleId, styleVersion, params), capped at 8 clips (LRU — the
 * oldest file is deleted on eviction). A cached clip is reused
 * only while its file still exists.
 *
 * Everything here is best-effort and never throws: a failed
 * render resolves to null and the card shows its static face.
 * The in-flight map stops two mounts of the same card rendering
 * the same clip twice.
 *
 * Not pure (native bridge + expo-file-system) — not in the Node
 * test compile. The cache-key math lives in sample.ts (pure, and
 * tested there).
 */

import { Directory, File, Paths } from 'expo-file-system';

import { renderExtraStylePreviewClip, releaseExtraStyleScene } from './bridge';
import { prepareCardPreviewScene } from './prepare';
import { defaultParams, resolveExtraStyleParams } from './params';
import {
  CARD_PREVIEW_DURATION_SECONDS,
  CARD_PREVIEW_FPS,
  CARD_PREVIEW_HEIGHT,
  CARD_PREVIEW_WIDTH,
  cardPreviewCacheKey,
} from './sample';
import type { ExtraStyleMetadata, ExtraStyleParamValue } from './types';

/** How many rendered card clips stay on disk (LRU). */
export const CARD_PREVIEW_CACHE_LIMIT = 8;

interface CardPreviewIndexEntry {
  key: string;
  styleId: string;
  uri: string;
  savedAt: number;
}

type CardPreviewIndex = CardPreviewIndexEntry[];

const INDEX_DIR = 'mvmt';
const INDEX_FILE = 'extra-style-card-previews.json';

const inMemory = new Map<string, string>();
const inFlight = new Map<string, Promise<string | null>>();

function indexFile(): File {
  const dir = new Directory(Paths.cache, INDEX_DIR);
  if (!dir.exists) dir.create({ intermediates: true });
  return new File(dir, INDEX_FILE);
}

async function readIndex(): Promise<CardPreviewIndex> {
  try {
    const file = indexFile();
    if (!file.exists) return [];
    const parsed = JSON.parse(await file.text()) as CardPreviewIndex;
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

async function writeIndex(index: CardPreviewIndex): Promise<void> {
  try {
    indexFile().write(JSON.stringify(index));
  } catch {
    // The cache index is advisory — a failed write just means
    // the next launch re-renders.
  }
}

function deleteCachedFile(uri: string): void {
  try {
    const file = new File(uri);
    if (file.exists) file.delete();
  } catch {
    // Best-effort cleanup.
  }
}

async function remember(key: string, styleId: string, uri: string): Promise<void> {
  const index = (await readIndex()).filter((e) => e.key !== key);
  index.push({ key, styleId, uri, savedAt: Date.now() });
  while (index.length > CARD_PREVIEW_CACHE_LIMIT) {
    const evicted = index.shift();
    if (evicted) deleteCachedFile(evicted.uri);
  }
  await writeIndex(index);
}

/**
 * The looping preview mp4 for a style card (or null when it
 * could not be rendered). `params` defaults to the style's
 * schema defaults — pass the project's live params for the
 * selected style's card so the preview matches the editor.
 */
export async function getExtraStyleCardPreview(
  metadata: ExtraStyleMetadata,
  clipUri: string,
  params?: Record<string, ExtraStyleParamValue>,
): Promise<string | null> {
  // Resolve first: the key and the scene must agree on the exact
  // values (a stray key must not mint a second cache entry for
  // the same render).
  const values = resolveExtraStyleParams(metadata.parameters, params ?? defaultParams(metadata.parameters)).params;
  const key = cardPreviewCacheKey(metadata.id, metadata.version, values);
  const cached = inMemory.get(key);
  if (cached) return cached;
  const existing = inFlight.get(key);
  if (existing) return existing;
  const promise = (async (): Promise<string | null> => {
    // Disk cache first (file must still exist).
    const index = await readIndex();
    const entry = index.find((e) => e.key === key);
    if (entry) {
      try {
        if (new File(entry.uri).exists) {
          inMemory.set(key, entry.uri);
          return entry.uri;
        }
      } catch {
        // Fall through to re-render.
      }
    }
    const handle = await prepareCardPreviewScene(metadata, values);
    if (!handle) return null;
    try {
      const uri = await renderExtraStylePreviewClip(
        handle,
        clipUri,
        CARD_PREVIEW_WIDTH,
        CARD_PREVIEW_HEIGHT,
        CARD_PREVIEW_DURATION_SECONDS,
        CARD_PREVIEW_FPS,
      );
      if (!uri) return null;
      inMemory.set(key, uri);
      await remember(key, metadata.id, uri);
      return uri;
    } finally {
      await releaseExtraStyleScene(handle);
    }
  })();
  inFlight.set(key, promise);
  try {
    return await promise;
  } finally {
    inFlight.delete(key);
  }
}
