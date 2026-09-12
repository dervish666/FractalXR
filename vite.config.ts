import { defineConfig } from 'vite'
import basicSsl from '@vitejs/plugin-basic-ssl'
import { cloudflare } from '@cloudflare/vite-plugin'

// HTTPS is required for WebXR (secure context). Two ways to reach the Quest:
//   1. LAN:  open https://<your-mac-LAN-ip>:5173 in the Quest Browser and accept
//            the self-signed cert warning (Advanced -> proceed).
//   2. USB:  `adb reverse tcp:5173 tcp:5173`, then open http://localhost:5173 in
//            the Quest Browser — localhost is a secure context, no cert hassle.
export default defineConfig({
  plugins: [basicSsl(), cloudflare()],
  server: {
    host: true, // expose on LAN
    port: 5173,
    strictPort: true, // the headset loop is `adb reverse tcp:5173`; a silent move to 5174 reads as a broken app
  },
  base: './', // relative paths so static-host deploys work from any subpath
  build: {
    rollupOptions: {
      // zoom.html is a second entry point: the relief zoomer, its own renderer and its own
      // WebXR session, sharing only the shader helpers and the palette with the main app.
      input: { main: 'index.html', zoom: 'zoom.html', splat: 'splat.html' },
    },
  },
})
