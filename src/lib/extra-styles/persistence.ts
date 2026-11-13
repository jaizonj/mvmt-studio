/**
 * Extra Styles 2.0 — persistence + migration (Phase 2 core engine).
 *
 * The project stores only the style choice + params (docs §14.1);
 * everything else is a derived cache rebuilt from (song, lyrics,
 * take) identity. Migration rules (docs §14.2):
 *
 *  - Same version → load as-is.
 *  - Older version → run the migration (param renames/defaults) or
 *    fill changed params with defaults, keep the rest.
 *  - Newer version than the registry (a project from a newer build)
 *    → render traditional lyrics only, with a notice — never crash,
 *    never drop the project.
 *  - Unknown style id (retired style, corrupted field) → no 2.0
 *    style, with a notice — never crash.
 *
 * v1 TEMPLATE RETIREMENT (Jaizon, 2026-11-13 ~01:25 MST — the
 * audit's "keep as legacy / Classic Extra Styles" proposal is
 * superseded): when 2.0 ships, all 30 v1 templates retire. A
 * project holding a v1 `templateId` maps to its 2.0 successor
 * where one exists, otherwise to classic lyrics (no template) —
 * with a notice, never a crash. The mapping below only lists
 * deliberate rebuilds (same concept, scene-based); everything else
 * falls back to classic rather than surprising the user with a
 * lookalike. (Whether the v1 rendering code itself gets deleted is
 * a Phase 3/ship-time cleanup step, not Phase 2 — Phase 2 just
 * does not design around keeping it.)
 */

import type { ExtraStyleCatalog, ExtraStyleMetadata, ExtraStyleState } from './types';
import { resolveExtraStyleParams } from './params';

/**
 * v1 template id → 2.0 successor style id. Only deliberate
 * rebuilds are listed; unlisted v1 ids fall back to classic.
 * The two overlapping concepts are 2.0 rebuilds, not replacements
 * — no special-casing: 'emoji-story' → 'emoji-storytelling' and
 * 'comic-book' → 'comic-book' like any other successor.
 */
export const V1_TEMPLATE_SUCCESSORS: Record<string, string> = {
  'emoji-story': 'emoji-storytelling',
  'comic-book': 'comic-book',
  hologram: 'holographic-interface',
  'neon-sign': 'neon-sign-world',
  chat: 'message-universe',
  'text-message-typing': 'message-universe',
  magazine: 'editorial-magazine',
  'retro-tv': 'vhs-dream',
  'sticker-pop': 'sticker-world',
  'word-explosion': 'typography-explosion',
  scrapbook: 'memory-fragments',
  cyberpunk: 'cyber-terminal',
  'split-screen-words': 'parallel-worlds',
  'big-bold-billboard': 'brutalist-typography',
  'typewriter-classic': 'cyber-terminal',
};

export interface V1MigrationResult {
  /** The 2.0 state to store, or null for classic lyrics. */
  state: ExtraStyleState | null;
  /** User-facing notice (always set — the user should know the
   *  template retired and what replaced it, or that it didn't). */
  notice: string;
}

/**
 * Migrate a project holding a v1 `templateId` (docs §14.2 + the
 * 2026-11-13 retirement decision). The successor only applies
 * when it EXISTS in the registry — in Phase 2 the registry holds
 * only the harness style, so everything maps to classic until the
 * 40 styles land in Phase 3. Never throws; unknown ids are
 * classic, never a crash.
 */
export function migrateV1Template(
  templateId: string | undefined | null,
  catalog: ExtraStyleCatalog,
): V1MigrationResult {
  if (!templateId) {
    return { state: null, notice: '' };
  }
  const successorId = V1_TEMPLATE_SUCCESSORS[templateId];
  const successor = successorId
    ? catalog.styles.find((s) => s.id === successorId && !s.internal)
    : undefined;
  if (successor) {
    return {
      state: {
        styleId: successor.id,
        styleVersion: successor.version,
        params: Object.fromEntries(successor.parameters.map((p) => [p.id, p.default])),
      },
      notice:
        `The Classic Extra Style "${templateId}" has retired. ` +
        `Your video now uses the rebuilt Extra Style "${successor.name}" — your lyrics are untouched.`,
    };
  }
  return {
    state: null,
    notice:
      `The Classic Extra Style "${templateId}" has retired. ` +
      `Your video now uses classic lyrics — your lyrics are untouched.`,
  };
}

// ---------------------------------------------------------------------------
// ExtraStyleState validation (docs §14.2)
// ---------------------------------------------------------------------------

export interface ValidatedExtraStyle {
  /** The state to use for rendering, or null for no 2.0 style. */
  state: ExtraStyleState | null;
  /** Set when the stored state was changed or dropped. */
  notice?: string;
  /** True when an older version was migrated to current defaults. */
  migrated?: boolean;
}

/**
 * Validate a stored ExtraStyleState against the registry
 * metadata. Pure — the loader calls this, never the renderer.
 */
export function validateExtraStyleState(
  stored: ExtraStyleState | undefined | null,
  catalog: ExtraStyleCatalog,
): ValidatedExtraStyle {
  if (!stored) return { state: null };
  const definition: ExtraStyleMetadata | undefined = catalog.styles.find(
    (s) => s.id === stored.styleId,
  );
  if (!definition || definition.internal) {
    return {
      state: null,
      notice:
        'This Extra Style is no longer available — your video and lyrics are untouched.',
    };
  }
  if (stored.styleVersion > definition.version) {
    return {
      state: null,
      notice:
        'This Extra Style was saved by a newer version of MVMT Studio — your video and lyrics are untouched.',
    };
  }
  const { params, dropped } = resolveExtraStyleParams(definition.parameters, stored.params);
  const migrated = stored.styleVersion < definition.version || dropped.length > 0;
  return {
    state: {
      styleId: definition.id,
      styleVersion: definition.version,
      params,
      ...(stored.layers ? { layers: stored.layers } : {}),
      ...(stored.favoriteStyleIds ? { favoriteStyleIds: stored.favoriteStyleIds } : {}),
    },
    ...(migrated
      ? {
          migrated: true,
          notice:
            'This Extra Style was updated to the latest version — your settings were kept where they still apply.',
        }
      : {}),
  };
}

/** Remove the 2.0 style from a project (back to no style). */
export function clearExtraStyleState(): undefined {
  return undefined;
}
