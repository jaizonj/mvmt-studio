import { Ionicons } from '@expo/vector-icons';
import { Tabs } from 'expo-router';

import { colors } from '../../theme';

/** Primary navigation: Studio · Projects · Settings (Overhaul IA). */
export default function TabsLayout() {
  return (
    <Tabs
      screenOptions={{
        headerShown: false,
        tabBarStyle: {
          backgroundColor: colors.base,
          borderTopColor: colors.separator,
          borderTopWidth: 1,
        },
        tabBarActiveTintColor: colors.accent,
        tabBarInactiveTintColor: colors.labelTertiary,
        tabBarLabelStyle: { fontSize: 11, fontWeight: '600' },
      }}>
      <Tabs.Screen
        name="index"
        options={{
          title: 'Studio',
          tabBarIcon: ({ focused, size }) => (<Ionicons name="play-circle-outline" size={size} color={focused ? colors.accent : colors.labelTertiary} />),
        }}
      />
      <Tabs.Screen
        name="projects"
        options={{
          title: 'Projects',
          tabBarIcon: ({ focused, size }) => (<Ionicons name="folder-outline" size={size} color={focused ? colors.accent : colors.labelTertiary} />),
        }}
      />
      <Tabs.Screen
        name="settings"
        options={{
          title: 'Settings',
          tabBarIcon: ({ focused, size }) => (<Ionicons name="settings-outline" size={size} color={focused ? colors.accent : colors.labelTertiary} />),
        }}
      />
    </Tabs>
  );
}
