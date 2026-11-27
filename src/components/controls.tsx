import { SymbolView } from 'expo-symbols';
import type { ReactNode } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import { colors, radius, space } from '../theme';

// one row of the settings card: a label on the left, a control on the right
export function SettingRow(props: { label: string; children: ReactNode; first?: boolean }) {
  return (
    <View style={[styles.row, !props.first && styles.rowBorder]}>
      <Text style={styles.rowLabel}>{props.label}</Text>
      {props.children}
    </View>
  );
}

export function Segments<T extends string | number>(props: {
  label: string;
  options: readonly { label: string; value: T }[];
  value: T;
  onChange: (value: T) => void;
}) {
  return (
    <View style={styles.segments}>
      {props.options.map((option) => {
        const selected = option.value === props.value;
        return (
          <Pressable
            key={option.label}
            accessibilityRole="button"
            accessibilityLabel={`${props.label} ${option.label}`}
            accessibilityState={{ selected }}
            onPress={() => props.onChange(option.value)}
            style={[styles.segment, selected && styles.segmentSelected]}>
            <Text style={[styles.segmentText, selected && styles.segmentTextSelected]}>
              {option.label}
            </Text>
          </Pressable>
        );
      })}
    </View>
  );
}

export function Stepper(props: {
  value: string;
  onDecrease: () => void;
  onIncrease: () => void;
  canDecrease: boolean;
  canIncrease: boolean;
}) {
  return (
    <View style={styles.stepper}>
      <Pressable
        accessibilityRole="button"
        accessibilityLabel="Slower"
        disabled={!props.canDecrease}
        hitSlop={8}
        onPress={props.onDecrease}
        style={styles.stepButton}>
        <SymbolView
          name="minus"
          size={14}
          tintColor={props.canDecrease ? colors.text : colors.textFaint}
        />
      </Pressable>
      <Text style={styles.stepValue}>{props.value}</Text>
      <Pressable
        accessibilityRole="button"
        accessibilityLabel="Faster"
        disabled={!props.canIncrease}
        hitSlop={8}
        onPress={props.onIncrease}
        style={styles.stepButton}>
        <SymbolView
          name="plus"
          size={14}
          tintColor={props.canIncrease ? colors.text : colors.textFaint}
        />
      </Pressable>
    </View>
  );
}

const styles = StyleSheet.create({
  row: {
    minHeight: 54,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: space.sm,
    paddingHorizontal: space.md,
  },
  rowBorder: {
    borderTopWidth: StyleSheet.hairlineWidth,
    borderTopColor: colors.separator,
  },
  rowLabel: { color: colors.text, fontSize: 16 },
  segments: {
    flexDirection: 'row',
    height: 34,
    padding: 2,
    borderRadius: radius.control,
    backgroundColor: colors.control,
  },
  segment: {
    minWidth: 44,
    paddingHorizontal: 10,
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: 8,
  },
  segmentSelected: { backgroundColor: colors.controlSelected },
  segmentText: { color: colors.textMuted, fontSize: 14, fontWeight: '600' },
  segmentTextSelected: { color: colors.text },
  stepper: {
    flexDirection: 'row',
    alignItems: 'center',
    height: 34,
    borderRadius: radius.control,
    backgroundColor: colors.control,
  },
  stepButton: { width: 40, height: 34, alignItems: 'center', justifyContent: 'center' },
  stepValue: {
    minWidth: 76,
    textAlign: 'center',
    color: colors.text,
    fontSize: 15,
    fontWeight: '600',
    fontVariant: ['tabular-nums'],
  },
});
