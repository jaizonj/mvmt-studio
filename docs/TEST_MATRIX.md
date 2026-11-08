# MVMT Studio — Test & Acceptance Matrix (Overhaul)

Companion to `docs/QA_AUDIT.md`. Derived from the overhaul directive
Part 5 acceptance criteria. Three classes:

- **(A) Headless** — runnable in this environment / CI. Exact commands given.
- **(B) Device-only** — physical iPhone procedures Jaizon executes,
  each with a pass criterion. *Nothing in section B has been run yet;
  no result in this document claims otherwise.*
- **(C) Not testable / blocked** — with the reason.

**Sync tolerance gates (PROPOSAL, from the architecture audit — not yet
ratified by Jaizon):** median take-start sync error ≤ 40 ms, 95th
percentile ≤ 80 ms, measured by procedure B-R06. At 30 fps, 40 ms ≈
1.2 frames. Treat as proposed acceptance thresholds until confirmed.

Status key: ✅ verified pass · ❌ verified fail · ⬜ not run · 🚫 blocked.

---

## A. Headless tests (here / CI)

| ID | Test | Exact command | Expected | Status (2026-11-08) |
| --- | --- | --- | --- | --- |
| A-01 | Typecheck | `cd ~/workspace/mvmt-studio && npx tsc --noEmit` | Exit 0, no errors | ✅ PASS |
| A-02 | Lint | `npx expo lint` | Exit 0, no findings | ✅ PASS |
| A-03 | Shuffle engine unit tests (incl. frequency regression tests) | `npm run test:shuffle` | All pass (currently 11) | ✅ PASS (11/11) |
| A-04 | EDL + shuffle→EDL bridge unit tests | `npm run test:edl` | All pass (currently 11) | ✅ PASS (11/11) |
| A-05 | Dependency/config health | `npm run doctor` (expo-doctor) | All checks pass (baseline was 20/20) | ⬜ Not run in this audit |
| A-06 | iOS JS bundle builds | `npx expo export --platform ios` | Exit 0, `dist` written | ✅ PASS |
| A-07 | Lockfile integrity (CI installs with `npm ci`) | `npm ci --dry-run` | Exit 0 (no lockfile desync) | ⬜ Re-run after any dependency change |
| A-08 | Native Swift compiles + unsigned IPA packages | Push branch → GitHub Actions `build-unsigned-ipa.yml` (or `gh workflow run build-unsigned-ipa.yml` after push) | Green run; artifact `MVMTStudio-unsigned.ipa` exists; `unzip -l` shows `Payload/MVMTStudio.app/main.jsbundle` | ⬜ Overhaul branch not yet built (last green: pre-overhaul master, run 42464377582) |
| A-09 | CI actually gates on quality | Inspect `.github/workflows/build-unsigned-ipa.yml` | Workflow runs A-01…A-04 before the archive step | ❌ FAIL — workflow has no test/tsc/lint step (QA_AUDIT F-10). Fix belongs to the lead. |
| A-10 | EDL gate: no screen imports seconds-based timeline once cut over | `grep -rn "TimelineClip" src/app src/components` | Zero hits after Wave 2 cutover | ⬜ Post-Wave-2 check |
| A-11 | Native contract gate: every TS-declared module function exists in Swift | `grep -o 'AsyncFunction("[a-zA-Z]*"' modules/mvmt-compositor/ios/*.swift` vs the function list in `modules/mvmt-compositor/src/index.ts` | Sets match (renderVideo, cancelExport, inspectAsset, createPreview, setPreviewPaused, seekPreview, releasePreview + view) | ❌ FAIL today — Swift registers only `renderVideo` (QA_AUDIT F-1). Re-run when Agent Swift lands v2. |

---

## B. Device-only tests (physical iPhone, sideload build)

General setup for all B tests: install the latest CI-built IPA via
Sideloadly (same Apple ID as before); Developer Mode on; note the
build's commit/run number in the result. Use a wired or quiet room
setup where audio matters. **Record results with the build id — a
pass on an old build proves nothing about a new one.**

### B-R — Recording

| ID | Procedure | Pass criterion |
| --- | --- | --- |
| B-R01 | **Multiple full-length takes.** Pick a 60s+ track, set length Full. Record 3 takes back-to-back without leaving the camera. | All 3 takes appear in Takes, each playable in Shuffle preview, none truncated early, no overlap/corruption between takes. |
| B-R02 | **Take duration accuracy.** Record one take at each length preset (15s/30s/1min). For each, note the on-screen elapsed time at stop, then check the take's duration shown in Takes. | Stated duration within ±0.5s of the preset for every take; recording stops at the preset, not before/after. |
| B-R03 | **Asset finalisation.** Record a take; immediately force-quit the app from the app switcher; relaunch. | (Today: take list is gone — known persistence gap, QA_AUDIT F-2. After persistence lands:) the take is present and playable; a corrupt/0-byte take = FAIL. |
| B-R04 | **Camera switching.** Record take 1 (back), flip to front, record take 2, flip back, record take 3. Also attempt flip mid-recording. | Each take uses the camera shown; flip is disabled or safely handled mid-recording (no crash, no frozen preview); front takes are mirrored as expected. |
| B-R05 | **Timer & count-in.** Set Timer 3s + Count-in 4 beats; record. Then set both off; record. | With timers: beeps/count-in occur, recording starts after them, take is not short by the timer amount. With both off: recording starts immediately. |
| B-R06 | **Sync measurement (the audit's method).** Use a test track: a 120 BPM click track with a spoken/printed count (or metronome app recording). Perform 5 takes of 15s: sit in frame and tap a tabletop sharply exactly on each beat for the first 4 beats, again at ~8s, and the final 4 beats. In the exported or previewed cut, scrub frame-by-frame (Photos editor / QuickTime on PC): for ≥10 taps per take, record (tap frame time − nearest click time) in ms. Compute per-take start offset (first taps), drift (last taps − first taps), and across the 5 takes: median + p95 of start offsets. | PROPOSED gates: median start error ≤ 40 ms; p95 ≤ 80 ms; drift over 15s ≤ 1 frame (33 ms). Any take > 150 ms off = FAIL regardless of medians. |
| B-R07 | **Long-take drift.** Record one 60s take with the click track, tapping on beats at start and end (as B-R06). Measure offset at start vs end. | Drift ≤ 2 frames (66 ms) over 60s. Larger drift = sync engine must add drift correction before Rapid editing is trusted. |
| B-R08 | **Recording doesn't fight playback.** While recording, receive a phone call / trigger Siri / pull Control Center, then return. | Recording stops or pauses gracefully with a clear state; the take is either complete-and-saved or clearly discarded — never a half-written file presented as good. Song does not keep playing in the background after leaving. |
| B-R09 | **Orientation/resolution metadata.** Record one portrait take; transfer the file to the PC; inspect (QuickTime Get Info / `ffprobe`). | Dimensions match the camera setting (e.g. 1080×1920 portrait), rotation displays correctly in Photos and on PC, duration matches B-R02. |

### B-P — Preview

| ID | Procedure | Pass criterion |
| --- | --- | --- |
| B-P01 | **Full composition playback.** Build a cut (≥2 takes), press Preview, watch start to finish without touching anything. | Plays to the end in one pass; no black frames, no frozen frames at cuts, no restart of the song mid-cut. |
| B-P02 | **Rapid cuts.** Frequency = Rapid, 15s cut (expect ~20–30 cuts). Play fully, twice. | No visible stutter/black frame at cut boundaries; no audible click/gap in the song at any cut; cuts land on the beat grid (compare against the song). |
| B-P03 | **No take audio.** In a quiet room, record a take while making a distinctive noise off-beat (e.g. clap at a random moment) with the song playing from the phone speaker. Preview the cut at full volume. | Only the song is audible. The clap/room noise must NOT be heard (master-only default). Any take audio = FAIL (current build is EXPECTED TO FAIL this — QA_AUDIT F-3). |
| B-P04 | **Pause/resume.** Play, pause mid-cut, wait 10s, resume. Repeat 5×. | Resume starts within ~0.3s, from the paused position, song and video still in sync afterwards (check against a beat). |
| B-P05 | **Seeking.** (Once native preview seek exists.) Scrub the timeline playhead to several positions incl. mid-cut and the final second. | Preview shows the frame at that position; play resumes from there in sync. |
| B-P06 | **Repeated shuffle.** Tap Shuffle 20× in a row, playing a few seconds after each. | Every shuffle produces a visibly different arrangement; no crash, no stuck shimmer, no silent preview; cut counts stay in the frequency's expected range. |
| B-P07 | **Background/foreground.** During preview playback, press Home, wait 5s, return. Also lock the phone mid-playback and unlock. | Audio stops when backgrounded; on return the preview is paused (not playing silently out of sync) and resumes cleanly. |
| B-P08 | **Take switching.** In the editor, tap a cut and switch its take; play. Switch 5 cuts. | Preview reflects each new take at the right timeline position; no other cut changes; playhead/timeline agree with what's shown. |
| B-P09 | **Frame-drop observation.** Play a Rapid 30s cut in a bright, high-motion take. Watch for judder; then screen-record the playback (iOS screen recording) and step through the recording on PC. | Subjective smoothness: no repeated freezes ≥ 2 frames at cuts in the screen recording. (Quantitative dropped-frame counts need Instruments — section C.) |

### B-E — Export

For duration/stream verification (used by several tests): after
export, Save to Photos, AirDrop/transfer the MP4 to the Windows PC,
and inspect with `ffprobe -v error -show_streams -show_format file.mp4`
(free, part of FFmpeg) or MediaInfo. Check: container duration, video
stream duration, audio stream duration, width/height, avg_frame_rate,
audio codec/channels. **Compare against what the app CLAIMS the
duration is** — a mismatch is itself a failure (the engine must report
measured values).

| ID | Procedure | Pass criterion |
| --- | --- | --- |
| B-E01 | **15s export.** Rapid cut over a 15s region, ≥2 takes. Export, save, inspect per above. | ffprobe duration 15.0s ± 0.2s; app-reported duration matches ffprobe within 0.1s; one video + one audio stream; 1080×1920; ~30fps. |
| B-E02 | **30s export.** Same at 30s (Normal frequency). | Same criteria at 30.0s ± 0.2s. |
| B-E03 | **60s export.** Same at 60s (a 1min length preset or full 60s track). | Same criteria at 60.0s ± 0.3s; export completes without the phone sleeping/cancelling (note wall-clock render time for B-PF02). |
| B-E04 | **Preview = export.** Take the B-E01 cut; screen-record the preview; then step through preview recording and exported MP4 side by side at 5 cut boundaries (PC, frame step). | Same take at the same timeline position at every boundary (±1 frame); same framing; song position matches. |
| B-E05 | **Mixed orientation.** Record one take portrait; rotate the phone and record another (or use a landscape take if the camera allows). Build a cut from both, export, inspect + watch. | No stretched footage; both takes fill or fit the canvas per policy (centre-crop/fill default); no sideways video; no black bars unless fit policy chosen. (Current engine is EXPECTED TO FAIL framing — canvas comes from the first clip, QA_AUDIT §8.) |
| B-E06 | **Different source offsets.** Set region start to 30s into the track; record 2 takes; shuffle; export; watch the first 2 seconds closely. | The cut starts at the song's 30s point (lyric/instrument check against the original track at 0:30), and takes are in sync from the first frame. |
| B-E07 | **Export audio purity.** Use the noisy take from B-P03 in a cut; export; listen to the MP4 on PC at full volume. | Song only; no room noise, no doubled/echoed song. (Current build EXPECTED TO FAIL — F-3.) |
| B-E08 | **Export cancel & progress.** (Once v2 lands.) Start a 60s export, cancel at ~50%. | Progress bar moved smoothly (not stuck at 0/100); cancel stops within ~2s; no partial file appears in Photos; app stays responsive; a fresh export afterwards succeeds. |
| B-E09 | **Repeat exports.** Export the same cut 3×. | All three files valid per ffprobe, durations identical ±0.1s, no degradation. |
| B-E10 | **Share/save integrity.** From Export: Save to Photos, then Share to Messages/Files. | Saved file plays in Photos; shared file is the same bytes (same duration/size); no permission dead-ends. |

### B-U — UI / navigation / persistence

| ID | Procedure | Pass criterion |
| --- | --- | --- |
| B-U01 | **Every destination.** Visit every tab/screen/sheet reachable in the build; open and dismiss every sheet. | No dead buttons, no screen that can't be left, no redirect loops (`/editor` included). |
| B-U02 | **Every primary action.** Record, Takes actions (save/share/delete), Shuffle, frequency change, take switch, Export render/save/share, every Settings row changed and re-checked. | Each action produces its visible effect; Settings changes are *actually applied* (frame-rate/export-quality/autosave are known-dead today — F-7 — retest after fixes). |
| B-U03 | **Delete-take safety.** Delete a take that is used in the cut. | A confirmation appears (after fix); the cut updates predictably; no crash. (Today: no confirmation — known finding.) |
| B-U04 | **Persistence / restart.** Build a project (track + 3 takes + a shuffled cut + changed settings). Force-quit, relaunch. | (Post-persistence:) project, takes, cut and settings all restored. (Today: everything is lost — F-2. This test is the acceptance gate for the persistence work.) |
| B-U05 | **Error states.** (a) Pick a non-audio file as track if the picker allows; (b) revoke camera permission in iOS Settings and open the app; (c) fill storage pressure: record with < 500 MB free if feasible; (d) export with no track. | Each shows a clear, recoverable message; no crash, no infinite spinner, no silent failure. |
| B-U06 | **Loading states.** Cold-launch; open a project with many takes; generate thumbnails on a fresh cut. | Skeletons/spinners appear and resolve; UI never shows a frozen frame > 1s without feedback. |
| B-U07 | **Small + large iPhones.** Run the full journey (record → takes → edit → export) on the smallest and largest available iPhone (or a borrowed one). | No clipped controls, timeline usable, record button reachable, sheets fully visible. |
| B-U08 | **Safe areas.** Check camera, editor, export on a notched/Dynamic-Island device in portrait. | Nothing under the notch/island or home indicator; pills don't collide with the top bar. |
| B-U09 | **Accessibility basics.** VoiceOver on: navigate Record and Editor. Dynamic Type at largest size: open Takes and Settings. | All primary controls labelled and reachable; no essential text truncated at largest type. |
| B-U10 | **Appearance consistency.** Walk every screen in a dark room / low brightness. | Single graphite/lime identity everywhere; no leftover iridescent/purple elements (known leftovers in timeline segment colours + shimmer — §7.6 of the audit); splash → first screen doesn't flash a different background colour. |
| B-U11 | **First-launch splash.** Force-quit; cold launch 3×. | Splash dismisses promptly every time (no hang on the splash screen — the app never calls the splash API explicitly; verify actual behaviour). |

### B-PF — Performance (device-observable)

| ID | Procedure | Pass criterion |
| --- | --- | --- |
| B-PF01 | **Composition preparation time.** From tapping into the editor (or pressing Preview) to first frame + playable, time 5 cold entries with a stopwatch. | Median ≤ 1.5s for a 30s cut (proposed); no entry > 3s. |
| B-PF02 | **Export render time.** Time B-E01/02/03 renders (stopwatch, screen on). | Record actuals. Proposed ceilings: 15s ≤ 20s, 30s ≤ 40s, 60s ≤ 90s on the test iPhone. Trend matters more than the absolute numbers. |
| B-PF03 | **Memory accumulation.** Record 10 takes in one session, shuffle 10×, export twice. Watch for slowdown; check Settings → General → iPhone Storage → MVMT before/after. | No crash or visible progressive slowdown; storage growth ≈ sum of take files + exports (no runaway cache). Precise memory profiling is section C. |
| B-PF04 | **Long playback session.** Loop-play previews and re-shuffle for 10 minutes continuously. | No crash, no audio degradation, phone not excessively hot, playback still in sync at the end (beat check). |
| B-PF05 | **Rapid-cut stress.** Rapid frequency on a 60s region (100+ cuts). Play fully. | Completes without crash; cut boundaries stay clean (B-P02 criteria at scale). If the player drops cuts or merges them audibly, FAIL with notes. |

---

## C. Not testable / blocked (and why)

| Item | Why blocked | What would unblock it |
| --- | --- | --- |
| Instruments profiling (CPU/GPU/memory, dropped-frame counts, decoder behaviour) | No Mac in the environment; Muse's VM is Linux; Jaizon's PC is Windows | A Mac with Xcode, or structured manual proxies (B-P09, B-PF03) accepted as interim evidence |
| iOS Simulator runs | Same — no Xcode/simulator available | Mac with Xcode |
| Swift compile verification pre-CI | Swift/AVFoundation code cannot compile on Linux | Push to CI (A-08); first green run on the overhaul branch is a programme milestone |
| Native preview behaviour (v2) | Not implemented in Swift yet (QA_AUDIT F-1) | Agent Swift lands v2 + CI green, then B-P/B-E08 tests apply |
| Measured sync *inside* the pipeline (player media-time vs capture timestamps) | Requires native instrumentation/logging build | Sync agent adds measurement logging; B-R06 is the black-box substitute until then |
| Automated on-device UI tests (XCUITest / Detox) | No Mac/Xcode; sideload-only distribution | Mac + dev build pipeline |
| Expo Go validation of the native engine | Custom native module is not in Expo Go by design | N/A — use the sideload build; Expo Go is parked |
| TestFlight / signed-build behaviour (entitlements, background modes at scale) | No Apple Developer Program account (free sideload route chosen) | Paid developer account, if Jaizon chooses it later |
| Frame-accurate (±1 frame) automated sync proof | Needs the click-track method + frame stepping by hand (B-R06) or Instruments | B-R06 executed carefully is the current best evidence |

---

## Sign-off rule

A build is "device-verified" for a release only when: all A tests
pass, CI is green (A-08/A-09), and B-R01…R07, B-P01…P04, B-P06,
B-E01…E04, B-E07, B-U01…U04 pass on that exact build, with B-E
durations verified by file inspection — not by the app's own readout.
Anything less must be reported as partially verified, naming the
untested areas (directive: do not declare production-ready without
evidence).
