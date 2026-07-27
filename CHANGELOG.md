# Changelog

## Unreleased

- Added deterministic terrain primitives for rolling hills, canyons, craters,
  mountains, mountain ranges, and volcanoes.
- Retired the experimental `ridged`, `craterfield`, `plates`, `dunesea`,
  `mountainside`, `ridge`, `rugged`, `slump`, and `uplift` generators. Legacy
  graphs using those node types now fail with an explicit unknown-node
  diagnostic. The independent `erosionfilter.ridge` analysis output remains
  available.
- Open the interactive viewer in windowed fullscreen by default, filling the
  display's visible work area while preserving the title bar and window controls.
- Made typed multi-output authoring explicit in the viewer with named input
  ports, field-colored sockets and wires, compatibility guidance, guarded
  connection drops, direct secondary-output preview, and a compatible-node
  picker when a connection is dropped on empty canvas. Port names now use the
  canonical `terrain`, `mask`, and `field` vocabulary, while legacy `height`
  references migrate transparently. Contextual suggestions are ranked by the
  selected output's purpose, and the picker stays above canvas controls.
- Unified right-click and connection-drop node selection into the same compact,
  searchable window, anchored it away from existing nodes, and replaced
  duplicate id/type captions with a single readable node title and type icon.
  The picker now follows both pointer axes, keeps the pending connector visible,
  supports Command-A in search, and limits its viewport instead of expanding
  through the full node catalog.

## 0.12.0-alpha.1

- Added the `fluvial` landscape-evolution node with drainage-area-driven
  stream-power incision, sediment deposition, nonlinear hillslope transport,
  and a named flow-accumulation output.
- Made slope-sensitive terrain processes use resolution-independent ground
  spacing, keeping slope masks, thermal erosion, hydraulic erosion, and
  other slope-derived outputs consistent across authoring and export
  resolutions.
- Corrected nonlinear hillslope transport to operate in world units, restored
  the intended critical-slope response, and bounded the explicit diffusion
  step for stability.
- Aligned parameter sliders and typed entry with the core's validated ranges,
  including deterministic clamping and snapping.
- Added fluvial and terrain-scale research audits, an example landscape graph,
  and expanded core and viewer regression coverage.

## 0.11.0-alpha.2

- Repaired the GPU hydraulic erosion solver with wet/dry velocity handling, a
  half-cell Courant cap, bounded bed/sediment exchange, input-relative
  curvature limiting, and conservative high-talus settling. Retuned defaults
  now produce flow-selective erosion without the former needle/checkerboard
  artifacts, while extreme legacy/API values remain finite and bounded.
- Reorganized hydraulic authoring around rainfall, duration, capacity, erosion,
  and deposition; numerical timestep, slope floor, vertical scale, and virtual
  pipe geometry now use documented Advanced controls and safe slider ranges.
- Reduced high-frequency camera edits from invalidating unrelated inspector or
  renderer state.

## 0.11.0-alpha.1

- Separated ephemeral viewer preview selection from persisted graph output,
  with an explicit **Set as Graph Output** action.

## 0.10.0-alpha.2

- Stabilized `erosionfilter` defaults and extreme controls, and added
  resolution-aware octave band-limiting to prevent cell distortion,
  under-sampled micro-spikes, normalization spikes, and clipped fade holes.
- `erosionfilter` now samples the input gradient at the gully-cell scale
  (coherent gullies on detail-bearing inputs) and auto-calibrates the fade
  target from the input's measured height range (`fadeAuto`, on by default),
  matching the reference's amplitude-normalized altitude fade.

## 0.10.0-alpha.1

- Added typed named graph ports with `terrain`, `mask`, and `data` field kinds.
- Added atomic multi-output evaluation and cache entries with per-output content
  keys, plus named output enumeration/evaluation/readback APIs.
- Upgraded graph persistence to format v2 with connection source ports,
  `sinkOutput`, and output-scoped mask erases; v1 files migrate automatically.
- Added `erosionfilter.terrain` and `erosionfilter.ridge` in one Metal dispatch.
  Ridge is normalized analysis data where crease=`0`, neutral=`0.5`, ridge=`1`.
- Added CLI `run/export --output`, typed port metadata in `nodes --json`, named
  raster export, and rejection of OBJ export for non-terrain fields.
- Added named output ports and selection in the viewer, terrain fallback geometry
  for analysis fields, data color ramp preview, and per-output mask editing.
- Added a mandatory research gate for changes involving physics or mathematics,
  including equations, units/normalization, boundaries, invariants, mapping,
  limitations, attribution, and license audit.

- Added an experimental `erosionfilter` GPU node for fast, branching
  slope-guided gullies without modifying the existing erosion simulations.
- Fixed CLI node catalog whitespace so every node reports its real inputs and
  default parameters in text and JSON output.
- Made saved mask erase strokes part of core graph evaluation and caching, so
  previews, downstream river carving, and exports use the same edited mask.
- Fixed the river-mask radial splat falloff.
- Unified legacy slope-mask migration with the core defaults.
- Moved live preview evaluation to a latest-snapshot background worker and
  added heightfield-aware mask-brush picking.
- Split large viewer responsibilities into dedicated editor, inspector, export,
  output, viewport, history, preview-worker, and picking components.
- Added headless viewer self-tests and Apple Silicon GitHub Actions CI with an
  offscreen Metal render artifact.

## 0.9.0-alpha.1

- Hardened `theia-cli` with global flags, strict unknown-option handling,
  `version`, `doctor`, structured `nodes --json`, and `diagnose --json`.
- Added version/capability APIs for SwiftPM callers.
- Added structured export API `graph_export2` with `png16`, `r16`, `pfm32`,
  and `obj` outputs.
- Kept legacy `graph_export` and CLI `--maps` export flow as compatibility
  wrappers.
- Moved RAW R16 export into `TheiaCore` so CLI and viewer share one export path.
