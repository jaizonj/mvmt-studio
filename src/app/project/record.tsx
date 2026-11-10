import { Ionicons } from '@expo/vector-icons';
import { setAudioModeAsync, useAudioPlayer, useAudioPlayerStatus } from 'expo-audio';
import { activateKeepAwakeAsync, deactivateKeepAwake } from 'expo-keep-awake';
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
import {
  CapturePreview,
  isCaptureAvailable,
  isCompositorAvailable,
  measureTakeSync,
  prepareSong,
  setCaptureQuality,
  startCapture,
  stopCapture,
  type CompositeRequest,
  type TakeSyncMeasurement,
} from '../../lib/compositor';
import {
  DEFAULT_FPS,
  edlToCompositeRequest,
  emptyEdl,
  secondsToFrames,
  sourceFrameForTimelineFrame,
  takeSyncOffsetSeconds,
  type Edl,
} from '../../lib/edl';
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
 * What the native capture module hands back when a take stops — the
 * recorded file plus its MEASURED facts. Derived from the contract
 * function's own return type so this screen tracks the module's
 * index.ts exactly.
 */
type StopCaptureResult = Awaited<ReturnType<typeof stopCapture>>;

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
 * Sync status in human words, PROVENANCE-AWARE (2026-11-09). The base
 * wording still comes from the take's sync offset — ~1 frame at 30 fps
 * (0.04s) is plainly in sync, up to 0.10s is a slight offset, beyond
 * that, check before export — but where the number came from is part
 * of the label: a file-correlated measurement says so ("measured from
 * file"), while a player-sampled (or legacy, provenance-less) figure
 * is honestly labelled an estimate. A manual frame calibration
 * appends "· adjusted ±Nf" (sign as stored). No raw second values are
 * ever shown.
 */
function syncStatusText(take: Take): string {
  const adjust = take.syncAdjustFrames ?? 0;
  const adjustSuffix = adjust !== 0 ? ` · adjusted ${adjust > 0 ? '+' : '−'}${Math.abs(adjust)}f` : '';
  const offset = take.syncOffsetSeconds;
  if (offset === undefined) return `Sync unmeasured${adjustSuffix}`;
  const provenance =
    take.syncSource === 'fileCorrelation'
      ? ' · measured from file'
      : take.syncSource === 'nativeCapture'
        ? ' · measured at capture'
        : ' · sync estimated';
  const magnitude = Math.abs(offset);
  if (magnitude <= 0.04) return `In sync${provenance}${adjustSuffix}`;
  if (magnitude <= 0.1) return `In sync · slight offset${provenance}${adjustSuffix}`;
  return `Off sync${provenance} — check before export${adjustSuffix}`;
}

/**
 * Song-referenced calibration preview for one take: a synthetic
 * one-segment EDL converted with the SAME edlToCompositeRequest the
 * Editor uses, so the rail card plays the take against the master
 * song exactly as a cut at the take's region start would (master song
 * only — the take's own audio stays muted, per the EDL audio policy).
 * The segment's source start comes from the ONE shared offset
 * (takeSyncOffsetSeconds: measured offset + manual frame
 * calibration), so a nudge here previews identically to the real
 * edit. The requestKey carries every sync input, so a nudge — or a
 * fresh file measurement landing — rebuilds the preview.
 */
function calibrationPreviewFor(take: Take, songUri: string): { request: CompositeRequest; requestKey: string } {
  const fps = DEFAULT_FPS;
  const durationFrames = secondsToFrames(take.durationSeconds ?? 0, fps);
  const sourceStartFrame = Math.max(
    0,
    sourceFrameForTimelineFrame(0, takeSyncOffsetSeconds(take, take.trackOffsetSeconds, fps), fps),
  );
  const edl: Edl = {
    ...emptyEdl(fps),
    segments: [
      {
        id: `sync-preview-${take.id}`,
        takeId: take.id,
        timelineStartFrame: 0,
        sourceStartFrame,
        durationFrames,
      },
    ],
    totalFrames: durationFrames,
    audio: { uri: songUri, regionStartFrame: secondsToFrames(take.trackOffsetSeconds, fps), volume: 1 },
  };
  const request = edlToCompositeRequest(edl, (id) => (id === take.id ? take.uri : undefined));
  const requestKey = [
    'sync-preview',
    take.id,
    take.syncAdjustFrames ?? 0,
    take.syncOffsetSeconds ?? 'unmeasured',
    take.syncSource ?? 'legacy',
    songUri,
  ].join('|');
  return { request, requestKey };
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
    captureQuality,
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
  // The takes rail starts COLLAPSED (Jaizon, 2026-11-09) — a slim
  // pull-tab on the left edge; tap to expand, chevron to collapse.
  const [railOpen, setRailOpen] = useState(false);
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

  // No track display on the camera (Jaizon, 2026-11-09): with no
  // track set, entering Record opens the song/part picker ONCE —
  // pick the song and the part, then the camera just knows. The
  // musical-notes button in the top bar reopens it any time.
  const autoOpenedTrackRef = useRef(false);
  useEffect(() => {
    if (!studio.hydrated || !isFocused || track || autoOpenedTrackRef.current) return;
    autoOpenedTrackRef.current = true;
    setTrackOpen(true);
  }, [studio.hydrated, isFocused, track]);

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

  // NATIVE CAPTURE availability: when the compositor module's
  // capture engine is linked, it owns the preview AND the recording
  // (AVCaptureSession + the song player on one host clock, reporting
  // the song position at the first real frame). When it isn't (Expo
  // Go), the expo-camera path below runs exactly as before.
  const useNativeCapture = isCaptureAvailable();
  // Pre-warm the native song player while this screen is up: the
  // module builds a standing, pre-loaded player for the current
  // track so pressing record adopts it instead of paying the cold
  // load inside the take (Jaizon: the first takes of a session
  // lagged and messed up until the app "caught up"). No-op on the
  // expo-camera path and in Expo Go.
  useEffect(() => {
    if (!isFocused || !useNativeCapture) return;
    void prepareSong(track?.uri ?? null);
  }, [isFocused, track?.uri, useNativeCapture]);

  // Capture quality (Settings): keep the module's session
  // configuration in step with the preference. Best-effort like
  // prepareSong — a no-op in Expo Go / on the expo-camera path.
  useEffect(() => {
    if (!isFocused || !useNativeCapture) return;
    void setCaptureQuality(captureQuality);
  }, [isFocused, captureQuality, useNativeCapture]);

  // Keep the screen awake through the whole capture flow (Jaizon:
  // "it falls asleep while recording") — from the countdown through
  // the take. Released the moment neither is active, and on unmount.
  useEffect(() => {
    if (recording || countingDown !== null) {
      void activateKeepAwakeAsync('mvmt-record');
    } else {
      void deactivateKeepAwake('mvmt-record');
    }
  }, [recording, countingDown]);
  useEffect(
    () => () => {
      void deactivateKeepAwake('mvmt-record');
    },
    [],
  );


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
  /**
   * Landing context for the CURRENT recording session: the region
   * start / length are locals of beginRecording, but the take lands
   * asynchronously and its stop can be triggered from outside that
   * closure (the record button) — so the values the shared landing
   * pipeline needs ride here, along with which capture path the
   * session is on.
   */
  const recordContextRef = useRef<{
    session: number;
    regionStartSeconds: number;
    lengthSeconds: number | null;
    native: boolean;
  } | null>(null);
  /**
   * Sessions for which stopCapture has already been invoked — the
   * deadline and a manual tap can race, and the module must be
   * stopped exactly once per take.
   */
  const nativeStopSessionRef = useRef(0);

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

  // Latest takes, mirrored into a ref for async sync work: a file
  // measurement that resolves after the user deleted the take or
  // switched projects must not patch anything (updateTake would
  // no-op on a missing id anyway — this makes the intent explicit
  // and avoids even the state write).
  const liveTakesRef = useRef(takes);
  useEffect(() => {
    liveTakesRef.current = takes;
  }, [takes]);

  /**
   * FILE-BASED SYNC REFINEMENT — after a take exists, ask the native
   * engine to measure its TRUE capture offset from the recorded file
   * itself (correlation of the song bleed in the take's mic audio
   * against the master song). Fire-and-forget: it NEVER blocks or
   * fails a save, and any outcome other than a confident 'measured'
   * leaves the take exactly as it is.
   *
   * The expected position is ACOUSTIC — where the song should be at
   * the take's start if the stored offset is right. The stored JS
   * offset had the Settings audio correction (audioOffsetMs)
   * SUBTRACTED out at record time; correlation hears the song as
   * actually emitted, so the expectation adds it back. Symmetrically,
   * the measured result is stored with NO audioOffset subtraction:
   * the file's timeline already embodies the acoustic path.
   */
  const refineTakeSyncFromFile = useCallback(
    async (candidate: {
      id: string;
      uri: string;
      trackOffsetSeconds: number;
      syncOffsetSeconds?: number;
      syncSource?: Take['syncSource'];
    }) => {
      // PRECEDENCE: a 'nativeCapture' measurement is authoritative —
      // the module owned both clocks at record time — so correlation
      // must NEVER overwrite it. This one guard covers both callers
      // (the take-landing refinement and the legacy upgrade pass).
      if (candidate.syncSource === 'nativeCapture') return;
      if (!track || !isCompositorAvailable()) return;
      let result: TakeSyncMeasurement;
      try {
        result = await measureTakeSync(
          candidate.uri,
          track.uri,
          candidate.trackOffsetSeconds + (candidate.syncOffsetSeconds ?? 0) + audioOffsetMs / 1000,
          2,
        );
      } catch {
        // Module unlinked in this build — same as status 'error':
        // keep the player-sample estimate.
        return;
      }
      if (result.status !== 'measured' || result.songPositionAtFirstFrameSeconds === null) return;
      // Gone meanwhile (deleted, or the user switched projects)?
      if (!liveTakesRef.current.some((t) => t.id === candidate.id)) return;
      studio.updateTake(candidate.id, {
        // The correlated position is absolute in the track; the stored
        // offset is relative to the take's region start — the same
        // definition the player-sample path stores (positive = capture
        // started late), on the acoustic timeline (see above).
        syncOffsetSeconds: result.songPositionAtFirstFrameSeconds - candidate.trackOffsetSeconds,
        syncSource: 'fileCorrelation',
        ...(result.confidence !== null ? { syncConfidence: result.confidence } : {}),
      });
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [audioOffsetMs, track],
  );

  // LEGACY SYNC UPGRADE — takes recorded before file-based
  // measurement existed carry player-sample estimates (or nothing)
  // and no syncSource. Once per project per mount, on focus, quietly
  // run the same file measurement over them — SEQUENTIALLY (the
  // correlation is real native work; never fan it out) and silently
  // (no notices, no UI). Idempotent via syncSource: once a take is
  // file-measured it is never a candidate again. Bails the moment
  // focus is lost.
  const syncUpgradedProjectRef = useRef<string | null>(null);
  useFocusEffect(
    useCallback(() => {
      if (!track || !isCompositorAvailable()) return;
      if (takes.length === 0) return; // Store still hydrating — retry on a later focus.
      const projectKey = studio.activeProjectId ?? 'no-active-project';
      if (syncUpgradedProjectRef.current === projectKey) return;
      syncUpgradedProjectRef.current = projectKey;
      const candidates = takes.filter((t) => t.syncSource === undefined);
      if (candidates.length === 0) return;
      let alive = true;
      void (async () => {
        for (const candidate of candidates) {
          if (!alive) return;
          await refineTakeSyncFromFile(candidate);
        }
      })();
      return () => {
        alive = false;
      };
      // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [refineTakeSyncFromFile, takes, track]),
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
  // (no separate Takes screen). Next ALWAYS goes to the Editor — the
  // shuffle screen — never straight to Export, even when a cut already
  // exists: landing on the cut first is how you re-shuffle or edit it
  // (Jaizon, 2026-11-09). Gated on the first take.
  const goForward = useCallback(() => {
    if (takes.length === 0) return flashNotice('Record a take first');
    router.push('/project/editor');
  }, [flashNotice, takes.length]);

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

  /**
   * THE take-landing pipeline — shared by BOTH capture paths, so a
   * take is measured, persisted and stored identically whichever
   * camera produced it. The session guard freezes duration at STOP
   * time, the persisted file's MEASURED duration replaces the
   * wall-clock value, and the sync fields follow the path's
   * measurement (see the sync branches below).
   */
  const landRecordedTake = useCallback(
    async (args: {
      session: number;
      /** The recorded file as the camera wrote it (cache URI); undefined = the recording failed. */
      rawUri: string | undefined;
      regionStartSeconds: number;
      lengthSeconds: number | null;
      /** JS player samples — expo-camera path only; null on the native path. */
      songStartSeconds: number | null;
      songEndSeconds: number | null;
      /** Native-capture first-frame measurement — null on the expo path. */
      nativeFirstFrameSongPositionSeconds: number | null;
      /** stopCapture's file-measured duration — null on the expo path (measured via probe instead). */
      nativeMeasuredDurationSeconds: number | null;
      /** stopCapture's file-measured frame size — null on the expo path. */
      nativeWidth: number | null;
      nativeHeight: number | null;
    }) => {
      const { session } = args;
      const mine = recordSessionRef.current === session;
      if (mine && elapsedTimerRef.current) clearInterval(elapsedTimerRef.current);
      if (mine) setRecording(false);
      player.pause();
      if (recordContextRef.current?.session === session) recordContextRef.current = null;
      if (!args.rawUri) return;
      // Duration = stop time minus start time (both frozen above),
      // never the promise-resolution time. Then prefer the FILE's own
      // MEASURED duration when it can be read — stopCapture's value
      // on the native path, else native inspectAsset / the JS probe
      // (see measureTakeDurationSeconds) — it's the ground truth for
      // what actually got recorded, and it replaces the wall-clock
      // value.
      const stopAt = stopAtRef.current ?? Date.now();
      let durationSeconds = Math.max(0.1, (stopAt - recordStartRef.current) / 1000);
      if (args.lengthSeconds !== null) durationSeconds = Math.min(durationSeconds, args.lengthSeconds);
      const saved = await persistTake(args.rawUri);
      let measuredDurationSeconds = args.nativeMeasuredDurationSeconds;
      if (measuredDurationSeconds === null) {
        measuredDurationSeconds = await measureTakeDurationSeconds(saved.uri);
      }
      if (measuredDurationSeconds !== null) {
        durationSeconds =
          args.lengthSeconds !== null ? Math.min(measuredDurationSeconds, args.lengthSeconds) : measuredDurationSeconds;
      }
      // MEASURED SYNC fields — the session's samples arrive as args,
      // so a late-finishing take can only ever attach its OWN
      // measurements to its OWN Take. Either figure outside the
      // sanity bound means the measurement was untrustworthy — the
      // field is then left undefined (honestly unmeasured) rather
      // than stored.
      let syncOffsetSeconds: number | undefined;
      let syncDriftSeconds: number | undefined;
      let syncSource: Take['syncSource'];
      if (args.nativeFirstFrameSongPositionSeconds !== null) {
        // NATIVE CAPTURE — the module owned the camera AND the song
        // player on ONE host clock, so this is the item-clock song
        // position at the first REAL frame: the value the JS sample
        // below can only estimate (its spin-up error is exactly what
        // this path eliminates). Stored under the SAME definition as
        // the player-sample path —
        //
        //   syncOffsetSeconds = songPositionAtFirstFrame
        //                       − audioOffset − regionStart
        //
        // (the Settings audio correction was added to the position
        // startCapture was given, so it comes back out here) — so
        // takeSyncOffsetSeconds consumes both paths identically.
        const offset = args.nativeFirstFrameSongPositionSeconds - audioOffsetMs / 1000 - args.regionStartSeconds;
        if (Math.abs(offset) <= SYNC_MEASUREMENT_SANITY_SECONDS) {
          syncOffsetSeconds = offset;
          syncSource = 'nativeCapture';
        }
        // No drift figure on this path: drift exists to cross-check
        // TWO independent clocks (JS player vs camera) against each
        // other. The module runs one clock, so the number would be
        // meaningless — and drift is diagnostic-only everywhere.
      } else if (args.songStartSeconds !== null) {
        // PLAYER-SAMPLE path (expo-camera) —
        //
        //   syncOffsetSeconds = songStart − regionStart − audioOffset
        //
        // The seek targeted regionStart + audioOffsetMs/1000 (the
        // Settings Bluetooth/output-latency correction, applied
        // there on purpose) — subtracting that same correction here
        // leaves only the UNINTENDED capture error, matching the EDL
        // bridge's definition: positive = capture started late, so
        // the footage for a timeline frame lives earlier inside the
        // file.
        //
        //   syncDriftSeconds = (songEnd − songStart) − measuredDuration
        //
        // using the file's RAW measured duration (not the length-
        // clamped value stored as durationSeconds): how much the
        // song clock and the camera clock disagreed over this take.
        syncSource = 'playerSample';
        const offset = args.songStartSeconds - audioOffsetMs / 1000 - args.regionStartSeconds;
        if (Math.abs(offset) <= SYNC_MEASUREMENT_SANITY_SECONDS) {
          syncOffsetSeconds = offset;
          if (args.songEndSeconds !== null && measuredDurationSeconds !== null) {
            const drift = args.songEndSeconds - args.songStartSeconds - measuredDurationSeconds;
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
        trackOffsetSeconds: args.regionStartSeconds,
        ...(syncOffsetSeconds !== undefined ? { syncOffsetSeconds } : {}),
        ...(syncDriftSeconds !== undefined ? { syncDriftSeconds } : {}),
        // Provenance for the offset above: 'nativeCapture' (module
        // measured it at record time), 'playerSample' (the JS
        // estimate, until the file-based refinement replaces it with
        // 'fileCorrelation'), or absent when nothing was measurable.
        ...(syncSource !== undefined ? { syncSource } : {}),
        ...(args.nativeWidth !== null && args.nativeHeight !== null
          ? { width: args.nativeWidth, height: args.nativeHeight }
          : {}),
      });
      // FILE-BASED SYNC REFINEMENT — fire-and-forget (see
      // refineTakeSyncFromFile): re-measure this take's capture
      // offset from the recorded file itself and upgrade the
      // estimate in place when the correlation is confident. It can
      // NEVER touch a 'nativeCapture' take (guarded inside the
      // refinement) — correlation is the fallback for expo-path and
      // legacy takes only. Runs whether or not the JS sample
      // survived the sanity bound — the expectation just falls back
      // to the region start.
      void refineTakeSyncFromFile({
        id: saved.id,
        uri: saved.uri,
        trackOffsetSeconds: args.regionStartSeconds,
        ...(syncOffsetSeconds !== undefined ? { syncOffsetSeconds } : {}),
        ...(syncSource !== undefined ? { syncSource } : {}),
      });
      // Cache the sampled section energies for the shuffle engine.
      // (Native-path takes contribute none — the JS player never
      // played — so previously cached sections simply stay.)
      if (energyAccRef.current && energyAccRef.current.sampledSectionCount > 0) {
        studio.setTrackSections(energyAccRef.current.finish());
      }
      flashNotice('Take saved — find it in Takes');
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [audioOffsetMs, facing, flashNotice, player, refineTakeSyncFromFile],
  );

  /**
   * Stop the native capture for `session` and land the take via the
   * shared pipeline. Invoked by BOTH the deadline interval and the
   * record button — the once-per-session guard makes their race
   * harmless (the module must be stopped exactly once per take). A
   * failed stopCapture mirrors recordAsync's rejection: the session
   * state is torn down and no take is saved.
   */
  const stopNativeTake = useCallback(
    (session: number) => {
      if (nativeStopSessionRef.current === session) return;
      nativeStopSessionRef.current = session;
      void (async () => {
        let result: StopCaptureResult | null = null;
        try {
          result = await stopCapture();
        } catch {
          result = null;
        }
        const ctx = recordContextRef.current;
        if (!result?.uri || !ctx || ctx.session !== session) {
          if (recordSessionRef.current === session) {
            if (elapsedTimerRef.current) clearInterval(elapsedTimerRef.current);
            setRecording(false);
          }
          if (recordContextRef.current?.session === session) recordContextRef.current = null;
          return;
        }
        await landRecordedTake({
          session,
          rawUri: result.uri,
          regionStartSeconds: ctx.regionStartSeconds,
          lengthSeconds: ctx.lengthSeconds,
          songStartSeconds: null,
          songEndSeconds: null,
          nativeFirstFrameSongPositionSeconds: result.firstFrameSongPositionSeconds,
          nativeMeasuredDurationSeconds: result.durationSeconds > 0 ? result.durationSeconds : null,
          nativeWidth: result.width > 0 ? result.width : null,
          nativeHeight: result.height > 0 ? result.height : null,
        });
      })();
    },
    [landRecordedTake],
  );

  const beginRecording = useCallback(async () => {
    if (!useNativeCapture && !cameraRef.current) return;
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
    if (useNativeCapture) {
      // The native module owns the song during capture — it plays the
      // track itself, on the same host clock as the camera — so the
      // JS player must stay silent: a second playback would double
      // the song and invalidate the first-frame measurement. The
      // module itself is started further below, after the shared
      // session setup, so the deadline and UI state are already live
      // if it fails.
    } else if (track) {
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
    // Landing context for this session: the region/length are locals
    // here, but the take lands asynchronously (recordAsync promise on
    // the expo path, stopCapture on the native path) and the stop can
    // be triggered from outside this closure (the record button) — so
    // the values the landing pipeline needs ride in a ref.
    recordContextRef.current = { session, regionStartSeconds, lengthSeconds, native: useNativeCapture };
    recordStartRef.current = Date.now();
    stopAtRef.current = null;
    stopRequestedRef.current = false;
    setElapsed(0);
    elapsedTimerRef.current = setInterval(() => {
      if (recordSessionRef.current !== session) return;
      const elapsedNow = (Date.now() - recordStartRef.current) / 1000;
      setElapsed(lengthSeconds !== null ? Math.min(elapsedNow, lengthSeconds) : elapsedNow);
      if (stopRequestedRef.current) return;
      if (lengthSeconds !== null && Date.now() >= recordStartRef.current + lengthSeconds * 1000) {
        stopRequestedRef.current = true;
        stopAtRef.current = Date.now();
        if (useNativeCapture) {
          // stopCapture() resolves with the take and lands it.
          stopNativeTake(session);
        } else {
          player.pause();
          cameraRef.current?.stopRecording();
        }
      }
    }, 100);
    setRecording(true);
    setRailOpen(false);

    if (useNativeCapture) {
      // NATIVE CAPTURE start — the module starts the song (at the
      // seek target the expo path would have used: region start + the
      // Settings audio correction) and the camera together, and will
      // report the item-clock song position at the first real frame
      // when the take stops. If it cannot start, there is NO seamless
      // fallback to expo-camera: that CameraView is not mounted on
      // this path, and mounting it now would begin the take seconds
      // late and unsynchronised. Abort the attempt cleanly instead —
      // the session unwinds exactly like a recordAsync rejection —
      // and let the user tap record again.
      try {
        await startCapture({
          songUri: track?.uri ?? null,
          songStartSeconds: regionStartSeconds + audioOffsetMs / 1000,
          // The same safety-net cap as recordAsync below (the app
          // deadline + 1s). With no known length, a generous ceiling
          // stands in for maxDuration: undefined — the app's manual
          // stop / deadline still ends the take.
          maxDurationSeconds: lengthSeconds !== null ? Math.max(1, lengthSeconds + 1) : 3600,
        });
        // The take's length clock runs from the FIRST REAL FRAME
        // (startCapture resolves when it is appended), not from the
        // tap: on a cold start the module can spend a beat arming
        // (seek + preroll), and that warm-up must not eat the
        // take's length — Jaizon's cold takes were stopping early.
        // The deadline interval reads recordStartRef live, and the
        // landing duration is measured from the same epoch.
        if (recordSessionRef.current === session) {
          recordStartRef.current = Date.now();
        }
      } catch {
        if (recordSessionRef.current === session) {
          if (elapsedTimerRef.current) clearInterval(elapsedTimerRef.current);
          setRecording(false);
        }
        if (recordContextRef.current?.session === session) recordContextRef.current = null;
        flashNotice('Camera problem: could not start recording — tap record to try again');
      }
      return;
    }

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

    const camera = cameraRef.current;
    if (!camera) return;
    recordPromiseRef.current = camera.recordAsync({
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
        await landRecordedTake({
          session,
          rawUri: result?.uri,
          regionStartSeconds,
          lengthSeconds,
          songStartSeconds,
          songEndSeconds,
          nativeFirstFrameSongPositionSeconds: null,
          nativeMeasuredDurationSeconds: null,
          nativeWidth: null,
          nativeHeight: null,
        });
      })
      .catch(() => {
        if (recordSessionRef.current !== session) return;
        if (elapsedTimerRef.current) clearInterval(elapsedTimerRef.current);
        if (recordContextRef.current?.session === session) recordContextRef.current = null;
        setRecording(false);
      });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [audioOffsetMs, facing, flashNotice, landRecordedTake, player, playerStatus.duration, playCue, recording, stopNativeTake, track, useNativeCapture]);

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
    // Keep the session in RECORD mode for the whole countdown — do
    // NOT flip allowsRecording off here (Jaizon, 2026-11-09: with the
    // countdown on, every OTHER take recorded with the song audio
    // wrong). This call is the ONLY session-mode change that differs
    // between a countdown take and a plain/count-in take: it moved
    // the shared AVAudioSession to the .playback category, tearing
    // down the mic route under the compositor's LIVE capture session
    // (interruption / runtime-error → the module rebuilds its inputs,
    // flipping its configured state per flip), and beginRecording
    // then flipped straight back and raced startCapture against that
    // rebuild — alternate takes lost the race. The beeps never needed
    // the flip: count-in clicks and the 'go' cue already play under
    // .playAndRecord. Same mode beginRecording applies, so the
    // category never changes and nothing is torn down.
    void setAudioModeAsync({ playsInSilentMode: true, allowsRecording: true });
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
    const ctx = recordContextRef.current;
    if (ctx?.native) {
      // Native path: stopCapture() resolves with the take and lands
      // it via the shared pipeline. The JS player was never started
      // on this path, so there is nothing to pause.
      stopNativeTake(ctx.session);
      return;
    }
    player.pause();
    cameraRef.current?.stopRecording();
  }, [player, stopNativeTake]);

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

  // Rail preview card: with a track loaded, the preview is
  // SONG-REFERENCED (calibrationPreviewFor — the take plays against
  // the master song exactly as the editor would cut it) so sync can
  // be judged and nudged; without a track it stays the plain muted
  // take-only preview and there is no Sync row.
  const railCalibration = railPreviewTake && track ? calibrationPreviewFor(railPreviewTake, track.uri) : null;
  const railAdjust = railPreviewTake?.syncAdjustFrames ?? 0;
  const nudgeRailSync = (delta: number) => {
    if (!railPreviewTake) return;
    const next = Math.max(-90, Math.min(90, railAdjust + delta));
    if (next !== railAdjust) studio.updateTake(railPreviewTake.id, { syncAdjustFrames: next });
  };

  return (
    <View style={styles.root}>
      <GestureDetector gesture={pinch}>
        {useNativeCapture ? (
          // Native capture preview — the module's own AVCaptureSession
          // view. It is driven by the SAME facing/torch/zoom/mirror
          // state as CameraView below (torch no-ops on the front
          // camera natively; the screen-flash overlay handles that
          // case), and `active` follows focus/AppState exactly like
          // CameraView's, so iOS interruptions pause/resume it the
          // same way. All overlays below layer over either preview.
          <CapturePreview
            style={StyleSheet.absoluteFill}
            facing={facing}
            torch={torch}
            zoom={zoom}
            mirrored={mirror}
            active={isFocused && appActive}
          />
        ) : (
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
        )}
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

      {/* Top bar — Settings gear left; song, flash and flip right.
          No track display on the camera (Jaizon, 2026-11-09): the
          song/part picker is the musical-notes button, and with no
          track set the picker opens by itself on entry. */}
      <View style={[styles.topBar, { top: insets.top + spacing.sm }]}>
        <IconButton icon="settings-outline" accessibilityLabel="Settings" onPress={() => router.push('/settings')} />
        <View style={styles.topRight}>
          <IconButton
            icon="musical-notes"
            accessibilityLabel="Choose the song and which part to use"
            active={!!track}
            onPress={() => setTrackOpen(true)}
          />
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
        <View style={[styles.recordingPill, { top: insets.top + 112 }]} pointerEvents="none">
          <View style={styles.recordingDot} />
          <Text style={styles.recordingText}>
            {formatTime(elapsed)}
            {regionEffForLabel ? ` / ${formatTime(regionEffForLabel.lengthSeconds)}` : ''}
          </Text>
          {metronome ? <View style={[styles.beatDot, beatFlash && styles.beatDotOn]} /> : null}
        </View>
      ) : null}
      {notice ? (
        <View style={[styles.noticePill, { top: insets.top + 154 }]} pointerEvents="none">
          <Text style={styles.noticeText}>{notice}</Text>
        </View>
      ) : null}

      {/* Bottom control bar — projects | record | next. The left
          button is the way OUT: this screen is pushed over the tabs
          and a cold launch lands here directly, so without it there
          was no route back to switch projects (Jaizon, 2026-11-09).
          Next follows the flow and is gated on having a take. */}
      <View style={[styles.bottomBar, { paddingBottom: Math.max(insets.bottom, spacing.md) }]}>
        <Pressable
          style={styles.sideButton}
          onPress={() => router.back()}
          accessibilityRole="button"
          accessibilityLabel="Back to projects">
          <Ionicons name="chevron-back" size={26} color="#FFFFFF" />
          <Text style={styles.sideButtonLabel}>Projects</Text>
        </Pressable>
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

      {/* Takes rail — COLLAPSED by default (Jaizon, 2026-11-09):
          a slim pull-tab on the left edge (film icon + count). Tap
          it and the rail slides in: takes stacked on the LEFT, each
          with a real preview frame. Tap a tile for the preview card;
          the chevron at the top of the rail collapses it again. */}
      {takes.length > 0 ? (
        railOpen && !recording ? (
        <ScrollView
          style={[styles.takeRail, { top: insets.top + 64, bottom: insets.bottom + 208 }]}
          contentContainerStyle={styles.takeRailContent}
          showsVerticalScrollIndicator={false}>
          <Pressable
            style={styles.railCollapse}
            onPress={() => setRailOpen(false)}
            accessibilityRole="button"
            accessibilityLabel="Hide takes">
            <Ionicons name="chevron-back" size={15} color={colors.label} />
          </Pressable>
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
        ) : (
          <Pressable
            style={[styles.railTab, { top: insets.top + 64 }]}
            onPress={() => setRailOpen(true)}
            disabled={recording}
            accessibilityRole="button"
            accessibilityLabel={`Show your ${takes.length} takes`}>
            <Ionicons name="film-outline" size={16} color={colors.label} />
            <Text style={styles.railTabCount}>{takes.length}</Text>
            <Ionicons name="chevron-forward" size={12} color={colors.labelSecondary} />
          </Pressable>
        )
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
                request={
                  railCalibration
                    ? railCalibration.request
                    : {
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
                      }
                }
                requestKey={railCalibration ? railCalibration.requestKey : railPreviewTake.id}
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
                {railPreviewTake.facing === 'front' ? 'Front' : 'Back'} camera
                {railCalibration ? '' : ` · ${syncStatusText(railPreviewTake)}`}
              </Text>
            </View>
            {/* Sync calibration — only with a track loaded (the
                preview above is song-referenced then). Nudging shifts
                the take's manual frame calibration inside the ONE
                shared offset, so the preview rebuilds on every press
                and the editor/export honour the same value. Sign, from
                sourceFrameForTimelineFrame: a LARGER offset reads
                footage EARLIER in the file for a given timeline frame,
                so the performance appears LATER — "+" moves lips
                later, "−" moves them earlier. Optional by design: the
                card stays a preview first; nothing forces it open. */}
            {railCalibration && railPreviewTake.durationSeconds ? (
              <View style={styles.syncBlock}>
                <View style={styles.syncHeader}>
                  <Text style={styles.syncLabel}>Sync</Text>
                  <Text style={styles.syncStatus} numberOfLines={2}>
                    {syncStatusText(railPreviewTake)}
                  </Text>
                </View>
                <View style={styles.syncStepperRow}>
                  {([-5, -1, 1, 5] as const).map((delta) => {
                    const atLimit = delta < 0 ? railAdjust <= -90 : railAdjust >= 90;
                    return (
                      <Pressable
                        key={delta}
                        disabled={atLimit}
                        onPress={() => nudgeRailSync(delta)}
                        style={[styles.syncStepButton, atLimit && styles.syncStepButtonDisabled]}
                        accessibilityRole="button"
                        accessibilityState={{ disabled: atLimit }}
                        accessibilityLabel={`Move lips ${delta > 0 ? 'later' : 'earlier'} by ${
                          Math.abs(delta) === 1 ? 'one frame' : 'five frames'
                        }`}>
                        <Text style={styles.syncStepText}>{delta > 0 ? `+${delta}f` : `−${Math.abs(delta)}f`}</Text>
                      </Pressable>
                    );
                  })}
                  {railAdjust !== 0 ? (
                    <Pressable
                      onPress={() => studio.updateTake(railPreviewTake.id, { syncAdjustFrames: undefined })}
                      style={styles.syncResetButton}
                      accessibilityRole="button"
                      accessibilityLabel="Reset sync adjustment to zero">
                      <Text style={styles.syncResetText}>Reset</Text>
                    </Pressable>
                  ) : null}
                </View>
              </View>
            ) : null}
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

  takeRail: { position: 'absolute', left: spacing.md, width: 60 },
  takeRailContent: { gap: spacing.md, alignItems: 'center', paddingVertical: spacing.xs },
  // Collapsed takes rail: a slim pull-tab hugging the left edge —
  // film icon + take count + chevron. Translucent graphite so it
  // reads as a control, not content.
  railTab: {
    position: 'absolute',
    left: 0,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 3,
    backgroundColor: 'rgba(16,17,20,0.55)',
    paddingVertical: 9,
    paddingLeft: 7,
    paddingRight: 8,
    borderTopRightRadius: radius.md,
    borderBottomRightRadius: radius.md,
  },
  railTabCount: { color: colors.label, fontSize: 12, fontWeight: '700', fontVariant: ['tabular-nums'] },
  railCollapse: {
    width: 44,
    height: 26,
    borderRadius: radius.pill,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: 'rgba(16,17,20,0.55)',
  },
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
  syncBlock: { gap: spacing.sm },
  syncHeader: { flexDirection: 'row', alignItems: 'baseline', gap: spacing.sm },
  syncLabel: { ...typeScale.subhead, color: colors.label, fontWeight: '700' },
  syncStatus: { ...typeScale.footnote, color: colors.labelSecondary, flex: 1 },
  syncStepperRow: { flexDirection: 'row', gap: spacing.sm, alignItems: 'center' },
  syncStepButton: {
    flex: 1,
    height: 38,
    borderRadius: radius.pill,
    backgroundColor: colors.elevated,
    alignItems: 'center',
    justifyContent: 'center',
  },
  syncStepButtonDisabled: { opacity: 0.35 },
  syncStepText: { ...typeScale.subhead, color: colors.label, fontWeight: '700', fontVariant: ['tabular-nums'] },
  syncResetButton: { height: 38, paddingHorizontal: spacing.sm, alignItems: 'center', justifyContent: 'center' },
  syncResetText: { ...typeScale.subhead, color: colors.accent, fontWeight: '600' },
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
