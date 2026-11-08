import { Redirect } from 'expo-router';

/**
 * Legacy route. The separate Edit stage is gone (Jaizon, 2026-11-08):
 * the flow is Record → Takes → Shuffle → Export, and the light editing
 * that remains — switching which take each cut uses — lives on the
 * Shuffle timeline itself. Old links land on Shuffle.
 */
export default function EditorRedirect() {
  return <Redirect href="/shuffle" />;
}
