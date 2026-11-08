import { Stack } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { GestureHandlerRootView } from 'react-native-gesture-handler';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import { StudioProvider } from '../store/StudioContext';
import { colors } from '../theme';

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
            {/* The guided flow: index (Record) → takes → shuffle → export.
                `editor` is kept only as a legacy redirect to /shuffle. */}
            <Stack.Screen name="index" />
            <Stack.Screen name="takes" options={{ animation: 'slide_from_bottom' }} />
            <Stack.Screen name="shuffle" options={{ animation: 'slide_from_bottom' }} />
            <Stack.Screen name="export" options={{ animation: 'slide_from_bottom' }} />
            <Stack.Screen name="editor" options={{ animation: 'slide_from_bottom' }} />
          </Stack>
        </StudioProvider>
      </SafeAreaProvider>
    </GestureHandlerRootView>
  );
}
