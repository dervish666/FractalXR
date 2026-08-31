extends RefCounted
class_name PresetLibrary

## Loads data/presets.json, generated from src/flame/presets.ts by
## tools/export-presets.mjs. The TypeScript stays the single source of truth: add a
## preset there, re-run the exporter, and it appears here with no transcription.
##
## Adding a NEW FRACTAL TYPE means adding a section to that JSON (or a sibling file)
## and a FractalSource subclass that knows how to read it. Nothing here needs editing.

const PATH := "res://data/presets.json"
const MAX_TRANSFORMS := 8

var variation_order: PackedStringArray = []
var presets: Array = []
## Curated palettes, for the generator to draw on.
var themes: Array = []
## Distance-estimate genomes: Mandelbulb, Mandelbox, KIFS, quaternion Julia, Sierpinski.
var bulbs: Array = []
## How many of `presets` came from the file. Anything past this was generated at runtime.
var authored := 0
var _serial := 0
var load_error := ""


func load_all() -> bool:
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		load_error = "cannot open %s" % PATH
		return false
	var parsed = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		load_error = "%s is not valid JSON" % PATH
		return false
	variation_order = PackedStringArray(parsed.get("variationOrder", []))
	presets = parsed.get("presets", [])
	themes = parsed.get("themes", [])
	bulbs = parsed.get("bulbs", [])
	authored = presets.size()
	if presets.is_empty():
		load_error = "%s contains no presets" % PATH
		return false
	return true


func count() -> int:
	return presets.size()


func name_at(i: int) -> String:
	return presets[wrapi(i, 0, presets.size())].get("name", "?")


func at(i: int) -> Dictionary:
	return presets[wrapi(i, 0, presets.size())]


## Append a generated genome and return its index. Generated flames join the gallery
## on equal terms, so drift wanders through them and morphs work to and from them
## exactly as they do for the authored ones.
func add(g: Dictionary) -> int:
	presets.append(g)
	return presets.size() - 1


func next_serial() -> int:
	_serial += 1
	return _serial


## Five palette control colours for a preset.
static func palette_of(p: Dictionary) -> Array:
	var out: Array = []
	for c in p.get("palette", []):
		out.append(Vector3(c[0], c[1], c[2]))
	while out.size() < 5:
		out.append(Vector3.ONE)
	return out


static func tone_of(p: Dictionary) -> Dictionary:
	return {
		"exposure": float(p.get("brightness", 0.32)),
		"gamma": float(p.get("gamma", 2.4)),
		"k2": float(p.get("k2", 55.0)),
		"hi_desat": float(p.get("highlightDesat", 0.3)),
		"point_brightness": float(p.get("pointBrightness", 0.9)),
	}
