# Dynamic AI Mixing & Mastering Suite

Authorised by Jaizon, 2026-11-12. Programme doc — the working plan.
Builds directly on Auto EQ (commit 0930aac). Nothing here touches
capture, sync, the EDL, or video export: the suite produces a
processed AUDIO file that a project can then use as its song.

## 1. What exists today (audit, 2026-11-12)

- **Auto EQ** (`prepareEqSong` in
  `modules/mvmt-compositor/ios/MvmtCompositorModule.swift`):
  decodes the full song once (`AVAssetReader` → Float32 LPCM),
  measures RMS per band through a bank of RBJ bandpass biquads
  (`BandpassFilter`, centres `eqBandCentersHz`: 125, 250, 500, 1k,
  **2k, 3k, 4k, 6k, 8k**, 12k), reference = mean band level,
  harsh-band cut = `clamp(level − reference − 2 dB, 0, 6 dB)` with
  half-strength shoulders into neighbour bands. Renders the full
  song through `AVAudioUnitEQ` in `AVAudioEngine` offline manual
  rendering to a Float32 WAV at the EXACT source frame count
  (sample-true, no encoder priming), cached in
  Application Support/MVMTStudio/eq, keyed by
  path|size|mtime|eqSettingsVersion. Any failure → original URI.
- **Loudness**: `measureLoudness` / `decodeLoudness` (same module) +
  `src/lib/loudness.ts` mirror; auto-volume gain to −14 LUFS via the
  composition's audioMix. The suite's limiter/loudness stage reuses
  this measurement, it does not re-derive it.
- **Wiring**: `src/lib/autoEq.ts` (`prepareEqSongUri`,
  `warmUpEqSong`, `useEqSongUri` hook); `edlToCompositeRequest`
  takes an `audioUri` override; editor + export swap the song URI
  for composition builds only. Recording/capture (`prepareSong`,
  `measureTakeSync`) always use the ORIGINAL file.
- **Playback**: standing song player for recording; native preview
  compositions for editor/export preview. A/B compare reuses the
  standing player with the two URIs.

## 2. Architecture

### Processing chain (offline, one pass)
```
source file → analysis → profile → render:
  [corrective dynamic EQ] → [master EQ (static)] → [limiter*] → WAV/AAC
```
*Limiter is Stage 5 (not in the first build); the chain is built so
stages are independent nodes with their own on/off + intensity.

### Dynamic analysis (Stage 1)
- Decode once, streaming. Analysis windows: **1.0 s, 50% overlap**
  (a new analysis point every 0.5 s). Per window, per band: RMS
  level (same RBJ bank as Auto EQ — the bank is stateless per
  window after a short settle; window the input with a Hann window
  so overlaps sum cleanly).
- Per window, per harsh band: the same cut rule as Auto EQ
  (excess over that window's reference, 0 to −6 dB), plus the
  existing mud rule: low-mid bands (250/500) cut when they exceed
  reference by the same threshold — the window's own balance
  decides, so a boomy chorus and a thin verse get different
  treatment. Bass/treble balance is handled by the Master stage,
  not per-window.
- **Smoothing is the product**: raw per-window gains are passed
  through (a) a 3-point moving average across windows, then (b) a
  slew limit (max ±1.5 dB change per 100 ms of song time). The
  stored curve is the SMOOTHED curve. This is what makes it
  dynamic EQ instead of a one-second EQ switch.

### Automation (Stage 1, the honest part)
The offline render loop renders in 4096-frame blocks. Before each
block, the engine sets each `AVAudioUnitEQ` band's `gain` from the
smoothed curve evaluated at that block's timestamp (linear
interpolation between analysis points). `AVAudioUnitEQ` parameters
are settable per block in manual rendering mode; there is no
parameter-automation scheduling to fight with. No clicks: gains
move at most the slew limit between blocks, and the EQ's own
filter state is continuous (same unit, same session).

### Master EQ (Stage 2)
- A second analysis over the WHOLE song: overall band levels vs a
  gentle target curve (slight low-end shelf, flat mids, gentle
  high shelf — the exact target is a constant in the module, tuned
  by ear on device, not per-song magic). Produces ONE static gain
  set (max ±3 dB per band, cuts and boosts allowed here — this is
  the broad tonal stage, unlike the corrective stage which is
  cuts-only).
- Applied as a SECOND `AVAudioUnitEQ` in the same render chain,
  after the corrective unit. Independent toggle + intensity
  (0–100% scales the gains toward 0).
- Corrective and Master stages never share gains: the master
  analysis runs on the CORRECTED signal's band levels (measured
  by re-running the band measurement on the corrective unit's
  output in the same pass — or, simpler and equivalent: subtract
  the mean corrective gain per band from the raw overall levels).

### Profile (the stored artifact)
```ts
interface MixMasterProfile {
  version: number; songKey: string; // path|size|mtime
  sampleRate: number; durationSeconds: number;
  windows: { timeSeconds: number; gainsDb: number[] }[]; // smoothed
  masterGainsDb: number[];
  findings: { timeSeconds: number; bandHz: number; cutDb: number; reason: string }[];
}
```
Stored beside the rendered file (JSON, same cache dir). The UI
reads the profile — the spectrum view, the EQ curve, the "what
changed and why" list, and the activity-over-time strip are all
draws of this data, never re-analysis.

### Output files
- Render target: Float32 WAV (exact frame count, sample-true) —
  the master file. Optional AAC (256 kbps) export for sharing.
- Stored in Application Support/MVMTStudio/mixmaster, keyed by
  songKey + profile version + stage toggles/intensities (a settings
  change re-renders; the file is cached, never re-rendered twice
  for the same settings).
- The original file is NEVER overwritten. The processed file can be
  picked as a project's song (it is a normal audio file; the song
  picker accepts it) — that is the "reusable in projects" path.

## 3. User interface — Mix & Master section

A dedicated screen, reached from the song picker / track sheet
("Mix & Master" button on the track row):
- Waveform of the original (reuse the picker's waveform component).
- Spectrum analyzer: the profile's per-window band levels drawn
  as bars; playhead-scrubbable.
- EQ curve: the master gains + the corrective gain at the playhead,
  drawn as a curve over the band centres.
- Dynamic EQ activity over time: a strip showing total cut per
  window across the song (the "what changed" timeline).
- Findings list: "3.2 kHz −4 dB at 0:42 — harshness", "250 Hz
  −3 dB at 1:10 — mud", etc., from `profile.findings`.
- Stages: Corrective EQ (toggle + intensity), Master EQ (toggle +
  intensity), each with its own section.
- A/B compare: play original vs processed through the standing
  player (same position, instant switch).
- Progress: analysis + render progress (the native function
  reports progress via the existing onProgress pattern).
- Export: saves the WAV (and optionally AAC) to Files / share
  sheet, plus "Use in this project" (sets the track to the
  processed file).

Phone-first: one vertical scroll, compact plugin-style sections,
no nested scroll views, no desktop panels.

## 4. Staging (one build per stage)
- **Stage 1 — Dynamic corrective EQ**: windowed analysis +
  smoothing + per-block automation + profile + WAV render + cache.
  No UI beyond a progress indicator; the processed file is
  usable via the existing Auto EQ path for verification.
- **Stage 2 — Master EQ**: whole-song analysis, static gains,
  second unit in the chain, per-stage toggles + intensity.
  SHIPPED (commit pending, 2026-11-12): whole-song band levels
  measured in the same decode pass as the windows; master gains
  from the CORRECTED levels (raw + mean applied corrective gain
  per band) vs the target curve (low shelf +1.5/+1/+0.5, flat
  mids, high shelf +0.5/+1/+1.5), clamped ±3 dB, peak-relative
  active-band reference (dead bands stay flat and out of the
  reference); second AVAudioUnitEQ after the corrective unit,
  static gains; per-stage toggle + intensity in
  `Project.mixMasterStages` (unset = both ON at 100%), in the
  cache key; profile gains `masterGainsDb` + `stages`. No UI yet
  (Stage 3) — defaults keep Stage 1 behaviour when the master
  stage is off.
- **Stage 3 — Mix & Master UI**: the screen in Section 3, driven
  entirely by the stored profile; A/B compare; findings list.
  SHIPPED (commit pending, 2026-11-12): `src/app/project/mix-master.tsx`
  (route `/project/mix-master`, reached from Export beside the Auto EQ
  toggle), new native `getMixMasterProfile` bridge (reads the stored
  profile JSON, or rebuilds it from a fresh analysis when no render
  was written), `useMixMasterProfile` hook, waveform + activity
  strip + Dynamic/Master EQ curves + findings list + A/B compare
  through the one standing player at the same playhead (the SAME
  processed file editor/export use). Master switch defaults OFF —
  no analysis runs until the user turns it on. Progress is an
  indeterminate spinner: `prepareMixMasterSong` reports no progress
  (no onProgress on that bridge), so there is nothing real to show.
- **Stage 4 — Export**: WAV/AAC export, share sheet, "use in
  project".
  SHIPPED (commit bedb738, 2026-11-12): `src/lib/mixMasterExport.ts`
  (pure half — file names, uniqueness, use-in-project / restore
  patches) + `exportMixMasterSongFile` in `src/lib/mixMaster.ts`
  (re-prepares for the CURRENT settings first, so a stale render
  can never be exported; WAV is the Float32 master copied as-is,
  AAC is a native `exportMixMasterAac` transcode, AppleM4A 256 kbps
  .m4a) + Export card on the Mix & Master screen (Export WAV /
  Export AAC → share sheet via `shareFile`; "Use in this project"
  behind a confirm, pointing the track at the EXPORT copy in
  Documents/exports). "Use in project" patches the project
  directly — NOT setTrack, which would reset the region and clear
  the lyrics — so region, EDL, takes and lyrics carry over (the
  render is the exact frame count, so every song-time position
  stays valid); it turns Mix & Master + Auto EQ off (the chain is
  baked into the file) and records the original in
  `Project.mixMasterSource` (a second apply never overwrites it);
  "Restore original song" switches back and turns Mix & Master on
  again. Exports are disabled while the profile is loading and
  when the song needs no corrections. Swift uncompiled until CI,
  like all Swift work.
- **Stage 5 — Later modules** (NOT promised in this programme):
  multiband compression, standard compression, de-essing, stereo
  imaging, saturation, limiting, loudness normalization. The chain
  is built node-by-node so each can be added as a stage without
  re-architecting. Do not ship stubs for these.

## 5. Acceptance (Jaizon's list, mapped)
- Time-varying analysis + smooth automation → Stages 1–2 (slew
  limit + interpolated per-block gains; never a per-second switch).
- Separate corrective + master stages → Stage 2.
- Real DSP, full-resolution, no clipping/clicks/gaps, exact
  duration → offline render, Float32 WAV, frame-count check
  (the same guard Auto EQ already uses).
- Mix & Master UI with waveform/spectrum/curve/activity/A-B →
  Stage 3, all drawn from the stored profile.
- Exported file with the full chain, shareable, reusable →
  Stage 4. Original untouched.
- No regressions → capture/sync/EDL/video export untouched; the
  suite only ever reads the original and writes new files.
