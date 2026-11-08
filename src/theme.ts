/**
 * MVMT Studio design tokens — Overhaul design system (2026-11-08).
 *
 * Identity: a premium, music-first creative studio.
 * - Deep graphite surfaces (#101114 family), warm-white text (#F4F1E9),
 *   ONE accent: acid lime (#C9F36B). No competing accent colours, no
 *   decorative gradients on surfaces (the record ring keeps a subtle
 *   lime ramp — the single sanctioned gradient).
 * - System font only (SF Pro on iOS by default — no fontFamily anywhere).
 * - Restrained borders, consistent radii, generous spacing, large
 *   cinematic media areas. References: Apple Camera (capture clarity),
 *   Final Cut Pro (editor gravity), CapCut (approachability) — with a
 *   distinct MVMT voice, not a copy of any of them.
 *
 * Token NAMES are stable across the overhaul so screens can be
 * redesigned one at a time against the same surface.
 */
export const colors = {
  base: '#101114',
  groupedBackground: '#101114',
  card: '#17181D',
  cardPressed: '#1F2026',
  elevated: '#1D1E24',
  separator: 'rgba(244,241,233,0.10)',

  label: '#F4F1E9',
  labelSecondary: 'rgba(244,241,233,0.68)',
  labelTertiary: 'rgba(244,241,233,0.42)',

  // Translucent materials over the camera, so the picture shows through.
  material: 'rgba(16,17,20,0.78)',
  materialBorder: 'rgba(244,241,233,0.22)',

  accent: '#C9F36B', // acid lime — the single accent colour
  accentDim: 'rgba(201,243,107,0.16)',
  /** Text/icons drawn ON the accent colour. */
  onAccent: '#14160C',
  danger: '#FF453A', // iOS system red
  success: '#7BD88F',

  /** The one sanctioned gradient (record ring / key selected states). */
  iridescent: ['#E9FFA8', '#C9F36B', '#A8E04A', '#C9F36B'] as const,
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

/** Type scale — system font, MVMT weights. */
export const type = {
  largeTitle: { fontSize: 34, fontWeight: '700' as const, letterSpacing: 0.2 },
  title2: { fontSize: 22, fontWeight: '700' as const },
  headline: { fontSize: 17, fontWeight: '600' as const },
  body: { fontSize: 17, fontWeight: '400' as const },
  subhead: { fontSize: 15, fontWeight: '400' as const },
  footnote: { fontSize: 13, fontWeight: '400' as const },
  caption: { fontSize: 12, fontWeight: '500' as const },
};

/** One radius scale everywhere — no per-screen improvisation. */
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
