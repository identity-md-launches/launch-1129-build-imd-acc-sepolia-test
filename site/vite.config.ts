import { defineConfig } from 'vite';

// Relative base so the export works from an IPFS gateway subpath or an ENS name.
export default defineConfig({
  base: './',
  build: {
    outDir: '../dist',
    emptyOutDir: true,
    sourcemap: false,
  },
});
