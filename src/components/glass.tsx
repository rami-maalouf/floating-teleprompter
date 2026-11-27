import { GlassView, isLiquidGlassAvailable } from 'expo-glass-effect';
import { SymbolView, type SFSymbol } from 'expo-symbols';
import type { ReactNode } from 'react';
import { Pressable, StyleSheet, Text, type StyleProp, type ViewStyle } from 'react-native';

import { colors, radius } from '../theme';

// liquid glass needs ios 26. older systems get a plain dark surface.
const glass = isLiquidGlassAvailable();

export function GlassCard(props: { children: ReactNode; style?: StyleProp<ViewStyle> }) {
  return (
    <GlassView
      colorScheme="dark"
      style={[styles.card, !glass && styles.fallback, props.style]}>
      {props.children}
    </GlassView>
  );
}

export function GlassButton(props: {
  label: string;
  onPress: () => void;
  symbol?: SFSymbol;
  // the main action of the screen
  prominent?: boolean;
  destructive?: boolean;
  disabled?: boolean;
  style?: StyleProp<ViewStyle>;
}) {
  const textColor = props.destructive ? colors.danger : colors.text;
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={props.label}
      accessibilityState={{ disabled: props.disabled }}
      disabled={props.disabled}
      onPress={props.onPress}
      style={[props.style, props.disabled && styles.disabled]}>
      <GlassView
        isInteractive
        colorScheme="dark"
        tintColor={props.prominent ? colors.accent : undefined}
        style={[
          styles.button,
          props.prominent && styles.prominent,
          !glass && (props.prominent ? styles.prominentFallback : styles.fallback),
        ]}>
        {props.symbol ? <SymbolView name={props.symbol} size={17} tintColor={textColor} /> : null}
        <Text style={[styles.buttonText, props.prominent && styles.prominentText, { color: textColor }]}>
          {props.label}
        </Text>
      </GlassView>
    </Pressable>
  );
}

export function GlassIconButton(props: {
  symbol: SFSymbol;
  accessibilityLabel: string;
  onPress: () => void;
  size?: number;
}) {
  const size = props.size ?? 44;
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={props.accessibilityLabel}
      hitSlop={6}
      onPress={props.onPress}>
      <GlassView
        isInteractive
        colorScheme="dark"
        style={[styles.icon, { width: size, height: size }, !glass && styles.fallback]}>
        <SymbolView name={props.symbol} size={size * 0.4} tintColor={colors.text} />
      </GlassView>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  card: {
    borderRadius: radius.card,
    borderCurve: 'continuous',
    overflow: 'hidden',
  },
  fallback: { backgroundColor: colors.surface },
  button: {
    height: 50,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
    paddingHorizontal: 14,
    borderRadius: radius.pill,
  },
  prominent: { height: 54 },
  prominentFallback: { backgroundColor: colors.accent },
  buttonText: { fontSize: 16, fontWeight: '600' },
  prominentText: { fontSize: 17, fontWeight: '700' },
  icon: {
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: radius.pill,
  },
  disabled: { opacity: 0.4 },
});
