import { Ionicons } from '@expo/vector-icons';
import { router } from 'expo-router';
import { useEffect, useMemo, useRef, useState } from 'react';
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { NativePreview } from '../../components/NativePreview';
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
  secondsToFrames,
  validateEdl,
  type AssetMeasure,
  type Edl,
} from '../../lib/edl';
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
  balanced: { width: 720, height: 1280 },
  small: { width: 540, height: 960 },
};

const QUALITY_CAPTIONS: Record<ExportQualityPref, string> = {
  high: 'Best quality, bigger file.',
  balanced: 'A good size for sharing.',
  small: 'Smaller file, softer picture.',
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
  const { activeProject, takes, edl, exportQuality, setExportQuality, watermarkEnabled } = studio;

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
      const base = edlToCompositeRequest(cut.edl, takeUri, {
        watermarkEnabled,
        watermarkImageUri: watermarkEnabled ? watermarkUri : null,
      });
      const canvas = QUALITY_CANVAS[exportQuality] ?? cut.edl.canvas;
      // The canvas override is applied HERE, on the single shared
      // request, so the preview the user approves is framed identically
      // to the file the exporter writes (see header note).
      return { ...base, canvasWidth: canvas.width, canvasHeight: canvas.height };
    } catch {
      return null;
    }
  }, [cut, takeUri, exportQuality, watermarkEnabled, watermarkUri]);

  const requestKey = useMemo(() => (request ? JSON.stringify(request) : ''), [request]);
  const totalSeconds = cut ? edlDurationSeconds(cut.edl) : 0;
  const cutCount = cut?.edl.segments.length ?? 0;

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
                </Text>
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
                        { value: 'balanced', label: 'Balanced' },
                        { value: 'small', label: 'Small file' },
                      ]}
                      value={exportQuality}
                      onChange={setExportQuality}
                      accessibilityLabel="Export quality"
                    />
                  </View>
                </View>
                <Text style={styles.qualityCaption}>
                  {request.canvasWidth} × {request.canvasHeight} · {cut?.edl.fps ?? 30} fps · Portrait · Song only —
                  your takes&apos; camera sound is off · {QUALITY_CAPTIONS[exportQuality]}
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
