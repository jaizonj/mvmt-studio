/**
 * Mix & Master — pure curve math (Stages 1–2: dynamic corrective
 * EQ + static Master EQ).
 *
 * The analysis itself runs natively (`prepareMixMasterSong` in
 * modules/mvmt-compositor): the song is measured in 1.0 s windows
 * with 50% overlap, each window's band balance turns into per-band
 * gains (cuts only), and the curve is smoothed before it is stored
 * or rendered; the Master stage then measures the whole song's
 * balance against a gentle target curve and produces one static
 * gain set. These functions are the pure, platform-free half of
 * that pipeline — window layout, smoothing, gain interpolation,
 * stage settings, and the master-gain computation — and the Swift
 * engine mirrors them exactly (same constants, same order of
 * operations), so the Node tests in tests/mixmaster.test.cjs pin
 * the behaviour BOTH sides implement.
 *
 * Zero runtime imports: the compiled module loads under plain
 * `node --test` with no React Native or Expo in the room.
 */

/**
 * Recipe version for the analysis + render (part of the native
 * cache key). Bumped to 2 in Stage 2: the Master EQ stage joined
 * the chain, so Stage 1 renders must never be served for Stage 2
 * settings.
 */
export const MIX_MASTER_PROFILE_VERSION = 2;

/** Analysis window length, seconds. */
export const MM_WINDOW_SECONDS = 1.0;
/** Hop between analysis points, seconds (50% overlap). */
export const MM_HOP_SECONDS = 0.5;
/** A window holding less than this much audio is dropped (except the first). */
export const MM_MIN_WINDOW_SECONDS = 0.25;
/** Smoothing slew limit: max gain change per 100 ms of song time. */
export const MM_SLEW_DB_PER_100MS = 1.5;

/**
 * EQ band centres in Hz, same order as Auto EQ and the native
 * `eqBandCentersHz` in MvmtCompositorModule.swift — the one band
 * order every gain set in this module uses. Mirrored here so the
 * Stage 3 UI can label the curve without a second source of truth.
 */
export const MM_BAND_CENTERS_HZ: readonly number[] = [
  125, 250, 500, 1000, 2000, 3000, 4000, 6000, 8000, 12000,
];

/** A master gain below this is inaudible — it counts as "no correction". */
export const MM_MEANINGFUL_GAIN_DB = 0.05;

/** Short chart label for a band centre: 125, 250, 500, 1k, 2k, …, 12k. */
export function shortBandLabelHz(hz: number): string {
  return hz >= 1000 ? `${Math.round(hz / 100) / 10}k` : `${Math.round(hz)}`;
}

/** Long label for a band centre: "125 Hz", "1 kHz", "3 kHz", "12 kHz". */
export function formatBandHz(hz: number): string {
  return hz >= 1000 ? `${Math.round(hz / 100) / 10} kHz` : `${Math.round(hz)} Hz`;
}

/** m:ss for a song time (the theme's formatTime, kept import-free here). */
export function formatMixMasterTime(seconds: number): string {
  const safe = Math.max(0, Math.floor(seconds));
  return `${Math.floor(safe / 60)}:${String(safe % 60).padStart(2, '0')}`;
}

/** One smoothed analysis point: the gain set that applies at this song time. */
export interface MixMasterWindow {
  timeSeconds: number;
  /** Per-band gains in dB (cuts only, 0 … −6), same band order as Auto EQ. */
  gainsDb: number[];
}

/** One reported correction: the deepest cuts, for the "what changed and why" list. */
export interface MixMasterFinding {
  timeSeconds: number;
  bandHz: number;
  /** Positive depth of the cut in dB. */
  cutDb: number;
  reason: 'harshness' | 'mud';
}

/** The stored artifact: the smoothed curve + findings for one song. */
export interface MixMasterProfile {
  version: number;
  /** Native cache key: path|size|mtime|recipe version|stage settings. */
  songKey: string;
  sampleRate: number;
  durationSeconds: number;
  windows: MixMasterWindow[];
  findings: MixMasterFinding[];
  /** Master EQ gains as applied (post toggle/intensity), same band order. */
  masterGainsDb: number[];
  /** The stage settings the render was made with. */
  stages: MixMasterStageSettings;
}

/**
 * Per-stage controls for the two EQ stages (Stage 2). The master
 * switch is separate (`Project.mixMasterEnabled`): these only
 * matter while the suite is on. Each stage has an independent
 * toggle and an intensity (0–100%) that scales that stage's gains
 * toward 0 — 0% is a flat stage, 100% is the full computed gain.
 */
export interface MixMasterStageSettings {
  correctiveEnabled: boolean;
  /** 0–100. */
  correctiveIntensity: number;
  masterEnabled: boolean;
  /** 0–100. */
  masterIntensity: number;
}

/** Unset stage fields read as both stages ON at full intensity. */
export const DEFAULT_MIX_MASTER_STAGE_SETTINGS: MixMasterStageSettings = {
  correctiveEnabled: true,
  correctiveIntensity: 100,
  masterEnabled: true,
  masterIntensity: 100,
};

/** Resolve partial/stored stage settings to the effective set. */
export function resolveMixMasterStageSettings(
  partial?: Partial<MixMasterStageSettings> | null,
): MixMasterStageSettings {
  const intensity = (value: unknown): number => {
    const n = typeof value === 'number' && Number.isFinite(value) ? value : 100;
    return Math.min(100, Math.max(0, n));
  };
  return {
    correctiveEnabled: partial?.correctiveEnabled !== false,
    correctiveIntensity: intensity(partial?.correctiveIntensity),
    masterEnabled: partial?.masterEnabled !== false,
    masterIntensity: intensity(partial?.masterIntensity),
  };
}

/** Canonical cache-key fragment for a resolved stage settings set. */
export function mixMasterStageSettingsKey(settings: MixMasterStageSettings): string {
  const r = resolveMixMasterStageSettings(settings);
  return (
    `c${r.correctiveEnabled ? 1 : 0}:${Math.round(r.correctiveIntensity)}` +
    `|m${r.masterEnabled ? 1 : 0}:${Math.round(r.masterIntensity)}`
  );
}

/**
 * Scale a gain set toward 0 by an intensity (0–100%): 100% keeps
 * the gains, 0% flattens the stage. Applied to both stages — the
 * corrective windows and the master gains — after they are
 * computed, so the stored profile always shows what was actually
 * rendered.
 */
export function scaleGainsTowardZero(gainsDb: number[], intensityPercent: number): number[] {
  const factor = Math.min(1, Math.max(0, intensityPercent / 100));
  return gainsDb.map((g) => {
    const scaled = g * factor;
    // −0 is numerically 0 but distinct under deepStrictEqual and
    // in JSON; normalise it away (a −2 dB cut at 0% is 0, not −0).
    return scaled === 0 ? 0 : scaled;
  });
}

/**
 * Analysis-point times for a song of this duration: 0, 0.5, 1.0,
 * … while the start is inside the song. A trailing start whose
 * window would hold less than `minWindowSeconds` of audio is
 * dropped — except the first window, which is always kept so a
 * sub-second song still gets one analysis point.
 */
export function mixMasterWindowStarts(
  durationSeconds: number,
  hopSeconds: number = MM_HOP_SECONDS,
  minWindowSeconds: number = MM_MIN_WINDOW_SECONDS,
): number[] {
  // The layout depends only on hop + duration; the window length
  // matters at flush time, not here.
  if (!(durationSeconds > 0)) return [];
  const starts: number[] = [];
  for (let i = 0; ; i++) {
    const t = i * hopSeconds;
    if (t >= durationSeconds) break;
    if (i === 0 || durationSeconds - t >= minWindowSeconds) starts.push(t);
  }
  return starts;
}

/**
 * Smooths raw per-window gains — this is what makes the EQ
 * dynamic instead of a per-second switch:
 * (a) a 3-point moving average across windows, per band (edge
 * windows average over their available neighbours), then
 * (b) a slew limit applied sequentially per band: no window's gain
 * may move more than `slewDbPer100ms` per 100 ms of song time from
 * the previous window's (smoothed) gain. Gains are cuts (≤ 0), so
 * smoothing can only soften a cut, never invent a boost.
 */
export function smoothGainCurve(
  rawWindows: number[][],
  hopSeconds: number = MM_HOP_SECONDS,
  slewDbPer100ms: number = MM_SLEW_DB_PER_100MS,
): number[][] {
  if (rawWindows.length === 0) return [];
  const averaged: number[][] = rawWindows.map((gains, i) =>
    gains.map((g, b) => {
      let sum = g;
      let n = 1;
      if (i > 0) {
        sum += rawWindows[i - 1][b];
        n += 1;
      }
      if (i < rawWindows.length - 1) {
        sum += rawWindows[i + 1][b];
        n += 1;
      }
      return sum / n;
    }),
  );
  const maxStep = slewDbPer100ms * (hopSeconds / 0.1);
  const out: number[][] = [averaged[0].slice()];
  for (let i = 1; i < averaged.length; i++) {
    out.push(
      averaged[i].map((g, b) => {
        const prev = out[i - 1][b];
        return Math.max(prev - maxStep, Math.min(prev + maxStep, g));
      }),
    );
  }
  return out;
}

/**
 * The smoothed gain set at a song time: linear interpolation
 * between the bracketing analysis points, clamped to the first /
 * last window outside the range. This is what the offline render
 * evaluates once per 4096-frame block.
 */
export function mixMasterGainAtTime(
  windows: MixMasterWindow[],
  timeSeconds: number,
): number[] {
  if (windows.length === 0) return [];
  const first = windows[0];
  if (timeSeconds <= first.timeSeconds) return first.gainsDb.slice();
  const last = windows[windows.length - 1];
  if (timeSeconds >= last.timeSeconds) return last.gainsDb.slice();
  for (let i = 1; i < windows.length; i++) {
    if (timeSeconds <= windows[i].timeSeconds) {
      const a = windows[i - 1];
      const b = windows[i];
      const span = b.timeSeconds - a.timeSeconds;
      const f = span > 0 ? (timeSeconds - a.timeSeconds) / span : 0;
      return a.gainsDb.map((ga, band) => ga + (b.gainsDb[band] - ga) * f);
    }
  }
  return last.gainsDb.slice();
}

// --- Master EQ (Stage 2) -------------------------------------------------

/**
 * The Master EQ target curve, in dB per band (same band order as
 * Auto EQ: 125, 250, 500, 1k, 2k, 3k, 4k, 6k, 8k, 12k Hz): a
 * slight low-end shelf, flat mids, a gentle high shelf. A constant
 * in the module, tuned by ear on device — not per-song magic. The
 * gains are computed RELATIVE to this shape (see
 * computeMasterGains), so its mean never biases the overall level.
 */
export const MM_MASTER_TARGET_DB: readonly number[] = [
  1.5, 1.0, 0.5, 0, 0, 0, 0, 0.5, 1.0, 1.5,
];
/** Master EQ gain clamp, dB — cuts AND boosts are allowed here. */
export const MM_MASTER_MAX_GAIN_DB = 3;
/** A song quieter than this broadband takes no master EQ at all. */
export const MM_MASTER_SILENCE_DBFS = -60;
/** Band levels at or below this floor count as "no measurable energy". */
export const MM_MASTER_LEVEL_FLOOR_DB = -80;
/** A band counts as carrying energy when its corrected level is within this many dB of the loudest band. */
export const MM_MASTER_ACTIVE_BELOW_PEAK_DB = 25;

/** Mean applied corrective gain per band, over the stored windows. */
export function meanGainPerBand(windows: MixMasterWindow[]): number[] {
  if (windows.length === 0) return [];
  const bandCount = windows[0].gainsDb.length;
  const sums = new Array<number>(bandCount).fill(0);
  for (const w of windows) {
    for (let b = 0; b < bandCount; b++) sums[b] += w.gainsDb[b] ?? 0;
  }
  return sums.map((s) => s / windows.length);
}

/**
 * The Master EQ gain set for a song: one static gain per band,
 * driving the whole-song balance toward the target curve.
 *
 * The balance is measured on the CORRECTED signal — each band's
 * raw overall level plus the mean APPLIED corrective gain for
 * that band (the doc's "simpler and equivalent" way of measuring
 * the corrective unit's output, with no second decode pass). So
 * when the corrective stage already cut a band, the master stage
 * sees the cut balance and does not cut it twice — and when the
 * corrective stage is off, the mean gain is 0 and the master
 * measures the raw song.
 *
 * The reference is the mean of (corrected level − target) over
 * the bands that actually carry energy, so the target shape
 * itself never biases the overall level, and a dead band (no
 * content at 12 kHz in a lo-fi recording, say) can neither drag
 * the reference nor be boosted into noise — it stays flat.
 * Gains are clamped to ±MM_MASTER_MAX_GAIN_DB. A near-silent
 * song gets no master EQ at all.
 */
export function computeMasterGains(
  overallLevelsDb: number[],
  meanCorrectiveGainsDb: number[],
  broadbandDbfs: number,
  targetDb: readonly number[] = MM_MASTER_TARGET_DB,
): number[] {
  const bandCount = overallLevelsDb.length;
  if (bandCount === 0) return [];
  if (!(broadbandDbfs >= MM_MASTER_SILENCE_DBFS)) {
    return new Array<number>(bandCount).fill(0);
  }
  // Corrected levels, floored like the window measurements.
  const floored = overallLevelsDb.map((level, b) =>
    Math.max(level + (meanCorrectiveGainsDb[b] ?? 0), MM_MASTER_LEVEL_FLOOR_DB),
  );
  // "Carries energy" is peak-relative: a band more than 25 dB
  // below the loudest corrected band is inaudible in context, so
  // it stays flat and out of the reference.
  const peak = Math.max(...floored);
  const active = floored.map((level) => level > peak - MM_MASTER_ACTIVE_BELOW_PEAK_DB);
  // Reference over the active bands only.
  let referenceSum = 0;
  let activeCount = 0;
  for (let b = 0; b < bandCount; b++) {
    if (active[b]) {
      referenceSum += floored[b] - (targetDb[b] ?? 0);
      activeCount += 1;
    }
  }
  if (activeCount === 0) return new Array<number>(bandCount).fill(0);
  const reference = referenceSum / activeCount;
  return floored.map((level, b) => {
    if (!active[b]) return 0;
    const gain = reference + (targetDb[b] ?? 0) - level;
    return Math.max(-MM_MASTER_MAX_GAIN_DB, Math.min(MM_MASTER_MAX_GAIN_DB, gain));
  });
}

// --- Stage 3 UI: profile reading + display --------------------------------

/** A gain set is valid only when it covers every band exactly once. */
function isGainSet(value: unknown): value is number[] {
  return (
    Array.isArray(value) &&
    value.length === MM_BAND_CENTERS_HZ.length &&
    value.every((g) => typeof g === 'number' && Number.isFinite(g))
  );
}

function isFiniteNumber(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value);
}

/**
 * Validate a decoded profile JSON object into a MixMasterProfile,
 * or null when anything is missing or malformed. The profile is
 * written by the native engine beside its render; a strict read
 * keeps a corrupt or stale file (wrong version, short gain sets,
 * a bogus reason) from ever reaching the screen — the UI treats
 * null as "no analysis available", never as a crash. Stage
 * settings inside the profile resolve through the same defaults
 * as everywhere else.
 */
export function parseMixMasterProfile(value: unknown): MixMasterProfile | null {
  if (typeof value !== 'object' || value === null) return null;
  const v = value as Record<string, unknown>;
  if (v.version !== MIX_MASTER_PROFILE_VERSION) return null;
  if (typeof v.songKey !== 'string' || v.songKey.length === 0) return null;
  if (!isFiniteNumber(v.sampleRate) || v.sampleRate <= 0) return null;
  if (!isFiniteNumber(v.durationSeconds) || v.durationSeconds < 0) return null;
  if (!isGainSet(v.masterGainsDb)) return null;
  if (!Array.isArray(v.windows)) return null;
  const windows: MixMasterWindow[] = [];
  for (const raw of v.windows) {
    if (typeof raw !== 'object' || raw === null) return null;
    const w = raw as Record<string, unknown>;
    if (!isFiniteNumber(w.timeSeconds) || w.timeSeconds < 0) return null;
    if (!isGainSet(w.gainsDb)) return null;
    windows.push({ timeSeconds: w.timeSeconds, gainsDb: (w.gainsDb as number[]).slice() });
  }
  if (!Array.isArray(v.findings)) return null;
  const findings: MixMasterFinding[] = [];
  for (const raw of v.findings) {
    if (typeof raw !== 'object' || raw === null) return null;
    const f = raw as Record<string, unknown>;
    if (!isFiniteNumber(f.timeSeconds) || f.timeSeconds < 0) return null;
    if (!isFiniteNumber(f.bandHz) || f.bandHz <= 0) return null;
    if (!isFiniteNumber(f.cutDb) || f.cutDb < 0) return null;
    if (f.reason !== 'harshness' && f.reason !== 'mud') return null;
    findings.push({
      timeSeconds: f.timeSeconds,
      bandHz: f.bandHz,
      cutDb: f.cutDb,
      reason: f.reason,
    });
  }
  const stagesRaw =
    typeof v.stages === 'object' && v.stages !== null
      ? (v.stages as Partial<MixMasterStageSettings>)
      : null;
  return {
    version: MIX_MASTER_PROFILE_VERSION,
    songKey: v.songKey,
    sampleRate: v.sampleRate,
    durationSeconds: v.durationSeconds,
    windows,
    findings,
    masterGainsDb: (v.masterGainsDb as number[]).slice(),
    stages: resolveMixMasterStageSettings(stagesRaw),
  };
}

/** The one-line answer to "what did it do to my song?" */
export interface MixMasterSummary {
  /** Findings count (direct cuts ≥ 1 dB). */
  totalCuts: number;
  /** Deepest single cut in dB, 0 when there are no findings. */
  deepestCutDb: number;
  deepestBandHz: number | null;
  deepestTimeSeconds: number | null;
  /** Largest absolute master gain in dB (0 when the master stage is flat). */
  masterMaxAbsDb: number;
  /** Anything was actually changed (a cut, or a meaningful master gain). */
  hasCorrections: boolean;
}

/** Summarise a profile for the screen's headline + A/B gating. */
export function summarizeMixMasterProfile(profile: MixMasterProfile): MixMasterSummary {
  let deepest: MixMasterFinding | null = null;
  for (const f of profile.findings) {
    if (!deepest || f.cutDb > deepest.cutDb) deepest = f;
  }
  const masterMaxAbsDb = profile.masterGainsDb.reduce((m, g) => Math.max(m, Math.abs(g)), 0);
  return {
    totalCuts: profile.findings.length,
    deepestCutDb: deepest ? deepest.cutDb : 0,
    deepestBandHz: deepest ? deepest.bandHz : null,
    deepestTimeSeconds: deepest ? deepest.timeSeconds : null,
    masterMaxAbsDb,
    hasCorrections: profile.findings.length > 0 || masterMaxAbsDb > MM_MEANINGFUL_GAIN_DB,
  };
}

/** One finding as a list row: "3 kHz −4.2 dB at 0:42 — harshness". */
export function formatMixMasterFinding(finding: MixMasterFinding): string {
  return (
    `${formatBandHz(finding.bandHz)} −${finding.cutDb.toFixed(1)} dB ` +
    `at ${formatMixMasterTime(finding.timeSeconds)} — ${finding.reason}`
  );
}

/** The screen's summary line for a profile. */
export function formatMixMasterSummary(profile: MixMasterProfile): string {
  const summary = summarizeMixMasterProfile(profile);
  if (!summary.hasCorrections) {
    return 'No corrections needed — this song is already balanced.';
  }
  const cuts =
    summary.totalCuts === 1 ? '1 cut' : `${summary.totalCuts} cuts`;
  let line = cuts;
  if (summary.deepestBandHz !== null && summary.deepestTimeSeconds !== null) {
    line +=
      ` · deepest −${summary.deepestCutDb.toFixed(1)} dB at ` +
      `${formatBandHz(summary.deepestBandHz)} (${formatMixMasterTime(summary.deepestTimeSeconds)})`;
  }
  if (summary.masterMaxAbsDb > MM_MEANINGFUL_GAIN_DB) {
    line += ` · master up to ${summary.masterMaxAbsDb.toFixed(1)} dB`;
  }
  return line;
}

/** Total cut depth in one window (sum of |cut| across bands), for the activity strip. */
export function windowTotalCutDb(window: MixMasterWindow): number {
  let total = 0;
  for (const g of window.gainsDb) if (g < 0) total += -g;
  return total;
}

/**
 * The activity strip: per-window total cut resampled to exactly
 * `count` bars, taking the MAXIMUM within each slice — a loud
 * correction must survive downsampling, or the strip would lie
 * about where the EQ is working. Mirrors `samplePeaks` in
 * src/lib/waveform.ts (same contract, different signal).
 */
export function mixMasterActivityBars(profile: MixMasterProfile, count: number): number[] {
  if (count <= 0) return [];
  const totals = profile.windows.map(windowTotalCutDb);
  if (totals.length === 0) return Array.from({ length: count }, () => 0);
  const out: number[] = [];
  for (let i = 0; i < count; i++) {
    const start = Math.floor((i * totals.length) / count);
    const end = Math.max(start + 1, Math.floor(((i + 1) * totals.length) / count));
    let max = 0;
    for (let j = start; j < end && j < totals.length; j++) {
      if (totals[j] > max) max = totals[j];
    }
    out.push(max);
  }
  return out;
}
