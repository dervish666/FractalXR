import { defineConfig } from 'vite'
import basicSsl from '@vitejs/plugin-basic-ssl'

// HTTPS is required for WebXR (secure context). Two ways to reach the Quest:
//   1. LAN:  open https://<your-mac-LAN-ip>:5173 in the Quest Browser and accept
//            the self-signed cert warning (Advanced -> proceed).
//   2. USB:  `adb reverse tcp:5173 tcp:5173`, then open http://localhost:5173 in
//            the Quest Browser — localhost is a secure context, no cert hassle.
export default defineConfig({
  plugins: [basicSsl()],
  server: {
    host: true, // expose on LAN
    port: 5173,
  },
  base: './', // relative paths so static-host deploys work from any subpath
})
