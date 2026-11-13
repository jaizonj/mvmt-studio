/**
 * Extra Styles 2.0 — public surface (Phase 2 core engine).
 * Pure modules only: bridge.ts (the native wrappers) is exported
 * from here for app code, but the Node test bundle imports the
 * pure modules directly — bridge.ts pulls in the Expo module and
 * must stay out of the test compile.
 */
export * from './types';
export * from './animation';
export * from './params';
export * from './interpretation';
export * from './catalog';
export * from './automation';
export * from './persistence';
export * from './scene';
export * from './bridge';
