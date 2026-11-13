/**
 * Extra Styles 2.0 — parameter schemas (Phase 2 core engine).
 *
 * A style declares its own controls (docs §8.1); the UI generates
 * them from the schema — there is no per-style UI code. Values are
 * JSON-safe and small; the whole set crosses the bridge as one JSON
 * blob on change. Invalid values never reach the renderer: they
 * fall back to the schema default and are reported as dropped.
 */

import type { ExtraStyleParameter, ExtraStyleParamValue, ExtraStylePreset } from './types';

const COLOR_RE = /^#[0-9a-fA-F]{6}$/;

/** The schema's defaults, as a value map. */
export function defaultParams(schema: ExtraStyleParameter[]): Record<string, ExtraStyleParamValue> {
  const out: Record<string, ExtraStyleParamValue> = {};
  for (const param of schema) out[param.id] = param.default;
  return out;
}

function isValidValue(param: ExtraStyleParameter, value: ExtraStyleParamValue): boolean {
  switch (param.kind) {
    case 'slider':
    case 'number':
      return typeof value === 'number' && Number.isFinite(value);
    case 'toggle':
      return typeof value === 'boolean';
    case 'color':
      return typeof value === 'string' && COLOR_RE.test(value);
    case 'segmented':
    case 'select':
    case 'asset':
      return (
        typeof value === 'string' &&
        (!param.options || param.options.some((o) => o.value === value))
      );
    default:
      return false;
  }
}

function sanitizeValue(param: ExtraStyleParameter, value: ExtraStyleParamValue): ExtraStyleParamValue {
  if ((param.kind === 'slider' || param.kind === 'number') && typeof value === 'number') {
    let v = value;
    if (typeof param.min === 'number') v = Math.max(param.min, v);
    if (typeof param.max === 'number') v = Math.min(param.max, v);
    if (typeof param.step === 'number' && param.step > 0) {
      const base = typeof param.min === 'number' ? param.min : 0;
      v = base + Math.round((v - base) / param.step) * param.step;
      // Re-clamp after snapping (rounding can push past a bound),
      // and round off float dust (1.24 → 1.2, not 1.2000000000000002).
      v = Math.round(v * 1e10) / 1e10;
      if (typeof param.min === 'number') v = Math.max(param.min, v);
      if (typeof param.max === 'number') v = Math.min(param.max, v);
    }
    return v;
  }
  return value;
}

export interface ResolvedParams {
  /** Ready to store / send to the renderer. */
  params: Record<string, ExtraStyleParamValue>;
  /** Keys that were dropped (unknown id or invalid value). */
  dropped: string[];
}

/**
 * Resolve stored/edited values against the schema: unknown ids
 * are dropped, invalid values fall back to the schema default,
 * numbers are clamped (+ step-snapped). Missing ids get defaults.
 * Pure — the same function validates a loaded project, a preset,
 * and a bridge payload.
 */
export function resolveExtraStyleParams(
  schema: ExtraStyleParameter[],
  values: Record<string, ExtraStyleParamValue> | undefined | null,
): ResolvedParams {
  const params = defaultParams(schema);
  const dropped: string[] = [];
  const byId = new Map(schema.map((p) => [p.id, p]));
  for (const [id, value] of Object.entries(values ?? {})) {
    const param = byId.get(id);
    if (!param) {
      dropped.push(id);
      continue;
    }
    if (!isValidValue(param, value)) {
      dropped.push(id);
      continue;
    }
    params[id] = sanitizeValue(param, value);
  }
  return { params, dropped };
}

/** Apply a named preset: its values resolved through the schema. */
export function applyExtraStylePreset(
  schema: ExtraStyleParameter[],
  preset: ExtraStylePreset,
): ResolvedParams {
  return resolveExtraStyleParams(schema, preset.values);
}

/**
 * Does the change from `oldParams` to `newParams` alter any param
 * that changes the scene STRUCTURE (docs §8.2)? Such a change can
 * alter node count or geometry, so the scene must be rebuilt ahead
 * of time. Everything else just swaps values in the compositor
 * store with no rebuild — motion, appearance, and density (the
 * emitter's rateParamId binding re-times the particle rate, the
 * loop's periodParamId re-times its period, a colour param
 * repaints glyphs that were laid out colour-free).
 *
 * A param rebuilds iff its `affects` is 'layout' OR its id is in
 * the style's `rebuildParamIds` (the definition's escape hatch for
 * structural params whose `affects` is something else).
 */
export function paramsNeedSceneRebuild(
  schema: ExtraStyleParameter[],
  oldParams: Record<string, ExtraStyleParamValue>,
  newParams: Record<string, ExtraStyleParamValue>,
  rebuildParamIds: string[] = [],
): boolean {
  const rebuildIds = new Set(rebuildParamIds);
  for (const param of schema) {
    const structural = param.affects === 'layout' || rebuildIds.has(param.id);
    if (!structural) continue;
    const oldValue = oldParams[param.id] ?? param.default;
    const newValue = newParams[param.id] ?? param.default;
    if (JSON.stringify(oldValue) !== JSON.stringify(newValue)) return true;
  }
  return false;
}
