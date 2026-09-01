import { defineConfig } from 'vite'
import { writeFileSync, mkdirSync } from 'node:fs'

// Dev-only config for the offline thumbnail baker (`npm run bake`). Plain HTTP (no WebXR here, so
// no secure-context needed) + a tiny endpoint that writes the posted atlas straight to public/
// thumbs.png — so baking is one click with no download dialog. Not used by the production build.
export default defineConfig({
  server: { host: true, port: 8091 },
  base: './',
  plugins: [
    {
      // Icon / store-art renderer (/icon.html): one PNG per preset into godot/art/candidates/.
      name: 'save-art',
      configureServer(server) {
        server.middlewares.use('/save-art', (req, res) => {
          if (req.method !== 'POST') {
            res.statusCode = 405
            res.end('POST only')
            return
          }
          const raw = new URL(req.url ?? '', 'http://localhost').searchParams.get('name') ?? 'art'
          const name = raw.replace(/[^a-z0-9-]/gi, '').slice(0, 64) || 'art'
          const dir = 'godot/art/candidates'
          mkdirSync(dir, { recursive: true })
          const chunks: Buffer[] = []
          req.on('data', (c: Buffer) => chunks.push(c))
          req.on('end', () => {
            writeFileSync(`${dir}/${name}.png`, Buffer.concat(chunks))
            res.statusCode = 200
            res.end('ok')
          })
        })
      },
    },
    {
      name: 'save-thumbs',
      configureServer(server) {
        server.middlewares.use('/save-thumbs', (req, res) => {
          if (req.method !== 'POST') {
            res.statusCode = 405
            res.end('POST only')
            return
          }
          const chunks: Buffer[] = []
          req.on('data', (c: Buffer) => chunks.push(c))
          req.on('end', () => {
            writeFileSync('public/thumbs.png', Buffer.concat(chunks))
            res.statusCode = 200
            res.end('ok')
          })
        })
      },
    },
  ],
})
