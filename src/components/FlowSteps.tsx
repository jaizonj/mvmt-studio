import { Ionicons } from '@expo/vector-icons';
import { StyleSheet, Text, View } from 'react-native';

import { colors, radius, spacing } from '../theme';

/**
 * The guided flow — one clean line (Jaizon, 2026-11-08; the separate
 * Edit stage was removed):
 *
 *   Record → Takes → Shuffle → Export
 *
 * Shuffle is where the cut is made AND adjusted: the shuffled timeline
 * sits on the Shuffle screen, and tapping a cut there switches which
 * take it uses. Export needs a non-empty cut and stays locked before
 * anything is recorded. Going back is always allowed; the screens
 * themselves enforce the gating. Settings is NOT a flow step: it's a
 * separate gear sheet for configuration only.
 */
export type FlowStepId = 'record' | 'takes' | 'shuffle' | 'export';
export type FlowStepStatus = 'done' | 'current' | 'locked' | 'ready';

export const FLOW_STEPS: { id: FlowStepId; label: string }[] = [
  { id: 'record', label: 'Record' },
  { id: 'takes', label: 'Takes' },
  { id: 'shuffle', label: 'Shuffle' },
  { id: 'export', label: 'Export' },
];

const RANK: Record<FlowStepId, number> = { record: 0, takes: 1, shuffle: 2, export: 3 };
const NUMBER: Record<FlowStepId, string> = { record: '1', takes: '2', shuffle: '3', export: '4' };

/** Shared gating logic so every screen locks/unlocks identically. */
export function flowStatuses(
  current: FlowStepId,
  takesCount: number,
  cutCount: number,
): Record<FlowStepId, FlowStepStatus> {
  const hasTakes = takesCount > 0;
  const hasCut = cutCount > 0;
  const unlocked: Record<FlowStepId, boolean> = {
    record: true,
    takes: hasTakes,
    shuffle: hasTakes,
    export: hasCut,
  };
  const result = {} as Record<FlowStepId, FlowStepStatus>;
  for (const step of FLOW_STEPS) {
    const id = step.id;
    if (id === current) result[id] = 'current';
    else if (!unlocked[id]) result[id] = 'locked';
    else if (RANK[id] < RANK[current]) result[id] = 'done';
    else result[id] = 'ready';
  }
  return result;
}

function StepDot({ id, statuses }: { id: FlowStepId; statuses: Record<FlowStepId, FlowStepStatus> }) {
  const status = statuses[id];
  const label = FLOW_STEPS.find((s) => s.id === id)!.label;
  return (
    <View style={styles.step}>
      <View
        style={[
          styles.dot,
          status === 'current' && styles.dotCurrent,
          status === 'done' && styles.dotDone,
          status === 'locked' && styles.dotLocked,
        ]}>
        {status === 'done' ? (
          <Ionicons name="checkmark" size={10} color="#14141F" />
        ) : status === 'locked' ? (
          <Ionicons name="lock-closed" size={9} color={colors.labelTertiary} />
        ) : (
          <Text style={[styles.dotNumber, status === 'current' && styles.dotNumberCurrent]}>{NUMBER[id]}</Text>
        )}
      </View>
      <Text style={[styles.label, status === 'current' && styles.labelCurrent, status === 'locked' && styles.labelLocked]}>
        {label}
      </Text>
    </View>
  );
}

export function FlowSteps({
  current,
  takesCount,
  cutCount,
  onDark = false,
}: {
  current: FlowStepId;
  takesCount: number;
  cutCount: number;
  /** Rendered over the camera (dark, translucent pill background). */
  onDark?: boolean;
}) {
  const statuses = flowStatuses(current, takesCount, cutCount);
  return (
    <View
      style={[styles.row, onDark && styles.rowOnDark]}
      accessibilityRole="progressbar"
      accessibilityLabel={`Step: ${FLOW_STEPS.find((s) => s.id === current)?.label} of Record, Takes, Shuffle, Export`}>
      <StepDot id="record" statuses={statuses} />
      <View style={[styles.connector, statuses.takes === 'locked' && styles.connectorLocked]} />
      <StepDot id="takes" statuses={statuses} />
      <View style={[styles.connector, statuses.shuffle === 'locked' && styles.connectorLocked]} />
      <StepDot id="shuffle" statuses={statuses} />
      <View style={[styles.connector, statuses.export === 'locked' && styles.connectorLocked]} />
      <StepDot id="export" statuses={statuses} />
    </View>
  );
}

const styles = StyleSheet.create({
  row: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    justifyContent: 'center',
  },
  rowOnDark: {
    backgroundColor: colors.material,
    borderColor: colors.materialBorder,
    borderWidth: 1,
    borderRadius: radius.pill,
    paddingHorizontal: spacing.md,
    paddingVertical: spacing.sm,
    alignSelf: 'center',
  },
  step: { alignItems: 'center', gap: 3, width: 46 },
  connector: {
    width: 9,
    height: 1,
    backgroundColor: 'rgba(255,255,255,0.4)',
    marginTop: 8,
  },
  connectorLocked: { backgroundColor: 'rgba(255,255,255,0.15)' },
  dot: {
    width: 17,
    height: 17,
    borderRadius: 9,
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.45)',
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: 'transparent',
  },
  dotCurrent: { backgroundColor: '#FFFFFF', borderColor: '#FFFFFF' },
  dotDone: { backgroundColor: colors.accent, borderColor: colors.accent },
  dotLocked: { borderColor: 'rgba(255,255,255,0.18)' },
  dotNumber: { color: colors.labelSecondary, fontSize: 9, fontWeight: '700' },
  dotNumberCurrent: { color: '#14141F' },
  label: { color: colors.labelSecondary, fontSize: 10, fontWeight: '600' },
  labelCurrent: { color: colors.label },
  labelLocked: { color: colors.labelTertiary },
});
