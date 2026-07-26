# Changelog

## Unreleased

## 0.12.0-alpha.1

- Added the `fluvial` landscape-evolution node with drainage-area-driven
  stream-power incision, sediment deposition, nonlinear hillslope transport,
  and a named flow-accumulation output.
- Made slope-sensitive terrain processes use resolution-independent ground
  spacing, keeping slope masks, thermal erosion, hydraulic erosion, and
  material previews consistent across authoring and export resolutions.
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
- Hardened material evaluation and export with finite/dimension guards,
  reusable packed-weight caching, durable checked writes, and transactional
  rollback that preserves existing bundles after write or publish failures.
- Refined material-layer authoring with explicit overlay sources, stable channel
  identity, repairable dangling sources, coalesced background previews, and
  color-only shader updates that avoid graph reevaluation.
- Prevented composite material preview from exposing the scalar mask eraser and
  reduced high-frequency camera and layer edits from invalidating unrelated
  inspector or renderer state.

## 0.11.0-alpha.1

- Added graph format v3 with an optional semantic material stack: one terrain
  reference, one base layer, and up to three mask/data overlays in stable RGBA
  channel order. Existing v1/v2 graphs continue to migrate automatically.
- Added audited finite/clamped material-weight normalization and deterministic
  largest-remainder RGBA8 quantization whose channel bytes sum exactly to 255.
- Added API v4 material-stack enumeration/readback and transactional bundle
  export for terrain, optional OBJ, linear RGBA8 weights, and JSON manifest.
- Added CLI `export-material` and a v3 example combining slope, river, and
  `erosionfilter.ridge` sources.
- Separated ephemeral viewer preview selection from persisted graph output,
  with an explicit **Set as Graph Output** action.
- Added a global Material Layers authoring panel, semantic undo/redo,
  mask/data-only source filtering, background evaluation with stale-result
  dropping, and linear-light convex color blending in the Metal shader.
- Added core and viewer coverage for migration, malformed/dangling references,
  cache reuse, color transfer, material history, exact-sum export, CLI, and
  offscreen visual rendering.

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
- Added `erosionfilter.height` and `erosionfilter.ridge` in one Metal dispatch.
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
