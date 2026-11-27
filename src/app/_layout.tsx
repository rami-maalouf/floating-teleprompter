import { Stack } from 'expo-router';
import { StatusBar } from 'expo-status-bar';

import { colors } from '../theme';

// keep the main screen under the sheets: it holds the frame that floats
export const unstable_settings = {
  anchor: 'index',
};

const sheet = {
  presentation: 'formSheet',
  headerShown: false,
  sheetGrabberVisible: true,
  sheetCornerRadius: 28,
} as const;

export default function Layout() {
  return (
    <>
      <StatusBar style="light" />
      <Stack screenOptions={{ contentStyle: { backgroundColor: colors.background } }}>
        <Stack.Screen name="index" options={{ headerShown: false }} />
        <Stack.Screen
          name="script"
          options={{ ...sheet, sheetAllowedDetents: [0.62, 1], contentStyle: { backgroundColor: 'transparent' } }}
        />
        <Stack.Screen
          name="log"
          options={{ ...sheet, sheetAllowedDetents: [0.5, 1], contentStyle: { backgroundColor: 'transparent' } }}
        />
      </Stack>
    </>
  );
}
