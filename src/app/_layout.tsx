import { Stack } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { GestureHandlerRootView } from 'react-native-gesture-handler';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import { StudioProvider } from '../store/StudioContext';
import { colors } from '../theme';

/**
 * Root layout — Overhaul IA (docs/DESIGN_SYSTEM.md):
 * - `(tabs)`: Studio / Projects / Settings — the app's home level.
 * - `project/*`: the active project's workspace (Record → Editor →
 *   Export; takes live on Record's left rail), pushed over the tabs.
 *   Editing is a workspace, never a permanent tab.
 */
export default function RootLayout() {
  return (
    <GestureHandlerRootView style={{ flex: 1, backgroundColor: colors.base }}>
      <SafeAreaProvider>
        <StudioProvider>
          <StatusBar style="light" />
          <Stack
            screenOptions={{
              headerShown: false,
              contentStyle: { backgroundColor: colors.base },
              animation: 'fade',
            }}>
            <Stack.Screen name="(tabs)" />
            <Stack.Screen name="project/record" />
            <Stack.Screen name="project/editor" options={{ animation: 'slide_from_bottom' }} />
            <Stack.Screen name="project/export" options={{ animation: 'slide_from_bottom' }} />
            <Stack.Screen name="project/mix-master" options={{ animation: 'slide_from_bottom' }} />
            <Stack.Screen name="project/extra-styles" options={{ animation: 'slide_from_bottom' }} />
          </Stack>
        </StudioProvider>
      </SafeAreaProvider>
    </GestureHandlerRootView>
  );
}
