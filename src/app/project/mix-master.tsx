import { Ionicons } from '@expo/vector-icons';
import { router } from 'expo-router';
import { useAudioPlayer, useAudioPlayerStatus } from 'expo-audio';
import { useEffect, useMemo, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Pressable,
  ScrollView,
  StyleSheet,
  Switch,
  Text,
  View,
} from 'react-native';
import Slider from '@react-native-community/slider';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { SegmentedControl } from '../../components/SegmentedControl';
import { isCompositorAvailable } from '../../lib/compositor';
import { shareFile } from '../../lib/media';
import { exportMixMasterSongFile, useMixMasterProfile, useMixMasterSongUri } from '../../lib/mixMaster';
import {
  MM_BAND_CENTERS_HZ,
  formatMixMasterFinding,
  formatMixMasterSummary,
  mixMasterActivityBars,
  mixMasterGainAtTime,
  shortBandLabelHz,
  summarizeMixMasterProfile,
} from '../../lib/mixMasterCurve';
import {
  mixMasterExportMimeType,
  type MixMasterExportFormat,
} from '../../lib/mixMasterExport';
import { loadTrackPeaks, samplePeaks, standinPeaks } from '../../lib/waveform';
import { useStudio } from '../../store/StudioContext';
import { colors, formatTime, radius, spacing, type as typeScale } from '../../theme';

const WAVEFORM_BARS = 48;
const ACTIVITY_BARS = 48;
const FINDINGS_SHOWN = 8;

/**
 * Mix & Master — the Stage 3 screen (docs/MIX-MASTER.md §3).
 *
 * Reached from the Export screen, beside the Auto EQ toggle. It is a
 * settings-style audio screen, not a step in the Record → Editor →
 * Export flow: the main switch defaults OFF and nothing is analyzed
 * or changed until the user turns it on. Once on, the engine's
 * stored profile (windows + findings + master gains) drives every
 * panel — the waveform, the EQ curves, the activity strip and the
 * findings list are all draws of that data, never re-analysis.
 *
 * A/B compare plays the ORIGINAL and the PROCESSED song through the
 * one standing expo-audio player, swapping sources at the same
 * playhead — and the processed file it plays is the SAME file the
 * editor preview and the export render use (useMixMasterSongUri),
 * so what you hear here is what the export carries. Preview ==
 * export, by construction.
 */

type AbMode = 'original' | 'processed';

/** One EQ chart: 10 band columns against a zero line (cuts below, boosts above). */
function GainChart({
  gainsDb,
  title,
  subtitle,
}: {
  gainsDb: number[];
  title: string;
  subtitle?: string;
}) {
  // Chart geometry: 84px tall, zero line 1/3 down (max boost +3 dB
  // above, max cut −6 dB below — the two stages' real ranges).
  const height = 84;
  const zeroY = 28;
  const aboveH = zeroY;
  const belowH = height - zeroY;
  return (
    <View>
      <View style={styles.chartTitleRow}>
        <Text style={styles.chartTitle}>{title}</Text>
        {subtitle ? <Text style={styles.chartSubtitle}>{subtitle}</Text> : null}
      </View>
      <View style={styles.chartWrap}>
        <View style={styles.chartRow}>
          {gainsDb.map((g, i) => {
            const magnitude = Math.abs(g);
            const barHeight =
              magnitude <= 0.05
                ? 0
                : Math.max(
                    2,
                    g < 0 ? (magnitude / 6) * belowH : (magnitude / 3) * aboveH,
                  );
            const top = g < 0 ? zeroY : zeroY - barHeight;
            return (
              <View key={i} style={styles.chartCol}>
                <View style={[styles.chartTrack, { height }]}>
                  {barHeight > 0 ? (
                    <View
                      style={[
                        styles.chartBar,
                        {
                          top,
                          height: barHeight,
                          backgroundColor: g < 0 ? colors.label : colors.accent,
                        },
                      ]}
                    />
                  ) : null}
                </View>
                <Text style={styles.chartLabel}>{shortBandLabelHz(MM_BAND_CENTERS_HZ[i])}</Text>
              </View>
            );
          })}
        </View>
        <View style={[styles.chartZeroLine, { top: zeroY }]} />
      </View>
    </View>
  );
}

/** One stage's controls: toggle + intensity slider (commits on release). */
function StageSection({
  title,
  hint,
  enabled,
  intensity,
  intensityDraft,
  onToggle,
  onIntensityDraft,
  onIntensityCommit,
  accessibilityLabel,
}: {
  title: string;
  hint: string;
  enabled: boolean;
  intensity: number;
  intensityDraft: number | null;
  onToggle: (enabled: boolean) => void;
  onIntensityDraft: (value: number) => void;
  onIntensityCommit: (value: number) => void;
  accessibilityLabel: string;
}) {
  return (
    <View style={styles.card}>
      <View style={styles.switchRow}>
        <View style={styles.switchText}>
          <Text style={styles.cardTitle}>{title}</Text>
          <Text style={styles.cardHint}>{hint}</Text>
        </View>
        <Switch
          value={enabled}
          onValueChange={onToggle}
          trackColor={{ true: colors.accent, false: colors.elevated }}
          thumbColor={enabled ? colors.onAccent : colors.label}
          accessibilityLabel={accessibilityLabel}
        />
      </View>
      <View pointerEvents={enabled ? 'auto' : 'none'} style={enabled ? undefined : styles.controlDisabled}>
        <View style={styles.sliderLabelRow}>
          <Text style={styles.sliderLabel}>Intensity</Text>
          <Text style={styles.sliderValue}>{Math.round(intensityDraft ?? intensity)}%</Text>
        </View>
        <Slider
          value={intensityDraft ?? intensity}
          minimumValue={0}
          maximumValue={100}
          step={5}
          onValueChange={onIntensityDraft}
          onSlidingComplete={(v) => onIntensityCommit(Math.round(v))}
          minimumTrackTintColor={colors.accent}
          maximumTrackTintColor={colors.elevated}
          thumbTintColor={colors.label}
          accessibilityLabel={`${accessibilityLabel} intensity`}
        />
        <Text style={styles.cardHint}>0% is a flat stage — 100% is the full computed correction.</Text>
      </View>
    </View>
  );
}

export default function MixMasterScreen() {
  const insets = useSafeAreaInsets();
  const studio = useStudio();
  const {
    track,
    mixMasterEnabled,
    setMixMasterEnabled,
    mixMasterStages,
    setMixMasterStages,
    mixMasterSource,
    applyMixMasterTrack,
    restoreMixMasterSource,
  } = studio;

  const trackUri = track?.uri ?? null;
  const trackName = track?.name ?? null;
  const duration = track?.durationSeconds ?? 0;

  // The profile for the current settings (null + not loading while
  // off — no analysis runs until the user turns it on).
  const { profile, loading } = useMixMasterProfile(trackUri, mixMasterEnabled, mixMasterStages);
  // The SAME processed file the editor preview and the export render
  // use — A/B plays it, never a second copy.
  const processedUri = useMixMasterSongUri(trackUri, mixMasterEnabled, mixMasterStages);

  const summary = useMemo(
    () => (profile ? summarizeMixMasterProfile(profile) : null),
    [profile],
  );
  const activityBars = useMemo(
    () => (profile ? mixMasterActivityBars(profile, ACTIVITY_BARS) : []),
    [profile],
  );
  const activityMax = useMemo(
    () => activityBars.reduce((m, v) => Math.max(m, v), 0),
    [activityBars],
  );
  const findings = useMemo(() => {
    if (!profile) return [];
    return [...profile.findings].sort((a, b) => b.cutDb - a.cutDb);
  }, [profile]);

  // ---- A/B player: one expo-audio player, two sources --------------
  const player = useAudioPlayer(trackUri);
  const status = useAudioPlayerStatus(player);
  // The A/B pick is tagged with the track it was made for — a track
  // change derives back to 'original' during render (no effect
  // reset), since the hook swaps the player's source with it.
  const [abState, setAbState] = useState<{ forUri: string | null; mode: AbMode }>({
    forUri: null,
    mode: 'original',
  });
  const abMode = abState.forUri === trackUri ? abState.mode : 'original';
  /** The URI the player is currently holding (replace() is not observable). */
  const playerUriRef = useRef<string | null>(trackUri);
  const playhead = status.currentTime;
  const playheadDuration = status.duration > 0 ? status.duration : duration;

  // Never leave audio playing after the screen unmounts.
  useEffect(() => {
    return () => {
      try {
        player.pause();
      } catch {
        /* player already released */
      }
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // The track changed under us: the hook swaps the source, so the
  // ref follows (the A/B mode derives back to 'original' above).
  useEffect(() => {
    playerUriRef.current = trackUri;
  }, [trackUri]);

  /** Swap the player's source at the same playhead, keeping play state. */
  const swapPlayerSource = async (uri: string) => {
    const wasPlaying = status.playing;
    const pos = player.currentTime;
    try {
      player.replace(uri);
      playerUriRef.current = uri;
      await player.seekTo(Math.min(pos, Math.max(0, playheadDuration - 0.1)));
      if (wasPlaying) player.play();
    } catch {
      /* seek/play failed — the new source is loaded, paused */
    }
  };

  const switchAb = (mode: AbMode) => {
    if (mode === abMode || !trackUri) return;
    const uri = mode === 'processed' ? processedUri : trackUri;
    if (!uri) return;
    setAbState({ forUri: trackUri, mode });
    void swapPlayerSource(uri);
  };

  // A settings change re-renders the processed file: if A/B is
  // sitting on the processed side, follow the new render at the
  // same position instead of playing a stale file.
  const processedUriRef = useRef(processedUri);
  useEffect(() => {
    const previous = processedUriRef.current;
    processedUriRef.current = processedUri;
    if (abMode !== 'processed' || !processedUri || processedUri === previous) return;
    if (playerUriRef.current === processedUri) return;
    void swapPlayerSource(processedUri);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [processedUri]);

  const togglePlay = async () => {
    if (status.playing) {
      player.pause();
      return;
    }
    try {
      if (playheadDuration > 0 && playhead >= playheadDuration - 0.2) {
        await player.seekTo(0);
      }
      player.play();
    } catch {
      /* player released */
    }
  };

  // ---- Waveform: real decoded peaks, same source as the picker ----
  const [loadedBars, setLoadedBars] = useState<{ uri: string; bars: number[] } | null>(null);
  useEffect(() => {
    if (!trackUri || !trackName) return;
    let alive = true;
    void loadTrackPeaks({ uri: trackUri, name: trackName }).then((loaded) => {
      if (alive) setLoadedBars({ uri: trackUri, bars: samplePeaks(loaded, WAVEFORM_BARS) });
    });
    return () => {
      alive = false;
    };
  }, [trackUri, trackName]);
  const bars =
    loadedBars && loadedBars.uri === trackUri
      ? loadedBars.bars
      : standinPeaks(trackName ?? 'track', WAVEFORM_BARS);

  // ---- Intensity drafts (commit on release — a change re-renders) --
  const [correctiveDraft, setCorrectiveDraft] = useState<number | null>(null);
  const [masterDraft, setMasterDraft] = useState<number | null>(null);

  const engineAvailable = isCompositorAvailable();
  const correctiveAtPlayhead = useMemo(
    () => (profile ? mixMasterGainAtTime(profile.windows, playhead) : []),
    [profile, playhead],
  );
  const identicalAb =
    !profile || !summary?.hasCorrections || !processedUri || processedUri === trackUri;

  // ---- Export (Stage 4) -------------------------------------------------
  const [exporting, setExporting] = useState<MixMasterExportFormat | null>(null);
  const [exportNote, setExportNote] = useState<string | null>(null);
  // Exportable only when a processed file exists for the CURRENT
  // settings: a settings change keeps `loading` true until the new
  // render lands, so a tap can never export a stale file — and
  // `identicalAb` covers the song that needs no corrections (the
  // "processed" file IS the original, so there is nothing to save).
  const canExport =
    mixMasterEnabled && !!profile && !loading && !identicalAb && !!processedUri && !!trackUri;

  const runExport = async (format: MixMasterExportFormat) => {
    if (!trackUri || !trackName || !canExport || exporting) return;
    setExporting(format);
    setExportNote(null);
    try {
      const result = await exportMixMasterSongFile(trackUri, trackName, mixMasterStages, format);
      if (!result) {
        setExportNote('Export failed — the processed song could not be written.');
        return;
      }
      const shared = await shareFile(result.uri, mixMasterExportMimeType(format));
      setExportNote(
        shared
          ? `Saved “${result.fileName}” — share sheet opened.`
          : `Saved “${result.fileName}” in Files (MVMT Studio → exports).`,
      );
    } finally {
      setExporting(null);
    }
  };

  /**
   * "Use in project": the track becomes the processed song. A
   * confirm first — it changes the project's song. The track
   * points at the EXPORT copy (a durable file outside the render
   * cache), and the store records the original for Restore.
   */
  const useInProject = () => {
    if (!trackUri || !trackName || !canExport) return;
    Alert.alert(
      'Use processed song in this project?',
      `Your track becomes the Mix & Master version of “${trackName}”. The region, takes, edit and lyrics carry over — it is the same song at the same length. Your original is kept, and you can switch back from this screen.`,
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Use processed song',
          onPress: () => {
            void (async () => {
              const result = await exportMixMasterSongFile(
                trackUri,
                trackName,
                mixMasterStages,
                'wav',
              );
              if (!result) {
                setExportNote('Could not save the processed song — the track was not changed.');
                return;
              }
              applyMixMasterTrack(result.uri, result.fileName);
              setExportNote(
                `Now performing to “${result.fileName}”. The original is kept — tap “Restore original song” to switch back.`,
              );
            })();
          },
        },
      ],
    );
  };

  const restoreOriginal = () => {
    if (!mixMasterSource) return;
    restoreMixMasterSource();
    setExportNote(
      `Back to the original “${mixMasterSource.name}” — Mix & Master is on again.`,
    );
  };

  const playheadPct =
    playheadDuration > 0 ? Math.min(100, Math.max(0, (playhead / playheadDuration) * 100)) : 0;

  return (
    <View style={styles.root}>
      <View style={[styles.header, { paddingTop: insets.top + spacing.sm }]}>
        <Pressable
          style={styles.backButton}
          onPress={() => router.back()}
          accessibilityRole="button"
          accessibilityLabel="Back to Export">
          <Ionicons name="chevron-back" size={24} color={colors.accent} />
          <Text style={styles.backText}>Export</Text>
        </Pressable>
        <Text style={styles.largeTitle}>Mix &amp; Master</Text>
        <Text style={styles.headerSubtitle} numberOfLines={1}>
          {trackName ?? 'No track'}
        </Text>
      </View>

      <ScrollView
        style={styles.scroll}
        contentContainerStyle={[
          styles.scrollContent,
          { paddingBottom: Math.max(insets.bottom, spacing.md) + spacing.xl },
        ]}>
        {!track ? (
          <View style={styles.card}>
            <Text style={styles.cardTitle}>Add a track first</Text>
            <Text style={styles.cardHint}>
              Mix &amp; Master works on the project&apos;s song — pick one, then come back here.
            </Text>
          </View>
        ) : (
          <>
            {/* Master switch — the only control that exists while off. */}
            <View style={styles.card}>
              <View style={styles.switchRow}>
                <View style={styles.switchText}>
                  <Text style={styles.cardTitle}>Mix &amp; Master</Text>
                  <Text style={styles.cardHint}>
                    Dynamic EQ + Master EQ replace Auto EQ while on. Nothing is analyzed or
                    changed until you turn it on.
                  </Text>
                </View>
                <Switch
                  value={mixMasterEnabled}
                  onValueChange={setMixMasterEnabled}
                  trackColor={{ true: colors.accent, false: colors.elevated }}
                  thumbColor={mixMasterEnabled ? colors.onAccent : colors.label}
                  accessibilityLabel="Mix & Master"
                />
              </View>
            </View>

            {/* The original song, kept after "Use in project" — the way back. */}
            {mixMasterSource ? (
              <View style={styles.card}>
                <Text style={styles.cardTitle}>Original song kept</Text>
                <Text style={styles.cardHint}>
                  This project is performing to a Mix &amp; Master render. The original
                  “{mixMasterSource.name}” is untouched.
                </Text>
                <Pressable
                  style={styles.restoreButton}
                  onPress={restoreOriginal}
                  accessibilityRole="button"
                  accessibilityLabel="Restore original song">
                  <Text style={styles.restoreButtonText}>Restore original song</Text>
                </Pressable>
              </View>
            ) : null}

            {!mixMasterEnabled ? (
              <View style={styles.card}>
                <Text style={styles.cardTitle}>What it does</Text>
                <Text style={styles.cardHint}>
                  The song is listened to moment by moment — harsh frequencies (2–8 kHz) and
                  mud (250/500 Hz) are pulled down where they flare up, then the whole-song
                  balance is nudged toward a gentle target. Cuts only in the dynamic stage;
                  the master stage can also lift. The original file is never changed.
                </Text>
              </View>
            ) : loading && !profile ? (
              <View style={styles.card}>
                <View style={styles.progressRow}>
                  <ActivityIndicator color={colors.accent} />
                  <Text style={styles.progressLabel}>Analyzing your song…</Text>
                </View>
                <Text style={styles.cardHint}>
                  The full song is measured before anything plays — this takes a few seconds.
                </Text>
              </View>
            ) : !engineAvailable || !profile ? (
              <View style={styles.card}>
                <Text style={styles.cardTitle}>Couldn&apos;t analyze this song</Text>
                <Text style={styles.cardHint}>
                  {!engineAvailable
                    ? 'Mix & Master needs the native engine — it runs in the sideload build, not in Expo Go.'
                    : 'The song could not be read. The original plays untouched.'}
                </Text>
              </View>
            ) : (
              <>
                {/* Summary */}
                <View style={styles.card}>
                  <Text style={styles.summaryText}>{formatMixMasterSummary(profile)}</Text>
                  {loading ? (
                    <View style={styles.updatingRow}>
                      <ActivityIndicator size="small" color={colors.accent} />
                      <Text style={styles.updatingText}>Updating…</Text>
                    </View>
                  ) : null}
                </View>

                {/* A/B compare */}
                <View style={styles.card}>
                  <Text style={styles.cardTitle}>A/B compare</Text>
                  <Text style={styles.cardHint}>
                    The same playhead, the same player — hear the original against the
                    processed song. This is the file the editor preview and the export use.
                  </Text>
                  <View style={styles.abRow}>
                    <Pressable
                      style={styles.playButton}
                      onPress={() => void togglePlay()}
                      accessibilityRole="button"
                      accessibilityLabel={status.playing ? 'Pause' : 'Play'}>
                      <Ionicons
                        name={status.playing ? 'pause' : 'play'}
                        size={22}
                        color={colors.onAccent}
                      />
                    </Pressable>
                    <View style={styles.abControl}>
                      <SegmentedControl<AbMode>
                        options={[
                          { value: 'original', label: 'Original' },
                          { value: 'processed', label: 'Processed' },
                        ]}
                        value={abMode}
                        onChange={switchAb}
                        accessibilityLabel="A/B compare"
                      />
                      {identicalAb ? (
                        <Text style={styles.abNote}>
                          Original and processed are identical — nothing was corrected.
                        </Text>
                      ) : null}
                    </View>
                  </View>
                  <Text style={styles.timeReadout}>
                    {formatTime(playhead)} / {formatTime(playheadDuration)}
                  </Text>
                </View>

                {/* Waveform + activity */}
                <View style={styles.card}>
                  <Text style={styles.cardTitle}>Waveform</Text>
                  <View style={styles.barWrap}>
                    <View style={styles.bars}>
                      {bars.map((h, i) => (
                        <View key={i} style={[styles.bar, { height: 8 + h * 30 }]} />
                      ))}
                    </View>
                    <View style={[styles.playhead, { left: `${playheadPct}%` }]} />
                  </View>
                  <Text style={styles.cardTitle}>EQ activity over time</Text>
                  <Text style={styles.cardHint}>
                    Where the dynamic EQ is working — taller means a deeper cut in that moment.
                  </Text>
                  <View style={styles.activityWrap}>
                    {activityBars.map((total, i) => (
                      <View
                        key={i}
                        style={[
                          styles.activityBar,
                          {
                            height:
                              activityMax > 0 ? 3 + (total / activityMax) * 25 : 3,
                          },
                        ]}
                      />
                    ))}
                  </View>
                </View>

                {/* EQ curves */}
                <View style={styles.card}>
                  <Text style={styles.cardTitle}>EQ curve</Text>
                  <GainChart
                    gainsDb={correctiveAtPlayhead}
                    title="Dynamic EQ"
                    subtitle={`at ${formatTime(playhead)}`}
                  />
                  <View style={styles.chartGap} />
                  <GainChart
                    gainsDb={profile.masterGainsDb}
                    title="Master EQ"
                    subtitle="whole song"
                  />
                  <Text style={styles.cardHint}>
                    Bars below the line are cuts, above it are boosts. The dynamic curve follows
                    the playhead; the master curve is one static shape for the whole song.
                  </Text>
                </View>

                {/* Findings */}
                <View style={styles.card}>
                  <Text style={styles.cardTitle}>What changed and why</Text>
                  {findings.length === 0 ? (
                    <Text style={styles.cardHint}>
                      No single moment measured harsh or muddy enough to cut.
                    </Text>
                  ) : (
                    <>
                      {findings.slice(0, FINDINGS_SHOWN).map((f, i) => (
                        <Text key={`${f.timeSeconds}-${f.bandHz}-${i}`} style={styles.findingRow}>
                          {formatMixMasterFinding(f)}
                        </Text>
                      ))}
                      {findings.length > FINDINGS_SHOWN ? (
                        <Text style={styles.cardHint}>
                          + {findings.length - FINDINGS_SHOWN} more corrections
                        </Text>
                      ) : null}
                    </>
                  )}
                </View>

                {/* Stages */}
                <StageSection
                  title="Corrective EQ"
                  hint="Pulls down harsh (2–8 kHz) and muddy (250/500 Hz) bands, moment by moment. Cuts only, never boosts."
                  enabled={mixMasterStages.correctiveEnabled}
                  intensity={mixMasterStages.correctiveIntensity}
                  intensityDraft={correctiveDraft}
                  onToggle={(v) => setMixMasterStages({ correctiveEnabled: v })}
                  onIntensityDraft={setCorrectiveDraft}
                  onIntensityCommit={(v) => {
                    setMixMasterStages({ correctiveIntensity: v });
                    setCorrectiveDraft(null);
                  }}
                  accessibilityLabel="Corrective EQ"
                />
                <StageSection
                  title="Master EQ"
                  hint="Broad whole-song balance toward a gentle target — slight low shelf, flat mids, gentle high shelf. Cuts and boosts up to ±3 dB."
                  enabled={mixMasterStages.masterEnabled}
                  intensity={mixMasterStages.masterIntensity}
                  intensityDraft={masterDraft}
                  onToggle={(v) => setMixMasterStages({ masterEnabled: v })}
                  onIntensityDraft={setMasterDraft}
                  onIntensityCommit={(v) => {
                    setMixMasterStages({ masterIntensity: v });
                    setMasterDraft(null);
                  }}
                  accessibilityLabel="Master EQ"
                />

                {/* Export (Stage 4) */}
                <View style={styles.card}>
                  <Text style={styles.cardTitle}>Export the processed song</Text>
                  <Text style={styles.cardHint}>
                    Save the mastered song as its own file — WAV is the full-quality master,
                    AAC is the smaller shareable copy. The original file is never changed.
                  </Text>
                  <View style={styles.exportRow}>
                    <Pressable
                      style={[styles.exportButton, (!canExport || exporting) && styles.buttonDisabled]}
                      disabled={!canExport || exporting !== null}
                      onPress={() => void runExport('wav')}
                      accessibilityRole="button"
                      accessibilityLabel="Export WAV">
                      {exporting === 'wav' ? (
                        <ActivityIndicator size="small" color={colors.label} />
                      ) : (
                        <Text style={styles.exportButtonText}>Export WAV</Text>
                      )}
                    </Pressable>
                    <Pressable
                      style={[styles.exportButton, (!canExport || exporting) && styles.buttonDisabled]}
                      disabled={!canExport || exporting !== null}
                      onPress={() => void runExport('aac')}
                      accessibilityRole="button"
                      accessibilityLabel="Export AAC">
                      {exporting === 'aac' ? (
                        <ActivityIndicator size="small" color={colors.label} />
                      ) : (
                        <Text style={styles.exportButtonText}>Export AAC</Text>
                      )}
                    </Pressable>
                  </View>
                  <Pressable
                    style={[styles.useButton, (!canExport || exporting) && styles.buttonDisabled]}
                    disabled={!canExport || exporting !== null}
                    onPress={useInProject}
                    accessibilityRole="button"
                    accessibilityLabel="Use processed song in this project">
                    <Text style={styles.useButtonText}>Use in this project</Text>
                  </Pressable>
                  {!canExport && !loading ? (
                    <Text style={styles.cardHint}>
                      Nothing to export yet — either the song needs no corrections, or the
                      settings are still updating.
                    </Text>
                  ) : null}
                  {exportNote ? <Text style={styles.exportNote}>{exportNote}</Text> : null}
                </View>

                <Text style={styles.footnote}>
                  The processed song is what the editor preview and export use while Mix &amp;
                  Master is on. Your original file is never changed.
                </Text>
              </>
            )}
          </>
        )}
      </ScrollView>
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
  scroll: { flex: 1 },
  scrollContent: { paddingHorizontal: spacing.xl, gap: spacing.md },

  card: {
    backgroundColor: colors.card,
    borderRadius: radius.lg,
    padding: spacing.lg,
    gap: spacing.sm,
  },
  cardTitle: { ...typeScale.headline, color: colors.label },
  cardHint: { ...typeScale.subhead, color: colors.labelSecondary, lineHeight: 21 },
  summaryText: { ...typeScale.headline, color: colors.label, lineHeight: 23 },
  footnote: { ...typeScale.footnote, color: colors.labelTertiary, lineHeight: 18 },

  switchRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.md },
  switchText: { flex: 1, gap: spacing.xs },
  controlDisabled: { opacity: 0.45 },

  progressRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm },
  progressLabel: { ...typeScale.headline, color: colors.label },
  updatingRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.xs },
  updatingText: { ...typeScale.footnote, color: colors.labelSecondary },

  abRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.md, marginTop: spacing.xs },
  playButton: {
    width: 44,
    height: 44,
    borderRadius: 22,
    backgroundColor: colors.accent,
    alignItems: 'center',
    justifyContent: 'center',
  },
  abControl: { flex: 1, gap: spacing.xs },
  abNote: { ...typeScale.footnote, color: colors.labelTertiary, lineHeight: 18 },
  timeReadout: { ...typeScale.subhead, color: colors.labelSecondary },

  barWrap: { position: 'relative', paddingVertical: spacing.sm },
  bars: { flexDirection: 'row', alignItems: 'center', gap: 2, height: 48 },
  bar: { flex: 1, backgroundColor: colors.label, opacity: 0.75, borderRadius: 1 },
  playhead: {
    position: 'absolute',
    top: 0,
    bottom: 0,
    width: 2,
    backgroundColor: colors.accent,
    borderRadius: 1,
  },
  activityWrap: { flexDirection: 'row', alignItems: 'flex-end', gap: 2, height: 32 },
  activityBar: { flex: 1, backgroundColor: colors.accent, opacity: 0.7, borderRadius: 1 },

  chartTitleRow: { flexDirection: 'row', alignItems: 'baseline', gap: spacing.sm },
  chartTitle: { ...typeScale.headline, color: colors.label },
  chartSubtitle: { ...typeScale.footnote, color: colors.labelSecondary },
  chartGap: { height: spacing.md },
  chartWrap: { position: 'relative', marginTop: spacing.xs },
  chartRow: { flexDirection: 'row', gap: 2 },
  chartCol: { flex: 1, alignItems: 'center', gap: 4 },
  chartTrack: { position: 'relative', width: '100%', backgroundColor: colors.elevated, borderRadius: radius.sm },
  chartBar: { position: 'absolute', left: '18%', right: '18%', borderRadius: 2 },
  chartZeroLine: {
    position: 'absolute',
    left: 0,
    right: 0,
    height: 1,
    backgroundColor: colors.separator,
  },
  chartLabel: { ...typeScale.caption, color: colors.labelTertiary },

  findingRow: { ...typeScale.subhead, color: colors.label, lineHeight: 22 },

  exportRow: { flexDirection: 'row', gap: spacing.sm },
  exportButton: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    minHeight: 44,
    borderRadius: radius.md,
    backgroundColor: colors.elevated,
  },
  exportButtonText: { ...typeScale.headline, color: colors.label },
  useButton: {
    alignItems: 'center',
    justifyContent: 'center',
    minHeight: 44,
    borderRadius: radius.md,
    backgroundColor: colors.accent,
  },
  useButtonText: { ...typeScale.headline, color: colors.onAccent },
  buttonDisabled: { opacity: 0.45 },
  restoreButton: {
    alignItems: 'center',
    justifyContent: 'center',
    minHeight: 44,
    borderRadius: radius.md,
    backgroundColor: colors.elevated,
  },
  restoreButtonText: { ...typeScale.headline, color: colors.label },
  exportNote: { ...typeScale.subhead, color: colors.labelSecondary, lineHeight: 21 },

  sliderLabelRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'baseline' },
  sliderLabel: { ...typeScale.subhead, color: colors.label },
  sliderValue: { ...typeScale.subhead, color: colors.labelSecondary },
});
