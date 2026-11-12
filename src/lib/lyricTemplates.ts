import type { LyricStyle } from '../types';

/**
 * Lyric templates — Extra Styles (Styles Redesign Stage 2,
 * docs/STYLES-REDESIGN.md §2).
 *
 * ONE template system, not 30 disconnected implementations: a
 * template is a complete creative treatment — its own typography,
 * palette, animation, composition, and a `decor` — the thing that
 * makes it EXTRA (an emoji row, a chat bubble, a comic burst…).
 * The decor is a SECOND parametric model with a `kind`
 * discriminator and generic params, resolved once per project the
 * same way the animation params are. A template is chosen in the
 * panel (stored as `ProjectLyrics.templateId`, optional — unset =
 * classic style) and the resolved style + decor travel in the SAME
 * composite payload the export already carries, so preview and
 * export cannot drift.
 *
 * This module is PURE DATA + lookups (like lyricFonts.ts /
 * lyricAnimations.ts) so the node unit tests load it directly.
 */

export type LyricDecorKind =
  | 'emoji-row'
  | 'chat-bubble'
  | 'comic-burst'
  | 'sticker-frame'
  | 'scanlines'
  | 'glow'
  | 'cursor'
  | 'burst'
  | 'pill';

/** The decor model, as authored in a template (fields optional). */
export interface LyricDecor {
  kind: LyricDecorKind;
  /** Accent colour (#RRGGBB or rgba()) — bubble fill, glow colour… */
  color?: string;
  /** Second colour — receiver bubble, burst stroke, sticker dots… */
  secondaryColor?: string;
  /** 0..1 — scanline strength, glow strength, bar opacity… */
  opacity?: number;
  /** Size multiplier — emoji size, burst travel… */
  scale?: number;
  /** Free text — the comic burst word ("POW"), etc. */
  text?: string;
}

/** The decor model, RESOLVED: every field present, defaults
 *  folded in. This is what crosses the bridge to Swift. */
export interface ResolvedLyricDecor {
  kind: LyricDecorKind;
  color: string;
  secondaryColor: string;
  opacity: number;
  scale: number;
  text: string;
}

export function resolveLyricDecor(decor: LyricDecor): ResolvedLyricDecor {
  return {
    kind: decor.kind,
    color: decor.color ?? '#FFFFFF',
    secondaryColor: decor.secondaryColor ?? '#101114',
    opacity: decor.opacity ?? 1,
    scale: decor.scale ?? 1,
    text: decor.text ?? '',
  };
}

export type ExtraStyleCategory = 'Story' | 'Chat' | 'Comic' | 'Playful' | 'Futuristic' | 'Classic';

export const EXTRA_STYLE_CATEGORIES: ExtraStyleCategory[] = [
  'Story',
  'Chat',
  'Comic',
  'Playful',
  'Futuristic',
  'Classic',
];

export interface LyricTemplate {
  id: string;
  name: string;
  tagline: string;
  category: ExtraStyleCategory;
  /** The template's style, merged into the project's LyricStyle on apply. */
  style: Partial<LyricStyle>;
  decor: LyricDecor;
}

/**
 * Every decor kind the JS preview implements. The Swift burn-in
 * implements the SAME set — `SWIFT_DECOR_KINDS` below is the
 * hand-maintained mirror of the Swift builders, and the contract
 * tests fail when the two lists differ, so a kind can never exist
 * on one side only.
 */
export const LYRIC_DECOR_KINDS: LyricDecorKind[] = [
  'emoji-row',
  'chat-bubble',
  'comic-burst',
  'sticker-frame',
  'scanlines',
  'glow',
  'cursor',
  'burst',
  'pill',
];

/** Mirror of the Swift-side decor builders
 *  (modules/mvmt-compositor/ios/MvmtCompositorModule.swift,
 *  `makeLyricDecorLayers`). Keep in step with LYRIC_DECOR_KINDS. */
export const SWIFT_DECOR_KINDS: LyricDecorKind[] = [
  'emoji-row',
  'chat-bubble',
  'comic-burst',
  'sticker-frame',
  'scanlines',
  'glow',
  'cursor',
  'burst',
  'pill',
];

/** Stage 2 — the first 10 Extra Styles (Stage 3 adds the other 20). */
export const LYRIC_TEMPLATES: LyricTemplate[] = [
  {
    id: 'emoji-story',
    name: 'Emoji Story',
    tagline: 'A matching emoji floats above every line',
    category: 'Story',
    style: {
      fontId: 'fredoka-semibold',
      sizeRatio: 0.09,
      color: '#F4F1E9',
      strokeColor: '#101114',
      strokeWidthRatio: 0.08,
      background: 'none',
      position: 'center',
      animationId: 'rise',
      bold: true,
    },
    decor: { kind: 'emoji-row', scale: 1.15 },
  },
  {
    id: 'chat',
    name: 'Chat',
    tagline: 'Lyrics as a messaging conversation',
    category: 'Chat',
    style: {
      fontId: 'avenir-next',
      sizeRatio: 0.075,
      color: '#101114',
      background: 'none',
      position: 'bottom',
      animationId: 'rise',
      bold: false,
    },
    decor: { kind: 'chat-bubble', color: '#C9F36B', secondaryColor: '#F4F1E9' },
  },
  {
    id: 'comic-book',
    name: 'Comic Book',
    tagline: 'Speech bursts and POW-styled emphasis',
    category: 'Comic',
    style: {
      fontId: 'bangers',
      sizeRatio: 0.11,
      color: '#FFD60A',
      strokeColor: '#101114',
      strokeWidthRatio: 0.12,
      background: 'none',
      position: 'center',
      // word-pop (stagger), not pop: emphasis words render
      // per-word in both renderers, so the flagged words can go big.
      animationId: 'word-pop',
      bold: true,
    },
    decor: { kind: 'comic-burst', color: '#FFD60A', secondaryColor: '#FF453A', text: 'POW' },
  },
  {
    id: 'word-explosion',
    name: 'Word Explosion',
    tagline: 'Words burst outward and settle, one by one',
    category: 'Playful',
    style: {
      fontId: 'archivo-black',
      sizeRatio: 0.1,
      color: '#F4F1E9',
      strokeColor: '#BF5AF2',
      strokeWidthRatio: 0.06,
      background: 'none',
      position: 'center',
      animationId: 'word-pop',
      bold: true,
    },
    decor: { kind: 'burst', color: '#BF5AF2', scale: 1 },
  },
  {
    id: 'scrapbook',
    name: 'Scrapbook',
    tagline: 'Handwritten words in a sticker frame',
    category: 'Playful',
    style: {
      fontId: 'caveat',
      sizeRatio: 0.105,
      color: '#101114',
      strokeColor: '#F4F1E9',
      strokeWidthRatio: 0.05,
      background: 'none',
      position: 'center',
      animationId: 'rise',
      bold: true,
    },
    decor: { kind: 'sticker-frame', color: '#FF9F0A', secondaryColor: '#64D2FF' },
  },
  {
    id: 'hologram',
    name: 'Hologram',
    tagline: 'Floating futuristic holographic type',
    category: 'Futuristic',
    style: {
      fontId: 'orbitron',
      sizeRatio: 0.08,
      color: '#64D2FF',
      background: 'none',
      position: 'center',
      animationId: 'fade',
      bold: true,
    },
    decor: { kind: 'scanlines', color: '#64D2FF', opacity: 0.5 },
  },
  {
    id: 'karaoke-pop',
    name: 'Karaoke Pop',
    tagline: 'Sung words pop big and glow gold',
    category: 'Classic',
    style: {
      fontId: 'montserrat-extrabold',
      sizeRatio: 0.095,
      color: '#F4F1E9',
      strokeColor: '#101114',
      strokeWidthRatio: 0.1,
      background: 'none',
      position: 'bottom',
      animationId: 'karaoke-pop',
      bold: true,
    },
    decor: { kind: 'glow', color: '#FFD60A', opacity: 0.6 },
  },
  {
    id: 'neon-sign',
    name: 'Neon Sign',
    tagline: 'Glowing neon type on a dark pill',
    category: 'Futuristic',
    style: {
      fontId: 'audiowide',
      sizeRatio: 0.09,
      color: '#BF5AF2',
      strokeColor: '#101114',
      strokeWidthRatio: 0.06,
      background: 'pill',
      backgroundColor: 'rgba(10,10,12,0.8)',
      position: 'center',
      animationId: 'pulse',
      bold: true,
    },
    decor: { kind: 'glow', color: '#BF5AF2', opacity: 0.8 },
  },
  {
    id: 'typewriter-classic',
    name: 'Typewriter Classic',
    tagline: 'Monospace type with a blinking cursor',
    category: 'Classic',
    style: {
      fontId: 'american-typewriter',
      sizeRatio: 0.08,
      color: '#F4F1E9',
      background: 'none',
      position: 'bottom',
      animationId: 'typewriter',
      bold: false,
    },
    decor: { kind: 'cursor', color: '#C9F36B' },
  },
  {
    id: 'film-subtitle',
    name: 'Film Subtitle',
    tagline: 'Clean cinema subtitle on a soft bar',
    category: 'Classic',
    style: {
      fontId: 'avenir-next',
      sizeRatio: 0.065,
      color: '#FFFFFF',
      background: 'none',
      position: 'bottom',
      animationId: 'fade',
      bold: false,
    },
    // Hex (not rgba): the Swift burn-in parses #RRGGBB only.
    decor: { kind: 'pill', color: '#0A0A0C', opacity: 0.7 },
  },
];

const byId = new Map(LYRIC_TEMPLATES.map((t) => [t.id, t]));

/** Catalog lookup; unknown ids return undefined (classic style). */
export function lyricTemplateById(id: string | null | undefined): LyricTemplate | undefined {
  if (!id) return undefined;
  return byId.get(id);
}
