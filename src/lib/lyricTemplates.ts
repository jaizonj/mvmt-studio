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
  | 'pill'
  // Stage 3 kinds:
  | 'rule'
  | 'spray'
  | 'shadow'
  | 'duet'
  | 'ghost-trail'
  | 'rain'
  | 'bounce'
  | 'wave-path'
  | 'typing-dots'
  | 'split-screen'
  | 'none';

/** The decor model, as authored in a template (fields optional). */
export interface LyricDecor {
  kind: LyricDecorKind;
  /** Accent colour (#RRGGBB or rgba()) — bubble fill, glow colour… */
  color?: string;
  /** Second colour — receiver bubble, burst stroke, sticker dots… */
  secondaryColor?: string;
  /** 0..1 — scanline strength, glow strength, bar opacity… For
   *  kind 'none' it is the LINE's text opacity (Whisper). */
  opacity?: number;
  /** Size multiplier — emoji size, burst travel… */
  scale?: number;
  /** Free text — the comic burst word ("POW"), etc. */
  text?: string;
  /** Static rotation of the whole line, degrees (Graffiti).
   *  Applied outside the line's enter/exit animation on both
   *  sides, so it never fights the animation transform. */
  rotationDeg?: number;
  /** Letter-spacing as a fraction of the font size (Minimal Mono).
   *  0 = normal spacing. */
  tracking?: number;
  /** Horizontal alignment of the line (Minimal Mono sits left).
   *  'center' is the classic behaviour. */
  align?: 'left' | 'center' | 'right';
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
  rotationDeg: number;
  tracking: number;
  align: 'left' | 'center' | 'right';
}

export function resolveLyricDecor(decor: LyricDecor): ResolvedLyricDecor {
  return {
    kind: decor.kind,
    color: decor.color ?? '#FFFFFF',
    secondaryColor: decor.secondaryColor ?? '#101114',
    opacity: decor.opacity ?? 1,
    scale: decor.scale ?? 1,
    text: decor.text ?? '',
    rotationDeg: decor.rotationDeg ?? 0,
    tracking: decor.tracking ?? 0,
    align: decor.align ?? 'center',
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
  'rule',
  'spray',
  'shadow',
  'duet',
  'ghost-trail',
  'rain',
  'bounce',
  'wave-path',
  'typing-dots',
  'split-screen',
  'none',
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
  'rule',
  'spray',
  'shadow',
  'duet',
  'ghost-trail',
  'rain',
  'bounce',
  'wave-path',
  'typing-dots',
  'split-screen',
  'none',
];

/** All 30 Extra Styles — Stage 2 shipped the first 10, Stage 3
 *  the remaining 20 below. Every template is a complete creative
 *  treatment: own font, palette, animation, composition, decor. */
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

  // ---- Stage 3 — the remaining 20 Extra Styles -------------------
  {
    id: 'magazine',
    name: 'Magazine',
    tagline: 'Big serif headline between lime rules',
    category: 'Classic',
    style: {
      fontId: 'playfair-display',
      sizeRatio: 0.11,
      color: '#F4F1E9',
      background: 'none',
      position: 'center',
      animationId: 'rise',
      bold: true,
    },
    decor: { kind: 'rule', color: '#C9F36B', opacity: 0.9 },
  },
  {
    id: 'graffiti',
    name: 'Graffiti',
    tagline: 'Spray-painted marker type, tilted and dotted',
    category: 'Playful',
    style: {
      fontId: 'permanent-marker',
      sizeRatio: 0.1,
      color: '#FFD60A',
      strokeColor: '#FF453A',
      strokeWidthRatio: 0.08,
      background: 'none',
      position: 'center',
      animationId: 'word-pop',
      bold: true,
    },
    decor: { kind: 'spray', color: '#FF453A', secondaryColor: '#64D2FF', rotationDeg: -3 },
  },
  {
    id: 'retro-tv',
    name: 'Retro TV',
    tagline: 'Pixel type on a dark tube screen',
    category: 'Classic',
    style: {
      fontId: 'press-start-2p',
      sizeRatio: 0.055,
      color: '#F4F1E9',
      background: 'pill',
      backgroundColor: 'rgba(10,10,12,0.75)',
      position: 'center',
      animationId: 'fade',
      bold: false,
    },
    decor: { kind: 'scanlines', color: '#F4F1E9', opacity: 0.35 },
  },
  {
    id: 'minimal-mono',
    name: 'Minimal Mono',
    tagline: 'Tiny letterspaced mono, low and left',
    category: 'Classic',
    style: {
      fontId: 'menlo',
      sizeRatio: 0.045,
      color: '#F4F1E9',
      background: 'none',
      position: 'bottom',
      animationId: 'fade',
      bold: false,
    },
    decor: { kind: 'none', tracking: 0.35, align: 'left' },
  },
  {
    id: 'big-bold-billboard',
    name: 'Big Bold Billboard',
    tagline: 'Huge condensed caps with a hard shadow',
    category: 'Playful',
    style: {
      fontId: 'anton',
      sizeRatio: 0.13,
      color: '#FFFFFF',
      strokeColor: '#101114',
      strokeWidthRatio: 0.1,
      background: 'none',
      position: 'center',
      animationId: 'impact',
      bold: true,
    },
    decor: { kind: 'shadow', color: '#101114', opacity: 0.85 },
  },
  {
    id: 'duet',
    name: 'Duet',
    tagline: 'Call and response — lime low, blue high',
    category: 'Story',
    style: {
      fontId: 'avenir-next',
      sizeRatio: 0.085,
      color: '#F4F1E9',
      background: 'none',
      position: 'bottom',
      animationId: 'rise',
      bold: true,
    },
    decor: { kind: 'duet', color: '#C9F36B', secondaryColor: '#64D2FF' },
  },
  {
    id: 'echo',
    name: 'Echo',
    tagline: 'The line repeats behind itself, fading',
    category: 'Playful',
    style: {
      fontId: 'avenir-next',
      sizeRatio: 0.09,
      color: '#F4F1E9',
      strokeColor: '#101114',
      strokeWidthRatio: 0.06,
      background: 'none',
      position: 'center',
      animationId: 'fade',
      bold: true,
    },
    decor: { kind: 'ghost-trail', color: '#F4F1E9', opacity: 0.35, scale: 1 },
  },
  {
    id: 'spotlight',
    name: 'Spotlight',
    tagline: 'Dark type on a glowing gold pill',
    category: 'Classic',
    style: {
      fontId: 'avenir-next',
      sizeRatio: 0.09,
      color: '#101114',
      background: 'pill',
      backgroundColor: 'rgba(244,241,233,0.9)',
      position: 'center',
      animationId: 'fade',
      bold: true,
    },
    decor: { kind: 'glow', color: '#FFD60A', opacity: 0.6 },
  },
  {
    id: 'rain',
    name: 'Rain',
    tagline: 'Words fall in from above, one by one',
    category: 'Playful',
    style: {
      fontId: 'avenir-next',
      sizeRatio: 0.085,
      color: '#64D2FF',
      strokeColor: '#101114',
      strokeWidthRatio: 0.05,
      background: 'none',
      position: 'center',
      animationId: 'cascade',
      bold: true,
    },
    decor: { kind: 'rain', color: '#64D2FF', scale: 1 },
  },
  {
    id: 'bounce-house',
    name: 'Bounce House',
    tagline: 'Every word bounces in with overshoot',
    category: 'Playful',
    style: {
      fontId: 'fredoka-semibold',
      sizeRatio: 0.1,
      color: '#FFD60A',
      strokeColor: '#FF453A',
      strokeWidthRatio: 0.07,
      background: 'none',
      position: 'center',
      animationId: 'word-pop',
      bold: true,
    },
    decor: { kind: 'bounce', color: '#FFD60A', scale: 1 },
  },
  {
    id: 'elegant-script',
    name: 'Elegant Script',
    tagline: 'Slow script between fine gold rules',
    category: 'Classic',
    style: {
      fontId: 'snell-roundhand',
      sizeRatio: 0.1,
      color: '#F4F1E9',
      background: 'none',
      position: 'center',
      animationId: 'fade',
      bold: false,
    },
    decor: { kind: 'rule', color: '#C9F36B', opacity: 0.7 },
  },
  {
    id: 'cyberpunk',
    name: 'Cyberpunk',
    tagline: 'Magenta type, cyan split, glitch jitter',
    category: 'Futuristic',
    style: {
      fontId: 'orbitron',
      sizeRatio: 0.085,
      color: '#FF2E88',
      strokeColor: '#00E5FF',
      strokeWidthRatio: 0.08,
      background: 'none',
      position: 'center',
      animationId: 'jitter',
      bold: true,
    },
    decor: { kind: 'glow', color: '#00E5FF', opacity: 0.7 },
  },
  {
    id: 'storybook',
    name: 'Storybook',
    tagline: 'Gentle serif on a soft dark pill, ruled',
    category: 'Story',
    style: {
      fontId: 'palatino',
      sizeRatio: 0.085,
      color: '#F4F1E9',
      background: 'pill',
      backgroundColor: 'rgba(16,17,20,0.6)',
      position: 'center',
      animationId: 'rise',
      bold: false,
    },
    decor: { kind: 'rule', color: '#FFD60A', opacity: 0.6 },
  },
  {
    id: 'sticker-pop',
    name: 'Sticker Pop',
    tagline: 'Chunky type, thick white stroke, dark bar',
    category: 'Playful',
    style: {
      fontId: 'luckiest-guy',
      sizeRatio: 0.11,
      color: '#FFD60A',
      strokeColor: '#FFFFFF',
      strokeWidthRatio: 0.14,
      background: 'none',
      position: 'center',
      animationId: 'pop',
      bold: true,
    },
    decor: { kind: 'pill', color: '#101114', opacity: 0.85 },
  },
  {
    id: 'wave-rider',
    name: 'Wave Rider',
    tagline: 'Words ride a sine wave across the line',
    category: 'Playful',
    style: {
      fontId: 'fredoka-semibold',
      sizeRatio: 0.09,
      color: '#64D2FF',
      strokeColor: '#101114',
      strokeWidthRatio: 0.06,
      background: 'none',
      position: 'center',
      animationId: 'word-rise',
      bold: true,
    },
    decor: { kind: 'wave-path', color: '#64D2FF', scale: 1 },
  },
  {
    id: 'countdown',
    name: 'Countdown',
    tagline: 'Huge words slam in, one after another',
    category: 'Playful',
    style: {
      fontId: 'anton',
      sizeRatio: 0.13,
      color: '#FFFFFF',
      strokeColor: '#FF453A',
      strokeWidthRatio: 0.08,
      background: 'none',
      position: 'center',
      animationId: 'word-zoom',
      bold: true,
    },
    decor: { kind: 'glow', color: '#FFD60A', opacity: 0.7 },
  },
  {
    id: 'whisper',
    name: 'Whisper',
    tagline: 'Tiny and faint, up in the corner',
    category: 'Classic',
    style: {
      fontId: 'avenir-next-condensed',
      sizeRatio: 0.045,
      color: '#F4F1E9',
      background: 'none',
      position: 'top',
      animationId: 'fade',
      bold: false,
    },
    decor: { kind: 'none', opacity: 0.55 },
  },
  {
    id: 'anthem',
    name: 'Anthem',
    tagline: 'Huge gold-stroked caps, slow zoom',
    category: 'Classic',
    style: {
      fontId: 'cinzel',
      sizeRatio: 0.12,
      color: '#F4F1E9',
      strokeColor: '#FFD60A',
      strokeWidthRatio: 0.1,
      background: 'none',
      position: 'center',
      animationId: 'zoom',
      bold: true,
    },
    decor: { kind: 'glow', color: '#FFD60A', opacity: 0.5 },
  },
  {
    id: 'text-message-typing',
    name: 'Text Message Typing',
    tagline: 'Typing dots, then the message appears',
    category: 'Chat',
    style: {
      fontId: 'avenir-next',
      sizeRatio: 0.075,
      color: '#101114',
      background: 'none',
      position: 'bottom',
      animationId: 'typewriter',
      bold: false,
    },
    decor: { kind: 'typing-dots', color: '#C9F36B', secondaryColor: '#F4F1E9' },
  },
  {
    id: 'split-screen-words',
    name: 'Split Screen Words',
    tagline: 'Words alternate top and bottom halves',
    category: 'Playful',
    style: {
      fontId: 'montserrat-extrabold',
      sizeRatio: 0.085,
      color: '#FFFFFF',
      strokeColor: '#101114',
      strokeWidthRatio: 0.08,
      background: 'none',
      position: 'center',
      animationId: 'word-pop',
      bold: true,
    },
    decor: { kind: 'split-screen', color: '#FFFFFF', scale: 1 },
  },
];

const byId = new Map(LYRIC_TEMPLATES.map((t) => [t.id, t]));

/** Catalog lookup; unknown ids return undefined (classic style). */
export function lyricTemplateById(id: string | null | undefined): LyricTemplate | undefined {
  if (!id) return undefined;
  return byId.get(id);
}
