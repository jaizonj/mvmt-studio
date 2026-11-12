/**
 * Lyric font catalog — 50 faces for the lyrics renderer. This module
 * is PURE DATA + lookups (the node unit tests load it transitively);
 * the useFonts loader hook lives in src/components/useLyricFonts.ts.
 *
 * Two kinds:
 * - 'system': iOS built-in families, always available. `family` is
 *   the iOS family name React Native resolves (fontWeight picks the
 *   bold face inside the family); `postScriptName` is the REGULAR
 *   face's PostScript name, which is what the native export renderer
 *   (CATextLayer) looks the font up by.
 * - 'bundled': OFL display fonts shipped in assets/fonts/, embedded
 *   at build time by the expo-font config plugin (app.json) AND
 *   loadable at runtime with useFonts (src/components/useLyricFonts.ts
 *   holds the source map, keyed by PostScript name). For these,
 *   `family` IS the PostScript name — the
 *   one identifier that resolves identically in React Native (when
 *   loaded under that key), in CoreText and in the export renderer.
 *   Their PostScript names were READ from the actual TTF name tables
 *   (fontTools), never guessed.
 *
 * `boldPostScriptName`, when present, is the family's real bold face:
 * the resolved export style prefers it when the style's bold flag is
 * on; otherwise the base PostScript name + the bold flag travel and
 * the native renderer synthesises/trait-matches the weight.
 */
/** Browse categories for the Style tab picker (docs/STYLES-REDESIGN.md §1). */
export type LyricFontCategory =
  | 'Clean Sans'
  | 'Serif & Elegant'
  | 'Handwritten & Playful'
  | 'Display & Impact'
  | 'Typewriter & Mono'
  | 'Script';

export const LYRIC_FONT_CATEGORIES: LyricFontCategory[] = [
  'Clean Sans',
  'Serif & Elegant',
  'Handwritten & Playful',
  'Display & Impact',
  'Typewriter & Mono',
  'Script',
];

export interface LyricFont {
  id: string;
  displayName: string;
  /** Browse category for the Style tab picker. */
  category: LyricFontCategory;
  /** React Native fontFamily value. */
  family: string;
  /** PostScript name the native export renderer resolves. */
  postScriptName: string;
  kind: 'system' | 'bundled';
  /** Real bold face's PostScript name, when the family has one. */
  boldPostScriptName?: string;
}

export const LYRIC_FONTS: LyricFont[] = [
  // ---- iOS system families -------------------------------------------
  { id: 'avenir-next', displayName: 'Avenir Next', family: 'Avenir Next', postScriptName: 'AvenirNext-Regular', boldPostScriptName: 'AvenirNext-Bold', kind: 'system', category: 'Clean Sans' },
  { id: 'avenir-next-condensed', displayName: 'Avenir Condensed', family: 'Avenir Next Condensed', postScriptName: 'AvenirNextCondensed-Regular', boldPostScriptName: 'AvenirNextCondensed-Bold', kind: 'system', category: 'Clean Sans' },
  { id: 'helvetica-neue', displayName: 'Helvetica Neue', family: 'Helvetica Neue', postScriptName: 'HelveticaNeue', boldPostScriptName: 'HelveticaNeue-Bold', kind: 'system', category: 'Clean Sans' },
  { id: 'futura', displayName: 'Futura', family: 'Futura', postScriptName: 'Futura-Medium', boldPostScriptName: 'Futura-Bold', kind: 'system', category: 'Clean Sans' },
  { id: 'gill-sans', displayName: 'Gill Sans', family: 'Gill Sans', postScriptName: 'GillSans', boldPostScriptName: 'GillSans-Bold', kind: 'system', category: 'Clean Sans' },
  { id: 'optima', displayName: 'Optima', family: 'Optima', postScriptName: 'Optima-Regular', boldPostScriptName: 'Optima-Bold', kind: 'system', category: 'Clean Sans' },
  { id: 'copperplate', displayName: 'Copperplate', family: 'Copperplate', postScriptName: 'Copperplate', boldPostScriptName: 'Copperplate-Bold', kind: 'system', category: 'Display & Impact' },
  { id: 'din-alternate', displayName: 'DIN Alternate', family: 'DIN Alternate', postScriptName: 'DINAlternate-Bold', boldPostScriptName: 'DINAlternate-Bold', kind: 'system', category: 'Clean Sans' },
  { id: 'rockwell', displayName: 'Rockwell', family: 'Rockwell', postScriptName: 'Rockwell-Regular', boldPostScriptName: 'Rockwell-Bold', kind: 'system', category: 'Serif & Elegant' },
  { id: 'superclarendon', displayName: 'Superclarendon', family: 'Superclarendon', postScriptName: 'Superclarendon-Regular', boldPostScriptName: 'Superclarendon-Bold', kind: 'system', category: 'Serif & Elegant' },
  { id: 'didot', displayName: 'Didot', family: 'Didot', postScriptName: 'Didot', boldPostScriptName: 'Didot-Bold', kind: 'system', category: 'Serif & Elegant' },
  { id: 'bodoni-72', displayName: 'Bodoni 72', family: 'Bodoni 72', postScriptName: 'BodoniSvtyTwoITCTT-Book', boldPostScriptName: 'BodoniSvtyTwoITCTT-Bold', kind: 'system', category: 'Serif & Elegant' },
  { id: 'baskerville', displayName: 'Baskerville', family: 'Baskerville', postScriptName: 'Baskerville', boldPostScriptName: 'Baskerville-Bold', kind: 'system', category: 'Serif & Elegant' },
  { id: 'georgia', displayName: 'Georgia', family: 'Georgia', postScriptName: 'Georgia', boldPostScriptName: 'Georgia-Bold', kind: 'system', category: 'Serif & Elegant' },
  { id: 'palatino', displayName: 'Palatino', family: 'Palatino', postScriptName: 'Palatino-Roman', boldPostScriptName: 'Palatino-Bold', kind: 'system', category: 'Serif & Elegant' },
  { id: 'cochin', displayName: 'Cochin', family: 'Cochin', postScriptName: 'Cochin', boldPostScriptName: 'Cochin-Bold', kind: 'system', category: 'Serif & Elegant' },
  { id: 'american-typewriter', displayName: 'Typewriter', family: 'American Typewriter', postScriptName: 'AmericanTypewriter', boldPostScriptName: 'AmericanTypewriter-Bold', kind: 'system', category: 'Typewriter & Mono' },
  { id: 'courier-new', displayName: 'Courier New', family: 'Courier New', postScriptName: 'CourierNewPSMT', boldPostScriptName: 'CourierNewPS-BoldMT', kind: 'system', category: 'Typewriter & Mono' },
  { id: 'menlo', displayName: 'Menlo', family: 'Menlo', postScriptName: 'Menlo-Regular', boldPostScriptName: 'Menlo-Bold', kind: 'system', category: 'Typewriter & Mono' },
  { id: 'marker-felt', displayName: 'Marker Felt', family: 'Marker Felt', postScriptName: 'MarkerFelt-Thin', kind: 'system', category: 'Handwritten & Playful' },
  { id: 'noteworthy', displayName: 'Noteworthy', family: 'Noteworthy', postScriptName: 'Noteworthy-Light', boldPostScriptName: 'Noteworthy-Bold', kind: 'system', category: 'Handwritten & Playful' },
  { id: 'chalkboard-se', displayName: 'Chalkboard', family: 'Chalkboard SE', postScriptName: 'ChalkboardSE-Regular', boldPostScriptName: 'ChalkboardSE-Bold', kind: 'system', category: 'Handwritten & Playful' },
  { id: 'snell-roundhand', displayName: 'Snell Roundhand', family: 'Snell Roundhand', postScriptName: 'SnellRoundhand', kind: 'system', category: 'Script' },
  { id: 'zapfino', displayName: 'Zapfino', family: 'Zapfino', postScriptName: 'Zapfino', kind: 'system', category: 'Script' },
  { id: 'papyrus', displayName: 'Papyrus', family: 'Papyrus', postScriptName: 'Papyrus', kind: 'system', category: 'Script' },
  { id: 'party-let', displayName: 'Party LET', family: 'Party LET', postScriptName: 'PartyLetPlain', kind: 'system', category: 'Handwritten & Playful' },

  // ---- Bundled OFL display fonts (assets/fonts/, SIL OFL 1.1) --------
  // PostScript names verified against the shipped TTF name tables.
  { id: 'anton', displayName: 'Anton', family: 'Anton-Regular', postScriptName: 'Anton-Regular', kind: 'bundled', category: 'Clean Sans' },
  { id: 'bebas-neue', displayName: 'Bebas Neue', family: 'BebasNeue-Regular', postScriptName: 'BebasNeue-Regular', kind: 'bundled', category: 'Clean Sans' },
  { id: 'oswald-semibold', displayName: 'Oswald', family: 'Oswald-SemiBold', postScriptName: 'Oswald-SemiBold', kind: 'bundled', category: 'Clean Sans' },
  { id: 'montserrat-extrabold', displayName: 'Montserrat XBold', family: 'Montserrat-ExtraBold', postScriptName: 'Montserrat-ExtraBold', kind: 'bundled', category: 'Clean Sans' },
  { id: 'archivo-black', displayName: 'Archivo Black', family: 'ArchivoBlack-Regular', postScriptName: 'ArchivoBlack-Regular', kind: 'bundled', category: 'Clean Sans' },
  { id: 'bangers', displayName: 'Bangers', family: 'Bangers-Regular', postScriptName: 'Bangers-Regular', kind: 'bundled', category: 'Handwritten & Playful' },
  { id: 'luckiest-guy', displayName: 'Luckiest Guy', family: 'LuckiestGuy-Regular', postScriptName: 'LuckiestGuy-Regular', kind: 'bundled', category: 'Handwritten & Playful' },
  { id: 'pacifico', displayName: 'Pacifico', family: 'Pacifico-Regular', postScriptName: 'Pacifico-Regular', kind: 'bundled', category: 'Handwritten & Playful' },
  { id: 'dancing-script', displayName: 'Dancing Script', family: 'DancingScript-Bold', postScriptName: 'DancingScript-Bold', kind: 'bundled', category: 'Handwritten & Playful' },
  { id: 'permanent-marker', displayName: 'Permanent Marker', family: 'PermanentMarker-Regular', postScriptName: 'PermanentMarker-Regular', kind: 'bundled', category: 'Handwritten & Playful' },
  { id: 'alfa-slab-one', displayName: 'Alfa Slab One', family: 'AlfaSlabOne-Regular', postScriptName: 'AlfaSlabOne-Regular', kind: 'bundled', category: 'Display & Impact' },
  { id: 'righteous', displayName: 'Righteous', family: 'Righteous-Regular', postScriptName: 'Righteous-Regular', kind: 'bundled', category: 'Display & Impact' },
  { id: 'bungee', displayName: 'Bungee', family: 'Bungee-Regular', postScriptName: 'Bungee-Regular', kind: 'bundled', category: 'Display & Impact' },
  { id: 'fredoka-semibold', displayName: 'Fredoka', family: 'Fredoka-SemiBold', postScriptName: 'Fredoka-SemiBold', kind: 'bundled', category: 'Handwritten & Playful' },
  { id: 'abril-fatface', displayName: 'Abril Fatface', family: 'AbrilFatface-Regular', postScriptName: 'AbrilFatface-Regular', kind: 'bundled', category: 'Serif & Elegant' },
  { id: 'playfair-display', displayName: 'Playfair Display', family: 'PlayfairDisplay-Bold', postScriptName: 'PlayfairDisplay-Bold', kind: 'bundled', category: 'Serif & Elegant' },
  { id: 'dm-serif-display', displayName: 'DM Serif Display', family: 'DMSerifDisplay-Regular', postScriptName: 'DMSerifDisplay-Regular', kind: 'bundled', category: 'Serif & Elegant' },
  { id: 'cinzel', displayName: 'Cinzel', family: 'Cinzel-Bold', postScriptName: 'Cinzel-Bold', kind: 'bundled', category: 'Serif & Elegant' },
  { id: 'audiowide', displayName: 'Audiowide', family: 'Audiowide-Regular', postScriptName: 'Audiowide-Regular', kind: 'bundled', category: 'Display & Impact' },
  { id: 'orbitron', displayName: 'Orbitron', family: 'Orbitron-Bold', postScriptName: 'Orbitron-Bold', kind: 'bundled', category: 'Display & Impact' },
  { id: 'caveat', displayName: 'Caveat', family: 'Caveat-Bold', postScriptName: 'Caveat-Bold', kind: 'bundled', category: 'Handwritten & Playful' },
  // Shadows Into Light's PostScript name genuinely has no weight
  // suffix in the shipped TTF (read from its name table, like all).
  { id: 'shadows-into-light', displayName: 'Shadows Into Light', family: 'ShadowsIntoLight', postScriptName: 'ShadowsIntoLight', kind: 'bundled', category: 'Handwritten & Playful' },
  { id: 'press-start-2p', displayName: 'Press Start 2P', family: 'PressStart2P-Regular', postScriptName: 'PressStart2P-Regular', kind: 'bundled', category: 'Display & Impact' },
  { id: 'rubik-mono-one', displayName: 'Rubik Mono One', family: 'RubikMonoOne-Regular', postScriptName: 'RubikMonoOne-Regular', kind: 'bundled', category: 'Clean Sans' },
];

export const DEFAULT_FONT_ID = 'avenir-next';

const byId = new Map(LYRIC_FONTS.map((f) => [f.id, f]));
const byPostScriptName = new Map<string, LyricFont>();
for (const font of LYRIC_FONTS) {
  byPostScriptName.set(font.postScriptName, font);
  if (font.boldPostScriptName) byPostScriptName.set(font.boldPostScriptName, font);
}

/** Catalog lookup; unknown ids fall back to the default font. */
export function lyricFontById(id: string): LyricFont {
  return byId.get(id) ?? byId.get(DEFAULT_FONT_ID)!;
}

/** Reverse lookup — the preview overlay only receives the resolved
 *  PostScript name (via the composite payload) and maps it back to
 *  the React Native family here. Bold-face PostScript names resolve
 *  to the same catalog entry. Undefined when unknown. */
export function lyricFontByPostScriptName(postScriptName: string): LyricFont | undefined {
  return byPostScriptName.get(postScriptName);
}
