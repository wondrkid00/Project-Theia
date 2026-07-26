# Metal and Hydrology Reference Notes

Date: 2026-06-28

This note captures implementation knowledge from:

- `/Users/seandamara/Downloads/MetalbyExample.pdf`
  - Title: Metal by Example
  - Author: Warren Moore
  - PDF metadata date: 2015-10-31
  - 154 pages
- `/Users/seandamara/Downloads/SimpleHydrology`
  - Upstream remote: https://github.com/weigert/SimpleHydrology.git
  - Local commit: `2709726`
  - README states MIT License, but the downloaded tree does not include a top-level LICENSE file. If code is copied, preserve attribution and include license text/notice.
- `/Users/seandamara/Downloads/Procedural Hydrology: Improvements and Meandering Rivers in Particle-Based Hydraulic Erosion Simulations - Nick's Blog.pdf`
  - Source URL printed in PDF: https://nickmcd.me/2023/12/12/meandering-rivers-in-particle-based-hydraulic-erosion-simulations/
  - PDF metadata title: Procedural Hydrology: Improvements and Meandering Rivers in Particle-Based Hydraulic Erosion Simulations - Nick's Blog
  - Created from Safari on 2026-06-28
  - 33 pages
- Gaea documentation, checked 2026-06-28:
  - Rivers node: https://docs.gaea.app/reference/nodes/simulate/rivers.html
  - HydroFix node: https://docs.gaea.app/reference/nodes/simulate/hydrofix.html

## Metal by Example: Theia Takeaways

Theia already follows several Metal practices from the book:

- Keep `MTLDevice`, `MTLCommandQueue`, and compiled pipeline state long-lived.
  - Theia: `GPUContext` owns device/queue and caches `MTLComputePipelineState`.
  - Viewer: `Renderer` owns a render pipeline and depth state.
- Treat command buffers as frame/work units and encoders as scoped command recording.
  - Theia's compute nodes batch multi-pass erosion in one command buffer where appropriate.
- Build expensive pipeline state once and reuse it.
  - Avoid per-evaluation shader compilation unless a new node/kernel entry point is first encountered.
- Use explicit render pass load/store actions.
  - Viewer offscreen and live rendering should keep `.clear` plus `.store` for color attachments and avoid preserving depth when not needed.
- Use uniforms for per-draw state that changes each frame.
  - Viewer terrain shader already uses a single `Uniforms` struct for MVP, lighting, display mode, and grid data.
- Use Metal texture coordinate conventions carefully.
  - Metal texture origin is top-left; Theia heightfields are row-major. Any future texture-backed heightfield or material map should document whether y is image-space or terrain-space.
- Use samplers deliberately.
  - Nearest sampling is deterministic and useful for exact masks; linear sampling is visually smoother for previews/materials.
- Use blit encoders for GPU-side copies/fills/mipmap generation.
  - Theia hydraulic erosion already uses a blit fill for dynamic buffers. Future GPU export/preview maps could use blit where data transfer dominates.
- For compute kernels over 2D data, dispatch a 2D grid and guard bounds in the kernel.
  - Theia uses `dispatchThreads` with non-uniform threadgroups on Apple GPUs. Keep bounds checks in every kernel.
- Pick threadgroups from `threadExecutionWidth` and `maxTotalThreadsPerThreadgroup`.
  - Current `GPUContext::dispatch2D` and erosion nodes do this. Keep this pattern for new GPU nodes.
- Keep UI responsive by moving heavy compute or readback work off the main thread, then update UI on the main actor.
  - Phase 6 export follows this pattern. Future long-running erosion/export jobs should do the same.

## Metal Gaps Worth Considering Later

- The core API remains synchronous for deterministic CLI/export behavior. The viewer now evaluates live-edit snapshots on a serial background worker and drops stale results before they reach the renderer.
- The core uses shared buffers for easy CPU readback. That is convenient for CLI/export/tests. If viewport-only GPU workflows grow, private storage plus explicit blits may be faster.
- Runtime MSL compilation is convenient for SwiftPM-only development. For production builds, consider optional precompiled libraries or a pipeline warmup step if launch latency becomes noticeable.
- Texture-backed heightfields could help surface preview and GPU export maps, but buffer-backed heightfields remain better aligned with current node kernels.

## SimpleHydrology: Algorithm Notes

SimpleHydrology is particle-based procedural hydrology, distinct from Theia's current virtual-pipes hydraulic erosion.

Core data per cell:

- `height`
- smoothed `discharge`
- smoothed momentum field `momentumx`, `momentumy`
- per-frame tracking buffers `discharge_track`, `momentumx_track`, `momentumy_track`
- `rootdensity` for vegetation effects

Droplet state:

- `pos`
- `speed`
- `volume`
- `sediment`
- `age`

Important parameters:

- `maxAge`
- `minVol`
- `evapRate`
- `depositionRate`
- `entrainment`
- `gravity`
- `momentumTransfer`

Droplet update loop:

1. Sample current cell and terrain normal.
2. Stop if age or volume exceeds termination rules; deposit remaining sediment.
3. Reduce deposition in rooted/vegetated areas.
4. Accelerate along terrain normal/gradient.
5. Add momentum-field steering from previous water movement.
6. Clamp speed to roughly one diagonal cell per step.
7. Move particle.
8. Accumulate discharge and momentum tracking maps.
9. Estimate downstream height and equilibrium sediment capacity.
10. Erode or deposit via `cdiff = c_eq - sediment`.
11. Evaporate water volume while conserving sediment mass concentration.
12. Run cascade relaxation around the droplet position.
13. Repeat until termination.

The follow-up Nick's Blog article is important because it explains the current SimpleHydrology design intent and the reasons behind several code changes.

### Blog Details: Retrospective and Corrections

Procedural hydrology model:

- The system is particle-based hydraulic erosion on a 2.5D height-map.
- The useful abstraction is a motion law plus a mass-transfer law.
- Particles are coupled to the terrain and to each other through maps such as discharge and momentum, not only through the heightfield.
- The original stream-map idea evolved into a physically more interpretable discharge map.
- The old pool-map/flood-fill approach was removed because it was both expensive and conceptually brittle.

Natural smoothing:

- Hydraulic erosion self-reinforces channels and can create jagged, arbitrarily deep ridges.
- The blog argues that thermal erosion / sediment avalanching is not a fake blur; it is a natural settling process that limits slopes by an angle of repose.
- For Theia, droplet or hydrology nodes should either include a settling/cascade pass or document that users should chain `thermal` after erosion.
- Material/biome controls could later expose different repose angles for different terrain layers, but that is outside the current single-channel model.

Surface normal / slope computation:

- The blog explicitly rejects using the rendered triangle mesh slope for simulation.
- Triangle diagonal choice on a grid creates directional artifacts and piecewise-constant slope regions.
- Simulation should compute a continuous surface gradient from finite differences, then derive normal as `normalize((-gx, 1, -gy))`.
- This lines up with Theia's export normal/slope utilities and should become the standard for future erosion/math nodes.
- A future pass should audit old node math for any accidental dependence on mesh winding or viewer geometry.

Dynamic step length:

- Constant time steps let droplets skip over local terrain features and make mass transfer non-local.
- The blog stabilizes particle erosion by normalizing droplet movement so each step lands in a neighboring cell.
- The effective time-step/rates are then scaled by the ratio between particle speed and cell width.
- In Theia terms, a droplet node should separate "direction/speed as erosion intensity" from "cell-to-cell stepping as integration stability".

Pool-map removal:

- Flood-filling pooled water per droplet became too expensive as lakes grew.
- Flood-fill also implies instant water-surface equilibrium, which is not aligned with the simulation time scale.
- The author removed lakes until a better equilibrium/mass-transfer model can replace them.
- For Theia, do not start with lakes. Start with streams/discharge/meanders, then treat lakes/oceans/shores as a later dedicated phase.

Discharge map:

- During particle descent, accumulate `discharge_track += drop.volume` per visited cell.
- After all droplets/cycles, exponentially blend persistent discharge toward the tracked values.
- The sample code normalizes display/sampling with an error function, yielding a bounded `[0,1)` style activation.
- Discharge is used as a flow proxy that can scale erosion/suspension.
- In Theia's stateless graph evaluation, raw droplet discharge can read as broad basin patches because there is no long-lived lake/flood state. Droplet discharge should stay an internal erosion-feedback field unless a future node exposes it as an analysis map.

Meandering:

- Meandering needs two ingredients:
  - suspension/erosion strength increases with local flow velocity/discharge;
  - outer banks of curved streams experience higher effective velocity.
- The system approximates stream momentum by storing a persistent momentum vector map.
- During particle descent, add `drop.volume * drop.speed` to per-cell momentum tracking.
- After all particles finish, exponentially blend persistent momentum toward tracked momentum.
- The momentum map is fed back into particle motion, scaled by alignment with the particle direction and divided by water volume plus discharge.
- This is intentionally procedural/approximate rather than full CFD, but produces coherent long-distance streams, meander growth, cutoffs, oxbow traces, and stream scars.

Watershed behavior:

- Fractal noise starts with many closed basins.
- With lakes disabled, erosion can gradually solve the watershed by cutting outlets.
- Momentum feedback helps streams become stable enough to break out of basins, but larger maps require more time to settle.

Visualization insight:

- Pigment/sediment maps can reveal historic river paths. The idea is to let transported material carry a scalar/color property so old meanders remain visible.
- For Theia's single-channel graph, this suggests future analysis nodes such as `flowHistory`, `sedimentMask`, or `riverScars`, but those likely require internal multi-field simulation.

Discharge/momentum update:

- Each erosion cycle resets tracking maps.
- Many droplets are spawned.
- After droplets finish, persistent discharge/momentum fields are exponentially blended toward the tracked values:
  - `field = (1 - lrate) * field + lrate * tracked`

Cascade relaxation:

- Inspect 8 neighbors around the current cell.
- Sort neighbors by height.
- If the height difference exceeds distance-scaled `maxdiff`, move a fraction of excess material.
- This acts like local talus/settling and prevents overly sharp spikes.
- Theia uses normalized `0...1` heightfields, so droplet mass-transfer is capped per step to avoid one cell receiving a source-scale erosion/deposition impulse when users push deposition/gravity/heightScale beyond the SimpleHydrology defaults. A final local-extrema relaxation clips isolated needles without blurring the whole terrain.

Vegetation coupling:

- Plants avoid high discharge, steep slopes, and high elevations.
- Root density reduces erosion/deposition response.
- This is interesting for a future ecology/biome phase, but not necessary for a first hydrology port.

## How This Could Map To Theia

Potential node family:

- `dropletErosion`
  - input: terrain
  - output: terrain
  - internal CPU or GPU implementation
  - params: seed, cycles, dropsPerCycle, maxAge, evaporation, deposition, entrainment, gravity, momentumTransfer, settling, maxDiff, heightScale
- `river`
  - input: terrain
  - output: mask
  - trace a connected macro river network across the actual terrain, using conditioned routing and seed-driven meanders so small depressions do not break plausible paths
  - params stay mask-only: seed, water, width, headwaters
  - useful for preview and export
- `rivercarve`
  - input: terrain + river mask
  - output: terrain
  - owns destructive river-shaping params such as depth, downcutting, and river valley width
  - keeps river network generation separate from destructive terrain modification
- `riverScars` or `flowHistory`
  - input: terrain
  - output: mask/data map
  - inspired by the pigment washing visualization from the blog; likely requires internal history state during evaluation

Single-channel constraint:

- SimpleHydrology has multiple internal fields. Theia can keep the public graph single-channel by treating discharge/momentum/sediment as internal scratch buffers, or by adding analysis nodes that output one selected field as the node result.

Gaea Rivers/HydroFix UX implication:

- Gaea's Rivers node behaves like terrain tracing, not a raw wetness heatmap: it creates unbroken river pathways and exposes controls such as headwaters, flow, and width.
- Gaea's HydroFix exists because raw flow on noisy terrain can get trapped in small depressions and produce short, fragmented flow zones.
- Theia's public mask node is therefore `river`, not `flowaccum`. It should trace the input terrain from selected high headwaters toward lower outlets on a conditioned routing surface. Carving should happen in a separate `rivercarve` node so the graph can preview/export the river mask without accidentally destroying the upstream terrain.

Determinism:

- Replace `rand()` with Theia's deterministic seeded RNG/hash.
- Keep droplet spawn count and update ordering fixed.
- Tests should compare stats and exact/near-exact output for identical params.
- Avoid parallel scatter writes in the first version if determinism matters more than speed.

GPU feasibility:

- A particle algorithm is harder to map to GPU than virtual pipes because droplet paths update arbitrary cells and need scatter writes.
- First practical implementation should probably be CPU-side for correctness and reference behavior, then consider GPU versions later.
- If GPU is attempted, use one particle per thread plus atomics/scatter buffers, but expect determinism and write contention issues.
- The blog's dynamic cell-to-cell stepping strengthens the case for a CPU reference implementation first, because the step count per particle varies.

Integration risks:

- MIT license is compatible, but copied code must retain license/copyright notice.
- SimpleHydrology depends on GLM, TinyEngine, and FastNoiseLite in the app, but the erosion idea can be ported without those dependencies.
- The source uses integer cell positions in several places. Theia should decide whether droplet movement samples bilinear height or snapped cell height.
- The blog supersedes some older SimpleHydrology ideas: do not copy the old flood-fill pool behavior unless a future phase specifically revisits lakes.

## Recommended Future Research Before Coding Hydrology

Use SimpleHydrology as an implementation reference, then compare against at least one paper or mature terrain tool:

- Particle-based hydraulic erosion references for droplet capacity/deposition formulas.
- Mei et al. 2007 virtual-pipes paper for contrast with Theia's current node.
- Gaea/World Machine workflows for user-facing controls: erosion strength, duration, sediment, downcutting, flow/river masks.
- Nick McDonald's follow-up article above for practical SimpleHydrology design corrections: finite-difference normals, dynamic cell stepping, discharge maps, and momentum-driven meandering.

## Candidate UAT For A Future Hydrology Phase

- `dropletErosion` changes terrain visibly from Perlin input.
- Same seed and params produce deterministic output.
- Different seed changes drainage paths.
- Increasing cycles increases channel/valley development without exploding height range.
- Increasing evaporation shortens paths.
- Increasing momentum transfer creates more coherent/meandering flow.
- Step normalization prevents single droplets from tunneling through one-cell ridges.
- Discharge output is non-degenerate and highlights coherent stream channels.
- Momentum-enabled mode produces more stable long-distance channels than discharge-only mode.
- Chaining thermal/cascade after droplet erosion reduces jagged channel walls.
- Exported mask output can be used as a river or wetness mask in downstream tools.
- Old graphs without new nodes remain loadable.
