/**
 * MVMT Studio design tokens — native iOS / Human Interface direction.
 *
 * Principles (from Jaizon's brief):
 * - Look like an Apple-made app: system font (no custom fontFamily anywhere —
 *   React Native uses SF Pro on iOS by default), large titles, generous
 *   spacing, grouped lists, bottom sheets.
 * - Restrained palette: near-black base, white/grey labels, ONE accent.
 * - Iridescent is an accent only — a thin gradient ring / hairline / selected
 *   state — never big rainbow surfaces.
 * - Camera controls are translucent materials (blur + tint), like iOS system
 *   overlays, so the picture always shows through.
 */
export const colors = {
  base: '#000000',
  groupedBackground: '#0B0B10',
  card: '#17171F',
  cardPressed: '#22222C',
  separator: 'rgba(255,255,255,0.12)',

  label: '#FFFFFF',
  // Raised from 0.6/0.3 (Jaizon's device test: not enough contrast over
  // bright video and dark cards alike).
  labelSecondary: 'rgba(235,235,245,0.82)',
  labelTertiary: 'rgba(235,235,245,0.5)',

  // Translucent materials over the camera (pair with BlurView). Darkened
  // from 0.55 alpha — controls washed out over bright scenes.
  material: 'rgba(16,16,24,0.78)',
  materialBorder: 'rgba(255,255,255,0.38)',

  accent: '#B9A7FF', // soft iridescent violet — the single accent colour
  accentDim: 'rgba(185,167,255,0.22)',
  danger: '#FF453A', // iOS system red
  success: '#30D158', // iOS system green

  /** Thin iridescent gradient — record ring, hairlines, selected chips only. */
  iridescent: ['#F5C6FF', '#B9C8FF', '#A9EFFF', '#C2FFDF'] as const,
};

export const spacing = {
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 20,
  xxl: 28,
  xxxl: 40,
};

/** iOS large-title / headline / body scale. No fontFamily: system font only. */
export const type = {
  largeTitle: { fontSize: 34, fontWeight: '700' as const, letterSpacing: 0.2 },
  title2: { fontSize: 22, fontWeight: '700' as const },
  headline: { fontSize: 17, fontWeight: '600' as const },
  body: { fontSize: 17, fontWeight: '400' as const },
  subhead: { fontSize: 15, fontWeight: '400' as const },
  footnote: { fontSize: 13, fontWeight: '400' as const },
  caption: { fontSize: 12, fontWeight: '500' as const },
};

export const radius = {
  sm: 8,
  md: 12,
  lg: 16,
  sheet: 20,
  pill: 999,
};

export function formatTime(totalSeconds: number): string {
  const safe = Math.max(0, Math.floor(totalSeconds));
  const m = Math.floor(safe / 60);
  const s = safe % 60;
  return `${m}:${s.toString().padStart(2, '0')}`;
}
