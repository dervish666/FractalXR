// Generate godot/data/presets.json from src/flame/presets.ts.
//
// The TypeScript stays the single source of truth for genomes and palettes: add a
// preset there, re-run this, and the Godot build picks it up with no transcription
// and no chance of the two drifting.
//
//   node tools/export-presets.mjs
import { execFileSync } from 'node:child_process'
import { mkdtempSync, writeFileSync, mkdirSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const tmp = mkdtempSync(join(tmpdir(), 'fx-presets-'))
const bundle = join(tmp, 'presets.mjs')

// esbuild ships with vite; it resolves the extensionless TS imports that plain node cannot.
execFileSync('npx', ['esbuild', join(root, 'src/flame/presets.ts'),
  '--bundle', '--format=esm', '--platform=node', `--outfile=${bundle}`],
  { cwd: root, stdio: ['ignore', 'ignore', 'inherit'] })

const { GALLERY } = await import(bundle)
// Themes travel too: the generator picks a curated palette 60% of the time, and a
// cohesive palette beats a random one more often than not.
const themesBundle = join(tmp, 'palettes.mjs')
execFileSync('npx', ['esbuild', join(root, 'src/flame/palettes.ts'),
  '--bundle', '--format=esm', '--platform=node', `--outfile=${themesBundle}`],
  { cwd: root, stdio: ['ignore', 'ignore', 'inherit'] })
const { THEMES } = await import(themesBundle)

// Distance-estimate genomes (Mandelbulb, Mandelbox, KIFS, quaternion Julia, Sierpinski).
// Their "breath" fields are what animate the surface over time, which is the thing that
// makes a bulb feel alive rather than like a static model.
const bulbsBundle = join(tmp, 'bulbs.mjs')
execFileSync('npx', ['esbuild', join(root, 'src/flame/bulbs.ts'),
  '--bundle', '--format=esm', '--platform=node', `--outfile=${bulbsBundle}`],
  { cwd: root, stdio: ['ignore', 'ignore', 'inherit'] })
const { BULB_GALLERY } = await import(bulbsBundle)

// Variation order is load-bearing and lives in src/flame/types.ts. Re-derive it from a
// genome's variation record rather than hardcoding it here, so a new variation added
// upstream flows through without editing this script.
const order = Object.keys(GALLERY[0].transforms[0].variations)

const out = {
  _generated: 'tools/export-presets.mjs from src/flame/presets.ts — do not edit by hand',
  variationOrder: order,
  themes: THEMES.map((t) => t.colors),
  bulbs: BULB_GALLERY,
  presets: GALLERY.map((g) => ({
    name: g.name,
    brightness: g.brightness,
    gamma: g.gamma,
    k2: g.k2,
    highlightDesat: g.highlightDesat,
    pointBrightness: g.pointBrightness,
    palette: g.palette,
    transforms: g.transforms.map((t) => ({
      rowX: t.rowX, rowY: t.rowY, rowZ: t.rowZ, translate: t.translate,
      weight: t.weight, colorIndex: t.colorIndex,
      variations: order.map((n) => t.variations[n] ?? 0),
    })),
  })),
}

mkdirSync(join(root, 'godot/data'), { recursive: true })
writeFileSync(join(root, 'godot/data/presets.json'), JSON.stringify(out, null, 1))
console.log(`wrote godot/data/presets.json - ${out.presets.length} flames, ${out.bulbs.length} bulbs, ${out.themes.length} themes`)
console.log(`variation order: ${order.join(', ')}`)
