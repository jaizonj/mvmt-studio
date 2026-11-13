import type { LookParams, ProjectLook } from '../types';

/**
 * Video looks — tasteful, preset-first colour grades for the cut.
 *
 * Follows the app's parametric pattern (lyric fonts/animations): a
 * preset is just a named point in ONE numeric parameter space
 * (LookParams, src/types.ts). The stored project look is
 * { presetId, intensity, overrides? }; `resolveLookParams` turns it
 * into the single numeric set the native engine applies (a CI filter
 * chain in the compositor — the engine has no preset catalog).
 *
 * Looks are an EDIT/EXPORT-stage grade: they ride the composition
 * request like the watermark/lyrics, so the editor's native preview
 * and the export render show exactly the same picture. The Record
 * screen's raw camera preview never carries a look.
 *
 * Magnitudes are deliberately small — these are finishing touches
 * (a lift, a warmth, a touch of bite), not Instagram-clown filters.
 */

/** The neutral parameter set: rendering with it changes nothing. */
export const IDENTITY_LOOK_PARAMS: LookParams = {
  brightness: 0,
  contrast: 1,
  saturation: 1,
  exposureEV: 0,
  temperature: 0,
  vibrance: 0,
  sharpen: 0,
  vignette: 0,
};

/** Legal range per parameter — presets and overrides clamp to these. */
export const LOOK_PARAM_RANGES: Record<keyof LookParams, { min: number; max: number }> = {
  brightness: { min: -0.15, max: 0.15 },
  contrast: { min: 0.85, max: 1.2 },
  saturation: { min: 0, max: 1.6 },
  exposureEV: { min: -0.7, max: 0.7 },
  temperature: { min: -30, max: 30 },
  vibrance: { min: -1, max: 1 },
  sharpen: { min: 0, max: 1.2 },
  vignette: { min: 0, max: 1.2 },
};

const LOOK_PARAM_KEYS = Object.keys(LOOK_PARAM_RANGES) as (keyof LookParams)[];

/** Two params closer than this on every axis count as the same look. */
const IDENTITY_EPSILON = 0.001;

export interface LookPreset {
  id: string;
  name: string;
  /** One-line character note, shown in the Edit screen's picker. */
  blurb: string;
  params: LookParams;
}

/** A full param set with the unspecified axes at identity. */
function params(partial: Partial<LookParams>): LookParams {
  return { ...IDENTITY_LOOK_PARAMS, ...partial };
}

export const LOOK_PRESETS: LookPreset[] = [
  {
    id: 'original',
    name: 'Original',
    blurb: 'No grade — the video exactly as shot.',
    params: params({}),
  },
  {
    id: 'auto-enhance',
    name: 'Auto Enhance',
    blurb: 'A gentle all-round lift.',
    params: params({ exposureEV: 0.12, contrast: 1.06, saturation: 1.08, vibrance: 0.25, sharpen: 0.35 }),
  },
  {
    id: 'vivid',
    name: 'Vivid',
    blurb: 'Colours turned up, still believable.',
    params: params({ exposureEV: 0.05, contrast: 1.08, saturation: 1.32, vibrance: 0.4 }),
  },
  {
    id: 'punch',
    name: 'Punch',
    blurb: 'Contrast and bite for flat, grey footage.',
    params: params({ exposureEV: 0.03, contrast: 1.16, saturation: 1.18, sharpen: 0.5 }),
  },
  {
    id: 'crisp',
    name: 'Crisp',
    blurb: 'Sharpening first — edges and detail pop.',
    params: params({ contrast: 1.07, saturation: 1.05, vibrance: 0.15, sharpen: 0.9 }),
  },
  {
    id: 'warm-glow',
    name: 'Warm Glow',
    blurb: 'Cosy warmth with softly darkened edges.',
    params: params({ exposureEV: 0.08, saturation: 1.1, temperature: 14, vibrance: 0.2, vignette: 0.25 }),
  },
  {
    id: 'golden-hour',
    name: 'Golden Hour',
    blurb: 'Late-sun warmth and a mellow frame.',
    params: params({ exposureEV: 0.1, contrast: 1.04, saturation: 1.12, temperature: 22, vibrance: 0.25, vignette: 0.35 }),
  },
  {
    id: 'cool-tone',
    name: 'Cool Tone',
    blurb: 'A cooler, cleaner cast — good under LEDs.',
    params: params({ exposureEV: 0.02, contrast: 1.05, saturation: 1.06, temperature: -14 }),
  },
  {
    id: 'daylight',
    name: 'Daylight',
    blurb: 'Brighter and fresher, like stepping outside.',
    params: params({ exposureEV: 0.18, contrast: 1.03, saturation: 1.05, temperature: -4, sharpen: 0.3 }),
  },
  {
    id: 'night-lift',
    name: 'Night Lift',
    blurb: 'Lifts dim rooms without slamming the contrast.',
    params: params({ brightness: 0.04, exposureEV: 0.45, contrast: 0.96, saturation: 1.05, vibrance: 0.2, sharpen: 0.25 }),
  },
  {
    id: 'stage',
    name: 'Stage',
    blurb: 'Exposure and colour that hold up under gig lighting.',
    params: params({ exposureEV: 0.25, contrast: 1.14, saturation: 1.15, vibrance: 0.3, sharpen: 0.4 }),
  },
  {
    id: 'soft',
    name: 'Soft',
    blurb: 'Lowered contrast, nothing harsh — kind to skin.',
    params: params({ brightness: 0.03, exposureEV: 0.06, contrast: 0.92, saturation: 0.95 }),
  },
  {
    id: 'dream',
    name: 'Dream',
    blurb: 'Bright, hazy and a little romantic.',
    params: params({ brightness: 0.04, exposureEV: 0.15, contrast: 0.9, saturation: 1.05, temperature: 8, vignette: 0.3 }),
  },
  {
    id: 'matte',
    name: 'Matte',
    blurb: 'Filmic flatness — lifted blacks, quiet colour.',
    params: params({ brightness: 0.05, exposureEV: 0.05, contrast: 0.88, saturation: 0.9 }),
  },
  {
    id: 'fade',
    name: 'Fade',
    blurb: 'Washed and gentle, like an old print.',
    params: params({ brightness: 0.07, exposureEV: 0.04, contrast: 0.85, saturation: 0.78 }),
  },
  {
    id: 'vintage',
    name: 'Vintage',
    blurb: 'Warm, faded colour with framed edges.',
    params: params({ exposureEV: 0.02, contrast: 0.94, saturation: 0.82, temperature: 10, vignette: 0.55 }),
  },
  {
    id: 'sepia',
    name: 'Sepia',
    blurb: 'Mostly-warm monochrome, old-photo style.',
    params: params({ exposureEV: 0.05, contrast: 0.98, saturation: 0.35, temperature: 18, vignette: 0.3 }),
  },
  {
    id: 'pastel',
    name: 'Pastel',
    blurb: 'Light, airy and desaturated — soft pop.',
    params: params({ brightness: 0.05, exposureEV: 0.12, contrast: 0.9, saturation: 0.85, temperature: 4 }),
  },
  {
    id: 'rose',
    name: 'Rose',
    blurb: 'A blush of warmth that flatters faces.',
    params: params({ exposureEV: 0.06, contrast: 0.98, saturation: 1.05, temperature: 9, vibrance: 0.3 }),
  },
  {
    id: 'noir',
    name: 'Noir',
    blurb: 'Black & white, high contrast, moody edges.',
    params: params({ exposureEV: 0.02, contrast: 1.2, saturation: 0, sharpen: 0.45, vignette: 0.4 }),
  },
  {
    id: 'mono',
    name: 'Mono',
    blurb: 'Soft black & white — the gentle monochrome.',
    params: params({ exposureEV: 0.05, contrast: 1.05, saturation: 0, vignette: 0.2 }),
  },
];

/** The preset new/untouched projects grade with: Original — no
 *  grade at all (Jaizon, 2026-11-13: the Auto Enhance auto-apply is
 *  removed; a grade is a manual choice only). resolveLookParams
 *  returns null for it, so the request carries no look and the
 *  engine renders unfiltered. */
export const DEFAULT_LOOK_PRESET_ID = 'original';

export function lookPresetById(id: string): LookPreset {
  return LOOK_PRESETS.find((p) => p.id === id) ?? LOOK_PRESETS[0];
}

function clampParam(key: keyof LookParams, value: number): number {
  const range = LOOK_PARAM_RANGES[key];
  return Math.min(range.max, Math.max(range.min, value));
}

/**
 * The look a project effectively has: its stored look when one was
 * chosen, otherwise Original (no grade — the Auto Enhance
 * auto-apply was removed 2026-11-13). Pure — the store exposes this
 * so every screen agrees.
 */
export function effectiveLook(project: { look?: ProjectLook } | null | undefined): ProjectLook {
  if (project?.look && typeof project.look.presetId === 'string') {
    return {
      presetId: project.look.presetId,
      intensity: Math.min(1, Math.max(0, project.look.intensity ?? 1)),
      ...(project.look.overrides ? { overrides: project.look.overrides } : {}),
    };
  }
  return { presetId: DEFAULT_LOOK_PRESET_ID, intensity: 1 };
}

/** True when a resolved param set would change nothing on screen. */
export function isIdentityLookParams(lookParams: LookParams): boolean {
  return LOOK_PARAM_KEYS.every(
    (key) => Math.abs(lookParams[key] - IDENTITY_LOOK_PARAMS[key]) < IDENTITY_EPSILON,
  );
}

/**
 * Resolve a stored look to the ONE numeric param set the engine
 * applies: the preset's params scaled from identity by `intensity`
 * (lerp), then the per-param overrides applied as ABSOLUTE values
 * (a slider the user dragged means exactly that value, whatever the
 * intensity), everything clamped to the legal ranges. Returns null
 * when the result is identity — the request then carries no look at
 * all and the engine renders unfiltered, exactly as before looks
 * existed.
 */
export function resolveLookParams(look: ProjectLook | null | undefined): LookParams | null {
  if (!look) return null;
  const preset = lookPresetById(look.presetId);
  const intensity = Math.min(1, Math.max(0, look.intensity ?? 1));
  const resolved = { ...IDENTITY_LOOK_PARAMS };
  for (const key of LOOK_PARAM_KEYS) {
    const lerped =
      IDENTITY_LOOK_PARAMS[key] + (preset.params[key] - IDENTITY_LOOK_PARAMS[key]) * intensity;
    const override = look.overrides?.[key];
    resolved[key] = clampParam(key, typeof override === 'number' ? override : lerped);
  }
  return isIdentityLookParams(resolved) ? null : resolved;
}
