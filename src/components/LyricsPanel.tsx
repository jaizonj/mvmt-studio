import { Ionicons } from '@expo/vector-icons';
import Slider from '@react-native-community/slider';
import { useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  Pressable,
  ScrollView,
  StyleSheet,
  Switch,
  Text,
  TextInput,
  View,
} from 'react-native';

import { SegmentedControl } from './SegmentedControl';
import { DEFAULT_FPS, framesToSeconds } from '../lib/edl';
import { LYRIC_ANIMATIONS } from '../lib/lyricAnimations';
import { LYRIC_FONTS } from '../lib/lyricFonts';
import {
  defaultLyricStyle,
  groupWhisperSegments,
  mergeLyricLines,
  newLyricLineId,
  splitLineAtWord,
} from '../lib/lyrics';
import { ensureModel, modelState, transcribe } from '../lib/whisper';
import { useStudio } from '../store/StudioContext';
import type { LyricLine } from '../types';
import { colors, formatTime, radius, spacing, type as typeScale } from '../theme';

/**
 * LyricsPanel — the Edit screen's lyrics section (Jaizon, 2026-11-10).
 *
 * Detection is Whisper SMALL on-device, DETECTION ONLY (no lookup):
 * the model (~470MB) downloads on first use, then transcription runs
 * locally. Detected lines land on the SONG timeline (frames) and are
 * edited here line by line: text, ±0.1s / ±1-frame nudges, split,
 * merge, delete, a global shift, and a tap-to-sync mode that stamps
 * line starts from the playing preview. The style half (30+ fonts,
 * 30 animations, colour/stroke/pill/position) writes the project's
 * one LyricStyle; preview (LyricsOverlay) and export (native text
 * layers) render the same resolved payload.
 *
 * Per Jaizon: there is deliberately NO "remove downloaded model"
 * control anywhere — the model UI is state, progress and errors only.
 */

interface LyricsPanelProps {
  /** Song frame that composition frame 0 maps to (the region start). */
  regionStartFrame: number;
  /** Preview playhead, composition seconds. */
  positionSeconds: number;
  isPlaying: boolean;
  onSeek: (compositionSeconds: number) => void;
  onPlay: () => void;
  onPause: () => void;
}

const FRAME_0_1S = Math.round(DEFAULT_FPS * 0.1); // 3 frames at 30fps
const COLOR_SWATCHES = [
  '#F4F1E9',
  '#FFFFFF',
  '#C9F36B',
  '#FFD60A',
  '#FF9F0A',
  '#FF6482',
  '#FF453A',
  '#64D2FF',
  '#BF5AF2',
  '#101114',
];
const PILL_SWATCHES = ['rgba(10,10,12,0.55)', 'rgba(10,10,12,0.8)', '#C9F36B', '#F4F1E9', '#101114'];

/** Words fully before the cursor = index of the first word of the second half. */
function wordIndexAtCursor(text: string, cursor: number): number {
  const re = /\S+/g;
  let match: RegExpExecArray | null;
  let count = 0;
  while ((match = re.exec(text)) !== null) {
    if (match.index + match[0].length <= cursor) count += 1;
    else break;
  }
  return count;
}

function isHexColor(value: string): boolean {
  return /^#[0-9a-fA-F]{6}$/.test(value.trim());
}

export function LyricsPanel({ regionStartFrame, positionSeconds, isPlaying, onSeek, onPlay, onPause }: LyricsPanelProps) {
  const studio = useStudio();
  const { track, lyrics } = studio;
  const lines = lyrics?.lines ?? [];
  const style = lyrics?.style;

  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [syncMode, setSyncMode] = useState(false);
  const [phase, setPhase] = useState<'idle' | 'model' | 'transcribe'>('idle');
  const [progress, setProgress] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [sizeDraft, setSizeDraft] = useState<number | null>(null);
  const [strokeDraft, setStrokeDraft] = useState<number | null>(null);
  const [hexDraft, setHexDraft] = useState('');

  const selectedIndex = lines.findIndex((l) => l.id === selectedId);
  const selected = selectedIndex >= 0 ? lines[selectedIndex] : null;
  const playheadSongFrame = Math.round(positionSeconds * DEFAULT_FPS) + regionStartFrame;
  const compSecondsOf = (songFrame: number) =>
    Math.max(0, framesToSeconds(songFrame - regionStartFrame, DEFAULT_FPS));

  // ---- Detection -----------------------------------------------------
  const runDetect = () => {
    if (!track || phase !== 'idle') return;
    const doRun = async () => {
      setError(null);
      try {
        if (modelState() !== 'ready') {
          setPhase('model');
          setProgress(0);
          await ensureModel(setProgress);
        }
        setPhase('transcribe');
        setProgress(0);
        const segments = await transcribe(track.uri, setProgress);
        const grouped = groupWhisperSegments(segments, DEFAULT_FPS);
        if (grouped.length === 0) {
          studio.setLyrics({ lines: [], style: style ?? defaultLyricStyle() });
          setError('No lyrics were detected in this song — you can add lines by hand below.');
          return;
        }
        studio.setLyrics({ lines: grouped, style: style ?? defaultLyricStyle() });
        studio.setLyricsEnabled(true);
        setSelectedId(grouped[0].id);
      } catch (e) {
        setError(e instanceof Error ? e.message : 'Lyrics detection failed.');
      } finally {
        setPhase('idle');
        setProgress(0);
      }
    };
    if (lines.length > 0) {
      Alert.alert('Replace lyrics?', 'Detecting again replaces the lines you have now.', [
        { text: 'Cancel', style: 'cancel' },
        { text: 'Replace', style: 'destructive', onPress: () => void doRun() },
      ]);
    } else {
      void doRun();
    }
  };

  // ---- Line operations ------------------------------------------------
  const handleSelectLine = (line: LyricLine) => {
    setSelectedId(line.id);
    onSeek(compSecondsOf(line.startFrame));
  };

  const handleNudge = (line: LyricLine, edge: 'start' | 'end', delta: number) => {
    if (edge === 'start') {
      studio.updateLyricLine(line.id, {
        startFrame: Math.max(0, line.startFrame + delta),
        // Timed words travel with the line's start.
        ...(line.words
          ? {
              words: line.words.map((w) => ({
                ...w,
                startFrame: Math.max(0, w.startFrame + delta),
                endFrame: Math.max(1, w.endFrame + delta),
              })),
            }
          : {}),
      });
    } else {
      studio.updateLyricLine(line.id, { endFrame: Math.max(line.startFrame + 1, line.endFrame + delta) });
    }
  };

  const handleSplit = (line: LyricLine, wordIndex: number) => {
    const parts = splitLineAtWord(line, wordIndex);
    if (!parts) return;
    const [a, b] = parts;
    studio.updateLyricLine(a.id, { text: a.text, endFrame: a.endFrame, words: a.words });
    studio.addLyricLine(b);
    setSelectedId(b.id);
  };

  const handleMergeDown = (line: LyricLine) => {
    const index = lines.findIndex((l) => l.id === line.id);
    const next = lines[index + 1];
    if (!next) return;
    const merged = mergeLyricLines(line, next);
    studio.updateLyricLine(line.id, {
      text: merged.text,
      startFrame: merged.startFrame,
      endFrame: merged.endFrame,
      words: merged.words,
    });
    studio.deleteLyricLine(next.id);
  };

  const handleDelete = (line: LyricLine) => {
    Alert.alert('Delete this line?', line.text, [
      { text: 'Cancel', style: 'cancel' },
      {
        text: 'Delete',
        style: 'destructive',
        onPress: () => {
          studio.deleteLyricLine(line.id);
          if (selectedId === line.id) setSelectedId(null);
        },
      },
    ]);
  };

  const handleAddLine = () => {
    const start =
      lines.length > 0 ? Math.max(playheadSongFrame, lines[lines.length - 1].endFrame) : playheadSongFrame;
    const line: LyricLine = {
      id: newLyricLineId(),
      text: 'New line',
      startFrame: start,
      endFrame: start + 2 * DEFAULT_FPS,
    };
    if (!lyrics) studio.setLyrics({ lines: [line], style: defaultLyricStyle() });
    else studio.addLyricLine(line);
    setSelectedId(line.id);
  };

  const handleTapSync = () => {
    if (!selected) {
      const next = lines.find((l) => l.endFrame > playheadSongFrame);
      if (next) setSelectedId(next.id);
      return;
    }
    const frame = playheadSongFrame;
    studio.updateLyricLine(selected.id, {
      startFrame: frame,
      endFrame: Math.max(selected.endFrame, frame + Math.round(DEFAULT_FPS / 2)),
    });
    const following = lines[selectedIndex + 1];
    if (following) setSelectedId(following.id);
  };

  const previewAnimation = (animationId: string) => {
    studio.setLyricStyle({ animationId });
    const target = selected ?? lines[0];
    if (target) {
      onSeek(compSecondsOf(target.startFrame));
      onPlay();
    }
  };

  // ---- Render ----------------------------------------------------------
  return (
    <View style={styles.section}>
      <View style={styles.panel}>
        <View style={styles.titleRow}>
          <Text style={styles.title}>Lyrics</Text>
          {lines.length > 0 ? (
            <Text style={styles.countLabel}>
              {lines.length} line{lines.length === 1 ? '' : 's'}
            </Text>
          ) : null}
        </View>

        {!track ? (
          <Text style={styles.caption}>Load a song first — lyrics are detected from the track itself.</Text>
        ) : (
          <>
            {/* Show/hide — only meaningful once a lyrics object exists. */}
            {lyrics ? (
              <View style={styles.switchRow}>
                <Text style={styles.rowLabel}>Show lyrics on the video</Text>
                <Switch
                  value={studio.lyricsEnabled}
                  onValueChange={studio.setLyricsEnabled}
                  trackColor={{ true: colors.accent, false: colors.elevated }}
                  thumbColor={studio.lyricsEnabled ? colors.onAccent : colors.label}
                  accessibilityLabel="Show lyrics on the video"
                />
              </View>
            ) : null}

            {/* Detection card / progress / error. */}
            {phase !== 'idle' ? (
              <View style={styles.progressBox}>
                <View style={styles.progressRow}>
                  <ActivityIndicator color={colors.accent} />
                  <Text style={styles.progressLabel}>
                    {phase === 'model' ? 'Downloading the Whisper model…' : 'Detecting lyrics on your phone…'}
                    {progress > 0 ? ` ${Math.round(progress * 100)}%` : ''}
                  </Text>
                </View>
                <View style={styles.progressTrack}>
                  <View style={[styles.progressFill, { width: `${Math.round(progress * 100)}%` }]} />
                </View>
              </View>
            ) : (
              <Pressable
                style={styles.detectButton}
                onPress={runDetect}
                accessibilityRole="button"
                accessibilityLabel={lines.length > 0 ? 'Detect lyrics again' : 'Detect lyrics'}>
                <Ionicons name="sparkles" size={18} color={colors.onAccent} />
                <Text style={styles.detectButtonText}>
                  {lines.length > 0 ? 'Detect again' : 'Detect lyrics'}
                </Text>
              </Pressable>
            )}
            {lines.length === 0 && phase === 'idle' ? (
              <Text style={styles.caption}>
                Whisper Small listens to the song on this phone and writes the lines with timings — nothing is
                uploaded. The first detection downloads the model (~470MB, Wi-Fi recommended); after that it works
                offline. Detected lines are a draft: fix any words below.
              </Text>
            ) : null}
            {error ? <Text style={styles.errorText}>{error}</Text> : null}

            {/* Line editor. */}
            {lines.length > 0 ? (
              <>
                <View style={styles.listBox}>
                  {lines.map((line, index) => (
                    <LyricLineRow
                      key={line.id}
                      line={line}
                      index={index}
                      isLast={index === lines.length - 1}
                      selected={line.id === selectedId}
                      playheadSongFrame={playheadSongFrame}
                      onSelect={() => handleSelectLine(line)}
                      onCommitText={(text) => studio.updateLyricLine(line.id, { text })}
                      onNudge={(edge, delta) => handleNudge(line, edge, delta)}
                      onSplit={(wordIndex) => handleSplit(line, wordIndex)}
                      onMergeDown={() => handleMergeDown(line)}
                      onDelete={() => handleDelete(line)}
                    />
                  ))}
                </View>

                <View style={styles.toolRow}>
                  <Pressable style={styles.toolButton} onPress={handleAddLine} accessibilityRole="button">
                    <Ionicons name="add" size={16} color={colors.label} />
                    <Text style={styles.toolButtonText}>Add line</Text>
                  </Pressable>
                  <View style={styles.shiftGroup}>
                    <Text style={styles.shiftLabel}>Shift all</Text>
                    <NudgeButton label="−1s" onPress={() => studio.shiftAllLyrics(-DEFAULT_FPS)} />
                    <NudgeButton label="−0.1s" onPress={() => studio.shiftAllLyrics(-FRAME_0_1S)} />
                    <NudgeButton label="+0.1s" onPress={() => studio.shiftAllLyrics(FRAME_0_1S)} />
                    <NudgeButton label="+1s" onPress={() => studio.shiftAllLyrics(DEFAULT_FPS)} />
                  </View>
                </View>

                {/* Tap-to-sync. */}
                <View style={styles.switchRow}>
                  <View style={styles.switchText}>
                    <Text style={styles.rowLabel}>Tap-to-sync</Text>
                    <Text style={styles.caption}>
                      Play the cut, then tap the big button the moment each line starts — it stamps the selected
                      line and moves to the next.
                    </Text>
                  </View>
                  <Switch
                    value={syncMode}
                    onValueChange={setSyncMode}
                    trackColor={{ true: colors.accent, false: colors.elevated }}
                    thumbColor={syncMode ? colors.onAccent : colors.label}
                    accessibilityLabel="Tap-to-sync mode"
                  />
                </View>
                {syncMode ? (
                  <View style={styles.syncRow}>
                    <Pressable
                      style={styles.syncPlayButton}
                      onPress={() => (isPlaying ? onPause() : onPlay())}
                      accessibilityRole="button"
                      accessibilityLabel={isPlaying ? 'Pause preview' : 'Play preview'}>
                      <Ionicons name={isPlaying ? 'pause' : 'play'} size={20} color={colors.label} />
                    </Pressable>
                    <Pressable
                      style={styles.tapButton}
                      onPress={handleTapSync}
                      accessibilityRole="button"
                      accessibilityLabel="Stamp the selected line at the playhead">
                      <Text style={styles.tapButtonText}>
                        {selected ? `TAP — “${truncate(selected.text, 18)}” starts here` : 'TAP — pick the line'}
                      </Text>
                    </Pressable>
                  </View>
                ) : null}
              </>
            ) : lyrics ? (
              <Pressable style={styles.toolButton} onPress={handleAddLine} accessibilityRole="button">
                <Ionicons name="add" size={16} color={colors.label} />
                <Text style={styles.toolButtonText}>Add a line by hand</Text>
              </Pressable>
            ) : null}

            {/* Style. */}
            {style ? (
              <View style={styles.styleBox}>
                <Text style={styles.panelLabel}>Style</Text>

                <ScrollView horizontal showsHorizontalScrollIndicator={false} style={styles.chipScroll}>
                  <View style={styles.chipRow}>
                    {LYRIC_FONTS.map((font) => {
                      const isCurrent = style.fontId === font.id;
                      return (
                        <Pressable
                          key={font.id}
                          onPress={() => studio.setLyricStyle({ fontId: font.id })}
                          accessibilityRole="button"
                          accessibilityState={{ selected: isCurrent }}
                          accessibilityLabel={`Font ${font.displayName}`}
                          style={[styles.fontChip, isCurrent && styles.chipCurrent]}>
                          <Text
                            style={{
                              fontFamily: font.family,
                              fontWeight: style.bold && font.kind === 'system' ? '700' : '400',
                              fontSize: 15,
                              color: isCurrent ? colors.accent : colors.label,
                            }}>
                            {font.displayName}
                          </Text>
                        </Pressable>
                      );
                    })}
                  </View>
                </ScrollView>

                <View style={styles.switchRow}>
                  <Text style={styles.rowLabel}>Bold</Text>
                  <Switch
                    value={style.bold}
                    onValueChange={(v) => studio.setLyricStyle({ bold: v })}
                    trackColor={{ true: colors.accent, false: colors.elevated }}
                    thumbColor={style.bold ? colors.onAccent : colors.label}
                    accessibilityLabel="Bold lyrics"
                  />
                </View>

                <Text style={styles.fieldLabel}>Size</Text>
                <Slider
                  value={sizeDraft ?? style.sizeRatio}
                  minimumValue={0.04}
                  maximumValue={0.16}
                  step={0.005}
                  onValueChange={setSizeDraft}
                  onSlidingComplete={(v) => {
                    studio.setLyricStyle({ sizeRatio: v });
                    setSizeDraft(null);
                  }}
                  minimumTrackTintColor={colors.accent}
                  maximumTrackTintColor={colors.elevated}
                  thumbTintColor={colors.label}
                  accessibilityLabel="Lyric size"
                />

                <Text style={styles.fieldLabel}>Colour</Text>
                <SwatchRow
                  swatches={COLOR_SWATCHES}
                  value={style.color}
                  onPick={(c) => studio.setLyricStyle({ color: c })}
                />
                <View style={styles.hexRow}>
                  <TextInput
                    value={hexDraft}
                    onChangeText={setHexDraft}
                    placeholder="#RRGGBB"
                    placeholderTextColor={colors.labelTertiary}
                    autoCapitalize="characters"
                    autoCorrect={false}
                    style={styles.hexInput}
                    onSubmitEditing={() => {
                      if (isHexColor(hexDraft)) {
                        studio.setLyricStyle({ color: hexDraft.trim().toUpperCase() });
                        setHexDraft('');
                      }
                    }}
                    accessibilityLabel="Custom lyric colour, hex"
                  />
                  <Pressable
                    style={styles.hexApply}
                    onPress={() => {
                      if (isHexColor(hexDraft)) {
                        studio.setLyricStyle({ color: hexDraft.trim().toUpperCase() });
                        setHexDraft('');
                      }
                    }}
                    accessibilityRole="button">
                    <Text style={styles.hexApplyText}>Apply</Text>
                  </Pressable>
                </View>

                <View style={styles.switchRow}>
                  <Text style={styles.rowLabel}>Outline</Text>
                  <Switch
                    value={!!style.strokeColor}
                    onValueChange={(v) =>
                      studio.setLyricStyle(
                        v
                          ? { strokeColor: '#000000', strokeWidthRatio: style.strokeWidthRatio ?? 0.12 }
                          : { strokeColor: undefined },
                      )
                    }
                    trackColor={{ true: colors.accent, false: colors.elevated }}
                    thumbColor={style.strokeColor ? colors.onAccent : colors.label}
                    accessibilityLabel="Lyric outline"
                  />
                </View>
                {style.strokeColor ? (
                  <>
                    <SwatchRow
                      swatches={COLOR_SWATCHES}
                      value={style.strokeColor}
                      onPick={(c) => studio.setLyricStyle({ strokeColor: c })}
                    />
                    <Slider
                      value={strokeDraft ?? style.strokeWidthRatio ?? 0.12}
                      minimumValue={0.02}
                      maximumValue={0.25}
                      step={0.01}
                      onValueChange={setStrokeDraft}
                      onSlidingComplete={(v) => {
                        studio.setLyricStyle({ strokeWidthRatio: v });
                        setStrokeDraft(null);
                      }}
                      minimumTrackTintColor={colors.accent}
                      maximumTrackTintColor={colors.elevated}
                      thumbTintColor={colors.label}
                      accessibilityLabel="Outline width"
                    />
                  </>
                ) : null}

                <Text style={styles.fieldLabel}>Background</Text>
                <SegmentedControl
                  options={[
                    { value: 'none' as const, label: 'None' },
                    { value: 'pill' as const, label: 'Pill' },
                  ]}
                  value={style.background}
                  onChange={(v) => studio.setLyricStyle({ background: v })}
                  accessibilityLabel="Lyric background"
                />
                {style.background === 'pill' ? (
                  <SwatchRow
                    swatches={PILL_SWATCHES}
                    value={style.backgroundColor ?? 'rgba(10,10,12,0.55)'}
                    onPick={(c) => studio.setLyricStyle({ backgroundColor: c })}
                  />
                ) : null}

                <Text style={styles.fieldLabel}>Position</Text>
                <SegmentedControl
                  options={[
                    { value: 'top' as const, label: 'Top' },
                    { value: 'center' as const, label: 'Center' },
                    { value: 'bottom' as const, label: 'Bottom' },
                  ]}
                  value={style.position}
                  onChange={(v) => studio.setLyricStyle({ position: v })}
                  accessibilityLabel="Lyric position"
                />

                <Text style={styles.fieldLabel}>Animation</Text>
                <View style={styles.animationGrid}>
                  {LYRIC_ANIMATIONS.map((animation) => {
                    const isCurrent = style.animationId === animation.id;
                    return (
                      <Pressable
                        key={animation.id}
                        onPress={() => previewAnimation(animation.id)}
                        accessibilityRole="button"
                        accessibilityState={{ selected: isCurrent }}
                        accessibilityLabel={`Animation ${animation.name}`}
                        style={[styles.animationChip, isCurrent && styles.chipCurrent]}>
                        <Text style={[styles.animationChipText, isCurrent && styles.animationChipTextCurrent]}>
                          {animation.name}
                        </Text>
                      </Pressable>
                    );
                  })}
                </View>
                <Text style={styles.caption}>
                  Tap an animation to preview it on the current line in the player above.
                </Text>
              </View>
            ) : null}
          </>
        )}
      </View>
    </View>
  );
}

function truncate(text: string, max: number): string {
  return text.length > max ? `${text.slice(0, max - 1)}…` : text;
}

function NudgeButton({ label, onPress }: { label: string; onPress: () => void }) {
  return (
    <Pressable style={styles.nudgeButton} onPress={onPress} accessibilityRole="button" accessibilityLabel={label}>
      <Text style={styles.nudgeButtonText}>{label}</Text>
    </Pressable>
  );
}

function SwatchRow({
  swatches,
  value,
  onPick,
}: {
  swatches: string[];
  value: string;
  onPick: (color: string) => void;
}) {
  return (
    <View style={styles.swatchRow}>
      {swatches.map((swatch) => {
        const isCurrent = value.toLowerCase() === swatch.toLowerCase();
        return (
          <Pressable
            key={swatch}
            onPress={() => onPick(swatch)}
            accessibilityRole="button"
            accessibilityState={{ selected: isCurrent }}
            accessibilityLabel={`Colour ${swatch}`}
            style={[
              styles.swatch,
              { backgroundColor: swatch },
              isCurrent && styles.swatchCurrent,
            ]}>
            {isCurrent ? (
              <Ionicons
                name="checkmark"
                size={14}
                color={swatch === '#101114' || swatch.startsWith('rgba(10') ? colors.label : colors.onAccent}
              />
            ) : null}
          </Pressable>
        );
      })}
    </View>
  );
}

/** One editable lyric line. The text field commits on blur/submit;
 *  selecting the row seeks the preview to the line (the panel's job);
 *  the expanded controls appear on the selected row. */
function LyricLineRow({
  line,
  index,
  isLast,
  selected,
  playheadSongFrame,
  onSelect,
  onCommitText,
  onNudge,
  onSplit,
  onMergeDown,
  onDelete,
}: {
  line: LyricLine;
  index: number;
  isLast: boolean;
  selected: boolean;
  playheadSongFrame: number;
  onSelect: () => void;
  onCommitText: (text: string) => void;
  onNudge: (edge: 'start' | 'end', delta: number) => void;
  onSplit: (wordIndex: number) => void;
  onMergeDown: () => void;
  onDelete: () => void;
}) {
  const [draft, setDraft] = useState<string | null>(null);
  const [cursor, setCursor] = useState<number | null>(null);
  const text = draft ?? line.text;
  const isCurrent = playheadSongFrame >= line.startFrame && playheadSongFrame < line.endFrame;

  const commit = () => {
    if (draft !== null && draft !== line.text) onCommitText(draft);
    setDraft(null);
  };

  const splitWordIndex = () => {
    if (cursor !== null) return wordIndexAtCursor(text, cursor);
    const count = line.words?.length ?? text.trim().split(/\s+/).filter(Boolean).length;
    return Math.max(1, Math.floor(count / 2));
  };

  return (
    <View style={[styles.lineRow, selected && styles.lineRowSelected]}>
      <Pressable onPress={onSelect} style={styles.lineHead} accessibilityRole="button" accessibilityLabel={`Line ${index + 1}, starts at ${formatTime(framesToSeconds(line.startFrame, DEFAULT_FPS))}`}>
        <Text style={[styles.lineTime, isCurrent && styles.lineTimeCurrent]}>
          {formatTime(framesToSeconds(line.startFrame, DEFAULT_FPS))} –{' '}
          {formatTime(framesToSeconds(line.endFrame, DEFAULT_FPS))}
        </Text>
        {isCurrent ? <View style={styles.nowDot} /> : null}
        <Ionicons name={selected ? 'chevron-up' : 'chevron-down'} size={15} color={colors.labelTertiary} />
      </Pressable>
      <TextInput
        value={text}
        onChangeText={setDraft}
        onFocus={onSelect}
        onBlur={commit}
        onSubmitEditing={commit}
        onSelectionChange={(e) => setCursor(e.nativeEvent.selection.start)}
        placeholder="Lyric line"
        placeholderTextColor={colors.labelTertiary}
        style={styles.lineInput}
        accessibilityLabel={`Lyric line ${index + 1} text`}
      />
      {selected ? (
        <View style={styles.lineControls}>
          <View style={styles.nudgeGroup}>
            <Text style={styles.nudgeLabel}>Start</Text>
            <NudgeButton label="−0.1s" onPress={() => onNudge('start', -FRAME_0_1S)} />
            <NudgeButton label="−1f" onPress={() => onNudge('start', -1)} />
            <NudgeButton label="+1f" onPress={() => onNudge('start', 1)} />
            <NudgeButton label="+0.1s" onPress={() => onNudge('start', FRAME_0_1S)} />
          </View>
          <View style={styles.nudgeGroup}>
            <Text style={styles.nudgeLabel}>End</Text>
            <NudgeButton label="−0.1s" onPress={() => onNudge('end', -FRAME_0_1S)} />
            <NudgeButton label="−1f" onPress={() => onNudge('end', -1)} />
            <NudgeButton label="+1f" onPress={() => onNudge('end', 1)} />
            <NudgeButton label="+0.1s" onPress={() => onNudge('end', FRAME_0_1S)} />
          </View>
          <View style={styles.lineActions}>
            <Pressable style={styles.lineAction} onPress={() => onSplit(splitWordIndex())} accessibilityRole="button">
              <Ionicons name="cut-outline" size={15} color={colors.label} />
              <Text style={styles.lineActionText}>Split at cursor</Text>
            </Pressable>
            <Pressable
              style={[styles.lineAction, isLast && styles.lineActionDisabled]}
              onPress={onMergeDown}
              disabled={isLast}
              accessibilityRole="button">
              <Ionicons name="git-merge-outline" size={15} color={isLast ? colors.labelTertiary : colors.label} />
              <Text style={[styles.lineActionText, isLast && styles.lineActionTextDisabled]}>Merge down</Text>
            </Pressable>
            <Pressable style={styles.lineAction} onPress={onDelete} accessibilityRole="button">
              <Ionicons name="trash-outline" size={15} color={colors.danger} />
              <Text style={[styles.lineActionText, { color: colors.danger }]}>Delete</Text>
            </Pressable>
          </View>
          <Text style={styles.caption}>
            {line.words
              ? 'Word timings attached — karaoke-style animations use them. Editing the words keeps the timings only if the word count stays the same.'
              : 'No word timings on this line — word animations fall back to whole-line.'}
          </Text>
        </View>
      ) : null}
    </View>
  );
}

const styles = StyleSheet.create({
  section: { paddingHorizontal: spacing.xl, marginTop: spacing.md },
  panel: { gap: spacing.sm },
  titleRow: { flexDirection: 'row', alignItems: 'baseline', gap: spacing.sm },
  title: { ...typeScale.headline, color: colors.label, fontSize: 19 },
  countLabel: { ...typeScale.footnote, color: colors.labelSecondary },
  caption: { ...typeScale.footnote, color: colors.labelSecondary, lineHeight: 18 },
  errorText: { ...typeScale.footnote, color: colors.danger, lineHeight: 18 },
  rowLabel: { ...typeScale.subhead, color: colors.label, flex: 1 },
  switchRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: spacing.md },
  switchText: { flex: 1, gap: 2 },
  detectButton: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
    backgroundColor: colors.accent,
    borderRadius: radius.md,
    paddingVertical: 13,
  },
  detectButtonText: { color: colors.onAccent, ...typeScale.headline },
  progressBox: { gap: spacing.sm, backgroundColor: colors.card, borderRadius: radius.md, padding: spacing.md },
  progressRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm },
  progressLabel: { ...typeScale.footnote, color: colors.label, flex: 1 },
  progressTrack: { height: 5, borderRadius: radius.pill, backgroundColor: colors.elevated, overflow: 'hidden' },
  progressFill: { height: '100%', backgroundColor: colors.accent, borderRadius: radius.pill },
  listBox: { gap: spacing.sm },
  lineRow: {
    backgroundColor: colors.card,
    borderRadius: radius.md,
    padding: spacing.md,
    gap: spacing.xs,
    borderWidth: 1,
    borderColor: 'transparent',
  },
  lineRowSelected: { borderColor: colors.accent },
  lineHead: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm },
  lineTime: { ...typeScale.caption, color: colors.labelSecondary, fontVariant: ['tabular-nums'], flex: 1 },
  lineTimeCurrent: { color: colors.accent },
  nowDot: { width: 7, height: 7, borderRadius: 4, backgroundColor: colors.accent },
  lineInput: {
    ...typeScale.body,
    color: colors.label,
    backgroundColor: colors.elevated,
    borderRadius: radius.sm,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
  },
  lineControls: { gap: spacing.sm, marginTop: spacing.xs },
  nudgeGroup: { flexDirection: 'row', alignItems: 'center', gap: spacing.xs },
  nudgeLabel: { ...typeScale.caption, color: colors.labelSecondary, width: 34 },
  nudgeButton: {
    backgroundColor: colors.elevated,
    borderRadius: radius.sm,
    paddingHorizontal: 10,
    paddingVertical: 6,
  },
  nudgeButtonText: { ...typeScale.caption, color: colors.label, fontVariant: ['tabular-nums'] },
  lineActions: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  lineAction: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 5,
    backgroundColor: colors.elevated,
    borderRadius: radius.pill,
    paddingHorizontal: 11,
    paddingVertical: 7,
  },
  lineActionDisabled: { opacity: 0.45 },
  lineActionText: { ...typeScale.caption, color: colors.label },
  lineActionTextDisabled: { color: colors.labelTertiary },
  toolRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: spacing.sm },
  toolButton: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    backgroundColor: colors.card,
    borderWidth: 1,
    borderColor: colors.separator,
    borderRadius: radius.pill,
    paddingHorizontal: 13,
    paddingVertical: 8,
    alignSelf: 'flex-start',
  },
  toolButtonText: { ...typeScale.subhead, color: colors.label, fontWeight: '600' },
  shiftGroup: { flexDirection: 'row', alignItems: 'center', gap: spacing.xs },
  shiftLabel: { ...typeScale.caption, color: colors.labelSecondary, marginRight: 2 },
  syncRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm },
  syncPlayButton: {
    width: 46,
    height: 46,
    borderRadius: 23,
    backgroundColor: colors.card,
    alignItems: 'center',
    justifyContent: 'center',
  },
  tapButton: {
    flex: 1,
    backgroundColor: colors.accent,
    borderRadius: radius.md,
    paddingVertical: 14,
    alignItems: 'center',
  },
  tapButtonText: { color: colors.onAccent, ...typeScale.headline, textAlign: 'center', paddingHorizontal: spacing.sm },
  styleBox: { gap: spacing.sm, marginTop: spacing.sm },
  panelLabel: { ...typeScale.headline, color: colors.label },
  fieldLabel: { ...typeScale.caption, color: colors.labelSecondary, marginTop: spacing.xs },
  chipScroll: { marginHorizontal: -spacing.xs },
  chipRow: { flexDirection: 'row', gap: spacing.sm, paddingHorizontal: spacing.xs, paddingVertical: 2 },
  fontChip: {
    backgroundColor: colors.card,
    borderWidth: 1,
    borderColor: colors.separator,
    borderRadius: radius.pill,
    paddingHorizontal: 14,
    paddingVertical: 8,
  },
  chipCurrent: { borderColor: colors.accent, borderWidth: 2, backgroundColor: colors.accentDim },
  swatchRow: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  swatch: {
    width: 34,
    height: 34,
    borderRadius: 17,
    borderWidth: 1,
    borderColor: colors.separator,
    alignItems: 'center',
    justifyContent: 'center',
  },
  swatchCurrent: { borderColor: colors.accent, borderWidth: 2 },
  hexRow: { flexDirection: 'row', gap: spacing.sm, alignItems: 'center' },
  hexInput: {
    flex: 1,
    ...typeScale.subhead,
    color: colors.label,
    backgroundColor: colors.elevated,
    borderRadius: radius.sm,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
  },
  hexApply: { backgroundColor: colors.card, borderRadius: radius.sm, paddingHorizontal: 14, paddingVertical: 9 },
  hexApplyText: { ...typeScale.subhead, color: colors.label, fontWeight: '600' },
  animationGrid: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  animationChip: {
    backgroundColor: colors.card,
    borderWidth: 1,
    borderColor: colors.separator,
    borderRadius: radius.pill,
    paddingHorizontal: 12,
    paddingVertical: 8,
  },
  animationChipText: { ...typeScale.caption, color: colors.label },
  animationChipTextCurrent: { color: colors.accent },
});
