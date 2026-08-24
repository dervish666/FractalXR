import { defineConfig } from 'vite'
// dev-verify ONLY (plain HTTP, no self-signed cert so Claude-in-Chrome can attach). Not for Quest — WebXR needs HTTPS.
export default defineConfig({ server: { host: true, port: 5180 }, base: './' })
