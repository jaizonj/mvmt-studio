import { Ionicons } from '@expo/vector-icons';
import { setAudioModeAsync, useAudioPlayer, useAudioPlayerStatus } from 'expo-audio';
import { CameraView, useCameraPermissions, useMicrophonePermissions } from 'expo-camera';
import * as Brightness from 'expo-brightness';
import { router, useFocusEffect } from 'expo-router';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  Alert,
  AppState,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { IconButton } from '../../components/IconButton';
import { RecordButton } from '../../components/RecordButton';
import { DEFAULT_BPM, effectiveRegion, rmsOfFrames, SectionEnergyAccumulator } from '../../lib/analysis';
import { TrackSheet } from '../../components/TrackSheet';
import { Image } from 'expo-image';

import { NativePreview } from '../../components/NativePreview';
import { getCachedThumbnail, loadThumbnails } from '../../lib/thumbnails';
import type { Take } from '../../types';
import { measureTakeDurationSeconds, persistTake, pickAudioTrack } from '../../lib/media';
import { useStudio } from '../../store/StudioContext';
import { colors, formatTime, radius, spacing, type as typeScale } from '../../theme';

const ZOOM_PRESETS = [
  { label: '1×', value: 0 },
  { label: '2×', value: 0.12 },
  { label: '3×', value: 0.28 },
  { label: '5×', value: 0.55 },
];

/**
 * Sanity bound for measured-sync samples, seconds. A real capture-start
 * error is tens to a few hundred milliseconds; a sample further out than
 * this means the player position itself was untrustworthy (e.g. stale
 * from a previous screen), and an honestly UNMEASURED take (the EDL
 * falls back to the assumed offset) beats a wrong measurement that
 * would shift every cut. See the measured-sync block in beginRecording.
 */
const SYNC_MEASUREMENT_SANITY_SECONDS = 2;

/** Video-length choices for the bottom-centre row (song-part lengths). */
const LENGTH_PRESETS: { label: string; seconds: number | null }[] = [
  { label: '15s', seconds: 15 },
  { label: '30s', seconds: 30 },
  { label: '1 min', seconds: 60 },
  { label: '3 min', seconds: 180 },
  { label: 'Full', seconds: null },
];

/**
 * Camera screen — Stage 1 (Record) of the guided flow. The app opens
 * here, full-screen, like Snapchat.
 *
 * Minimal by design (HIG): only flip / torch / track / the Settings gear
 * sit on the camera itself. ALL the little options live in Settings
 * (gear). Forward movement follows the flow — Record → Takes → Shuffle
 * → Export — and the later stages are locked until you've recorded:
 * tapping Takes or Shuffle with zero takes shows "Record a take first"
 * instead of navigating. There is deliberately no Export action here.
 *
 * Camera preferences (facing/torch/mirror/zoom/countdown) live in the
 * studio store so Settings shows the real values from any screen.
 */
/**
 * Sync status in human words, from the take's MEASURED sync offset
 * (same mapping the Takes rail preview uses everywhere): ~1 frame at
 * 30 fps (0.04s) is plainly in sync; up to 0.10s is a slight offset;
 * beyond that, check before export. No raw values are shown.
 */
function syncStatusText(take: Take): string {
  const offset = take.syncOffsetSeconds;
  if (offset === undefined) return 'Sync not measured';
  const magnitude = Math.abs(offset);
  if (magnitude <= 0.04) return 'In sync';
  if (magnitude <= 0.1) return 'In sync · slight offset';
  return 'Off sync — check before export';
}

/** The rail tile's thumbnail moment: 40% into the take. */
function railSampleSeconds(take: Take): number {
  return take.durationSeconds ? Math.max(0.1, take.durationSeconds * 0.4) : 0.5;
}

export default function CameraScreen() {
  const insets = useSafeAreaInsets();
  const studio = useStudio();
  const {
    track,
    takes,
    facing,
    setFacing,
    torch,
    setTorch,
    mirror,
    zoom,
    setZoom,
    countdown,
    setCountdown,
    resolution,
    gridOverlay,
    levelGuide,
    audioOffsetMs,
    countInBeats,
    setCountInBeats,
    metronome,
  } = studio;

  const [cameraPermission, requestCameraPermission] = useCameraPermissions();
  const [micPermission, requestMicPermission] = useMicrophonePermissions();

  const [countingDown, setCountingDown] = useState<number | null>(null);
  const [countIn, setCountIn] = useState<number | null>(null);
  const [beatFlash, setBeatFlash] = useState(false);
  const [recording, setRecording] = useState(false);

  /**
   * Front-facing flash (Jaizon, 2026-11-08): the front camera has no torch
   * LED, so with torch ON and the FRONT camera active, recording lights the
   * screen instead — warm-white overlay + full system brightness, restored
   * when recording stops. Back camera keeps using the real torch
   * (enableTorch on CameraView).
   */
  const frontFlashActive = facing === 'front' && torch && recording;
  const savedBrightnessRef = useRef<number | null>(null);
  useEffect(() => {
    if (!frontFlashActive) return;
    let alive = true;
    void Brightness.getBrightnessAsync()
      .then((v) => {
        if (!alive) return;
        savedBrightnessRef.current = v;
        void Brightness.setBrightnessAsync(1);
      })
      .catch(() => undefined);
    return () => {
      alive = false;
      const prev = savedBrightnessRef.current;
      savedBrightnessRef.current = null;
      if (prev !== null) void Brightness.setBrightnessAsync(prev).catch(() => undefined);
    };
  }, [frontFlashActive]);
  const [elapsed, setElapsed] = useState(0);
  const [trackOpen, setTrackOpen] = useState(false);
  const [zoomOpen, setZoomOpen] = useState(false);
  const [timersOpen, setTimersOpen] = useState(false);

  // Takes rail (left side): the takes stack up here as they're recorded
  // — this replaces the separate Takes screen. A tapped tile opens the
  // preview card below.
  const [railPreviewId, setRailPreviewId] = useState<string | null>(null);
  const [railPaused, setRailPaused] = useState(false);
  const [, setRailThumbTick] = useState(0);
  useEffect(() => {
    let alive = true;
    const missing = takes.filter((t) => getCachedThumbnail(t.uri, railSampleSeconds(t)) === undefined);
    if (missing.length === 0) return;
    void Promise.all(missing.map((t) => loadThumbnails(t.uri, [railSampleSeconds(t)]))).then(() => {
      if (alive) setRailThumbTick((n) => n + 1);
    });
    return () => {
      alive = false;
    };
  }, [takes]);
  const railPreviewTake = railPreviewId ? (takes.find((t) => t.id === railPreviewId) ?? null) : null;
  const edlTakeIds = useMemo(() => new Set((studio.edl?.segments ?? []).map((seg) => seg.takeId)), [studio.edl]);
  const [appActive, setAppActive] = useState(true);
  const [isFocused, setIsFocused] = useState(true);
  const [notice, setNotice] = useState<string | null>(null);

  const cameraRef = useRef<CameraView>(null);
  const recordPromiseRef = useRef<Promise<{ uri: string } | undefined> | null>(null);
  const recordStartRef = useRef(0);
  // Recording-session bookkeeping (intermittent stop/duration bugs,
  // Jaizon 2026-11-08): every recording gets a session id; intervals and
  // promise handlers capture theirs and ignore themselves if a newer
  // session has started — a late-finishing take can no longer kill the
  // next take's timer or scramble its duration. stopAtRef freezes the
  // moment stop was requested, so the saved duration is measured at
  // STOP time, not whenever the camera finishes writing the file.
  const recordSessionRef = useRef(0);
  const stopAtRef = useRef<number | null>(null);
  const countdownTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const countInTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const elapsedTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const energyAccRef = useRef<SectionEnergyAccumulator | null>(null);
  const zoomAtPinchStartRef = useRef(0);

  // Track playback — the sync master clock for takes.
  const player = useAudioPlayer(track?.uri ?? null);
  const playerStatus = useAudioPlayerStatus(player);

  // Timer/count-in sounds (Jaizon asked for audible cues): a short beep
  // for each camera-timer second, a click for each count-in beat, and a
  // higher "go" tone the moment recording actually starts.
  const beepPlayer = useAudioPlayer(require('../../../assets/sounds/beep.wav'));
  const clickPlayer = useAudioPlayer(require('../../../assets/sounds/click.wav'));
  const goPlayer = useAudioPlayer(require('../../../assets/sounds/go.wav'));
  const playCue = useCallback((which: 'beep' | 'click' | 'go') => {
    const p = which === 'beep' ? beepPlayer : which === 'click' ? clickPlayer : goPlayer;
    try {
      void p.seekTo(0);
      p.play();
    } catch {
      /* cue sounds are best-effort */
    }
  }, [beepPlayer, clickPlayer, goPlayer]);
  const timerWasUsedRef = useRef(false);
  const stopRequestedRef = useRef(false);

  useFocusEffect(
    useCallback(() => {
      setIsFocused(true);
      return () => {
        setIsFocused(false);
        // Leaving the camera (e.g. into Takes/Edit/Export) must never
        // leave the track playing behind the new screen.
        try {
          player.pause();
        } catch {
          /* player already released */
        }
      };
      // eslint-disable-next-line react-hooks/exhaustive-deps
    }, []),
  );

  // iOS camera-session interruptions (call, Siri, Control Centre, app
  // backgrounding) end or suspend the capture session. Handle them
  // explicitly: the CameraView `active` prop follows AppState, and when the
  // app becomes active again we resumePreview() so the native preview
  // restarts cleanly instead of sitting on a frozen last frame.
  // (This is a native AVCaptureSession preview — there is no webview or
  // <video> element here, so the web version's pause-glyph problem, which
  // came from a paused HTML <video>, cannot occur. See README.)
  useEffect(() => {
    const sub = AppState.addEventListener('change', (state) => {
      const active = state === 'active';
      setAppActive(active);
      if (active) {
        // Restart the preview after an interruption/backgrounding.
        cameraRef.current?.resumePreview().catch(() => {
          // Preview may already be running — resuming is best-effort.
        });
      }
    });
    return () => sub.remove();
  }, []);

  // Learn the track duration once the player loads it.
  useEffect(() => {
    if (playerStatus.duration > 0) studio.setTrackDuration(playerStatus.duration);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [playerStatus.duration]);

  // Sample the track's real energy (RMS) while it plays during a take, so
  // the section table the shuffle engine uses is cached, not recomputed.
  useEffect(() => {
    player.setAudioSamplingEnabled(true);
    const sub = player.addListener('audioSampleUpdate', (sample) => {
      const acc = energyAccRef.current;
      if (!acc) return;
      const channel = sample.channels[0];
      if (channel) acc.addSample(sample.timestamp, rmsOfFrames(channel.frames));
    });
    return () => sub.remove();
  }, [player]);

  useEffect(
    () => () => {
      if (countdownTimerRef.current) clearInterval(countdownTimerRef.current);
      if (countInTimerRef.current) clearInterval(countInTimerRef.current);
      if (elapsedTimerRef.current) clearInterval(elapsedTimerRef.current);
    },
    [],
  );

  // Metronome beat flash while recording (Settings → Audio): a soft dot
  // pulsing at the assumed 120 BPM grid the sections are built on.
  useEffect(() => {
    if (!recording || !metronome) return;
    const timer = setInterval(() => setBeatFlash((v) => !v), 500);
    return () => clearInterval(timer);
  }, [recording, metronome]);

  const flashNotice = useCallback((message: string) => {
    setNotice(message);
    setTimeout(() => setNotice((current) => (current === message ? null : current)), 2600);
  }, []);

  // Forward navigation: the takes live on this screen's left rail now
  // (no separate Takes screen). Next goes to the Editor — or straight
  // to Export when a cut already exists. Gated on the first take.
  const goForward = useCallback(() => {
    if (takes.length === 0) return flashNotice('Record a take first');
    if (studio.edl) return router.push('/project/export');
    router.push('/project/editor');
  }, [flashNotice, takes.length, studio.edl]);

  const openRailPreview = useCallback((take: Take) => {
    setRailPreviewId(take.id);
    setRailPaused(false);
  }, []);

  const renameRailTake = useCallback((take: Take) => {
    Alert.prompt(
      'Rename take',
      undefined,
      (name) => {
        const trimmed = (name ?? '').trim();
        studio.updateTake(take.id, { displayName: trimmed ? trimmed.slice(0, 40) : undefined });
      },
      'plain-text',
      take.displayName ?? '',
    );
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const deleteRailTake = useCallback(
    (take: Take) => {
      const inCut = edlTakeIds.has(take.id);
      Alert.alert(
        'Delete take?',
        inCut
          ? 'This take is used in your cut — deleting it will clear the current edit.'
          : 'This take will be removed.',
        [
          { text: 'Cancel', style: 'cancel' },
          {
            text: 'Delete',
            style: 'destructive',
            onPress: () => {
              studio.removeTake(take.id);
              if (inCut) studio.setEdl(null);
              setRailPreviewId(null);
            },
          },
        ],
      );
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [edlTakeIds],
  );

  const handlePickTrack = useCallback(async () => {
    try {
      const picked = await pickAudioTrack();
      if (picked) {
        studio.setTrack(picked);
        flashNotice(`Track added — ${picked.name}`);
      }
    } catch {
      Alert.alert('Could not add that file', 'Try an MP3, M4A or WAV from Files.');
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [flashNotice]);

  const beginRecording = useCallback(async () => {
    if (!cameraRef.current) return;
    if (recordSessionRef.current > 0 && recording) return;
    const session = recordSessionRef.current + 1;
    recordSessionRef.current = session;
    await setAudioModeAsync({ playsInSilentMode: true, allowsRecording: true });

    // The selected region is the single source of truth for what plays.
    const regionEff = effectiveRegion(studio.trackRegion, playerStatus.duration || track?.durationSeconds);
    // The region start this take is recorded against: stored on the
    // take as trackOffsetSeconds AND used as the reference for the
    // measured sync offset below — one value, so the EDL bridge's
    // mapping (trackOffset − regionStart + syncOffset) stays coherent.
    const regionStartSeconds = regionEff?.startSeconds ?? studio.trackRegion.startSeconds ?? 0;

    // Fresh energy accumulation for this pass over the region.
    energyAccRef.current =
      track && regionEff
        ? new SectionEnergyAccumulator(regionEff.lengthSeconds, DEFAULT_BPM, regionEff.startSeconds)
        : null;

    // Sync at capture: the region restarts from its start at the same
    // moment the camera starts, so every take is time-aligned. The
    // Settings audio offset (Bluetooth/output-latency correction) shifts
    // the seek, and previews apply the same offset, so sync holds. The
    // RESIDUAL error this leaves (seek/play/camera-start latency) is no
    // longer assumed to be zero — it is measured per take (songStart
    // sample below, stored as Take.syncOffsetSeconds).
    if (track) {
      await player.seekTo(Math.max(0, (regionEff?.startSeconds ?? 0) + audioOffsetMs / 1000));
      player.play();
    }
    if (timerWasUsedRef.current) {
      timerWasUsedRef.current = false;
      playCue('go');
    }

    // LOCKED recording length — second attempt (Jaizon's device test:
    // takes stopped at 18s, 4s, and one saved as 9s). Root causes found:
    //  1. The old stop also fired when the AUDIO PLAYER's position
    //     passed the region end — but that player is shared, and its
    //     position can be stale (left at the end from a preview or the
    //     previous take), stopping a fresh take after a few seconds.
    //     The player position is NO LONGER a stop condition, ever.
    //  2. When the track's duration had not loaded yet, the region came
    //     back empty and the take recorded with NO limit at all. The
    //     length now falls back to the length the user picked.
    //  3. Sessions shared refs, so a late promise could scramble the
    //     next take. Everything below is guarded by the session id.
    // The ONE stop authority is the wall-clock deadline below, backed
    // by the camera's own maxDuration (set a touch LONGER, purely as a
    // safety net, so the app's stop always wins the race cleanly).
    const lengthSeconds = regionEff?.lengthSeconds ?? studio.trackRegion.durationSeconds ?? track?.durationSeconds ?? null;
    recordStartRef.current = Date.now();
    stopAtRef.current = null;
    stopRequestedRef.current = false;
    setElapsed(0);
    const deadlineMs = lengthSeconds !== null ? recordStartRef.current + lengthSeconds * 1000 : null;
    elapsedTimerRef.current = setInterval(() => {
      if (recordSessionRef.current !== session) return;
      const elapsedNow = (Date.now() - recordStartRef.current) / 1000;
      setElapsed(lengthSeconds !== null ? Math.min(elapsedNow, lengthSeconds) : elapsedNow);
      if (stopRequestedRef.current) return;
      if (deadlineMs !== null && Date.now() >= deadlineMs) {
        stopRequestedRef.current = true;
        stopAtRef.current = Date.now();
        player.pause();
        cameraRef.current?.stopRecording();
      }
    }, 100);
    setRecording(true);

    // MEASURED SYNC — songStart sample (Overhaul Wave 2; the audit's
    // core complaint was that sync was ASSUMED, never measured).
    //
    // Sampled here — after the seek + play above, as close to the
    // recordAsync call as JS allows — this is the song position the
    // take's first frames were captured against, as best this stack
    // can know it. HONEST LIMIT: expo-camera exposes NO first-frame
    // timestamp, so this is a player-side ESTIMATE of capture start:
    // recordAsync's own pipeline spin-up latency sits inside it and
    // cannot be separated out without a custom capture module. The
    // drift figure computed when the take lands (song elapsed between
    // this sample and the stop sample, minus the file's measured
    // duration) is the measurable cross-check on this estimate — a bad
    // start sample or clock disagreement shows up there instead of
    // hiding. Both values are stored on the Take and consumed by the
    // EDL bridge (src/lib/shuffleEdl.ts) via src/lib/edl.ts's single
    // mapping: sourceFrame = timelineFrame − round(offset · fps),
    // where offset's measured part is (this sample − the seek target).
    const songStartSeconds = track ? player.currentTime : null;

    recordPromiseRef.current = cameraRef.current.recordAsync({
      // Safety net only: our own deadline stops the take first.
      maxDuration: lengthSeconds !== null ? Math.max(1, lengthSeconds + 1) : undefined,
    });
    recordPromiseRef.current
      .then(async (result) => {
        // MEASURED SYNC — songEnd sample, taken FIRST, before anything
        // here pauses or seeks the player. The player was already
        // paused at the moment recording stopped (stopRecording / the
        // deadline both pause it), so this reads the song position at
        // stop time — the other end of the drift measurement.
        const songEndSeconds = track ? player.currentTime : null;
        const mine = recordSessionRef.current === session;
        if (mine && elapsedTimerRef.current) clearInterval(elapsedTimerRef.current);
        if (mine) setRecording(false);
        player.pause();
        if (!result?.uri) return;
        // Duration = stop time minus start time (both frozen above),
        // never the promise-resolution time. Then prefer the FILE's own
        // MEASURED duration when it can be read — native inspectAsset
        // when the engine is linked, else the JS probe (see
        // measureTakeDurationSeconds) — it's the ground truth for what
        // actually got recorded, and it replaces the wall-clock value.
        const stopAt = stopAtRef.current ?? Date.now();
        let durationSeconds = Math.max(0.1, (stopAt - recordStartRef.current) / 1000);
        if (lengthSeconds !== null) durationSeconds = Math.min(durationSeconds, lengthSeconds);
        const saved = await persistTake(result.uri);
        const measuredDurationSeconds = await measureTakeDurationSeconds(saved.uri);
        if (measuredDurationSeconds !== null) {
          durationSeconds = lengthSeconds !== null ? Math.min(measuredDurationSeconds, lengthSeconds) : measuredDurationSeconds;
        }
        // MEASURED SYNC fields — this session's samples are locals of
        // this beginRecording invocation, so a late-finishing take can
        // only ever attach its OWN measurements to its OWN Take.
        //
        //   syncOffsetSeconds = songStart − regionStart − audioOffset
        //
        // The seek above targeted regionStart + audioOffsetMs/1000
        // (the Settings Bluetooth/output-latency correction, applied
        // there on purpose) — subtracting that same correction here
        // leaves only the UNINTENDED capture error, matching the EDL
        // bridge's definition: positive = capture started late, so the
        // footage for a timeline frame lives earlier inside the file.
        //
        //   syncDriftSeconds = (songEnd − songStart) − measuredDuration
        //
        // using the file's RAW measured duration (not the length-
        // clamped value stored as durationSeconds): how much the song
        // clock and the camera clock disagreed over this take.
        //
        // Either figure outside the sanity bound means a sample was
        // untrustworthy (stale player position) — the field is then
        // left undefined (honestly unmeasured) rather than stored.
        let syncOffsetSeconds: number | undefined;
        let syncDriftSeconds: number | undefined;
        if (songStartSeconds !== null) {
          const offset = songStartSeconds - audioOffsetMs / 1000 - regionStartSeconds;
          if (Math.abs(offset) <= SYNC_MEASUREMENT_SANITY_SECONDS) {
            syncOffsetSeconds = offset;
            if (songEndSeconds !== null && measuredDurationSeconds !== null) {
              const drift = songEndSeconds - songStartSeconds - measuredDurationSeconds;
              if (Math.abs(drift) <= SYNC_MEASUREMENT_SANITY_SECONDS) {
                syncDriftSeconds = drift;
              }
            }
          }
        }
        studio.addTake({
          id: saved.id,
          uri: saved.uri,
          createdAt: Date.now(),
          facing,
          durationSeconds,
          fileSizeBytes: saved.fileSizeBytes,
          // The take starts at the region's start in the track.
          trackOffsetSeconds: regionStartSeconds,
          ...(syncOffsetSeconds !== undefined ? { syncOffsetSeconds } : {}),
          ...(syncDriftSeconds !== undefined ? { syncDriftSeconds } : {}),
        });
        // Cache the sampled section energies for the shuffle engine.
        if (energyAccRef.current && energyAccRef.current.sampledSectionCount > 0) {
          studio.setTrackSections(energyAccRef.current.finish());
        }
        flashNotice('Take saved — find it in Takes');
      })
      .catch(() => {
        if (recordSessionRef.current !== session) return;
        if (elapsedTimerRef.current) clearInterval(elapsedTimerRef.current);
        setRecording(false);
      });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [audioOffsetMs, facing, flashNotice, player, playerStatus.duration, playCue, recording, track]);

  // Count-in (Settings → Audio): musical beats clicked/flashed at
  // 120 BPM before the take starts — a SEPARATE, optional feature from
  // the camera timer, and OFF by default so the two never stack into a
  // confusing "3-2-1 then 4-3-2-1" unless the user turns both on.
  const beginCountIn = useCallback(() => {
    if (countInBeats === 0) {
      void beginRecording();
      return;
    }
    timerWasUsedRef.current = true;
    let remaining = countInBeats;
    setCountIn(remaining);
    playCue('click');
    countInTimerRef.current = setInterval(() => {
      remaining -= 1;
      if (remaining <= 0) {
        if (countInTimerRef.current) clearInterval(countInTimerRef.current);
        setCountIn(null);
        void beginRecording();
      } else {
        setCountIn(remaining);
        playCue('click');
      }
    }, 500);
  }, [beginRecording, countInBeats, playCue]);

  // Camera timer: plain seconds to get into position (Off by default),
  // with a beep on every second shown.
  const startWithCountdown = useCallback(() => {
    if (countdown === 0) {
      beginCountIn();
      return;
    }
    timerWasUsedRef.current = true;
    void setAudioModeAsync({ playsInSilentMode: true, allowsRecording: false });
    let remaining = countdown;
    setCountingDown(remaining);
    playCue('beep');
    countdownTimerRef.current = setInterval(() => {
      remaining -= 1;
      if (remaining <= 0) {
        if (countdownTimerRef.current) clearInterval(countdownTimerRef.current);
        setCountingDown(null);
        beginCountIn();
      } else {
        setCountingDown(remaining);
        playCue('beep');
      }
    }, 1000);
  }, [beginCountIn, countdown, playCue]);

  const cancelCountdown = useCallback(() => {
    if (countdownTimerRef.current) clearInterval(countdownTimerRef.current);
    if (countInTimerRef.current) clearInterval(countInTimerRef.current);
    setCountingDown(null);
    setCountIn(null);
  }, []);

  const stopRecording = useCallback(() => {
    if (!stopRequestedRef.current) {
      stopRequestedRef.current = true;
      stopAtRef.current = Date.now();
    }
    player.pause();
    cameraRef.current?.stopRecording();
  }, [player]);

  const handleRecordPress = useCallback(() => {
    if (recording) return stopRecording();
    if (countingDown !== null || countIn !== null) return cancelCountdown();
    if (!track) {
      // No track = nothing to sync to. Send them straight to the picker.
      void handlePickTrack();
      return;
    }
    startWithCountdown();
  }, [cancelCountdown, countIn, countingDown, handlePickTrack, recording, startWithCountdown, stopRecording, track]);

  // Gesture callbacks run on user input, not during render — the ref holds
  // the zoom at pinch start. react-hooks/refs flags closures over refs in
  // the gesture definition, hence the scoped disable around this block.
  /* eslint-disable react-hooks/refs */
  const pinch = Gesture.Pinch()
    .runOnJS(true)
    .onBegin(() => {
      zoomAtPinchStartRef.current = zoom;
    })
    .onUpdate((event) => {
      // CameraView zoom is 0..1 (fraction of the device's max zoom), so a
      // pinch scales into that range gently rather than 1:1.
      setZoom(Math.min(1, Math.max(0, zoomAtPinchStartRef.current + (event.scale - 1) * 0.3)));
    });
  /* eslint-enable react-hooks/refs */

  // ---- Permissions gate (still camera-first: this IS the first screen) ----
  if (!cameraPermission || !micPermission) {
    return <View style={styles.permissionWrap} />;
  }
  if (!cameraPermission.granted || !micPermission.granted) {
    return (
      <View style={styles.permissionWrap}>
        <Ionicons name="videocam-outline" size={52} color={colors.label} />
        <Text style={styles.permissionTitle}>Camera & microphone</Text>
        <Text style={styles.permissionBody}>
          MVMT Studio records video takes while your track plays. Nothing is uploaded — takes stay on your phone.
        </Text>
        <Pressable
          style={styles.permissionButton}
          onPress={async () => {
            if (!cameraPermission.granted) await requestCameraPermission();
            if (!micPermission.granted) await requestMicPermission();
          }}>
          <Text style={styles.permissionButtonText}>Allow access</Text>
        </Pressable>
      </View>
    );
  }

  const currentZoomLabel =
    ZOOM_PRESETS.reduce((best, p) => (Math.abs(zoom - p.value) < Math.abs(zoom - best.value) ? p : best), ZOOM_PRESETS[0])
      .label;

  const regionEffForLabel = effectiveRegion(studio.trackRegion, track?.durationSeconds);

  return (
    <View style={styles.root}>
      <GestureDetector gesture={pinch}>
        <CameraView
          ref={cameraRef}
          style={StyleSheet.absoluteFill}
          facing={facing}
          enableTorch={torch}
          zoom={zoom}
          mirror={mirror}
          mode="video"
          mute={false}
          autofocus="on"
          videoQuality={resolution}
          active={isFocused && appActive}
          onMountError={(e) => flashNotice(`Camera problem: ${e.message} — tap the camera to retry`)}
        />
      </GestureDetector>

      {/* Framing guides from Settings — thirds grid and/or centre level line. */}
      {frontFlashActive ? <View style={styles.frontFlash} pointerEvents="none" /> : null}
      {gridOverlay ? (
        <View style={StyleSheet.absoluteFill} pointerEvents="none">
          <View style={[styles.gridLineV, { left: '33.33%' }]} />
          <View style={[styles.gridLineV, { left: '66.66%' }]} />
          <View style={[styles.gridLineH, { top: '33.33%' }]} />
          <View style={[styles.gridLineH, { top: '66.66%' }]} />
        </View>
      ) : null}
      {levelGuide ? (
        <View style={StyleSheet.absoluteFill} pointerEvents="none">
          <View style={styles.levelLine} />
          <View style={styles.levelDot} />
        </View>
      ) : null}

      {/* Top bar — track pill centred, Settings gear to the side. All material/blur. */}
      <View style={[styles.topBar, { top: insets.top + 52 }]}>
        <IconButton icon="settings-outline" accessibilityLabel="Settings" onPress={() => router.push('/settings')} />
        <Pressable style={styles.trackPill} onPress={() => setTrackOpen(true)} accessibilityRole="button">
          <Ionicons name={track ? 'musical-notes' : 'add'} size={16} color="#FFFFFF" />
          <Text style={styles.trackPillText} numberOfLines={1}>
            {track ? track.name : 'Add a track'}
          </Text>
          {track?.durationSeconds ? (
            <Text style={styles.trackPillDuration}>{formatTime(track.durationSeconds)}</Text>
          ) : null}
        </Pressable>
        <View style={styles.topRight}>
          <IconButton
            icon={torch ? 'flash' : 'flash-outline'}
            accessibilityLabel="Toggle torch"
            active={torch}
            onPress={() => setTorch((v) => !v)}
          />
          <IconButton
            icon="camera-reverse-outline"
            accessibilityLabel="Flip camera"
            disabled={recording}
            onPress={() => setFacing((f) => (f === 'back' ? 'front' : 'back'))}
          />
        </View>
      </View>

      {/* Countdown / recording status — centred, system style. */}
      {countingDown !== null ? (
        <View style={styles.centerOverlay} pointerEvents="none">
          <Text style={styles.countdownNumber}>{countingDown}</Text>
          <Text style={styles.countInLabel}>GET READY</Text>
        </View>
      ) : countIn !== null ? (
        <View style={styles.centerOverlay} pointerEvents="none">
          <Text style={styles.countInNumber}>{countIn}</Text>
          <Text style={styles.countInLabel}>COUNT-IN</Text>
        </View>
      ) : null}
      {recording ? (
        <View style={[styles.recordingPill, { top: insets.top + 156 }]} pointerEvents="none">
          <View style={styles.recordingDot} />
          <Text style={styles.recordingText}>
            {formatTime(elapsed)}
            {regionEffForLabel ? ` / ${formatTime(regionEffForLabel.lengthSeconds)}` : ''}
          </Text>
          {metronome ? <View style={[styles.beatDot, beatFlash && styles.beatDotOn]} /> : null}
        </View>
      ) : null}
      {notice ? (
        <View style={[styles.noticePill, { top: insets.top + 198 }]} pointerEvents="none">
          <Text style={styles.noticeText}>{notice}</Text>
        </View>
      ) : null}

      {/* Bottom control bar — takes review | record | shuffle (next stages).
          Both side actions follow the flow and are gated on having a take. */}
      <View style={[styles.bottomBar, { paddingBottom: Math.max(insets.bottom, spacing.md) }]}>
        <View style={styles.sideButtonSpacer} />
        <RecordButton recording={recording} onPress={handleRecordPress} />
        <Pressable
          style={styles.sideButton}
          onPress={goForward}
          accessibilityRole="button"
          accessibilityLabel="Next, open the editor">
          <Ionicons name="arrow-forward-circle-outline" size={26} color="#FFFFFF" />
          <Text style={styles.sideButtonLabel}>Next</Text>
        </Pressable>
      </View>

      {/* Takes rail — takes stack up on the LEFT as they're recorded,
          each with a real preview frame (this replaces the separate
          Takes screen). Tap a tile for the preview card. */}
      {takes.length > 0 ? (
        <ScrollView
          style={[styles.takeRail, { top: insets.top + 118, bottom: insets.bottom + 208 }]}
          contentContainerStyle={styles.takeRailContent}
          showsVerticalScrollIndicator={false}>
          {takes.map((take) => {
            const thumb = getCachedThumbnail(take.uri, railSampleSeconds(take));
            const inCut = edlTakeIds.has(take.id);
            return (
              <Pressable
                key={take.id}
                style={styles.railTile}
                onPress={() => openRailPreview(take)}
                accessibilityRole="button"
                accessibilityLabel={`Preview take ${take.seq ?? ''}${inCut ? ', used in your cut' : ''}`}>
                {thumb ? (
                  <Image source={thumb} style={styles.railThumb} contentFit="cover" />
                ) : (
                  <View style={[styles.railThumb, styles.railThumbPlaceholder]}>
                    <Ionicons name="film-outline" size={16} color={colors.labelSecondary} />
                  </View>
                )}
                <View style={styles.railBadge}>
                  <Text style={styles.railBadgeText}>{take.seq ?? ''}</Text>
                </View>
                {inCut ? <View style={styles.railInCutDot} /> : null}
                <Text style={styles.railDuration}>{take.durationSeconds ? formatTime(take.durationSeconds) : '…'}</Text>
              </Pressable>
            );
          })}
        </ScrollView>
      ) : null}

      {/* Take preview card — the rail tile's detail view: native
          preview, sync in words, rename / delete. */}
      {railPreviewTake ? (
        <View style={styles.railPreviewBackdrop}>
          <Pressable
            style={StyleSheet.absoluteFill}
            onPress={() => setRailPreviewId(null)}
            accessibilityRole="button"
            accessibilityLabel="Close take preview"
          />
          <View style={styles.railPreviewCard}>
            {railPreviewTake.durationSeconds ? (
              <NativePreview
                request={{
                  clips: [
                    {
                      uri: railPreviewTake.uri,
                      startSeconds: 0,
                      durationSeconds: railPreviewTake.durationSeconds,
                      muted: true,
                      volume: 1,
                    },
                  ],
                  audioUri: null,
                }}
                requestKey={railPreviewTake.id}
                paused={railPaused}
                style={styles.railPreviewVideo}
              />
            ) : (
              <View style={[styles.railPreviewVideo, styles.railPreviewUnavailable]}>
                <Text style={styles.railPreviewUnavailableText}>
                  Preview unavailable until this take&apos;s length is known.
                </Text>
              </View>
            )}
            <View style={styles.railPreviewMeta}>
              <Text style={styles.railPreviewName} numberOfLines={1}>
                {railPreviewTake.displayName?.trim() || `Take ${railPreviewTake.seq ?? ''}`}
              </Text>
              <Text style={styles.railPreviewSub}>
                {formatTime(railPreviewTake.durationSeconds ?? 0)} ·{' '}
                {railPreviewTake.facing === 'front' ? 'Front' : 'Back'} camera · {syncStatusText(railPreviewTake)}
              </Text>
            </View>
            <View style={styles.railPreviewActions}>
              <Pressable
                style={styles.railActionButton}
                onPress={() => setRailPaused((v) => !v)}
                accessibilityRole="button"
                accessibilityLabel={railPaused ? 'Play take' : 'Pause take'}>
                <Ionicons name={railPaused ? 'play' : 'pause'} size={17} color={colors.label} />
              </Pressable>
              <Pressable
                style={styles.railActionButton}
                onPress={() => renameRailTake(railPreviewTake)}
                accessibilityRole="button"
                accessibilityLabel="Rename take">
                <Ionicons name="pencil-outline" size={17} color={colors.label} />
                <Text style={styles.railActionText}>Rename</Text>
              </Pressable>
              <Pressable
                style={styles.railActionButton}
                onPress={() => deleteRailTake(railPreviewTake)}
                accessibilityRole="button"
                accessibilityLabel="Delete take">
                <Ionicons name="trash-outline" size={17} color={colors.danger} />
                <Text style={[styles.railActionText, { color: colors.danger }]}>Delete</Text>
              </Pressable>
              <Pressable
                style={styles.railActionButton}
                onPress={() => setRailPreviewId(null)}
                accessibilityRole="button"
                accessibilityLabel="Close preview">
                <Ionicons name="close" size={17} color={colors.label} />
              </Pressable>
            </View>
          </View>
        </View>
      ) : null}

      {/* Video length — where the zoom buttons used to sit (Jaizon):
          the bottom-centre row now picks how long each take records
          (the length of the song part). Same value as the track sheet's
          part picker; Full = the whole track. Hidden without a track. */}
      {!recording && track ? (
        <View style={[styles.lengthRow, { bottom: insets.bottom + 108 }]}>
          {LENGTH_PRESETS.map((preset) => {
            const tooLong = preset.seconds !== null && track.durationSeconds !== undefined && preset.seconds > track.durationSeconds;
            const selected =
              preset.seconds === null
                ? studio.trackRegion.durationSeconds === null
                : regionEffForLabel !== null && Math.abs(regionEffForLabel.lengthSeconds - preset.seconds) < 0.6;
            return (
              <Pressable
                key={preset.label}
                disabled={tooLong}
                onPress={() => {
                  const duration = track.durationSeconds ?? 0;
                  if (preset.seconds === null || duration <= 0) {
                    studio.setTrackRegion({ startSeconds: 0, durationSeconds: null });
                    flashNotice('Video length: full track');
                    return;
                  }
                  const length = Math.min(preset.seconds, duration);
                  const start = Math.min(studio.trackRegion.startSeconds, Math.max(0, duration - length));
                  studio.setTrackRegion({ startSeconds: start, durationSeconds: length });
                  flashNotice(`Video length: ${preset.label} — takes stop right there`);
                }}
                style={[styles.zoomPill, selected && styles.zoomPillSelected, tooLong && styles.lengthPillDisabled]}
                accessibilityRole="button"
                accessibilityState={{ selected, disabled: tooLong }}
                accessibilityLabel={`Video length ${preset.label}${tooLong ? ', longer than the track' : ''}`}>
                <Text style={[styles.zoomText, selected && styles.zoomTextSelected]}>{preset.label}</Text>
              </Pressable>
            );
          })}
        </View>
      ) : null}

      {/* RIGHT-SIDE control column (Jaizon, 2026-11-08): zoom and the
          timers live together on the right, each a single collapsible
          pill. Timer + Count-in used to be two always-visible chips on
          the left; now they're ONE pill — tap it and a small panel
          opens with both controls (Timer = seconds to get into
          position, Count-in = musical beats; both default OFF).
          Opening one pill closes the other. Pinch-to-zoom still works. */}
      {!recording ? (
        <View style={styles.sideRight}>
          <View style={styles.sideGroup}>
            {zoomOpen
              ? ZOOM_PRESETS.map((preset) => {
                  const selected = Math.abs(zoom - preset.value) < 0.03;
                  return (
                    <Pressable
                      key={preset.label}
                      onPress={() => {
                        setZoom(preset.value);
                        setZoomOpen(false);
                      }}
                      style={[styles.sideZoomOption, selected && styles.zoomPillSelected]}
                      accessibilityRole="button"
                      accessibilityState={{ selected }}
                      accessibilityLabel={`Zoom ${preset.label}`}>
                      <Text style={[styles.zoomText, selected && styles.zoomTextSelected]}>{preset.label}</Text>
                    </Pressable>
                  );
                })
              : null}
            <Pressable
              onPress={() => {
                setZoomOpen((v) => !v);
                setTimersOpen(false);
              }}
              style={[styles.sideZoomMain, zoomOpen && styles.zoomPillSelected]}
              accessibilityRole="button"
              accessibilityState={{ expanded: zoomOpen }}
              accessibilityLabel={zoomOpen ? 'Close zoom options' : `Zoom, currently ${currentZoomLabel}. Tap for zoom options.`}>
              <Text style={[styles.zoomText, zoomOpen && styles.zoomTextSelected]}>{currentZoomLabel}</Text>
              <Ionicons name={zoomOpen ? 'chevron-up' : 'chevron-down'} size={11} color={zoomOpen ? '#14141F' : '#FFFFFF'} />
            </Pressable>
          </View>

          {countingDown === null && countIn === null ? (
            <View style={styles.sideGroup}>
              {timersOpen ? (
                <View style={styles.timerPanel}>
                  <Text style={styles.timerRowLabel}>Timer</Text>
                  <View style={styles.timerChipRow}>
                    {([0, 3, 5, 10] as const).map((value) => (
                      <Pressable
                        key={`timer-${value}`}
                        onPress={() => {
                          setCountdown(value);
                          flashNotice(value === 0 ? 'Timer off — record starts straight away' : `Timer ${value}s — beeps each second`);
                        }}
                        style={[styles.miniChip, countdown === value && styles.miniChipSelected]}
                        accessibilityRole="button"
                        accessibilityState={{ selected: countdown === value }}
                        accessibilityLabel={`Camera timer ${value === 0 ? 'off' : `${value} seconds`}`}>
                        <Text style={[styles.miniChipText, countdown === value && styles.miniChipTextSelected]}>
                          {value === 0 ? 'Off' : `${value}s`}
                        </Text>
                      </Pressable>
                    ))}
                  </View>
                  <Text style={styles.timerRowLabel}>Count-in</Text>
                  <View style={styles.timerChipRow}>
                    {([0, 4, 8] as const).map((value) => (
                      <Pressable
                        key={`countin-${value}`}
                        onPress={() => {
                          setCountInBeats(value);
                          flashNotice(value === 0 ? 'Count-in off' : `Count-in ${value} beats — clicks each beat`);
                        }}
                        style={[styles.miniChip, countInBeats === value && styles.miniChipSelected]}
                        accessibilityRole="button"
                        accessibilityState={{ selected: countInBeats === value }}
                        accessibilityLabel={`Beat count-in ${value === 0 ? 'off' : `${value} beats`}`}>
                        <Text style={[styles.miniChipText, countInBeats === value && styles.miniChipTextSelected]}>
                          {value === 0 ? 'Off' : `${value}`}
                        </Text>
                      </Pressable>
                    ))}
                  </View>
                </View>
              ) : null}
              <Pressable
                onPress={() => {
                  setTimersOpen((v) => !v);
                  setZoomOpen(false);
                }}
                style={[styles.timerChip, timersOpen && styles.zoomPillSelected]}
                accessibilityRole="button"
                accessibilityState={{ expanded: timersOpen }}
                accessibilityLabel={
                  timersOpen
                    ? 'Close timer options'
                    : `Timers, timer ${countdown === 0 ? 'off' : `${countdown} seconds`}, count-in ${countInBeats === 0 ? 'off' : `${countInBeats} beats`}. Tap for timer options.`
                }>
                <Ionicons name="timer-outline" size={17} color={timersOpen ? '#14141F' : '#FFFFFF'} />
              </Pressable>
            </View>
          ) : null}
        </View>
      ) : null}

      {/* ---- Track sheet (audio-part picker) ---- */}
      <TrackSheet
        visible={trackOpen}
        onClose={() => setTrackOpen(false)}
        onPickTrack={() => void handlePickTrack()}
      />

    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#000' },
  topBar: {
    position: 'absolute',
    left: spacing.lg,
    right: spacing.lg,
    flexDirection: 'row',
    alignItems: 'flex-start',
    justifyContent: 'space-between',
    gap: spacing.sm,
  },
  topRight: { gap: spacing.sm },
  trackPill: {
    flex: 1,
    maxWidth: 210,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    alignSelf: 'center',
    // Jaizon: the track pill gets the green (accent) background.
    backgroundColor: colors.accent,
    borderColor: 'transparent',
    borderWidth: 1,
    borderRadius: radius.pill,
    paddingHorizontal: 12,
    paddingVertical: 9,
  },
  trackPillText: { color: colors.onAccent, fontSize: 13, fontWeight: '600', flexShrink: 1 },
  trackPillDuration: { color: colors.onAccent, fontSize: 12, fontWeight: '500' },
  centerOverlay: {
    position: 'absolute',
    top: 0,
    bottom: 0,
    left: 0,
    right: 0,
    alignItems: 'center',
    justifyContent: 'center',
  },
  countdownNumber: {
    fontSize: 120,
    fontWeight: '700',
    color: colors.label,
    textShadowColor: 'rgba(0,0,0,0.5)',
    textShadowRadius: 18,
  },
  countInNumber: {
    fontSize: 84,
    fontWeight: '700',
    color: colors.accent,
    textShadowColor: 'rgba(0,0,0,0.5)',
    textShadowRadius: 18,
  },
  countInLabel: {
    fontSize: 14,
    fontWeight: '700',
    letterSpacing: 3,
    color: colors.label,
    textShadowColor: 'rgba(0,0,0,0.5)',
    textShadowRadius: 8,
  },
  frontFlash: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    backgroundColor: '#FFF6E8',
    opacity: 0.94,
  },
  gridLineV: {
    position: 'absolute',
    top: 0,
    bottom: 0,
    width: StyleSheet.hairlineWidth,
    backgroundColor: 'rgba(255,255,255,0.35)',
  },
  gridLineH: {
    position: 'absolute',
    left: 0,
    right: 0,
    height: StyleSheet.hairlineWidth,
    backgroundColor: 'rgba(255,255,255,0.35)',
  },
  levelLine: {
    position: 'absolute',
    top: '50%',
    left: '18%',
    right: '18%',
    height: StyleSheet.hairlineWidth,
    backgroundColor: 'rgba(185,167,255,0.65)',
  },
  levelDot: {
    position: 'absolute',
    top: '50%',
    left: '50%',
    width: 7,
    height: 7,
    borderRadius: 4,
    marginLeft: -3.5,
    marginTop: -3.5,
    backgroundColor: 'rgba(185,167,255,0.8)',
  },
  beatDot: { width: 8, height: 8, borderRadius: 4, backgroundColor: 'rgba(255,255,255,0.25)' },
  beatDotOn: { backgroundColor: colors.accent },
  recordingPill: {
    position: 'absolute',
    alignSelf: 'center',
    flexDirection: 'row',
    alignItems: 'center',
    gap: 7,
    backgroundColor: colors.material,
    borderRadius: radius.pill,
    paddingHorizontal: 12,
    paddingVertical: 6,
  },
  recordingDot: { width: 9, height: 9, borderRadius: 5, backgroundColor: colors.danger },
  recordingText: { color: colors.label, fontSize: 14, fontWeight: '600', fontVariant: ['tabular-nums'] },
  noticePill: {
    position: 'absolute',
    alignSelf: 'center',
    backgroundColor: colors.material,
    borderRadius: radius.pill,
    paddingHorizontal: 14,
    paddingVertical: 8,
  },
  noticeText: { color: colors.label, fontSize: 13, fontWeight: '500' },
  bottomBar: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    flexDirection: 'row',
    alignItems: 'flex-end',
    justifyContent: 'space-between',
    paddingHorizontal: spacing.xxl,
  },
  timerChip: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    backgroundColor: colors.material,
    borderColor: colors.materialBorder,
    borderWidth: 1,
    borderRadius: radius.pill,
    paddingHorizontal: 13,
    paddingVertical: 8,
  },
  timerChipText: { color: colors.label, fontSize: 13, fontWeight: '700' },
  sideButtonSpacer: { width: 64 },
  takeRail: { position: 'absolute', left: spacing.md, width: 60 },
  takeRailContent: { gap: spacing.md, alignItems: 'center', paddingVertical: spacing.xs },
  railTile: { width: 60, alignItems: 'center' },
  railThumb: { width: 56, height: 74, borderRadius: radius.sm, backgroundColor: colors.card },
  railThumbPlaceholder: { alignItems: 'center', justifyContent: 'center', backgroundColor: colors.elevated },
  railBadge: {
    position: 'absolute',
    top: 4,
    left: 6,
    minWidth: 18,
    height: 18,
    borderRadius: 9,
    backgroundColor: colors.material,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 4,
  },
  railBadgeText: { ...typeScale.caption, color: colors.label, fontWeight: '700', fontVariant: ['tabular-nums'] },
  railInCutDot: {
    position: 'absolute',
    top: 5,
    right: 7,
    width: 9,
    height: 9,
    borderRadius: 5,
    backgroundColor: colors.accent,
  },
  railDuration: { ...typeScale.caption, color: colors.label, marginTop: 3, fontVariant: ['tabular-nums'] },
  railPreviewBackdrop: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    backgroundColor: 'rgba(0,0,0,0.55)',
    alignItems: 'center',
    justifyContent: 'center',
    padding: spacing.xl,
    zIndex: 40,
  },
  railPreviewCard: {
    width: '100%',
    maxWidth: 340,
    backgroundColor: colors.card,
    borderRadius: radius.lg,
    padding: spacing.md,
    gap: spacing.md,
  },
  railPreviewVideo: { width: '100%', aspectRatio: 9 / 16, maxHeight: 360, borderRadius: radius.md },
  railPreviewUnavailable: {
    backgroundColor: colors.elevated,
    alignItems: 'center',
    justifyContent: 'center',
    padding: spacing.lg,
  },
  railPreviewUnavailableText: { ...typeScale.footnote, color: colors.labelSecondary, textAlign: 'center' },
  railPreviewMeta: { gap: 2 },
  railPreviewName: { ...typeScale.headline, color: colors.label },
  railPreviewSub: { ...typeScale.footnote, color: colors.labelSecondary },
  railPreviewActions: { flexDirection: 'row', gap: spacing.sm },
  railActionButton: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 5,
    backgroundColor: colors.elevated,
    borderRadius: radius.pill,
    paddingHorizontal: spacing.md,
    height: 38,
  },
  railActionText: { ...typeScale.subhead, color: colors.label, fontWeight: '600' },
  sideButton: {
    alignItems: 'center',
    gap: 3,
    width: 64,
    paddingBottom: 8,
    paddingTop: 8,
    borderRadius: radius.lg,
    backgroundColor: colors.material,
    borderWidth: 1,
    borderColor: colors.materialBorder,
  },
  sideButtonLabel: {
    color: colors.label,
    fontSize: 11,
    fontWeight: '500',
    textShadowColor: 'rgba(0,0,0,0.5)',
    textShadowRadius: 4,
  },
  sideRight: {
    position: 'absolute',
    right: spacing.md,
    top: '36%',
    alignItems: 'flex-end',
    gap: spacing.md,
  },
  sideGroup: { alignItems: 'center', gap: 6 },
  timerPanel: {
    backgroundColor: colors.material,
    borderColor: colors.materialBorder,
    borderWidth: 1,
    borderRadius: radius.lg,
    padding: spacing.md,
    gap: 6,
    width: 178,
  },
  timerRowLabel: { color: colors.labelSecondary, fontSize: 11, fontWeight: '700', letterSpacing: 0.6 },
  timerChipRow: { flexDirection: 'row', gap: 5, marginBottom: 4 },
  miniChip: {
    backgroundColor: 'rgba(255,255,255,0.10)',
    borderRadius: radius.pill,
    paddingHorizontal: 9,
    paddingVertical: 6,
    minWidth: 34,
    alignItems: 'center',
  },
  miniChipSelected: { backgroundColor: 'rgba(255,255,255,0.92)' },
  miniChipText: { color: colors.label, fontSize: 12, fontWeight: '700' },
  miniChipTextSelected: { color: '#14141F' },
  sideZoomMain: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 3,
    backgroundColor: colors.material,
    borderColor: colors.materialBorder,
    borderWidth: 1,
    borderRadius: radius.pill,
    paddingHorizontal: 11,
    paddingVertical: 8,
  },
  sideZoomOption: {
    backgroundColor: colors.material,
    borderColor: colors.materialBorder,
    borderWidth: 1,
    borderRadius: radius.pill,
    paddingHorizontal: 11,
    paddingVertical: 8,
    minWidth: 46,
    alignItems: 'center',
  },
  lengthRow: {
    position: 'absolute',
    alignSelf: 'center',
    flexDirection: 'row',
    gap: 6,
    backgroundColor: colors.material,
    borderRadius: radius.pill,
    padding: 4,
  },
  lengthPillDisabled: { opacity: 0.35 },
  zoomPill: {
    minWidth: 38,
    height: 30,
    borderRadius: radius.pill,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 8,
  },
  zoomPillSelected: { backgroundColor: 'rgba(255,255,255,0.92)' },
  zoomText: { color: colors.label, fontSize: 12, fontWeight: '600' },
  zoomTextSelected: { color: '#14141F' },
  permissionWrap: {
    flex: 1,
    backgroundColor: colors.base,
    alignItems: 'center',
    justifyContent: 'center',
    padding: spacing.xxl,
    gap: spacing.md,
  },
  permissionTitle: { ...typeScale.title2, color: colors.label, textAlign: 'center' },
  permissionBody: { ...typeScale.subhead, color: colors.labelSecondary, textAlign: 'center', lineHeight: 21 },
  permissionButton: {
    marginTop: spacing.md,
    backgroundColor: '#FFFFFF',
    borderRadius: radius.pill,
    paddingHorizontal: 22,
    paddingVertical: 12,
  },
  permissionButtonText: { color: '#14141F', fontSize: 16, fontWeight: '600' },
  emptyText: { ...typeScale.subhead, color: colors.labelSecondary, lineHeight: 21, paddingVertical: spacing.md },
  takeRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    paddingVertical: spacing.md,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.separator,
  },
  takeTitle: { ...typeScale.headline, color: colors.label },
  takeSubtitle: { ...typeScale.footnote, color: colors.labelSecondary, marginTop: 1 },
  sheetPrimaryButton: {
    marginTop: spacing.lg,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
    backgroundColor: '#FFFFFF',
    borderRadius: radius.md,
    paddingVertical: 13,
  },
  sheetPrimaryButtonText: { color: '#14141F', fontSize: 15, fontWeight: '600' },
});
