/**
 * Extra Styles 2.0 — catalog (Phase 2 core engine).
 *
 * The 40-style capability mapping (docs §17) is the coverage spec:
 * every style names what it needs from the engine, and the test
 * asserts every named capability is in ENGINE_CAPABILITIES. The
 * five demos (★) are marked — they are the first five built in
 * Phase 3, not a gate.
 *
 * The live catalog itself is Swift-native (docs §3.1); this file
 * holds the static mapping (for the coverage proof) plus the
 * client-side helpers over the metadata the bridge returns
 * (search, category filter, favorites-first sort).
 */

import type { ExtraStyleCapability, ExtraStyleCatalog, ExtraStyleCategory, ExtraStyleMetadata } from './types';
import { ENGINE_CAPABILITIES } from './types';

export interface StyleCapabilityEntry {
  id: string;
  name: string;
  category: ExtraStyleCategory;
  /** The five demos are the first five built in Phase 3. */
  demo?: boolean;
  capabilities: ExtraStyleCapability[];
  needsAudioAutomation: boolean;
  needsSubjectMasks: boolean;
}

export const STYLE_CAPABILITY_MAP: StyleCapabilityEntry[] = [
  { id: 'dream-sequence', name: 'Dream Sequence', category: 'cinematic', demo: true, capabilities: ['text-line', 'particles', 'paths', 'keyframes', 'looping', 'seeded-random', 'audio-loudness', 'subject-mask'], needsAudioAutomation: true, needsSubjectMasks: false },
  { id: 'memory-fragments', name: 'Memory Fragments', category: 'cinematic', capabilities: ['nested-groups', 'images', 'keyframes', 'stagger', 'subject-face'], needsAudioAutomation: false, needsSubjectMasks: false },
  { id: 'floating-universe', name: 'Floating Universe', category: 'cinematic', capabilities: ['particles', 'shapes', 'paths', 'path-animation', 'looping', 'text-line'], needsAudioAutomation: false, needsSubjectMasks: false },
  { id: 'film-credits-reimagined', name: 'Film Credits Reimagined', category: 'cinematic', capabilities: ['text-line', 'shapes', 'gradients', 'keyframes'], needsAudioAutomation: false, needsSubjectMasks: false },
  { id: 'parallel-worlds', name: 'Parallel Worlds', category: 'cinematic', capabilities: ['text-line', 'masks', 'keyframes', 'audio-beat', 'second-video-layer'], needsAudioAutomation: true, needsSubjectMasks: false },
  { id: 'typography-physics', name: 'Typography Physics', category: 'typography', demo: true, capabilities: ['text-char', 'physics', 'springs', 'seeded-random', 'audio-onset'], needsAudioAutomation: true, needsSubjectMasks: false },
  { id: 'liquid-letters', name: 'Liquid Letters', category: 'typography', capabilities: ['text-line', 'shapes', 'paths', 'keyframes', 'audio-loudness'], needsAudioAutomation: true, needsSubjectMasks: false },
  { id: 'infinite-tunnel', name: 'Infinite Tunnel', category: 'typography', capabilities: ['shapes', 'text-line', 'looping', 'keyframes', 'audio-beat'], needsAudioAutomation: true, needsSubjectMasks: false },
  { id: 'portal-typography', name: 'Portal Typography', category: 'typography', capabilities: ['shapes', 'gradients', 'keyframes', 'path-animation', 'sections'], needsAudioAutomation: false, needsSubjectMasks: false },
  { id: 'typography-explosion', name: 'Typography Explosion', category: 'typography', capabilities: ['text-char', 'shapes', 'springs', 'seeded-random', 'audio-onset'], needsAudioAutomation: true, needsSubjectMasks: false },
  { id: 'holographic-interface', name: 'Holographic Interface', category: 'digital', demo: true, capabilities: ['nested-groups', 'shapes', 'gradients', 'keyframes', 'looping', 'seeded-random'], needsAudioAutomation: false, needsSubjectMasks: false },
  { id: 'digital-corruption', name: 'Digital Corruption', category: 'digital', capabilities: ['text-line', 'rgb-split', 'blend-modes', 'masks', 'keyframes', 'seeded-random', 'audio-onset'], needsAudioAutomation: true, needsSubjectMasks: false },
  { id: 'cyber-terminal', name: 'Cyber Terminal', category: 'digital', capabilities: ['nested-groups', 'text-char', 'shapes', 'keyframes', 'stagger'], needsAudioAutomation: false, needsSubjectMasks: false },
  { id: 'virtual-reality', name: 'Virtual Reality', category: 'digital', capabilities: ['nested-groups', 'text-line', 'perspective', 'subject-face', 'keyframes'], needsAudioAutomation: false, needsSubjectMasks: true },
  { id: 'data-visualization', name: 'Data Visualization', category: 'digital', capabilities: ['shapes', 'paths', 'counters', 'keyframes', 'audio-bands', 'audio-loudness'], needsAudioAutomation: true, needsSubjectMasks: false },
  { id: 'editorial-magazine', name: 'Editorial Magazine', category: 'design', capabilities: ['text-line', 'text-phrase', 'shapes', 'paths', 'keyframes'], needsAudioAutomation: false, needsSubjectMasks: false },
  { id: 'brutalist-typography', name: 'Brutalist Typography', category: 'design', capabilities: ['text-line', 'shapes', 'keyframes', 'audio-onset'], needsAudioAutomation: true, needsSubjectMasks: false },
  { id: 'collage-explosion', name: 'Collage Explosion', category: 'design', capabilities: ['text-char', 'images', 'shapes', 'keyframes', 'stagger', 'seeded-random'], needsAudioAutomation: false, needsSubjectMasks: false },
  { id: 'ink-and-paint', name: 'Ink and Paint', category: 'design', capabilities: ['paths', 'shapes', 'particles', 'keyframes'], needsAudioAutomation: false, needsSubjectMasks: false },
  { id: 'neon-sign-world', name: 'Neon Sign World', category: 'design', capabilities: ['text-line', 'shapes', 'gradients', 'blend-modes', 'keyframes', 'seeded-random'], needsAudioAutomation: false, needsSubjectMasks: false },
  { id: 'emoji-storytelling', name: 'Emoji Storytelling', category: 'playful', demo: true, capabilities: ['emoji', 'text-line', 'nested-groups', 'springs', 'stagger', 'semantic-tags', 'looping'], needsAudioAutomation: false, needsSubjectMasks: false },
  { id: 'cartoon-universe', name: 'Cartoon Universe', category: 'playful', capabilities: ['shapes', 'paths', 'nested-groups', 'springs', 'keyframes'], needsAudioAutomation: false, needsSubjectMasks: false },
  { id: 'message-universe', name: 'Message Universe', category: 'playful', capabilities: ['nested-groups', 'shapes', 'emoji', 'keyframes', 'looping', 'text-line'], needsAudioAutomation: false, needsSubjectMasks: false },
  { id: 'comic-book', name: 'Comic Book', category: 'playful', demo: true, capabilities: ['nested-groups', 'shapes', 'text-line', 'text-word', 'paths', 'springs', 'keyframes', 'audio-onset'], needsAudioAutomation: true, needsSubjectMasks: false },
  { id: 'sticker-world', name: 'Sticker World', category: 'playful', capabilities: ['images', 'text-line', 'springs', 'stagger'], needsAudioAutomation: false, needsSubjectMasks: false },
  { id: 'soundwave-typography', name: 'Soundwave Typography', category: 'music', capabilities: ['text-line', 'text-word', 'paths', 'path-animation', 'audio-bands', 'audio-onset'], needsAudioAutomation: true, needsSubjectMasks: false },
  { id: 'beat-reactor', name: 'Beat Reactor', category: 'music', capabilities: ['text-line', 'shapes', 'keyframes', 'audio-beat', 'audio-onset'], needsAudioAutomation: true, needsSubjectMasks: false },
  { id: 'frequency-universe', name: 'Frequency Universe', category: 'music', capabilities: ['shapes', 'particles', 'gradients', 'blend-modes', 'audio-bands', 'audio-loudness'], needsAudioAutomation: true, needsSubjectMasks: false },
  { id: 'rhythm-typography', name: 'Rhythm Typography', category: 'music', capabilities: ['text-word', 'text-char', 'syllables', 'springs', 'keyframes', 'audio-beat', 'audio-onset'], needsAudioAutomation: true, needsSubjectMasks: false },
  { id: 'audio-energy-world', name: 'Audio Energy World', category: 'music', capabilities: ['text-line', 'audio-loudness', 'keyframes', 'particles'], needsAudioAutomation: true, needsSubjectMasks: false },
  { id: 'glitch-reality', name: 'Glitch Reality', category: 'experimental', capabilities: ['displacement', 'text-line', 'masks', 'keyframes', 'seeded-random', 'audio-onset'], needsAudioAutomation: true, needsSubjectMasks: false },
  { id: 'surveillance-system', name: 'Surveillance System', category: 'experimental', capabilities: ['shapes', 'text-line', 'keyframes', 'subject-face', 'subject-mask'], needsAudioAutomation: false, needsSubjectMasks: true },
  { id: 'newspaper-explosion', name: 'Newspaper Explosion', category: 'experimental', capabilities: ['text-line', 'text-word', 'shapes', 'paths', 'keyframes', 'seeded-random'], needsAudioAutomation: false, needsSubjectMasks: false },
  { id: 'vhs-dream', name: 'VHS Dream', category: 'experimental', capabilities: ['text-line', 'shapes', 'displacement', 'keyframes', 'seeded-random'], needsAudioAutomation: false, needsSubjectMasks: false },
  { id: 'optical-illusion', name: 'Optical Illusion', category: 'experimental', capabilities: ['shapes', 'nested-groups', 'text-line', 'looping', 'keyframes', 'perspective'], needsAudioAutomation: false, needsSubjectMasks: false },
  { id: 'blueprint-world', name: 'Blueprint World', category: 'experimental', capabilities: ['paths', 'shapes', 'text-line', 'keyframes', 'stagger'], needsAudioAutomation: false, needsSubjectMasks: false },
  { id: 'kinetic-sculpture', name: 'Kinetic Sculpture', category: 'experimental', capabilities: ['shapes', 'paths', 'path-animation', 'looping', 'perspective'], needsAudioAutomation: false, needsSubjectMasks: false },
  { id: 'mirror-world', name: 'Mirror World', category: 'experimental', capabilities: ['text-line', 'shapes', 'gradients', 'masks', 'keyframes'], needsAudioAutomation: false, needsSubjectMasks: false },
  { id: 'living-typography', name: 'Living Typography', category: 'experimental', capabilities: ['text-char', 'shapes', 'paths', 'springs', 'seeded-random', 'audio-loudness'], needsAudioAutomation: true, needsSubjectMasks: false },
  { id: 'reality-distortion', name: 'Reality Distortion', category: 'experimental', capabilities: ['displacement', 'text-line', 'keyframes', 'audio-onset'], needsAudioAutomation: true, needsSubjectMasks: false },
];

/**
 * Coverage proof: every capability named by any of the 40 styles
 * must be implemented by the engine. Returns the missing ones
 * (empty = covered). The test asserts this is empty.
 */
export function missingEngineCapabilities(
  map: StyleCapabilityEntry[] = STYLE_CAPABILITY_MAP,
  capabilities: ExtraStyleCapability[] = ENGINE_CAPABILITIES,
): { styleId: string; capability: ExtraStyleCapability }[] {
  const have = new Set(capabilities);
  const missing: { styleId: string; capability: ExtraStyleCapability }[] = [];
  for (const entry of map) {
    for (const cap of entry.capabilities) {
      if (!have.has(cap)) missing.push({ styleId: entry.id, capability: cap });
    }
  }
  return missing;
}

// ---------------------------------------------------------------------------
// Client-side helpers over the bridge metadata (docs §12). Pure
// functions — the catalog UI (Phase 3) calls these, never the
// registry directly.
// ---------------------------------------------------------------------------

/** Styles the UI may show: internal / harness styles excluded. */
export function userVisibleStyles(catalog: ExtraStyleCatalog): ExtraStyleMetadata[] {
  return catalog.styles.filter((s) => !s.internal);
}

export function styleMetadataById(
  catalog: ExtraStyleCatalog,
  styleId: string,
): ExtraStyleMetadata | undefined {
  return catalog.styles.find((s) => s.id === styleId);
}

/** Search across name + tagline + category (case-insensitive). */
export function searchExtraStyleCatalog(catalog: ExtraStyleCatalog, query: string): ExtraStyleMetadata[] {
  const q = query.trim().toLowerCase();
  const styles = userVisibleStyles(catalog);
  if (q.length === 0) return styles;
  return styles.filter(
    (s) =>
      s.name.toLowerCase().includes(q) ||
      s.tagline.toLowerCase().includes(q) ||
      s.category.toLowerCase().includes(q),
  );
}

export function filterExtraStylesByCategory(
  catalog: ExtraStyleCatalog,
  category: ExtraStyleCategory,
): ExtraStyleMetadata[] {
  return userVisibleStyles(catalog).filter((s) => s.category === category);
}

/** Favorites first (in favourite order), then the rest in catalog order. */
export function sortExtraStylesWithFavoritesFirst(
  styles: ExtraStyleMetadata[],
  favoriteStyleIds: string[] | undefined,
): ExtraStyleMetadata[] {
  const favs = favoriteStyleIds ?? [];
  const rank = new Map(favs.map((id, i) => [id, i]));
  return [...styles].sort((a, b) => {
    const ra = rank.has(a.id) ? rank.get(a.id)! : Number.POSITIVE_INFINITY;
    const rb = rank.has(b.id) ? rank.get(b.id)! : Number.POSITIVE_INFINITY;
    return ra - rb;
  });
}
