/**
 * Extra Styles 2.0 — shared types (Phase 2 core engine).
 *
 * The engine's TypeScript half is PURE (no React Native / Expo
 * imports) so it can be unit-tested in Node — see
 * tests/extra-styles.test.cjs. The native half (Swift) mirrors
 * these shapes; the bridge payloads are JSON, and the contract
 * test pins their shapes.
 *
 * Independence contract (docs/EXTRA-STYLES-2.0.md §2): these types
 * never reference LyricStyle, animation preset ids, or LyricDecor.
 * A 2.0 style lives in Project.extraStyle (defined here — the
 * Project interface itself is wired in a later integration step),
 * never in ProjectLyrics.
 */

/** Bridge interface version (docs §6.6). Starts at 1. */
export const EXTRA_STYLES_BRIDGE_VERSION = 1;

/** Engine recipe version: bumped when the evaluator's math or the
 *  scene format changes incompatibly. Prepared scenes and cached
 *  artifacts carry it so stale work is never reused. */
export const EXTRA_STYLES_ENGINE_VERSION = 1;

/** The EDL grid — every animation time is an integer frame here. */
export const EXTRA_STYLES_FPS = 30;

/** A parameter value: JSON-safe only, so the whole set crosses
 *  the bridge as one JSON blob (docs §8.1). */
export type ExtraStyleParamValue = number | boolean | string | string[];

export type ExtraStyleParamKind =
  | 'slider'
  | 'toggle'
  | 'color'
  | 'segmented'
  | 'select'
  | 'number'
  | 'asset';

export type ExtraStyleParamAffects = 'layout' | 'motion' | 'appearance' | 'density';

export interface ExtraStyleParamOption {
  value: string;
  label: string;
}

/**
 * One declared control for a style (docs §8.1). Declared, not
 * hardcoded in the UI — the UI generates controls from the schema.
 * `affects` tells the engine what a change costs: 'layout' /
 * 'density' changes that alter node count re-run buildScene;
 * 'motion' / 'appearance' changes just swap values in the
 * compositor store, with no rebuild.
 */
export interface ExtraStyleParameter {
  id: string;
  label: string;
  kind: ExtraStyleParamKind;
  /** slider / number bounds. */
  min?: number;
  max?: number;
  step?: number;
  unit?: string;
  /** segmented / select / asset choices. */
  options?: ExtraStyleParamOption[];
  default: ExtraStyleParamValue;
  affects: ExtraStyleParamAffects;
}

/** A named parameter set inside one style (docs §8.1). Presets are
 *  parameter values, not separate styles. */
export interface ExtraStylePreset {
  id: string;
  label: string;
  values: Record<string, ExtraStyleParamValue>;
}

export type ExtraStyleCategory =
  | 'cinematic'
  | 'typography'
  | 'digital'
  | 'design'
  | 'playful'
  | 'music'
  | 'experimental';

export const EXTRA_STYLE_CATEGORIES: { id: ExtraStyleCategory; label: string }[] = [
  { id: 'cinematic', label: 'Cinematic' },
  { id: 'typography', label: 'Typography' },
  { id: 'digital', label: 'Digital' },
  { id: 'design', label: 'Design' },
  { id: 'playful', label: 'Playful' },
  { id: 'music', label: 'Music' },
  { id: 'experimental', label: 'Experimental' },
];

/** Which lyric/audio/subject data a style consumes (docs §3.2). */
export type ExtraStyleInputKind =
  | 'words'
  | 'lines'
  | 'phrases'
  | 'intelligence'
  | 'audio'
  | 'subject'
  | 'sections';

/**
 * Style metadata — the ONLY thing the JS side ever holds about a
 * style (docs §3.1). The registry itself is Swift-native; this
 * crosses the bridge once per launch, never per frame.
 */
export interface ExtraStyleMetadata {
  id: string;
  version: number;
  name: string;
  tagline: string;
  category: ExtraStyleCategory;
  parameters: ExtraStyleParameter[];
  presets?: ExtraStylePreset[];
  inputs: ExtraStyleInputKind[];
  needsAudioAutomation: boolean;
  needsSubjectMasks: boolean;
  /** Param ids that rebuild the scene in place on change (docs
   *  §8.2) — the native updateParams reads the definition's list;
   *  the TS side uses this copy for the same decision. Absent =
   *  none beyond `affects: 'layout'`. */
  rebuildParamIds?: string[];
  /** Internal / harness styles — never shown in the UI. */
  internal?: boolean;
}

export interface ExtraStyleCatalog {
  bridgeVersion: number;
  registryVersion: number;
  styles: ExtraStyleMetadata[];
}

/**
 * The project field (docs §14.1). Stored as Project.extraStyle —
 * additive, optional, beside `lyrics` (untouched). The lyric
 * interpretation, audio automation, subject masks, and card
 * previews are derived caches on disk, NOT project fields: the
 * project stores only the style choice + params.
 */
export interface ExtraStyleState {
  styleId: string;
  /** The definition version the project was built against. */
  styleVersion: number;
  params: Record<string, ExtraStyleParamValue>;
  /** Editable-layer overrides, where the style declares them. */
  layers?: Record<string, Record<string, ExtraStyleParamValue>>;
  /** Favourite 2.0 styles (per project, like favoriteTemplateIds). */
  favoriteStyleIds?: string[];
}

// ---------------------------------------------------------------------------
// Engine capabilities — the 40-style coverage spec (docs §17).
//
// Every capability the 40 styles need must be in this set, and the
// Swift evaluator implements each one. The catalog test asserts
// the mapping covers all 40. Notes on the ones that are NOT a
// renderer primitive but a composition of primitives:
//  - 'rgb-split': tinted text copies + screen blend + offsets
//    (built by the style, no special renderer support needed).
//  - 'second-video-layer': the compositor's layer loop already
//    composites the second video track (cross-dissolve track); a
//    style that wants mirrored footage requests it through the
//    request — the rendering capability exists in Phase 2, the
//    per-style request plumbing lands with the style in Phase 3.
//  - 'images': the scene graph supports image nodes backed by the
//    asset registry (procedural textures in Phase 2; the bundled
//    PNG pack ships with the styles that need it in Phase 3).
//  - 'syllables': a deterministic vowel-group heuristic over word
//    timings (docs §17 #29 — approximate, never phonetic).
// ---------------------------------------------------------------------------

export type ExtraStyleCapability =
  | 'text-line'
  | 'text-word'
  | 'text-char'
  | 'text-phrase'
  | 'nested-groups'
  | 'shapes'
  | 'gradients'
  | 'paths'
  | 'images'
  | 'emoji'
  | 'particles'
  | 'blend-modes'
  | 'masks'
  | 'keyframes'
  | 'springs'
  | 'physics'
  | 'stagger'
  | 'path-animation'
  | 'looping'
  | 'seeded-random'
  | 'audio-onset'
  | 'audio-beat'
  | 'audio-bands'
  | 'audio-loudness'
  | 'subject-mask'
  | 'subject-face'
  | 'sections'
  | 'semantic-tags'
  | 'second-video-layer'
  | 'perspective'
  | 'displacement'
  | 'rgb-split'
  | 'counters'
  | 'syllables';

export const ENGINE_CAPABILITIES: ExtraStyleCapability[] = [
  'text-line',
  'text-word',
  'text-char',
  'text-phrase',
  'nested-groups',
  'shapes',
  'gradients',
  'paths',
  'images',
  'emoji',
  'particles',
  'blend-modes',
  'masks',
  'keyframes',
  'springs',
  'physics',
  'stagger',
  'path-animation',
  'looping',
  'seeded-random',
  'audio-onset',
  'audio-beat',
  'audio-bands',
  'audio-loudness',
  'subject-mask',
  'subject-face',
  'sections',
  'semantic-tags',
  'second-video-layer',
  'perspective',
  'displacement',
  'rgb-split',
  'counters',
  'syllables',
];

// ---------------------------------------------------------------------------
// Audio automation (docs §9.2) — the artifact the native analysis
// produces, cached per song. The native side decodes once (STFT +
// spectral flux + autocorrelation tempo + DP beat tracking +
// band energies + K-weighted loudness); the TS side only SAMPLES
// the curves at a frame — no analysis at render time.
// ---------------------------------------------------------------------------

export const AUDIO_AUTOMATION_VERSION = 1;
/** Storage hop for the curves: 0.1 s (a 3-minute song is 1,800 samples). */
export const AUDIO_AUTOMATION_HOP_SECONDS = 0.1;
/** The 10-band bank (Hz) — the same centres Auto EQ uses, so the
 *  two analyses agree on what a "band" is. */
export const AUDIO_BAND_CENTERS_HZ: number[] = [
  125, 250, 500, 1000, 2000, 3000, 4000, 6000, 8000, 12000,
];

export interface AudioAutomationBeat {
  timeSeconds: number;
  isDownbeat: boolean;
  strength: number;
}

export interface AudioAutomation {
  version: number;
  songKey: string;
  sampleRate: number;
  durationSeconds: number;
  /** Onset strength per hop (spectral flux, normalised 0..1). */
  onsetEnvelope: { hopSeconds: number; values: number[] };
  /** Beat grid: tempo + beat times + downbeats + confidence. */
  tempoBpm: number;
  beats: AudioAutomationBeat[];
  /** 0..1 — styles gate beat reactions on this. */
  beatConfidence: number;
  /** Per-band energy (same 10-band bank), ~10 Hz, normalised 0..1. */
  bandEnergies: { hopSeconds: number; bandsHz: number[]; values: number[][] };
  /** Short-term loudness curve (~10 Hz), K-weighted, LUFS-like. */
  loudnessCurve: { hopSeconds: number; values: number[] };
}

// ---------------------------------------------------------------------------
// Lyric interpretation (docs §7.3) — derived ahead of time, cached
// on disk keyed by (song identity + lyrics hash + recipe version).
// Dictionary + repetition analysis over data the app already holds.
// Never computed per frame, never calls an AI API.
// ---------------------------------------------------------------------------

export const LYRIC_INTERPRETATION_VERSION = 1;

export interface LyricInterpretationSection {
  kind: 'verse' | 'chorus' | 'bridge' | 'other';
  startFrame: number;
  endFrame: number;
  /** 0..1 — a song with no repetition gets no sections at all. */
  confidence: number;
}

export interface LyricInterpretationLine {
  lineId: string;
  /** Extended semantic tags (weather, time, place, motion,
   *  emotion, objects — the v1 emoji dictionary generalised). */
  semanticTags: string[];
}

export interface LyricInterpretation {
  version: number;
  songKey: string;
  /** Hash of the stored lines + words the artifact was built from. */
  lyricsHash: string;
  sections: LyricInterpretationSection[];
  lines: LyricInterpretationLine[];
}

// ---------------------------------------------------------------------------
// Scene-build input (docs §3.2) — what crosses the bridge ONCE at
// preparation. Lines are in COMPOSITION frames (song frame minus
// the region start, plus the fine offset) — the same mapping
// buildCompositeLyrics uses. The Swift side builds the scene graph
// from this; per-frame evaluation is native-only.
// ---------------------------------------------------------------------------

export interface ExtraStyleSceneWordInput {
  text: string;
  /** Composition seconds. */
  startSeconds: number;
  endSeconds: number;
}

export interface ExtraStyleSceneLineInput {
  text: string;
  /** Composition seconds. */
  startSeconds: number;
  endSeconds: number;
  words?: ExtraStyleSceneWordInput[];
  /** Stored lyric intelligence — renderers read, never compute. */
  emoji?: string;
  tone?: 'joy' | 'sad' | 'anger' | 'love' | 'hype';
  emphasisWordIndices?: number[];
  /** Extended semantic tags from the interpretation (§7). */
  semanticTags?: string[];
}

export interface ExtraStyleSceneBuildInput {
  styleId: string;
  /** The style's parameter values, as one JSON string (open map). */
  paramsJson: string;
  /** Editable-layer overrides, as one JSON string. Absent = none. */
  layersJson?: string | null;
  lines: ExtraStyleSceneLineInput[];
  /** 32-bit seed: FNV-1a of (styleId + projectId) — stable across
   *  launches, previews, and exports (§5.4). */
  seed: number;
  canvasWidth: number;
  canvasHeight: number;
  /** Composition length, @30fps integer frames. */
  durationFrames: number;
  fps?: number;
  /** Audio automation JSON (when the style asked for it). */
  automationJson?: string | null;
  /** Subject-mask index JSON (when the style asked for it). */
  maskRefJson?: string | null;
}

/** Subject-mask precompute index (docs §10.2) — returned by
 *  prepareSubjectMasks, held by the scene input, read natively. */
export interface SubjectMaskIndex {
  version: number;
  takeKey: string;
  /** Sample times, seconds (2 fps — a mask every 15 frames). */
  sampleTimesSeconds: number[];
  /** Mask file URIs, one per sample time (270×480 grayscale). */
  maskUris: string[];
  /** Face boxes per sample: [x, y, w, h] in 0..1 canvas fractions. */
  faces: { timeSeconds: number; boxes: number[][] }[];
}
