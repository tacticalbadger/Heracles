/// <reference types="node" />
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Builds the note editor for the native Mac app: the same TipTap editor as
// the Electron renderer, as one page the app's web view loads from its own
// bundle. Run with `npm run build:editor`.
export default defineConfig({
  root: 'renderer/editor-host',
  base: './',
  plugins: [react()],
  build: {
    outDir: '../../macos/Sources/HeraclesApp/Resources/editor',
    emptyOutDir: true
  }
});
