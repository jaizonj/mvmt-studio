import { Ionicons } from '@expo/vector-icons';
import Slider from '@react-native-community/slider';
import { useEffect, useMemo, useState, type ReactNode } from 'react';
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
  type TextStyle,
} from 'react-native';

import { LyricsOverlay } from './LyricsOverlay';
import { SegmentedControl } from './SegmentedControl';
import type { CompositeLyrics } from '../lib/compositor';
import { DEFAULT_FPS, framesToSeconds } from '../lib/edl';
import {
  LYRIC_ANIMATION_CATEGORIES,
  PICKER_ANIMATIONS,
  lyricAnimationById,
  type LyricAnimation,
  type LyricAnimationCategory,
} from '../lib/lyricAnimations';
import {
  LYRIC_FONT_CATEGORIES,
  LYRIC_FONTS,
  lyricFontById,
  type LyricFont,
  type LyricFontCategory,
} from '../lib/lyricFonts';
import {
  defaultLyricStyle,
  groupWhisperSegments,
  mergeLyricLines,
  newLyricLineId,
  resolveLyricStyle,
  splitLineAtWord,
} from '../lib/lyrics';
import {
  EXTRA_STYLE_CATEGORIES,
  LYRIC_TEMPLATES,
  resolveLyricDecor,
  type ExtraStyleCategory,
  type LyricTemplate,
} from '../lib/lyricTemplates';
import { ensureModel, modelState, transcribe } from '../lib/whisper';
import { useStudio } from '../store/StudioContext';
import type { LyricLine } from '../types';
import { colors, formatTime, radius, spacing, type as typeScale } from '../theme';

/**
 * LyricsPanel — the Edit screen's lyrics section (Jaizon, 2026-11-10).
 *
 * Detection is Whisper SMALL on-device, DETECTION ONLY (no lookup):
 * the model (~470MB) downloads on first use, then transcription runs
 * locally. The grouper (src/lib/lyrics.ts) decides the lines —
 * pauses, sentence ends and length caps — and they land on the SONG
 * timeline (frames), editable here.
 *
 * Layout: a slim header carries the title, the Detect action and its
 * progress, and the show/hide switch; below it, two tabs.
 * - Lines: the line-by-line editor (text, ±0.1s / ±1-frame nudges,
 *   split, merge, delete, global shift) plus tap-to-sync.
 * - Style: ONE shared style for ALL lines — fonts and animations
 *   in browse categories with search and per-project favorites
 *   (Styles Redesign Stage 1), plus outline, position and the other
 *   global controls. There is no per-line style by design: the
 *   controls are grouped under an "All lines" header so it reads
 *   as global, and every change flows through the one resolved style
 *   into the preview overlay (all lines, immediately) and the export
 *   payload.
 *
 * Per Jaizon: there is deliberately NO "remove downloaded model"
 * control anywhere — the model UI is state, progress and errors only.
 */

/** "+0.37s" / "−0.50s" / "0.00s" readout for the offset drag bar. */
function formatOffsetSeconds(frames: number): string {
  const seconds = frames / DEFAULT_FPS;
  const sign = seconds > 0 ? '+' : seconds < 0 ? '−' : '';
  return `${sign}${Math.abs(seconds).toFixed(2)}s`;
}

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
/** Outline width range (ratio of font size). In the preview overlay
 *  the ratio IS the outline distance in points once multiplied by
 *  the font size — at the default lyric size on a phone-width stage
 *  this range reads as roughly 1pt to 9pt of outline, so the whole
 *  slider travel is visible. The export draws the same ratio as a
 *  real text stroke. */
const STROKE_MIN = 0.03;
const STROKE_MAX = 0.3;
const STROKE_DEFAULT = 0.12;
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

/** Favorites sort to the top of a list; catalog order is kept within each group. */
function favoritesFirst<T extends { id: string }>(items: T[], favoriteIds: string[]): T[] {
  return [...items].sort((a, b) => Number(favoriteIds.includes(b.id)) - Number(favoriteIds.includes(a.id)));
}

/** Horizontal category chips above a picker list (Styles Redesign Stage 1). */
function CategoryChips<T extends string>({
  categories,
  value,
  onChange,
  label,
}: {
  categories: readonly T[];
  value: 'All' | T;
  onChange: (c: 'All' | T) => void;
  label: string;
}) {
  return (
    <ScrollView horizontal showsHorizontalScrollIndicator={false} style={styles.chipScroll}>
      <View style={styles.chipRow}>
        {(['All', ...categories] as ('All' | T)[]).map((c) => {
          const isCurrent = value === c;
          return (
            <Pressable
              key={c}
              onPress={() => onChange(c)}
              accessibilityRole="button"
              accessibilityState={{ selected: isCurrent }}
              accessibilityLabel={`${label} category ${c}`}
              style={[styles.categoryChip, isCurrent && styles.chipCurrent]}>
              <Text style={[styles.categoryChipText, isCurrent && styles.categoryChipTextCurrent]}>{c}</Text>
            </Pressable>
          );
        })}
      </View>
    </ScrollView>
  );
}

/** One picker chip: the label picks the style, the heart favorites it.
 *  Two sibling Pressables (never nested) so a heart tap never also
 *  picks the style. */
function StylePickChip({
  label,
  labelStyle,
  selected,
  favorite,
  onPick,
  onToggleFavorite,
  accessibilityLabel,
}: {
  label: string;
  labelStyle: TextStyle;
  selected: boolean;
  favorite: boolean;
  onPick: () => void;
  onToggleFavorite: () => void;
  accessibilityLabel: string;
}) {
  return (
    <View style={[styles.pickChip, selected && styles.chipCurrent]}>
      <Pressable
        onPress={onPick}
        accessibilityRole="button"
        accessibilityState={{ selected }}
        accessibilityLabel={accessibilityLabel}
        style={styles.pickChipLabel}>
        <Text style={labelStyle}>{label}</Text>
      </Pressable>
      <Pressable
        onPress={onToggleFavorite}
        accessibilityRole="button"
        accessibilityState={{ selected: favorite }}
        accessibilityLabel={`${favorite ? 'Unfavorite' : 'Favorite'} ${label}`}
        hitSlop={6}
        style={styles.pickChipHeart}>
        <Ionicons
          name={favorite ? 'heart' : 'heart-outline'}
          size={14}
          color={favorite ? colors.accent : colors.labelTertiary}
        />
      </Pressable>
    </View>
  );
}

/** A grouped section inside the Style tab (category header + wrapping chips). */
function StyleSection({ title, children }: { title: string; children: ReactNode }) {
  return (
    <View style={styles.styleSection}>
      <Text style={styles.sectionHeader}>{title}</Text>
      {children}
    </View>
  );
}

/** A collapsible group inside the Style tab (Edit consolidation,
 *  2026-11-13 — the Style tab was the worst of the clutter): the
 *  tab's three concerns — Font, Text, Animation — each fold behind
 *  a header showing the current choice, so the tab stops sprawling.
 *  One group open at a time (accordion); while the search box has
 *  text, Font and Animation both stay open so matches are visible.
 *  Everything inside is props-driven, so folding loses no state. */
function StyleGroup({
  title,
  summary,
  open,
  onToggle,
  children,
}: {
  title: string;
  summary?: string;
  open: boolean;
  onToggle: () => void;
  children: ReactNode;
}) {
  return (
    <View style={styles.styleGroup}>
      <Pressable
        style={styles.styleGroupHeader}
        onPress={onToggle}
        accessibilityRole="button"
        accessibilityLabel={`${title} style group`}
        accessibilityState={{ expanded: open }}>
        <Text style={styles.styleGroupTitle}>{title}</Text>
        {summary ? (
          <Text style={styles.styleGroupSummary} numberOfLines={1}>
            {summary}
          </Text>
        ) : null}
        <Ionicons name={open ? 'chevron-up' : 'chevron-down'} size={18} color={colors.labelSecondary} />
      </Pressable>
      {open ? <View style={styles.styleGroupBody}>{children}</View> : null}
    </View>
  );
}

function FontChips({
  fonts,
  currentId,
  bold,
  favoriteIds,
  onPick,
  onToggleFavorite,
}: {
  fonts: LyricFont[];
  currentId: string;
  bold: boolean;
  favoriteIds: string[];
  onPick: (id: string) => void;
  onToggleFavorite: (id: string) => void;
}) {
  return (
    <View style={styles.pickRow}>
      {fonts.map((font) => {
        const isCurrent = currentId === font.id;
        return (
          <StylePickChip
            key={font.id}
            label={font.displayName}
            labelStyle={{
              fontFamily: font.family,
              fontWeight: bold && font.kind === 'system' ? '700' : '400',
              fontSize: 15,
              color: isCurrent ? colors.accent : colors.label,
            }}
            selected={isCurrent}
            favorite={favoriteIds.includes(font.id)}
            onPick={() => onPick(font.id)}
            onToggleFavorite={() => onToggleFavorite(font.id)}
            accessibilityLabel={`Font ${font.displayName}`}
          />
        );
      })}
    </View>
  );
}

function AnimationChips({
  animations,
  currentId,
  favoriteIds,
  onPick,
  onToggleFavorite,
}: {
  animations: LyricAnimation[];
  currentId: string;
  favoriteIds: string[];
  onPick: (id: string) => void;
  onToggleFavorite: (id: string) => void;
}) {
  return (
    <View style={styles.pickRow}>
      {animations.map((animation) => {
        const isCurrent = currentId === animation.id;
        return (
          <StylePickChip
            key={animation.id}
            label={animation.name}
            labelStyle={{
              fontSize: 13,
              color: isCurrent ? colors.accent : colors.label,
            }}
            selected={isCurrent}
            favorite={favoriteIds.includes(animation.id)}
            onPick={() => onPick(animation.id)}
            onToggleFavorite={() => onToggleFavorite(animation.id)}
            accessibilityLabel={`Animation ${animation.name}`}
          />
        );
      })}
    </View>
  );
}

/**
 * Extra tab sample line (Styles Redesign Stage 2): the card preview
 * animates a real sample line through the same `LyricsOverlay` the
 * editor preview uses — no thumbnails, no static mock.
 */
const SAMPLE_TEMPLATE_LINE = {
  text: 'Feel the rhythm tonight',
  startSeconds: 0,
  endSeconds: 2,
  words: [
    { text: 'Feel', startSeconds: 0, endSeconds: 0.4 },
    { text: 'the', startSeconds: 0.4, endSeconds: 0.7 },
    { text: 'rhythm', startSeconds: 0.7, endSeconds: 1.3 },
    { text: 'tonight', startSeconds: 1.3, endSeconds: 2 },
  ],
};

function sampleTemplatePayload(template: LyricTemplate): CompositeLyrics {
  return {
    lines: [SAMPLE_TEMPLATE_LINE],
    style: resolveLyricStyle({ ...defaultLyricStyle(), ...template.style }),
    decor: resolveLyricDecor(template.decor),
  };
}

/**
 * One Extra Style card: a live animated preview of the template
 * (its own 2s loop, driven by an interval — no video needed) over
 * a dark stage, with the name/tagline and a favorite heart. The
 * heart is a sibling Pressable so it never also applies the card.
 */
function TemplateCard({
  template,
  selected,
  favorite,
  onApply,
  onToggleFavorite,
}: {
  template: LyricTemplate;
  selected: boolean;
  favorite: boolean;
  onApply: () => void;
  onToggleFavorite: () => void;
}) {
  const [stageWidth, setStageWidth] = useState(0);
  const [time, setTime] = useState(0);
  useEffect(() => {
    const id = setInterval(() => setTime((t) => (t + 0.12 >= 2 ? 0 : t + 0.12)), 120);
    return () => clearInterval(id);
  }, []);
  const payload = useMemo(() => sampleTemplatePayload(template), [template]);
  return (
    <View style={[styles.templateCard, selected && styles.templateCardSelected]}>
      <Pressable
        onPress={onApply}
        accessibilityRole="button"
        accessibilityState={{ selected }}
        accessibilityLabel={`Apply extra style ${template.name}`}>
        <View style={styles.templateStage} onLayout={(e) => setStageWidth(e.nativeEvent.layout.width)}>
          {stageWidth > 0 ? <LyricsOverlay lyrics={payload} positionSeconds={time} width={stageWidth} /> : null}
        </View>
      </Pressable>
      <View style={styles.templateMeta}>
        <Pressable onPress={onApply} style={{ flex: 1 }} accessibilityRole="button" accessibilityLabel={template.name}>
          <Text style={styles.templateName}>{template.name}</Text>
          <Text style={styles.templateTagline}>{template.tagline}</Text>
        </Pressable>
        <Pressable
          onPress={onToggleFavorite}
          hitSlop={8}
          accessibilityRole="button"
          accessibilityState={{ selected: favorite }}
          accessibilityLabel={`${favorite ? 'Unfavorite' : 'Favorite'} ${template.name}`}>
          <Ionicons name={favorite ? 'heart' : 'heart-outline'} size={20} color={favorite ? colors.accent : colors.labelTertiary} />
        </Pressable>
      </View>
    </View>
  );
}

export function LyricsPanel({
  regionStartFrame,
  positionSeconds,
  isPlaying,
  onSeek,
  onPlay,
  onPause,
  bare,
}: LyricsPanelProps & { bare?: boolean }) {
  const studio = useStudio();
  const { track, lyrics } = studio;
  const lines = lyrics?.lines ?? [];
  const style = lyrics?.style;

  const [tab, setTab] = useState<'lines' | 'style' | 'extra'>('lines');
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [syncMode, setSyncMode] = useState(false);
  const [phase, setPhase] = useState<'idle' | 'model' | 'transcribe'>('idle');
  const [progress, setProgress] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [sizeDraft, setSizeDraft] = useState<number | null>(null);
  const [widthDraft, setWidthDraft] = useState<number | null>(null);
  const [offsetDraft, setOffsetDraft] = useState<number | null>(null);
  const [strokeDraft, setStrokeDraft] = useState<number | null>(null);
  const [nudgeDraft, setNudgeDraft] = useState<number | null>(null);
  const [hexDraft, setHexDraft] = useState('');
  // Style tab: search + category filters (Styles Redesign Stage 1).
  const [styleSearch, setStyleSearch] = useState('');
  const [fontCategory, setFontCategory] = useState<'All' | LyricFontCategory>('All');
  const [animationCategory, setAnimationCategory] = useState<'All' | LyricAnimationCategory>('All');
  // Style tab groups (Edit consolidation, 2026-11-13): Font / Text /
  // Animation fold behind headers showing the current choice.
  const [openStyleGroup, setOpenStyleGroup] = useState<'font' | 'text' | 'animation' | null>('font');
  const toggleStyleGroup = (group: 'font' | 'text' | 'animation') =>
    setOpenStyleGroup((current) => (current === group ? null : group));
  // Extra tab: search + category filters (Styles Redesign Stage 2).
  const [templateSearch, setTemplateSearch] = useState('');
  const [templateCategory, setTemplateCategory] = useState<'All' | ExtraStyleCategory>('All');

  const selectedIndex = lines.findIndex((l) => l.id === selectedId);
  const selected = selectedIndex >= 0 ? lines[selectedIndex] : null;
  const playheadSongFrame = Math.round(positionSeconds * DEFAULT_FPS) + regionStartFrame;
  const compSecondsOf = (songFrame: number) =>
    Math.max(0, framesToSeconds(songFrame - regionStartFrame, DEFAULT_FPS));

  // ---- Style tab derived lists ---------------------------------------
  // The stored ids resolve through the catalogs, so a project styled
  // with an aliased animation still highlights its survivor.
  const favoriteFontIds = lyrics?.favoriteFontIds ?? [];
  const favoriteAnimationIds = lyrics?.favoriteAnimationIds ?? [];
  const effectiveFontId = style ? lyricFontById(style.fontId).id : '';
  const effectiveAnimationId = style ? lyricAnimationById(style.animationId).id : '';
  const styleQuery = styleSearch.trim().toLowerCase();
  const fontMatches = LYRIC_FONTS.filter(
    (f) =>
      (fontCategory === 'All' || f.category === fontCategory) &&
      (styleQuery === '' || f.displayName.toLowerCase().includes(styleQuery)),
  );
  const animationMatches = PICKER_ANIMATIONS.filter(
    (a) =>
      (animationCategory === 'All' || a.category === animationCategory) &&
      (styleQuery === '' || a.name.toLowerCase().includes(styleQuery)),
  );
  // Grouped sections only when browsing everything unfiltered.
  const showFontGroups = fontCategory === 'All' && styleQuery === '';
  const showAnimationGroups = animationCategory === 'All' && styleQuery === '';
  // While searching, Font and Animation both stay open so matches
  // are visible; otherwise one group at a time (accordion).
  const fontOpen = styleQuery !== '' || openStyleGroup === 'font';
  const animationOpen = styleQuery !== '' || openStyleGroup === 'animation';
  const textOpen = openStyleGroup === 'text';
  const textGroupSummary = style
    ? `Size ${Math.round(style.sizeRatio * 100)}% · ${
        style.position.charAt(0).toUpperCase() + style.position.slice(1)
      }`
    : '';
  const favoriteFonts = LYRIC_FONTS.filter((f) => favoriteFontIds.includes(f.id));
  const favoriteAnimations = PICKER_ANIMATIONS.filter((a) => favoriteAnimationIds.includes(a.id));

  // ---- Extra tab derived lists (Styles Redesign Stage 2) ------------
  const favoriteTemplateIds = lyrics?.favoriteTemplateIds ?? [];
  const activeTemplateId = lyrics?.templateId;
  const templateQuery = templateSearch.trim().toLowerCase();
  const templateMatches = LYRIC_TEMPLATES.filter(
    (t) =>
      (templateCategory === 'All' || t.category === templateCategory) &&
      (templateQuery === '' ||
        t.name.toLowerCase().includes(templateQuery) ||
        t.tagline.toLowerCase().includes(templateQuery)),
  );
  const showTemplateGroups = templateCategory === 'All' && templateQuery === '';
  const favoriteTemplates = LYRIC_TEMPLATES.filter((t) => favoriteTemplateIds.includes(t.id));
  const favoritesFirstTemplates = (templates: LyricTemplate[]) => [
    ...templates.filter((t) => favoriteTemplateIds.includes(t.id)),
    ...templates.filter((t) => !favoriteTemplateIds.includes(t.id)),
  ];

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
          // A detection with no real words — annotations only, or
          // nothing at all — is not a result: save nothing, so it
          // can never wipe the lines the project already has. The
          // empty lyrics object is only set for a first detection
          // (no lines yet), where there is nothing to keep.
          if (lines.length === 0) {
            studio.setLyrics({ lines: [], style: style ?? defaultLyricStyle() });
          }
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

  const applyHex = () => {
    if (isHexColor(hexDraft)) {
      studio.setLyricStyle({ color: hexDraft.trim().toUpperCase() });
      setHexDraft('');
    }
  };

  // ---- Render ----------------------------------------------------------
  // `bare` (Edit consolidation, 2026-11-13): embedded in a
  // CollapsibleSection, the section supplies the outer spacing and
  // header — the panel renders without its section wrapper.
  const body = (
    <View style={styles.panel}>
        {/* Slim header: title + count, Detect (or live progress) on
            the right, show/hide switch under it. Always visible,
            whichever tab is open. */}
        <View style={styles.headerRow}>
          {/* When embedded in a CollapsibleSection (Edit
              consolidation, 2026-11-13) the section header already
              carries the title — the panel's own title is skipped,
              but the line count and Detect stay. */}
          {!bare ? <Text style={styles.title}>Lyrics</Text> : null}
          {lines.length > 0 ? (
            <Text style={styles.countLabel}>
              {lines.length} line{lines.length === 1 ? '' : 's'}
            </Text>
          ) : null}
          <View style={styles.headerSpacer} />
          {track ? (
            phase !== 'idle' ? (
              <View style={styles.busyRow}>
                <ActivityIndicator color={colors.accent} size="small" />
                <Text style={styles.busyLabel}>
                  {phase === 'model' ? 'Model' : 'Detecting'}
                  {progress > 0 ? ` ${Math.round(progress * 100)}%` : ''}
                </Text>
              </View>
            ) : (
              <Pressable
                style={styles.detectButton}
                onPress={runDetect}
                accessibilityRole="button"
                accessibilityLabel={lines.length > 0 ? 'Detect lyrics again' : 'Detect lyrics'}>
                <Ionicons name="sparkles" size={15} color={colors.onAccent} />
                <Text style={styles.detectButtonText}>{lines.length > 0 ? 'Detect again' : 'Detect lyrics'}</Text>
              </Pressable>
            )
          ) : null}
        </View>
        {phase !== 'idle' ? (
          <>
            <View style={styles.progressTrack}>
              <View style={[styles.progressFill, { width: `${Math.round(progress * 100)}%` }]} />
            </View>
            <Text style={styles.caption}>
              {phase === 'model'
                ? 'Downloading the Whisper model (~470MB) — it runs on this phone, nothing is uploaded.'
                : 'Listening to the song and writing the lines…'}
            </Text>
          </>
        ) : null}

        {!track ? (
          <Text style={styles.caption}>Load a song first — lyrics are detected from the track itself.</Text>
        ) : (
          <>
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
            {error ? <Text style={styles.errorText}>{error}</Text> : null}
            {lines.length === 0 && phase === 'idle' ? (
              <Text style={styles.caption}>
                Whisper Small listens to the song on this phone and writes the lines with timings — nothing is
                uploaded. The first detection downloads the model (~470MB, Wi-Fi recommended); after that it works
                offline. Detected lines are a draft: fix any words in the Lines tab.
              </Text>
            ) : null}

            <SegmentedControl
              options={[
                { value: 'lines' as const, label: 'Lines' },
                { value: 'style' as const, label: 'Style' },
                { value: 'extra' as const, label: 'Extra' },
              ]}
              value={tab}
              onChange={setTab}
              accessibilityLabel="Lyrics editor tabs"
            />

            {tab === 'lines' ? (
              <>
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

                    {/* Fine-offset drag bar (Jaizon): nudges EVERY line
                        in preview + export without rewriting the
                        authored timings — the "off by half a second"
                        fix. Stored as ProjectLyrics.offsetFrames and
                        applied in buildCompositeLyrics. */}
                    <View style={styles.offsetBox}>
                      <View style={styles.sliderLabelRow}>
                        <Text style={styles.sliderLabel}>Fine offset</Text>
                        <Text style={styles.sliderValue}>
                          {formatOffsetSeconds(offsetDraft ?? studio.lyricsOffsetFrames)}
                        </Text>
                      </View>
                      <Slider
                        value={offsetDraft ?? studio.lyricsOffsetFrames}
                        minimumValue={-45}
                        maximumValue={45}
                        step={1}
                        onValueChange={(v) => {
                          // Live commit: a pick that only saved on
                          // release could be lost entirely (Jaizon:
                          // "the size I pick isn't rendering").
                          setOffsetDraft(v);
                          studio.setLyricsOffset(v);
                        }}
                        onSlidingComplete={() => setOffsetDraft(null)}
                        minimumTrackTintColor={colors.accent}
                        maximumTrackTintColor={colors.elevated}
                        thumbTintColor={colors.label}
                        accessibilityLabel="Lyric fine offset"
                      />
                      <Text style={styles.caption}>
                        Drag to shift all lyrics earlier or later — for when the lines are off by a beat. Preview
                        and export follow; your line timings stay untouched.
                      </Text>
                    </View>

                    {/* Tap-to-sync. */}
                    <View style={styles.switchRow}>
                      <View style={styles.switchText}>
                        <Text style={styles.rowLabel}>Tap-to-sync</Text>
                        <Text style={styles.caption}>
                          Play the cut, then tap the big button the moment each line starts — it stamps the
                          selected line and moves to the next.
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
                ) : (
                  <Text style={styles.caption}>
                    No lines yet — tap Detect lyrics above, or switch to Style once lines exist.
                  </Text>
                )}
              </>
            ) : tab === 'style' ? (
              /* ---- Style tab: ONE style for ALL lines. ---- */
              <>
                {!style ? (
                  <Text style={styles.caption}>
                    No style yet — detect lyrics or add a line first, then set the look here.
                  </Text>
                ) : (
                  <View style={styles.styleBox}>
                    <Text style={styles.groupHeader}>All lines</Text>
                    <Text style={styles.caption}>
                      One style for the whole song. Font, outline, position and animation apply to every line at
                      once — watch the preview above change as you pick.
                    </Text>

                    {/* Search — filters fonts and animations by name. */}
                    <View style={styles.searchRow}>
                      <Ionicons name="search" size={15} color={colors.labelTertiary} />
                      <TextInput
                        value={styleSearch}
                        onChangeText={setStyleSearch}
                        placeholder="Search fonts & animations"
                        placeholderTextColor={colors.labelTertiary}
                        autoCorrect={false}
                        style={styles.searchInput}
                        accessibilityLabel="Search fonts and animations"
                        clearButtonMode="while-editing"
                      />
                    </View>

                    <StyleGroup
                      title="Font"
                      summary={lyricFontById(effectiveFontId).displayName}
                      open={fontOpen}
                      onToggle={() => toggleStyleGroup('font')}>
                    <CategoryChips
                      categories={LYRIC_FONT_CATEGORIES}
                      value={fontCategory}
                      onChange={setFontCategory}
                      label="Font"
                    />
                    {showFontGroups ? (
                      <>
                        {favoriteFonts.length > 0 ? (
                          <StyleSection title="★ Favorites">
                            <FontChips
                              fonts={favoriteFonts}
                              currentId={effectiveFontId}
                              bold={style.bold}
                              favoriteIds={favoriteFontIds}
                              onPick={(id) => studio.setLyricStyle({ fontId: id })}
                              onToggleFavorite={(id) => studio.toggleFavoriteLyricFont(id)}
                            />
                          </StyleSection>
                        ) : null}
                        {LYRIC_FONT_CATEGORIES.map((category) => (
                          <StyleSection key={category} title={category}>
                            <FontChips
                              fonts={favoritesFirst(
                                LYRIC_FONTS.filter((f) => f.category === category),
                                favoriteFontIds,
                              )}
                              currentId={effectiveFontId}
                              bold={style.bold}
                              favoriteIds={favoriteFontIds}
                              onPick={(id) => studio.setLyricStyle({ fontId: id })}
                              onToggleFavorite={(id) => studio.toggleFavoriteLyricFont(id)}
                            />
                          </StyleSection>
                        ))}
                      </>
                    ) : fontMatches.length === 0 ? (
                      <Text style={styles.caption}>No fonts match “{styleSearch.trim()}”.</Text>
                    ) : (
                      <FontChips
                        fonts={favoritesFirst(fontMatches, favoriteFontIds)}
                        currentId={effectiveFontId}
                        bold={style.bold}
                        favoriteIds={favoriteFontIds}
                        onPick={(id) => studio.setLyricStyle({ fontId: id })}
                        onToggleFavorite={(id) => studio.toggleFavoriteLyricFont(id)}
                      />
                    )}
                    </StyleGroup>

                    <StyleGroup
                      title="Text"
                      summary={textGroupSummary}
                      open={textOpen}
                      onToggle={() => toggleStyleGroup('text')}>
                    <View style={styles.sliderLabelRow}>
                      <Text style={styles.sliderLabel}>Size</Text>
                      <Text style={styles.sliderValue}>{Math.round(style.sizeRatio * 100)}%</Text>
                    </View>
                    <Slider
                      value={sizeDraft ?? style.sizeRatio}
                      minimumValue={0.04}
                      maximumValue={0.16}
                      step={0.005}
                      onValueChange={(v) => {
                        // Live commit (see the Fine offset slider):
                        // the pick applies as it moves, never only
                        // on release.
                        setSizeDraft(v);
                        studio.setLyricStyle({ sizeRatio: v });
                      }}
                      onSlidingComplete={() => setSizeDraft(null)}
                      minimumTrackTintColor={colors.accent}
                      maximumTrackTintColor={colors.elevated}
                      thumbTintColor={colors.label}
                      accessibilityLabel="Lyric size"
                    />

                    {/* Width — how wide a line may run before it
                        wraps onto the next row (Jaizon, 2026-11-12:
                        long lines were running off the frame in
                        TikTok/Instagram posts). */}
                    <View style={styles.sliderLabelRow}>
                      <Text style={styles.sliderLabel}>Width</Text>
                      <Text style={styles.sliderValue}>
                        {Math.round((widthDraft ?? style.maxWidthRatio ?? 0.88) * 100)}%
                      </Text>
                    </View>
                    <Slider
                      value={widthDraft ?? style.maxWidthRatio ?? 0.88}
                      minimumValue={0.5}
                      maximumValue={0.9}
                      step={0.01}
                      onValueChange={(v) => {
                        setWidthDraft(v);
                        studio.setLyricStyle({ maxWidthRatio: v });
                      }}
                      onSlidingComplete={() => setWidthDraft(null)}
                      minimumTrackTintColor={colors.accent}
                      maximumTrackTintColor={colors.elevated}
                      thumbTintColor={colors.label}
                      accessibilityLabel="Lyric line width"
                    />
                    <Text style={styles.caption}>
                      Narrower lines wrap sooner — nothing runs off the edges.
                    </Text>

                    <Text style={styles.sliderLabel}>Colour</Text>
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
                        onSubmitEditing={applyHex}
                        accessibilityLabel="Custom lyric colour, hex"
                      />
                      <Pressable style={styles.hexApply} onPress={applyHex} accessibilityRole="button">
                        <Text style={styles.hexApplyText}>Apply</Text>
                      </Pressable>
                    </View>

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

                    {/* Outline — a global, all-lines setting. */}
                    <View style={styles.switchRow}>
                      <Text style={styles.rowLabel}>Outline (all lines)</Text>
                      <Switch
                        value={!!style.strokeColor}
                        onValueChange={(v) =>
                          studio.setLyricStyle(
                            v
                              ? { strokeColor: '#000000', strokeWidthRatio: style.strokeWidthRatio ?? STROKE_DEFAULT }
                              : { strokeColor: undefined },
                          )
                        }
                        trackColor={{ true: colors.accent, false: colors.elevated }}
                        thumbColor={style.strokeColor ? colors.onAccent : colors.label}
                        accessibilityLabel="Lyric outline for all lines"
                      />
                    </View>
                    {style.strokeColor ? (
                      <>
                        <SwatchRow
                          swatches={COLOR_SWATCHES}
                          value={style.strokeColor}
                          onPick={(c) => studio.setLyricStyle({ strokeColor: c })}
                        />
                        <View style={styles.sliderLabelRow}>
                          <Text style={styles.sliderLabel}>Outline width</Text>
                          <Text style={styles.sliderValue}>
                            {(strokeDraft ?? style.strokeWidthRatio ?? STROKE_DEFAULT).toFixed(2)}
                          </Text>
                        </View>
                        <Slider
                          value={strokeDraft ?? style.strokeWidthRatio ?? STROKE_DEFAULT}
                          minimumValue={STROKE_MIN}
                          maximumValue={STROKE_MAX}
                          step={0.01}
                          onValueChange={(v) => {
                            setStrokeDraft(v);
                            studio.setLyricStyle({ strokeWidthRatio: v });
                          }}
                          onSlidingComplete={() => setStrokeDraft(null)}
                          minimumTrackTintColor={colors.accent}
                          maximumTrackTintColor={colors.elevated}
                          thumbTintColor={colors.label}
                          accessibilityLabel="Outline width for all lines"
                        />
                      </>
                    ) : null}

                    <Text style={styles.sliderLabel}>Background</Text>
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

                    {/* Position — also global: it moves every line. */}
                    <Text style={styles.sliderLabel}>Position (all lines)</Text>
                    <SegmentedControl
                      options={[
                        { value: 'top' as const, label: 'Top' },
                        { value: 'center' as const, label: 'Center' },
                        { value: 'bottom' as const, label: 'Bottom' },
                      ]}
                      value={style.position}
                      onChange={(v) => studio.setLyricStyle({ position: v })}
                      accessibilityLabel="Lyric position for all lines"
                    />

                    {/* Vertical nudge — a fine adjustment on top of
                        the Top/Center/Bottom anchor, for every line
                        at once (Jaizon, 2026-11-11). Positive = up. */}
                    <View style={styles.sliderLabelRow}>
                      <Text style={styles.sliderLabel}>Vertical nudge</Text>
                      <Text style={styles.sliderValue}>
                        {(() => {
                          const n = nudgeDraft ?? style.verticalOffsetRatio ?? 0;
                          return n === 0 ? '0%' : `${n > 0 ? '+' : '−'}${Math.abs(Math.round(n * 100))}%`;
                        })()}
                      </Text>
                    </View>
                    <Slider
                      value={nudgeDraft ?? style.verticalOffsetRatio ?? 0}
                      minimumValue={-0.25}
                      maximumValue={0.25}
                      step={0.005}
                      onValueChange={(v) => {
                        setNudgeDraft(v);
                        studio.setLyricStyle({ verticalOffsetRatio: v });
                      }}
                      onSlidingComplete={() => setNudgeDraft(null)}
                      minimumTrackTintColor={colors.accent}
                      maximumTrackTintColor={colors.elevated}
                      thumbTintColor={colors.label}
                      accessibilityLabel="Lyric vertical nudge for all lines"
                    />
                    <Text style={styles.caption}>
                      Slides every line up or down a little from its Top, Center or Bottom spot.
                    </Text>
                    </StyleGroup>

                    <StyleGroup
                      title="Animation"
                      summary={lyricAnimationById(effectiveAnimationId).name}
                      open={animationOpen}
                      onToggle={() => toggleStyleGroup('animation')}>
                    <CategoryChips
                      categories={LYRIC_ANIMATION_CATEGORIES}
                      value={animationCategory}
                      onChange={setAnimationCategory}
                      label="Animation"
                    />
                    {showAnimationGroups ? (
                      <>
                        {favoriteAnimations.length > 0 ? (
                          <StyleSection title="★ Favorites">
                            <AnimationChips
                              animations={favoriteAnimations}
                              currentId={effectiveAnimationId}
                              favoriteIds={favoriteAnimationIds}
                              onPick={previewAnimation}
                              onToggleFavorite={(id) => studio.toggleFavoriteLyricAnimation(id)}
                            />
                          </StyleSection>
                        ) : null}
                        {LYRIC_ANIMATION_CATEGORIES.map((category) => (
                          <StyleSection key={category} title={category}>
                            <AnimationChips
                              animations={favoritesFirst(
                                PICKER_ANIMATIONS.filter((a) => a.category === category),
                                favoriteAnimationIds,
                              )}
                              currentId={effectiveAnimationId}
                              favoriteIds={favoriteAnimationIds}
                              onPick={previewAnimation}
                              onToggleFavorite={(id) => studio.toggleFavoriteLyricAnimation(id)}
                            />
                          </StyleSection>
                        ))}
                      </>
                    ) : animationMatches.length === 0 ? (
                      <Text style={styles.caption}>No animations match “{styleSearch.trim()}”.</Text>
                    ) : (
                      <AnimationChips
                        animations={favoritesFirst(animationMatches, favoriteAnimationIds)}
                        currentId={effectiveAnimationId}
                        favoriteIds={favoriteAnimationIds}
                        onPick={previewAnimation}
                        onToggleFavorite={(id) => studio.toggleFavoriteLyricAnimation(id)}
                      />
                    )}
                    <Text style={styles.caption}>
                      Tap an animation to preview it on the current line in the player above.
                    </Text>
                    </StyleGroup>
                  </View>
                )}
              </>
            ) : (
              /* ---- Extra tab: complete creative templates. ---- */
              <View style={styles.styleBox}>
                <Text style={styles.groupHeader}>Extra Styles</Text>
                <Text style={styles.caption}>
                  A whole look in one tap — typography, colour, animation and decor. Each card shows the style
                  animating a sample line.
                </Text>
                <TextInput
                  style={styles.searchInput}
                  value={templateSearch}
                  onChangeText={setTemplateSearch}
                  placeholder="Search extra styles…"
                  placeholderTextColor={colors.labelTertiary}
                  accessibilityLabel="Search extra styles"
                  returnKeyType="search"
                />
                <CategoryChips
                  categories={EXTRA_STYLE_CATEGORIES}
                  value={templateCategory}
                  onChange={setTemplateCategory}
                  label="Template"
                />
                {showTemplateGroups ? (
                  <>
                    {favoriteTemplates.length > 0 ? (
                      <View style={styles.templateGroup}>
                        <Text style={styles.sectionHeader}>Favorites</Text>
                        {favoriteTemplates.map((template) => (
                          <TemplateCard
                            key={template.id}
                            template={template}
                            selected={activeTemplateId === template.id}
                            favorite
                            onApply={() => studio.setLyricTemplate(template.id)}
                            onToggleFavorite={() => studio.toggleFavoriteLyricTemplate(template.id)}
                          />
                        ))}
                      </View>
                    ) : null}
                    {EXTRA_STYLE_CATEGORIES.map((category) => (
                      <View key={category} style={styles.templateGroup}>
                        <Text style={styles.sectionHeader}>{category}</Text>
                        {favoritesFirstTemplates(LYRIC_TEMPLATES.filter((t) => t.category === category)).map(
                          (template) => (
                            <TemplateCard
                              key={template.id}
                              template={template}
                              selected={activeTemplateId === template.id}
                              favorite={favoriteTemplateIds.includes(template.id)}
                              onApply={() => studio.setLyricTemplate(template.id)}
                              onToggleFavorite={() => studio.toggleFavoriteLyricTemplate(template.id)}
                            />
                          ),
                        )}
                      </View>
                    ))}
                  </>
                ) : templateMatches.length === 0 ? (
                  <Text style={styles.caption}>No extra styles match “{templateSearch.trim()}”.</Text>
                ) : (
                  favoritesFirstTemplates(templateMatches).map((template) => (
                    <TemplateCard
                      key={template.id}
                      template={template}
                      selected={activeTemplateId === template.id}
                      favorite={favoriteTemplateIds.includes(template.id)}
                      onApply={() => studio.setLyricTemplate(template.id)}
                      onToggleFavorite={() => studio.toggleFavoriteLyricTemplate(template.id)}
                    />
                  ))
                )}
                <View style={styles.templateGroup}>
                  <Text style={styles.sectionHeader}>Classic</Text>
                  <Pressable
                    onPress={() => studio.setLyricTemplate(null)}
                    accessibilityRole="button"
                    accessibilityState={{ selected: activeTemplateId === undefined }}
                    accessibilityLabel="Classic style — no extra effects"
                    style={[styles.classicRow, activeTemplateId === undefined && styles.templateCardSelected]}>
                    <View style={{ flex: 1 }}>
                      <Text style={styles.templateName}>Classic</Text>
                      <Text style={styles.templateTagline}>Your current style, no extra effects.</Text>
                    </View>
                    {activeTemplateId === undefined ? (
                      <Ionicons name="checkmark" size={18} color={colors.accent} />
                    ) : null}
                  </Pressable>
                </View>
                <Text style={styles.caption}>
                  Applying a template sets its font, colours and animation too — your lines and timings stay
                  exactly as they are.
                </Text>
              </View>
            )}
          </>
        )}
    </View>
  );
  return bare ? body : <View style={styles.section}>{body}</View>;
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

/** One editable lyric line: a compact header (tabular timing, now
 *  dot, chevron), the text field on top, and — when selected — one
 *  grouped controls block: Start/End nudge rows, then a single icon
 *  row for split / merge / delete. Selecting the row seeks the
 *  preview to the line (the panel's job). */
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
        <Ionicons name={selected ? 'chevron-up' : 'chevron-down'} size={14} color={colors.labelTertiary} />
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
              ? 'Word timings attached — karaoke animations use them. Editing keeps them only if the word count stays the same.'
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
  headerRow: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm },
  headerSpacer: { flex: 1 },
  title: { ...typeScale.headline, color: colors.label, fontSize: 19 },
  countLabel: { ...typeScale.footnote, color: colors.labelSecondary, fontVariant: ['tabular-nums'] },
  busyRow: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  busyLabel: { ...typeScale.caption, color: colors.labelSecondary, fontVariant: ['tabular-nums'] },
  caption: { ...typeScale.footnote, color: colors.labelSecondary, lineHeight: 18 },
  errorText: { ...typeScale.footnote, color: colors.danger, lineHeight: 18 },
  rowLabel: { ...typeScale.subhead, color: colors.label, flex: 1 },
  switchRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: spacing.md },
  switchText: { flex: 1, gap: 2 },
  detectButton: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    backgroundColor: colors.accent,
    borderRadius: radius.pill,
    paddingHorizontal: 13,
    paddingVertical: 8,
  },
  detectButtonText: { color: colors.onAccent, ...typeScale.subhead, fontWeight: '600' },
  progressTrack: { height: 4, borderRadius: radius.pill, backgroundColor: colors.elevated, overflow: 'hidden' },
  progressFill: { height: '100%', backgroundColor: colors.accent, borderRadius: radius.pill },
  listBox: { gap: spacing.sm },
  lineRow: {
    backgroundColor: colors.card,
    borderRadius: radius.md,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    gap: 6,
    borderWidth: 1,
    borderColor: 'transparent',
  },
  lineRowSelected: { borderColor: colors.accent, backgroundColor: colors.elevated },
  lineHead: { flexDirection: 'row', alignItems: 'center', gap: spacing.sm, minHeight: 18 },
  lineTime: { ...typeScale.caption, color: colors.labelSecondary, fontVariant: ['tabular-nums'], flex: 1 },
  lineTimeCurrent: { color: colors.accent },
  nowDot: { width: 7, height: 7, borderRadius: 4, backgroundColor: colors.accent },
  lineInput: {
    ...typeScale.body,
    color: colors.label,
    // Darker than both row surfaces (card, and elevated when the row
    // is selected) so the field always reads as an inset.
    backgroundColor: colors.base,
    borderRadius: radius.sm,
    paddingHorizontal: spacing.sm,
    paddingVertical: 6,
  },
  lineControls: { gap: spacing.sm, marginTop: 2 },
  nudgeGroup: { flexDirection: 'row', alignItems: 'center', gap: spacing.xs },
  nudgeLabel: { ...typeScale.caption, color: colors.labelSecondary, width: 34 },
  nudgeButton: {
    backgroundColor: colors.card,
    borderRadius: radius.sm,
    paddingHorizontal: 9,
    paddingVertical: 5,
  },
  nudgeButtonText: { ...typeScale.caption, color: colors.label, fontVariant: ['tabular-nums'] },
  lineActions: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  lineAction: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 5,
    backgroundColor: colors.card,
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
  offsetBox: { marginTop: spacing.md, gap: spacing.xs },
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
  styleBox: { gap: spacing.sm },
  groupHeader: { ...typeScale.headline, color: colors.label },
  sliderLabelRow: { flexDirection: 'row', alignItems: 'baseline', justifyContent: 'space-between' },
  sliderLabel: { ...typeScale.subhead, color: colors.label },
  sliderValue: { ...typeScale.caption, color: colors.labelSecondary, fontVariant: ['tabular-nums'] },
  chipScroll: { marginHorizontal: -spacing.xs },
  // alignItems center: font families have wildly different intrinsic
  // line heights (Zapfino, Party LET) — with the default stretch, one
  // tall line box stretched EVERY chip and the labels sat at the top
  // of oversized pills (Jaizon, 2026-11-10: "put the fonts in the
  // middle"). Each chip now hugs its own label, centred both ways.
  chipRow: {
    flexDirection: 'row',
    gap: spacing.sm,
    paddingHorizontal: spacing.xs,
    paddingVertical: 2,
    alignItems: 'center',
  },
  chipCurrent: { borderColor: colors.accent, borderWidth: 2, backgroundColor: colors.accentDim },
  searchRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    backgroundColor: colors.elevated,
    borderRadius: radius.sm,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
  },
  searchInput: { flex: 1, ...typeScale.subhead, color: colors.label },
  categoryChip: {
    backgroundColor: colors.card,
    borderWidth: 1,
    borderColor: colors.separator,
    borderRadius: radius.pill,
    paddingHorizontal: 12,
    paddingVertical: 7,
    alignItems: 'center',
    justifyContent: 'center',
  },
  categoryChipText: { ...typeScale.caption, color: colors.label },
  categoryChipTextCurrent: { color: colors.accent },
  styleSection: { gap: spacing.xs },
  sectionHeader: { ...typeScale.subhead, color: colors.label, fontWeight: '600', marginTop: spacing.xs },
  // Collapsible Style tab groups (Edit consolidation, 2026-11-13):
  // a card header carrying the group name + current choice.
  styleGroup: { gap: spacing.xs },
  styleGroupHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    backgroundColor: colors.card,
    borderRadius: radius.md,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    minHeight: 48,
  },
  styleGroupTitle: { ...typeScale.subhead, color: colors.label, fontWeight: '600' },
  styleGroupSummary: { ...typeScale.footnote, color: colors.labelSecondary, flex: 1, textAlign: 'right' },
  styleGroupBody: { gap: spacing.sm, marginTop: spacing.sm },
  pickRow: { flexDirection: 'row', flexWrap: 'wrap', gap: spacing.sm },
  // One picker chip: label button + heart button side by side in a
  // pill, so a heart tap never also picks the style.
  pickChip: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: colors.card,
    borderWidth: 1,
    borderColor: colors.separator,
    borderRadius: radius.pill,
    paddingLeft: 12,
    paddingRight: 6,
    paddingVertical: 5,
  },
  // Extra Styles cards (Styles Redesign Stage 2): one vertical card
  // per template — a live animated preview stage on top, name/tagline
  // and a heart below. The stage is a dark video-like surface; the
  // overlay inside it is the real renderer, not a thumbnail.
  templateGroup: { gap: spacing.xs },
  templateCard: {
    backgroundColor: colors.card,
    borderRadius: radius.md,
    borderWidth: 2,
    borderColor: 'transparent',
    overflow: 'hidden',
  },
  templateCardSelected: { borderColor: colors.accent },
  templateStage: {
    height: 120,
    backgroundColor: '#17171C',
    overflow: 'hidden',
  },
  templateMeta: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
  },
  templateName: { ...typeScale.subhead, color: colors.label, fontWeight: '600' },
  templateTagline: { ...typeScale.caption, color: colors.labelSecondary },
  classicRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: spacing.sm,
    backgroundColor: colors.card,
    borderRadius: radius.md,
    borderWidth: 2,
    borderColor: 'transparent',
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
  },
  pickChipLabel: { paddingVertical: 3, paddingRight: 4 },
  pickChipHeart: { padding: 4 },
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
});
