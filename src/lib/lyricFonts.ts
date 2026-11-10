/**
 * Lyric font catalog — 36 faces for the lyrics renderer. This module
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
export interface LyricFont {
  id: string;
  displayName: string;
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
  { id: 'avenir-next', displayName: 'Avenir Next', family: 'Avenir Next', postScriptName: 'AvenirNext-Regular', boldPostScriptName: 'AvenirNext-Bold', kind: 'system' },
  { id: 'avenir-next-condensed', displayName: 'Avenir Condensed', family: 'Avenir Next Condensed', postScriptName: 'AvenirNextCondensed-Regular', boldPostScriptName: 'AvenirNextCondensed-Bold', kind: 'system' },
  { id: 'helvetica-neue', displayName: 'Helvetica Neue', family: 'Helvetica Neue', postScriptName: 'HelveticaNeue', boldPostScriptName: 'HelveticaNeue-Bold', kind: 'system' },
  { id: 'futura', displayName: 'Futura', family: 'Futura', postScriptName: 'Futura-Medium', boldPostScriptName: 'Futura-Bold', kind: 'system' },
  { id: 'gill-sans', displayName: 'Gill Sans', family: 'Gill Sans', postScriptName: 'GillSans', boldPostScriptName: 'GillSans-Bold', kind: 'system' },
  { id: 'optima', displayName: 'Optima', family: 'Optima', postScriptName: 'Optima-Regular', boldPostScriptName: 'Optima-Bold', kind: 'system' },
  { id: 'copperplate', displayName: 'Copperplate', family: 'Copperplate', postScriptName: 'Copperplate', boldPostScriptName: 'Copperplate-Bold', kind: 'system' },
  { id: 'din-alternate', displayName: 'DIN Alternate', family: 'DIN Alternate', postScriptName: 'DINAlternate-Bold', boldPostScriptName: 'DINAlternate-Bold', kind: 'system' },
  { id: 'rockwell', displayName: 'Rockwell', family: 'Rockwell', postScriptName: 'Rockwell-Regular', boldPostScriptName: 'Rockwell-Bold', kind: 'system' },
  { id: 'superclarendon', displayName: 'Superclarendon', family: 'Superclarendon', postScriptName: 'Superclarendon-Regular', boldPostScriptName: 'Superclarendon-Bold', kind: 'system' },
  { id: 'didot', displayName: 'Didot', family: 'Didot', postScriptName: 'Didot', boldPostScriptName: 'Didot-Bold', kind: 'system' },
  { id: 'bodoni-72', displayName: 'Bodoni 72', family: 'Bodoni 72', postScriptName: 'BodoniSvtyTwoITCTT-Book', boldPostScriptName: 'BodoniSvtyTwoITCTT-Bold', kind: 'system' },
  { id: 'baskerville', displayName: 'Baskerville', family: 'Baskerville', postScriptName: 'Baskerville', boldPostScriptName: 'Baskerville-Bold', kind: 'system' },
  { id: 'georgia', displayName: 'Georgia', family: 'Georgia', postScriptName: 'Georgia', boldPostScriptName: 'Georgia-Bold', kind: 'system' },
  { id: 'palatino', displayName: 'Palatino', family: 'Palatino', postScriptName: 'Palatino-Roman', boldPostScriptName: 'Palatino-Bold', kind: 'system' },
  { id: 'cochin', displayName: 'Cochin', family: 'Cochin', postScriptName: 'Cochin', boldPostScriptName: 'Cochin-Bold', kind: 'system' },
  { id: 'american-typewriter', displayName: 'Typewriter', family: 'American Typewriter', postScriptName: 'AmericanTypewriter', boldPostScriptName: 'AmericanTypewriter-Bold', kind: 'system' },
  { id: 'courier-new', displayName: 'Courier New', family: 'Courier New', postScriptName: 'CourierNewPSMT', boldPostScriptName: 'CourierNewPS-BoldMT', kind: 'system' },
  { id: 'menlo', displayName: 'Menlo', family: 'Menlo', postScriptName: 'Menlo-Regular', boldPostScriptName: 'Menlo-Bold', kind: 'system' },
  { id: 'marker-felt', displayName: 'Marker Felt', family: 'Marker Felt', postScriptName: 'MarkerFelt-Thin', kind: 'system' },
  { id: 'noteworthy', displayName: 'Noteworthy', family: 'Noteworthy', postScriptName: 'Noteworthy-Light', boldPostScriptName: 'Noteworthy-Bold', kind: 'system' },
  { id: 'chalkboard-se', displayName: 'Chalkboard', family: 'Chalkboard SE', postScriptName: 'ChalkboardSE-Regular', boldPostScriptName: 'ChalkboardSE-Bold', kind: 'system' },
  { id: 'snell-roundhand', displayName: 'Snell Roundhand', family: 'Snell Roundhand', postScriptName: 'SnellRoundhand', kind: 'system' },
  { id: 'zapfino', displayName: 'Zapfino', family: 'Zapfino', postScriptName: 'Zapfino', kind: 'system' },
  { id: 'papyrus', displayName: 'Papyrus', family: 'Papyrus', postScriptName: 'Papyrus', kind: 'system' },
  { id: 'party-let', displayName: 'Party LET', family: 'Party LET', postScriptName: 'PartyLetPlain', kind: 'system' },

  // ---- Bundled OFL display fonts (assets/fonts/, SIL OFL 1.1) --------
  // PostScript names verified against the shipped TTF name tables.
  { id: 'anton', displayName: 'Anton', family: 'Anton-Regular', postScriptName: 'Anton-Regular', kind: 'bundled' },
  { id: 'bebas-neue', displayName: 'Bebas Neue', family: 'BebasNeue-Regular', postScriptName: 'BebasNeue-Regular', kind: 'bundled' },
  { id: 'oswald-semibold', displayName: 'Oswald', family: 'Oswald-SemiBold', postScriptName: 'Oswald-SemiBold', kind: 'bundled' },
  { id: 'montserrat-extrabold', displayName: 'Montserrat XBold', family: 'Montserrat-ExtraBold', postScriptName: 'Montserrat-ExtraBold', kind: 'bundled' },
  { id: 'archivo-black', displayName: 'Archivo Black', family: 'ArchivoBlack-Regular', postScriptName: 'ArchivoBlack-Regular', kind: 'bundled' },
  { id: 'bangers', displayName: 'Bangers', family: 'Bangers-Regular', postScriptName: 'Bangers-Regular', kind: 'bundled' },
  { id: 'luckiest-guy', displayName: 'Luckiest Guy', family: 'LuckiestGuy-Regular', postScriptName: 'LuckiestGuy-Regular', kind: 'bundled' },
  { id: 'pacifico', displayName: 'Pacifico', family: 'Pacifico-Regular', postScriptName: 'Pacifico-Regular', kind: 'bundled' },
  { id: 'dancing-script', displayName: 'Dancing Script', family: 'DancingScript-Bold', postScriptName: 'DancingScript-Bold', kind: 'bundled' },
  { id: 'permanent-marker', displayName: 'Permanent Marker', family: 'PermanentMarker-Regular', postScriptName: 'PermanentMarker-Regular', kind: 'bundled' },
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
