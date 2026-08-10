import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

// Build the SPA into dist/; Firebase Hosting serves it (public → web/dist at
// cutover). The dev server proxies /api and /__ to the deployed dev backend so
// `vite dev` works against real Cloud Functions + Firebase auto-init.
export default defineConfig({
  plugins: [react()],
  build: { outDir: 'dist', emptyOutDir: true },
  server: {
    proxy: {
      '/api': { target: 'https://clingen-cvc-dev.web.app', changeOrigin: true, secure: true },
      '/__': { target: 'https://clingen-cvc-dev.web.app', changeOrigin: true, secure: true }
    }
  }
});
