import { Pressable, StyleSheet, Text, View } from 'react-native';

import { colors, formatTime, radius, spacing } from '../theme';

export interface TimelineStripClip {
  id: string;
  /** Display label, e.g. "Take 2". */
  label: string;
  /** Played length of this clip in the cut, seconds. */
  lengthSeconds: number;
}

const SEGMENT_COLORS = [
  'rgba(185,167,255,0.85)', // violet
  'rgba(148,233,255,0.85)', // ice blue
  'rgba(255,183,233,0.85)', // pink
  'rgba(162,255,209,0.85)', // mint
];

/**
 * The cut as a timeline: one segment per clip, width proportional to its
 * played length, labelled with its take and duration. It re-renders from
 * the shared timeline state, so after a Shuffle the new arrangement
 * appears here immediately.
 *
 * Interactive (Triller-style): when `onSelectClip` is provided, tapping
 * a segment selects that cut so the user can switch which take it uses;
 * the selected segment gets a white outline.
 */
export function TimelineStrip({
  clips,
  selectedClipId,
  onSelectClip,
}: {
  clips: TimelineStripClip[];
  selectedClipId?: string | null;
  onSelectClip?: (clipId: string) => void;
}) {
  const total = clips.reduce((sum, c) => sum + Math.max(0, c.lengthSeconds), 0);
  if (clips.length === 0 || total <= 0) return null;
  return (
    <View>
      <View style={styles.headerRow}>
        <Text style={styles.title}>Your cut · timeline</Text>
        <Text style={styles.total}>
          {clips.length} clips · {formatTime(total)}
        </Text>
      </View>
      <View style={styles.strip}>
        {clips.map((clip, i) => {
          const selected = selectedClipId === clip.id;
          const segmentStyle = [
            styles.segment,
            { flexGrow: Math.max(0.1, clip.lengthSeconds), backgroundColor: SEGMENT_COLORS[i % SEGMENT_COLORS.length] },
            i > 0 && styles.segmentDivider,
            selected && styles.segmentSelected,
          ];
          const inner = (
            <>
              <Text style={styles.segmentLabel} numberOfLines={1}>
                {clip.label}
              </Text>
              <Text style={styles.segmentTime}>{formatTime(clip.lengthSeconds)}</Text>
            </>
          );
          return onSelectClip ? (
            <Pressable
              key={clip.id}
              style={segmentStyle}
              onPress={() => onSelectClip(clip.id)}
              accessibilityRole="button"
              accessibilityState={{ selected }}
              accessibilityLabel={`${clip.label}, cut ${i + 1}. Tap to switch its take.`}>
              {inner}
            </Pressable>
          ) : (
            <View key={clip.id} style={segmentStyle}>
              {inner}
            </View>
          );
        })}
      </View>
      {onSelectClip ? <Text style={styles.hint}>Tap a cut to switch which take it uses</Text> : null}
    </View>
  );
}

const styles = StyleSheet.create({
  headerRow: {
    flexDirection: 'row',
    alignItems: 'baseline',
    justifyContent: 'space-between',
    marginBottom: spacing.sm,
  },
  title: { color: colors.label, fontSize: 15, fontWeight: '700' },
  total: { color: colors.labelSecondary, fontSize: 13, fontWeight: '500' },
  strip: {
    flexDirection: 'row',
    height: 46,
    borderRadius: radius.md,
    overflow: 'hidden',
    backgroundColor: colors.card,
  },
  segment: {
    flexBasis: 0,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 2,
    minWidth: 26,
  },
  segmentDivider: { borderLeftWidth: 1, borderLeftColor: 'rgba(11,11,16,0.55)' },
  segmentSelected: { borderWidth: 2, borderColor: '#FFFFFF' },
  hint: { color: colors.labelSecondary, fontSize: 12, fontWeight: '500', marginTop: spacing.sm },
  segmentLabel: { color: '#14141F', fontSize: 11, fontWeight: '800' },
  segmentTime: { color: 'rgba(20,20,31,0.75)', fontSize: 10, fontWeight: '600' },
});
