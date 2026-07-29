# Node workflow UAT — 2026-07-29

Exercise every registered node type through the authoring workflow and look for
dead ends: an output nothing can consume, a stage that cannot be reached, a
control that does nothing. Driven through `theia-cli` against real graphs rather
than by reading declarations, because the declared output kinds do not tell the
whole story — most filter nodes declare `data` but inherit their input's kind.

26 node types: 7 generators, 19 consumers.

## What was tested

| # | Check | Cases | Result |
|---|---|---|---|
| 1 | Every generator evaluates standalone, every output port reachable | 7 | pass |
| 2 | Every producer output into every consumer input | 462 | 389 accepted, 73 rejected — all correct kind rules |
| 3 | Every node output reaches an `export` node | 27 | pass |
| 4 | Targeted workflows (mask filtering, data-as-carve-mask, kind-matched blends, filtered terrain back into terrain-only consumers) | 50 | pass |
| 5 | Export matrix: 3 output kinds × 4 heightmap formats × mesh on/off | 21 | pass |
| 6 | Every parameter of every node changes the output | 180 | 1 genuine finding |

### 2 — the 73 rejections are all correct

They fall into two groups, both by design:

- Terrain-kind producers into `rivercarve.mask`, which accepts `[mask, data]`.
- Mask/data producers (`slopemask.mask`, `river.mask`, `fluvial.flow`,
  `erosionfilter.ridge`) into terrain-only inputs.

The `blend`/`combine` rejections in that set are an artefact of the harness
feeding the *other* input from a terrain generator; those nodes require both
inputs to be the same kind. Re-tested kind-matched in check 4 — all pass.

### 4 — the paths that matter

Confirmed working, and worth recording because they are not obvious from the
port declarations:

- `slopemask → blur/invert/clamp/remap/normalize/scalebias → rivercarve.mask`
  — mask kind survives filtering, so masks stay usable downstream.
- `fluvial.flow → rivercarve.mask` and `erosionfilter.ridge → rivercarve.mask`
  — the `data` outputs are usable as carve masks.
- `perlin → blur/scalebias/remap/clamp/invert/normalize → thermal/fluvial/warp/
  terrace/slopemask/river` — `inheritInput` keeps a filtered terrain a terrain,
  so filters do not break an erosion chain.

### 5 — export

Every output kind exports to `png16`, `r16` and `pfm32`. `--mesh obj` correctly
refuses a non-terrain sink with `OBJ export requires a terrain output`. That is
a guard rail, not a dead end.

### 6 — the one finding

Ten parameters initially looked inert. Six were artefacts of testing at 64²,
where `terrainSize = 1024` makes a cell ~16 world units: that floors `river`'s
channel width at the 0.5-cell clamp and pushes `thermal`'s talus threshold above
any real height difference. Re-run at 512² they all respond. **Worth knowing:
several controls are genuinely inert at very low preview resolutions.**

Three more were explained:

- `blend.opacity` — the harness fed both inputs from the same node.
- `remap.clamp` — functional, but invisible at the default `outLow 0 / outHigh 1`
  because the kernel clamps the result to `[0,1]` regardless. It changes the
  output as soon as the output range is narrower.
- `erosionfilter.detail`, `gain` — respond at 512².

That leaves one:

> **`erosionfilter.fadeCenter` and `fadeRange` do nothing while `fadeAuto` is on,
> and `fadeAuto` defaults on.**

`ErosionFilterNode.cpp` overwrites both from the input's measured height range.
Verified directly: with `fadeAuto = 1` the two extremes `(0.1, 0.1)` and
`(0.9, 0.9)` produce byte-identical output; with `fadeAuto = 0` they differ.

Fixed by dimming those rows with a lock glyph and a tooltip naming the control
driving them. The per-parameter reset stays live, because a value modified before
the gate closed still applies once it reopens.

`erosionfilter.fadeAuto` is the only gate of this kind in the core.

## Not dead ends, but noted

- **Contextual node picker.** Dragging a wire into empty space ranks suggestions
  per source kind (`flow`, `ridge`, `mask`, `terrain`, generic). `rivercarve` is
  suggested for `flow` and `mask` but not for `ridge`, even though
  `erosionfilter.ridge → rivercarve.mask` evaluates fine. Unranked types still
  appear, just lower, so nothing is unreachable — only a slightly weaker hint.
- **Low-resolution previews.** As above, `river.width` and the `thermal` controls
  are inert at 64²–128². The 1024 default keeps normal use clear of this, but a
  deliberately small preview will mislead.

## Reproducing

Harness under `/private/tmp/.../scratchpad/uat/` (scratch, not committed):
`t1_generators.py`, `t2_matrix.py`, `t3_export.py`, `t4_workflows.py`,
`t5_export.py`, `t6_params.py`, `t7_suspects.py`, `t8_remap.py`. Each builds
graph JSON and shells out to `theia-cli`, comparing PFM output bytes.
