# Gates: forest interaction and mixed-reality ground interior

OWNS: godot/scripts/main.gd, godot/scripts/tree/fractal_tree.gd, godot/scripts/xr/help_card.gd, godot/shaders/ground.gdshader, godot/tools/forest_shot.gd, godot/tools/forest_shot.sh, godot/tools/menu_shot.gd, GATES.md

Scope: point-to-plant forest interaction, right-stick species selection, an explicit room-through-interior ground option, and controls whose mode-specific behavior is visible to the user.

- [x] G0: the completion ledger has mechanically valid runnable outcomes
  CHECK: node .agents/skills/unlazy/scripts/gate-lint.mjs GATES.md
  EXPECT: LINT OK
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/Users/dervish/CascadeProjects/FractalXR; path=7a52069421e2/25 entries; EXPECT=matched; output-sha256=45f2f0b23659d603aebd358a717e9093af5a69c8ff812ab8199510941e171ecc; output-bytes=150

- [x] G1: all native scripts parse and the spatial ground shader compiles
  CHECK: GODOT=godot bash godot/tools/parse_all.sh && GODOT=godot bash godot/tools/shader_check.sh godot/shaders/ground.gdshader
  EXPECT: SHADERCHECK godot/shaders/ground.gdshader params=
  EVIDENCE: exit=0; shell=/bin/sh; cwd=/Users/dervish/CascadeProjects/FractalXR; path=7a52069421e2/25 entries; EXPECT=matched; output-sha256=26a2308f5ff47790cfb7a466058a4f31fdadb7a47f7d08488ca652009fd9c413; output-bytes=174

- [ ] G2: the real main scene can plant a bounded forest and select a tree species
  CHECK: bash godot/tools/forest_shot.sh
  EXPECT: FORESTSHOT PASS
  EVIDENCE: pending

- [ ] G3: the wrist menu render has a coherent app row after the control changes
  CHECK: bash godot/tools/menu_shot.sh
  EXPECT: MENUSHOT flame PASS
  EVIDENCE: pending

- [ ] G4: on Quest, pointing at the floor and pulling the right trigger plants a tree, right-stick X selects a species, and the ground interior room option is judged in passthrough
  EVIDENCE: pending headset verification required
