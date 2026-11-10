import { useFonts } from 'expo-font';

/**
 * Loads the bundled lyric fonts for any surface that renders lyric
 * text (Editor, Export stage). System fonts need no loading. Returns
 * true once the bundled faces are usable; lyric text in a bundled
 * face falls back gracefully until then (React Native silently uses
 * the system font for unknown families).
 *
 * The source map lives here (not in the pure catalog module) because
 * the require()s of .ttf assets must never load outside Metro — the
 * node unit tests import the catalogs directly. Keys are PostScript
 * names: the key doubles as the React Native fontFamily (see
 * src/lib/lyricFonts.ts).
 */
const BUNDLED_FONT_SOURCES: Record<string, number> = {
  'Anton-Regular': require('../../assets/fonts/Anton-Regular.ttf'),
  'BebasNeue-Regular': require('../../assets/fonts/BebasNeue-Regular.ttf'),
  'Oswald-SemiBold': require('../../assets/fonts/Oswald-SemiBold.ttf'),
  'Montserrat-ExtraBold': require('../../assets/fonts/Montserrat-ExtraBold.ttf'),
  'ArchivoBlack-Regular': require('../../assets/fonts/ArchivoBlack-Regular.ttf'),
  'Bangers-Regular': require('../../assets/fonts/Bangers-Regular.ttf'),
  'LuckiestGuy-Regular': require('../../assets/fonts/LuckiestGuy-Regular.ttf'),
  'Pacifico-Regular': require('../../assets/fonts/Pacifico-Regular.ttf'),
  'DancingScript-Bold': require('../../assets/fonts/DancingScript-Bold.ttf'),
  'PermanentMarker-Regular': require('../../assets/fonts/PermanentMarker-Regular.ttf'),
};

export function useLyricFonts(): boolean {
  const [loaded] = useFonts(BUNDLED_FONT_SOURCES);
  return loaded;
}
