import { Ionicons } from '@expo/vector-icons';
import { router } from 'expo-router';
import { useEffect, useMemo, useRef, useState } from 'react';
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Switch, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { LyricsOverlay } from '../../components/LyricsOverlay';
import { NativePreview } from '../../components/NativePreview';
import { useLyricFonts } from '../../components/useLyricFonts';
import { WatermarkOverlay } from '../../components/WatermarkOverlay';
import { SegmentedControl } from '../../components/SegmentedControl';
import {
  addExportProgressListener,
  cancelExport,
  inspectAsset,
  isCompositorAvailable,
  renderVideo,
  type CompositeRequest,
  type CompositeResult,
  type PreviewStatus,
} from '../../lib/compositor';
import {
  edlDurationSeconds,
  edlToCompositeRequest,
  edlWithTakeCanvas,
  secondsToFrames,
  validateEdl,
  type AssetMeasure,
  type Edl,
} from '../../lib/edl';
import {
  estimateExportBytes,
  formatFileSize,
  TIER_DEFAULT_VIDEO_BITRATE_BPS,
} from '../../lib/exportSize';
import { resolveLookParams } from '../../lib/looks';
import { buildCompositeLyrics } from '../../lib/lyrics';
import { saveToPhotoLibrary, shareFile } from '../../lib/media';
import { validateAgainstAssets } from '../../lib/shuffleEdl';
import { resolveWatermarkUri } from '../../lib/watermark';
import { useStudio } from '../../store/StudioContext';
import type { ExportQualityPref } from '../../types';
import { colors, formatTime, radius, spacing, type as typeScale } from '../../theme';

/**
 * Export — the finishing stage of the workspace (Record → Takes →
 * Editor → Export), rebuilt on the canonical EDL + native engine v2
 * (docs/DESIGN_SYSTEM.md §3.6). This is a deliberate final production
 * step: one final preview, one quality choice, one render — then the
 * MEASURED result, presented as the completion of the project.
 *
 * Preview == export, by construction: the final preview and the render
 * are handed the SAME CompositeRequest object, built once from the
 * validated EDL by `edlToCompositeRequest`. The quality choice overrides
 * canvasWidth/canvasHeight on that one request — it must apply to both,
 * because a preview rendered at a different size than the export would
 * no longer be a truthful preview of the file.
 *
 * Gating (empty states, not disabled chrome):
 *  - no takes → "Record a take first" → Record;
 *  - takes but no cut → "Your cut is empty" → Editor;
 *  - engine not linked (Expo Go) → one honest unavailable state.
 */

type RenderPhase = 'idle' | 'rendering' | 'done' | 'cancelled' | 'error';

let exportIdCounter = 0;

/** Quality → output size. 'high' keeps the project's own canvas. */
const QUALITY_CANVAS: Record<ExportQualityPref, { width: number; height: number } | null> = {
  high: null,
  // TikTok's canvas is always 1080×1920, whatever the takes were
  // shot at — its uploader downscales anything larger anyway.
  tiktok: { width: 1080, height: 1920 },
  balanced: { width: 720, height: 1280 },
  small: { width: 540, height: 960 },
};

const QUALITY_CAPTIONS: Record<ExportQualityPref, string> = {
  high: 'Best quality · 60fps, bigger file.',
  tiktok: 'For TikTok · 1080 × 1920 · 60fps · H.264 — the shape its uploader handles best.',
  balanced: 'A good size for sharing · 30fps.',
  small: 'Smaller file, softer picture · 30fps.',
};

interface ValidatedCut {
  sig: string;
  edl: Edl;
  /** How many cuts validation had to trim or drop (count only — the raw reasons stay internal). */
  issues: number;
}

export default function ExportScreen() {
  const insets = useSafeAreaInsets();
  const studio = useStudio();
  const {
    activeProject,
    takes,
    edl,
    exportQuality,
    setExportQuality,
    exportTargetSizeMB,
    setExportTargetSizeMB,
    autoVolume,
    setAutoVolume,
    watermarkEnabled,
  } = studio;

  // The controlled tiers (everything except High) render at a KNOWN
  // bitrate through the engine's post-render transcode; High keeps
  // the untouched HighestQuality render.
  const controlledBitrate: number | null =
    exportQuality === 'tiktok' || exportQuality === 'balanced' || exportQuality === 'small'
      ? TIER_DEFAULT_VIDEO_BITRATE_BPS[exportQuality]
      : null;

  // The project's look, resolved to the one numeric param set the
  // engine applies (null = no grade). Shared with the Editor through
  // the store's effective look, so both screens grade identically.
  const resolvedLook = useMemo(() => resolveLookParams(studio.look), [studio.look]);

  const engineAvailable = isCompositorAvailable();
  const noTakes = takes.length === 0;
  const noCut = !noTakes && (!edl || edl.segments.length === 0);
  const locked = noTakes || noCut;

  const takeUri = useMemo(() => {
    const byId = new Map(takes.map((t) => [t.id, t.uri]));
    return (takeId: string) => byId.get(takeId);
  }, [takes]);

  // ---- Validation: the EDL is checked against real take lengths before
  // it goes anywhere near the player or the exporter. Synchronous
  // fallback first (stored take durations), then upgraded with native
  // inspectAsset measures when the engine is present.
  const edlSig = useMemo(
    () => (edl ? edl.segments.map((s) => `${s.takeId}:${s.sourceStartFrame}:${s.durationFrames}`).join('|') : ''),
    [edl],
  );
  const fallbackCut = useMemo<ValidatedCut | null>(() => {
    if (!edl || edl.segments.length === 0) return null;
    const result = validateAgainstAssets(edl, takes, edl.fps);
    return { sig: edlSig, edl: result.edl, issues: result.errors.length };
  }, [edl, edlSig, takes]);

  const [nativeCut, setNativeCut] = useState<ValidatedCut | null>(null);
  useEffect(() => {
    if (!edl || edl.segments.length === 0 || !engineAvailable) return;
    let alive = true;
    void (async () => {
      try {
        const uniqueIds = [...new Set(edl.segments.map((s) => s.takeId))];
        const measures: AssetMeasure[] = [];
        for (const takeId of uniqueIds) {
          const uri = takeUri(takeId);
          if (!uri) throw new Error(`Take ${takeId} has no file.`);
          const info = await inspectAsset(uri);
          measures.push({ takeId, durationFrames: secondsToFrames(info.durationSeconds, edl.fps) });
        }
        if (!alive) return;
        const result = validateEdl(edl, measures);
        setNativeCut({ sig: edlSig, edl: result.edl, issues: result.errors.length });
      } catch {
        // Native measuring failed — the fallback validation stands.
      }
    })();
    return () => {
      alive = false;
    };
  }, [edl, edlSig, engineAvailable, takeUri]);

  const cut: ValidatedCut | null =
    nativeCut && nativeCut.sig === edlSig ? nativeCut : fallbackCut;

  // Lyrics: the project's song-frame lines mapped to composition
  // seconds against the cut's own region start — the payload rides
  // on the ONE request below, so the render burns exactly what the
  // stage preview draws through LyricsOverlay.
  useLyricFonts();
  const lyricsPayload = useMemo(
    () =>
      cut && studio.lyricsEnabled
        ? buildCompositeLyrics(studio.lyrics, cut.edl.audio.regionStartFrame, cut.edl.fps)
        : null,
    [cut, studio.lyrics, studio.lyricsEnabled],
  );

  // Watermark: the project's flag (toggled on the Edit screen) plus
  // the logo's resolved file URI (shared cache, src/lib/watermark.ts)
  // ride on the ONE request below — so the final preview shows the
  // stamp the render will carry.
  const [watermarkUri, setWatermarkUri] = useState<string | null>(null);
  useEffect(() => {
    if (!watermarkEnabled) return;
    let alive = true;
    void resolveWatermarkUri().then((uri) => {
      if (alive) setWatermarkUri(uri);
    });
    return () => {
      alive = false;
    };
  }, [watermarkEnabled]);

  // ---- The ONE request: preview and render consume exactly this.
  const request = useMemo<CompositeRequest | null>(() => {
    if (!cut || cut.edl.segments.length === 0) return null;
    try {
      const effectiveEdl = edlWithTakeCanvas(cut.edl, takes);
      const base = edlToCompositeRequest(effectiveEdl, takeUri, {
        watermarkEnabled,
        watermarkImageUri: watermarkEnabled ? watermarkUri : null,
        // Export frame rate follows the quality tier (Jaizon):
        // High and TikTok render 60fps; Balanced/Small render 30fps
        // to keep files shareable (<20MB for typical clip lengths).
        frameRate: exportQuality === 'high' || exportQuality === 'tiktok' ? 60 : 30,
        // The look is part of the COMPOSITION (the engine grades the
        // frames themselves), so it belongs on this shared request:
        // the stage preview shows the grade the file will carry.
        look: resolvedLook,
        // Auto volume likewise: the gain is applied to the song
        // inside the composition, so the preview plays at the level
        // the file will ship at.
        normalizeVolume: autoVolume,
      });
      // 'high' (null) renders at the cut's canvas — which follows the
      // takes, so 4K takes export at 4K; the other tiers are explicit
      // canvases the user picked (TikTok always 1080×1920).
      const canvas = QUALITY_CANVAS[exportQuality] ?? effectiveEdl.canvas;
      // The canvas override is applied HERE, on the single shared
      // request, so the preview the user approves is framed identically
      // to the file the exporter writes (see header note).
      //
      // Size control rides the same request, but note the asymmetry:
      // exportVideoBitrate / exportTargetSizeMB / exportCodec are
      // RENDER-ONLY — the engine reads them after the export session
      // writes the file and transcodes that file at the given rate.
      // They never touch the composition, so the preview built from
      // this request stays truthful; nobody should "fix" the preview
      // to match the transcode — the picture is identical, only the
      // file's encoding differs.
      const sizeControl =
        controlledBitrate === null
          ? {}
          : {
              exportCodec: 'h264' as const,
              ...(exportTargetSizeMB > 0
                ? { exportTargetSizeMB }
                : { exportVideoBitrate: controlledBitrate }),
            };
      return {
        ...base,
        canvasWidth: canvas.width,
        canvasHeight: canvas.height,
        lyrics: lyricsPayload,
        ...sizeControl,
      };
    } catch {
      return null;
    }
  }, [
    cut,
    takeUri,
    takes,
    exportQuality,
    watermarkEnabled,
    watermarkUri,
    lyricsPayload,
    resolvedLook,
    autoVolume,
    controlledBitrate,
    exportTargetSizeMB,
  ]);

  const requestKey = useMemo(() => (request ? JSON.stringify(request) : ''), [request]);
  const totalSeconds = cut ? edlDurationSeconds(cut.edl) : 0;
  const cutCount = cut?.edl.segments.length ?? 0;

  // Live size estimate for the controlled tiers, from the same math
  // the engine applies (src/lib/exportSize.ts): a chosen target IS
  // the estimate; otherwise the tier's known bitrate over the cut's
  // duration. High renders at an encoder-chosen rate — no estimate.
  const estimateBytes = useMemo(() => {
    if (controlledBitrate === null || totalSeconds <= 0) return null;
    if (exportTargetSizeMB > 0) return exportTargetSizeMB * 1_000_000;
    return estimateExportBytes(controlledBitrate, totalSeconds);
  }, [controlledBitrate, exportTargetSizeMB, totalSeconds]);

  // ---- Preview transport (display state only — the native player owns timing).
  const [stageWidth, setStageWidth] = useState(0);
  const [paused, setPaused] = useState(true);
  const [position, setPosition] = useState(0);
  const [previewStatus, setPreviewStatus] = useState<PreviewStatus>('loading');
  const [previewNonce, setPreviewNonce] = useState(0);

  // ---- Render state.
  // The id is (re)generated inside handleRender — a fresh one per
  // render attempt — so it is kept in a ref seeded without impure
  // calls during render; the counter guarantees uniqueness.
  const exportIdRef = useRef('export-0');
  const [phase, setPhase] = useState<RenderPhase>('idle');
  const [progress, setProgress] = useState(0);
  const [result, setResult] = useState<CompositeResult | null>(null);
  const [renderedKey, setRenderedKey] = useState<string | null>(null);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);
  const [savedKey, setSavedKey] = useState<string | null>(null);
  const [saveNote, setSaveNote] = useState<string | null>(null);

  // Real engine progress, filtered to the render this screen started.
  useEffect(() => {
    const sub = addExportProgressListener((event) => {
      if (event.exportId === exportIdRef.current) setProgress(event.progress);
    });
    return () => sub.remove();
  }, []);

  // A completion is only valid for the exact cut that produced it: if
  // the EDL (or quality) changed since the render, the completion is
  // stale and the screen returns to its pre-render state (§3.6).
  const showCompletion = phase === 'done' && result !== null && renderedKey === requestKey;
  const saved = showCompletion && savedKey === renderedKey;

  const handleRender = async () => {
    if (!request) return;
    // A fresh id per render: progress events and cancellation are keyed
    // by it, so a late event from an earlier render can never leak in.
    exportIdCounter += 1;
    exportIdRef.current = `export-${Date.now()}-${exportIdCounter}`;
    setProgress(0);
    setErrorMessage(null);
    setSaveNote(null);
    setPhase('rendering');
    try {
      const rendered = await renderVideo({ ...request, exportId: exportIdRef.current });
      setResult(rendered);
      setRenderedKey(requestKey);
      setPhase('done');
      // Stamp the project Exported (Studio Continue card + Projects state line).
      studio.markProjectExported();
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Something went wrong while making your video.';
      // Cancellation is a user choice, not a failure: the engine rejects
      // with a cancellation error ("The export was cancelled.").
      if (/cancel/i.test(message)) {
        setPhase('cancelled');
      } else {
        setErrorMessage(message);
        setPhase('error');
      }
    }
  };

  const handleCancel = () => {
    void cancelExport(exportIdRef.current);
  };

  const handleSaveToPhotos = async () => {
    if (!result || !showCompletion) return;
    if (await saveToPhotoLibrary(result.uri)) {
      setSavedKey(renderedKey);
      setSaveNote(null);
    } else {
      setSaveNote("Photos permission wasn't granted — you can share the video instead.");
    }
  };

  const handleShare = async () => {
    if (!result || !showCompletion) return;
    if (!(await shareFile(result.uri, 'video/mp4'))) {
      setSaveNote("Sharing isn't available on this device.");
    }
  };

  const projectName = activeProject?.name ?? 'Your project';
  const subtitle = locked
    ? projectName
    : `${projectName} · ${cutCount} cut${cutCount === 1 ? '' : 's'} · ${formatTime(totalSeconds)}`;

  // Ready = the finished cut can be previewed and rendered. Only then
  // does the screen switch to the near-fullscreen stage layout — the
  // locked/unavailable states keep the padded, header-led layout.
  const readyState = !locked && engineAvailable && request !== null;

  return (
    <View style={styles.root}>
      <ScrollView
        style={{ flex: 1 }}
        contentContainerStyle={
          readyState ? { flexGrow: 1 } : { paddingTop: insets.top + spacing.md, paddingBottom: spacing.xxl }
        }>
        {!readyState ? (
        <View style={styles.header}>
          <Pressable
            onPress={() => router.back()}
            hitSlop={10}
            accessibilityRole="button"
            accessibilityLabel="Back to Editor"
            style={styles.backButton}>
            <Ionicons name="chevron-back" size={26} color={colors.accent} />
            <Text style={styles.backText}>Editor</Text>
          </Pressable>
          <Text style={styles.largeTitle}>Export</Text>
          <Text style={styles.headerSubtitle}>{subtitle}</Text>
        </View>
        ) : null}

        {noTakes ? (
          <View style={[styles.section, styles.emptyCard]}>
            <Ionicons name="videocam-outline" size={30} color={colors.labelSecondary} />
            <Text style={styles.emptyTitle}>Record a take first</Text>
            <Text style={styles.emptyBody}>
              There&apos;s nothing to export until you&apos;ve recorded a take.
            </Text>
            <Pressable
              style={styles.primaryButton}
              onPress={() => router.replace('/project/record')}
              accessibilityRole="button">
              <Text style={styles.primaryButtonText}>Back to Record</Text>
            </Pressable>
          </View>
        ) : noCut ? (
          <View style={[styles.section, styles.emptyCard]}>
            <Ionicons name="lock-closed-outline" size={30} color={colors.labelSecondary} />
            <Text style={styles.emptyTitle}>Your cut is empty</Text>
            <Text style={styles.emptyBody}>
              You have takes, but no cut yet. Make your cut in the Editor — then export it here.
            </Text>
            <Pressable
              style={styles.primaryButton}
              onPress={() => router.replace('/project/editor')}
              accessibilityRole="button">
              <Text style={styles.primaryButtonText}>Go to Editor</Text>
            </Pressable>
          </View>
        ) : !engineAvailable ? (
          <View style={[styles.section, styles.emptyCard]}>
            <Ionicons name="alert-circle-outline" size={30} color={colors.labelSecondary} />
            <Text style={styles.emptyTitle}>Export isn&apos;t available in this build</Text>
            <Text style={styles.emptyBody}>
              Making the finished video needs the full MVMT app. Your project and cut are saved on this phone.
            </Text>
            <Pressable style={styles.primaryButton} onPress={() => router.back()} accessibilityRole="button">
              <Text style={styles.primaryButtonText}>Back to Editor</Text>
            </Pressable>
          </View>
        ) : !request ? (
          <View style={[styles.section, styles.emptyCard]}>
            <Ionicons name="alert-circle-outline" size={30} color={colors.labelSecondary} />
            <Text style={styles.emptyTitle}>This cut can&apos;t be exported</Text>
            <Text style={styles.emptyBody}>
              Every cut in it points at a take that&apos;s no longer there. Re-shuffle in the Editor to rebuild it.
            </Text>
            <Pressable
              style={styles.primaryButton}
              onPress={() => router.replace('/project/editor')}
              accessibilityRole="button">
              <Text style={styles.primaryButtonText}>Go to Editor</Text>
            </Pressable>
          </View>
        ) : (
          <View style={styles.readyWrap}>
            {/* Near-fullscreen final preview — the same request the
                render will use. The chrome floats on the video: a top
                bar (back button + title pill) and the transport pill
                along the stage's bottom edge. Buttons on the picture
                is the point of this layout. */}
            <View style={styles.stage} onLayout={(e) => setStageWidth(e.nativeEvent.layout.width)}>
              <NativePreview
                request={request}
                requestKey={`${requestKey}#${previewNonce}`}
                paused={paused}
                onProgress={(pos) => setPosition(pos)}
                onStatus={setPreviewStatus}
                style={styles.stagePreview}
              />
              <WatermarkOverlay enabled={watermarkEnabled} width={stageWidth} />
              <LyricsOverlay lyrics={lyricsPayload} positionSeconds={position} width={stageWidth} />
              {previewStatus === 'loading' ? (
                <View style={styles.previewLoading} pointerEvents="none">
                  <ActivityIndicator color={colors.label} />
                  <Text style={styles.previewLoadingText}>Preparing your cut…</Text>
                </View>
              ) : null}
              <View style={[styles.stageTopBar, { paddingTop: insets.top + spacing.sm }]}>
                <Pressable
                  onPress={() => router.back()}
                  hitSlop={8}
                  accessibilityRole="button"
                  accessibilityLabel="Back to Editor"
                  style={styles.stageRoundButton}>
                  <Ionicons name="chevron-back" size={24} color={colors.label} />
                </Pressable>
                <View style={styles.stageTitlePill}>
                  <Text style={styles.stageTitle}>Export</Text>
                  <Text style={styles.stageSubtitle} numberOfLines={1}>
                    {subtitle}
                  </Text>
                </View>
                <View style={styles.stageSpacer} />
              </View>
              <View style={styles.stageTransport}>
                <Pressable
                  style={styles.stagePlayButton}
                  onPress={() => setPaused((p) => !p)}
                  accessibilityRole="button"
                  accessibilityLabel={paused ? 'Play preview' : 'Pause preview'}>
                  <Ionicons name={paused ? 'play' : 'pause'} size={19} color={colors.label} />
                </Pressable>
                <Text style={styles.stageTime}>{formatTime(position)}</Text>
                <View style={styles.transportTrack}>
                  <View
                    style={[
                      styles.transportFill,
                      { width: `${totalSeconds > 0 ? Math.min(100, Math.max(0, (position / totalSeconds) * 100)) : 0}%` },
                    ]}
                  />
                </View>
                <Text style={styles.stageTime}>{formatTime(totalSeconds)}</Text>
              </View>
            </View>

            {previewStatus === 'error' ? (
              <View style={[styles.noteSection, styles.inlineNote]}>
                <Text style={styles.inlineNoteText}>The preview couldn&apos;t be prepared.</Text>
                <Pressable
                  hitSlop={8}
                  onPress={() => setPreviewNonce((n) => n + 1)}
                  accessibilityRole="button"
                  accessibilityLabel="Try preparing the preview again">
                  <Text style={styles.inlineNoteAction}>Try again</Text>
                </Pressable>
              </View>
            ) : null}
            {cut && cut.issues > 0 ? (
              <Text style={[styles.noteSection, styles.validationNote]}>
                {cut.issues} {cut.issues === 1 ? 'cut was' : 'cuts were'} trimmed to fit their takes.
              </Text>
            ) : null}

            {showCompletion && result ? (
              /* Completion — replaces the options area. The facts shown
                 are MEASURED from the written file, never requested. */
              <View style={[styles.section, styles.belowStage, styles.card, styles.completionCard]}>
                <Ionicons name="checkmark-circle" size={44} color={colors.success} />
                <Text style={styles.completionTitle}>Your video is ready</Text>
                <Text style={styles.completionFacts}>
                  {formatTime(result.durationSeconds)} · {result.width} × {result.height}
                  {typeof result.fileSizeBytes === 'number'
                    ? ` · ${formatFileSize(result.fileSizeBytes)}`
                    : ''}
                </Text>
                {typeof result.appliedGainDb === 'number' && Math.abs(result.appliedGainDb) >= 0.1 ? (
                  <Text style={styles.completionFacts}>
                    Volume adjusted {result.appliedGainDb >= 0 ? '+' : ''}
                    {result.appliedGainDb.toFixed(1)} dB to hit the platform level
                  </Text>
                ) : null}
                <Pressable
                  style={[styles.primaryButton, styles.completionAction, saved && styles.primaryButtonConfirmed]}
                  onPress={() => void handleSaveToPhotos()}
                  disabled={saved}
                  accessibilityRole="button"
                  accessibilityLabel={saved ? 'Saved to Photos' : 'Save video to Photos'}>
                  {saved ? <Ionicons name="checkmark" size={18} color={colors.success} /> : null}
                  <Text style={[styles.primaryButtonText, saved && styles.confirmedButtonText]}>
                    {saved ? 'Saved to Photos' : 'Save to Photos'}
                  </Text>
                </Pressable>
                <Pressable
                  style={[styles.secondaryButton, styles.completionAction]}
                  onPress={() => void handleShare()}
                  accessibilityRole="button"
                  accessibilityLabel="Share video">
                  <Ionicons name="share-outline" size={18} color={colors.label} />
                  <Text style={styles.secondaryButtonText}>Share</Text>
                </Pressable>
                {saveNote ? <Text style={styles.saveNote}>{saveNote}</Text> : null}
                <View style={styles.completionLinks}>
                  <Pressable hitSlop={8} onPress={() => router.back()} accessibilityRole="button">
                    <Text style={styles.linkText}>Back to Editor</Text>
                  </Pressable>
                  <Pressable hitSlop={8} onPress={() => router.dismissAll()} accessibilityRole="button">
                    <Text style={styles.linkText}>Done</Text>
                  </Pressable>
                </View>
              </View>
            ) : phase === 'error' ? (
              <View style={[styles.section, styles.belowStage, styles.card, styles.failureCard]}>
                <Ionicons name="alert-circle" size={30} color={colors.danger} />
                <Text style={styles.failureTitle}>That didn&apos;t work</Text>
                <Text style={styles.failureBody}>{errorMessage}</Text>
                <Pressable
                  style={[styles.primaryButton, styles.completionAction]}
                  onPress={() => void handleRender()}
                  accessibilityRole="button"
                  accessibilityLabel="Try rendering again">
                  <Text style={styles.primaryButtonText}>Try again</Text>
                </Pressable>
              </View>
            ) : (
              <View style={[styles.section, styles.belowStage]}>
                {phase === 'cancelled' ? (
                  <Text style={styles.cancelledNote}>Export cancelled — nothing was saved.</Text>
                ) : null}
                <View style={styles.card}>
                  <View style={styles.optionBlock}>
                    <Text style={styles.optionLabel}>Quality</Text>
                    <SegmentedControl<ExportQualityPref>
                      options={[
                        { value: 'high', label: 'High' },
                        { value: 'tiktok', label: 'TikTok' },
                        { value: 'balanced', label: 'Balanced' },
                        { value: 'small', label: 'Small' },
                      ]}
                      value={exportQuality}
                      onChange={setExportQuality}
                      accessibilityLabel="Export quality"
                    />
                  </View>
                  <View style={styles.optionBlock}>
                    <Text style={styles.optionLabel}>File size</Text>
                    <View
                      pointerEvents={controlledBitrate === null ? 'none' : 'auto'}
                      style={controlledBitrate === null ? styles.controlDisabled : undefined}>
                      <SegmentedControl<number>
                        options={[
                          { value: 0, label: 'Off' },
                          { value: 10, label: '10 MB' },
                          { value: 20, label: '20 MB' },
                          { value: 25, label: '25 MB' },
                          { value: 50, label: '50 MB' },
                        ]}
                        value={exportTargetSizeMB}
                        onChange={setExportTargetSizeMB}
                        accessibilityLabel="Target file size"
                      />
                    </View>
                    {controlledBitrate === null ? (
                      <Text style={styles.blockHint}>
                        Size control applies to TikTok, Balanced and Small — High keeps the
                        encoder&apos;s full quality.
                      </Text>
                    ) : exportTargetSizeMB > 0 ? (
                      <Text style={styles.blockHint}>
                        The render is fitted to about {exportTargetSizeMB} MB.
                      </Text>
                    ) : null}
                  </View>
                  <View style={styles.optionBlock}>
                    <View style={styles.switchRow}>
                      <View style={styles.switchText}>
                        <Text style={styles.optionLabel}>Auto volume</Text>
                        <Text style={styles.blockHint}>
                          Levels the song to the platform loudness, so posts don&apos;t come out
                          quiet or blasted.
                        </Text>
                      </View>
                      <Switch
                        value={autoVolume}
                        onValueChange={setAutoVolume}
                        trackColor={{ true: colors.accent, false: colors.elevated }}
                        thumbColor={autoVolume ? colors.onAccent : colors.label}
                        accessibilityLabel="Auto volume"
                      />
                    </View>
                  </View>
                </View>
                <Text style={styles.qualityCaption}>
                  {request.canvasWidth} × {request.canvasHeight} · {request.frameRate} fps · Portrait · Song only —
                  your takes&apos; camera sound is off · {QUALITY_CAPTIONS[exportQuality]}
                  {estimateBytes !== null ? ` · File ≈ ${formatFileSize(estimateBytes)}` : ''}
                </Text>
              </View>
            )}
          </View>
        )}
      </ScrollView>

      {/* Action band — one primary action, per the stage pattern. While
          rendering, real progress replaces the button. */}
      {!locked && engineAvailable && request && !showCompletion && phase !== 'error' ? (
        <View style={[styles.actionBand, { paddingBottom: Math.max(insets.bottom, spacing.md) }]}>
          {phase === 'rendering' ? (
            <View>
              <View style={styles.progressRow}>
                <Text style={styles.progressLabel}>Rendering your video…</Text>
                <Text style={styles.progressPercent}>{Math.round(progress * 100)}%</Text>
              </View>
              <View
                style={styles.progressTrack}
                accessibilityRole="progressbar"
                accessibilityValue={{ min: 0, max: 100, now: Math.round(progress * 100), text: `${Math.round(progress * 100)} percent` }}>
                <View style={[styles.progressFill, { width: `${Math.round(progress * 100)}%` }]} />
              </View>
              <Pressable
                style={styles.cancelButton}
                onPress={handleCancel}
                accessibilityRole="button"
                accessibilityLabel="Cancel export">
                <Text style={styles.cancelText}>Cancel</Text>
              </Pressable>
            </View>
          ) : (
            <Pressable
              style={styles.primaryButton}
              onPress={() => void handleRender()}
              accessibilityRole="button"
              accessibilityLabel="Save video">
              <Text style={styles.primaryButtonText}>Save video</Text>
            </Pressable>
          )}
        </View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: colors.groupedBackground },
  header: { paddingHorizontal: spacing.xl, marginBottom: spacing.lg },
  backButton: { flexDirection: 'row', alignItems: 'center', marginLeft: -6, marginBottom: spacing.xs },
  backText: { color: colors.accent, fontSize: 17 },
  largeTitle: { ...typeScale.largeTitle, color: colors.label },
  headerSubtitle: { ...typeScale.subhead, color: colors.labelSecondary, marginTop: 2 },
  section: { paddingHorizontal: spacing.xl, marginBottom: spacing.xl },

  emptyCard: {
    alignItems: 'center',
    gap: spacing.sm,
    backgroundColor: colors.card,
    borderRadius: radius.lg,
    padding: spacing.xl,
    marginHorizontal: spacing.xl,
  },
  emptyTitle: { ...typeScale.headline, color: colors.label },
  emptyBody: { ...typeScale.subhead, color: colors.labelSecondary, lineHeight: 21, textAlign: 'center' },
  primaryButton: {
    marginTop: spacing.sm,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: spacing.sm,
    backgroundColor: colors.accent,
    borderRadius: radius.md,
    paddingHorizontal: spacing.lg,
    paddingVertical: 14,
  },
  primaryButtonText: { ...typeScale.headline, color: colors.onAccent },
  primaryButtonConfirmed: { backgroundColor: colors.elevated },
  confirmedButtonText: { color: colors.success },

  // ---- Near-fullscreen stage (ready state only) ----
  readyWrap: { flex: 1 },
  stage: { flex: 1, minHeight: 360, backgroundColor: '#000', position: 'relative' },
  stagePreview: { flex: 1, borderRadius: 0 },
  stageTopBar: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    flexDirection: 'row',
    alignItems: 'flex-start',
    justifyContent: 'space-between',
    paddingHorizontal: spacing.md,
  },
  stageRoundButton: {
    width: 44,
    height: 44,
    borderRadius: 22,
    backgroundColor: colors.material,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.materialBorder,
    alignItems: 'center',
    justifyContent: 'center',
  },
  stageSpacer: { width: 44, height: 44 },
  stageTitlePill: {
    flex: 1,
    flexShrink: 1,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: spacing.sm,
    backgroundColor: colors.material,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.materialBorder,
    borderRadius: radius.pill,
    paddingHorizontal: spacing.md,
    paddingVertical: 10,
    marginHorizontal: spacing.md,
  },
  stageTitle: { ...typeScale.headline, color: colors.label },
  stageSubtitle: { ...typeScale.footnote, color: colors.labelSecondary, flexShrink: 1 },
  stageTransport: {
    position: 'absolute',
    left: spacing.md,
    right: spacing.md,
    bottom: spacing.md,
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.md,
    backgroundColor: colors.material,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.materialBorder,
    borderRadius: radius.pill,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
  },
  stagePlayButton: {
    width: 36,
    height: 36,
    borderRadius: 18,
    backgroundColor: colors.materialBorder,
    alignItems: 'center',
    justifyContent: 'center',
  },
  stageTime: {
    ...typeScale.caption,
    color: colors.label,
    fontVariant: ['tabular-nums'],
    minWidth: 30,
    textAlign: 'center',
  },
  noteSection: { paddingHorizontal: spacing.xl },
  belowStage: { marginTop: spacing.lg },

  previewLoading: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    alignItems: 'center',
    justifyContent: 'center',
    gap: spacing.sm,
  },
  previewLoadingText: { ...typeScale.footnote, color: colors.labelSecondary },
  transportTrack: {
    flex: 1,
    height: 4,
    borderRadius: radius.pill,
    backgroundColor: colors.elevated,
    overflow: 'hidden',
  },
  transportFill: { height: '100%', backgroundColor: colors.label, borderRadius: radius.pill },
  inlineNote: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    marginTop: spacing.md,
  },
  inlineNoteText: { ...typeScale.footnote, color: colors.labelSecondary },
  inlineNoteAction: { ...typeScale.footnote, color: colors.accent, fontWeight: '600' },
  validationNote: { ...typeScale.footnote, color: colors.labelSecondary, marginTop: spacing.md },

  card: {
    backgroundColor: colors.card,
    borderRadius: radius.lg,
    paddingHorizontal: spacing.lg,
    paddingVertical: spacing.sm,
  },
  optionBlock: { paddingVertical: spacing.md, gap: spacing.sm },
  optionLabel: { ...typeScale.headline, color: colors.label },
  controlDisabled: { opacity: 0.45 },
  blockHint: { ...typeScale.footnote, color: colors.labelSecondary, lineHeight: 17 },
  switchRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: spacing.md },
  switchText: { flex: 1, gap: 2 },
  qualityCaption: {
    ...typeScale.footnote,
    color: colors.labelSecondary,
    marginTop: spacing.md,
    marginLeft: spacing.xs,
  },
  cancelledNote: { ...typeScale.footnote, color: colors.labelSecondary, marginBottom: spacing.md },

  completionCard: { alignItems: 'center', paddingVertical: spacing.xxl, gap: spacing.sm },
  completionTitle: { ...typeScale.title2, color: colors.label, marginTop: spacing.sm },
  completionFacts: {
    ...typeScale.subhead,
    color: colors.labelSecondary,
    fontVariant: ['tabular-nums'],
    marginBottom: spacing.md,
  },
  completionAction: { alignSelf: 'stretch', marginTop: spacing.sm },
  secondaryButton: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: spacing.sm,
    backgroundColor: colors.elevated,
    borderRadius: radius.md,
    paddingHorizontal: spacing.lg,
    paddingVertical: 14,
  },
  secondaryButtonText: { ...typeScale.headline, color: colors.label },
  saveNote: { ...typeScale.footnote, color: colors.labelSecondary, textAlign: 'center', marginTop: spacing.sm },
  completionLinks: {
    flexDirection: 'row',
    gap: spacing.xxl,
    marginTop: spacing.lg,
  },
  linkText: { ...typeScale.subhead, color: colors.accent, fontWeight: '600' },

  failureCard: { alignItems: 'center', paddingVertical: spacing.xxl, gap: spacing.sm },
  failureTitle: { ...typeScale.headline, color: colors.label, marginTop: spacing.xs },
  failureBody: { ...typeScale.subhead, color: colors.labelSecondary, lineHeight: 21, textAlign: 'center' },

  actionBand: {
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colors.separator,
    backgroundColor: colors.groupedBackground,
    paddingHorizontal: spacing.xl,
    paddingTop: spacing.md,
  },
  progressRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginBottom: spacing.sm,
  },
  progressLabel: { ...typeScale.footnote, color: colors.labelSecondary },
  progressPercent: { ...typeScale.caption, color: colors.label, fontVariant: ['tabular-nums'] },
  progressTrack: {
    height: 6,
    borderRadius: radius.pill,
    backgroundColor: colors.elevated,
    overflow: 'hidden',
  },
  progressFill: { height: '100%', backgroundColor: colors.accent, borderRadius: radius.pill },
  cancelButton: { alignItems: 'center', paddingVertical: spacing.md },
  cancelText: { ...typeScale.subhead, color: colors.accent, fontWeight: '600' },
});
