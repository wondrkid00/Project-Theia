# Erosion Filter Reference Gate

Audit status: **approved for Phase 8 implementation**
Audit date: 2026-07-10; stability addendum audited 2026-07-14

## Primary sources and license

- Rune Skovbo Johansen, [Fast and Gorgeous Erosion Filter](https://blog.runevision.com/2026/03/fast-and-gorgeous-erosion-filter.html).
- Rune Skovbo Johansen, [Advanced Terrain Erosion Filter](https://www.shadertoy.com/view/wXcfWn), the published reference shader.
- Rune Skovbo Johansen, [Clean Terrain Erosion Filter](https://www.shadertoy.com/view/33cXW8), the earlier frequency-based version used to check height-path lineage.
- C. E. Shannon, [Communication in the Presence of Noise](https://doi.org/10.1109/JRPROC.1949.232969),
  Proceedings of the IRE 37(1), 1949, for the sampling bound.

The reference shader is MPL-2.0. The Metal port is therefore explicitly
MPL-2.0, carries source links in its header, and is listed in
`THIRD-PARTY-NOTICES.md`. Secondary ports were consulted only to verify the
source transcription when Shadertoy did not expose its text to automated
readers; they are not the algorithm authority.

## Classification

This is a point-local procedural appearance filter, not a hydraulic or sediment
simulation. Every texel is evaluated independently from the input height,
finite-difference slope, and deterministic cell noise. It does not claim
conservation of water, sediment, mass, or energy.

## Quantities, units, and normalization

- Input height `h` is a dimensionless scalar in `[0,1]`.
- Domain coordinates `u,v` are normalized to `[0,1]²`.
- Central differences estimate derivatives per normalized-domain unit:

  `dh/du ≈ (h(x+1,y) - h(x-1,y)) * (width-1)/2`

  `dh/dv ≈ (h(x,y+1) - h(x,y-1)) * (height-1)/2`

- `fadeTarget` is signed analysis data in `[-1,1]`, derived from height by
  `(h - fadeCenter) / fadeRange` and clamped.
- The public ridge field is stored in `[0,1]` using
  `ridge01 = clamp(0.5 * ridgeSigned + 0.5)`. Thus crease is `0`, neutral is
  `0.5`, and ridge is `1`.
- Scale, strength, masks, rounding, and noise phase are dimensionless artistic
  controls. They are not meters, seconds, or material coefficients.

## Boundary condition

Height sampling clamps coordinates to the closest edge texel. At the boundary,
the duplicated endpoint makes the outward finite difference zero on the missing
side. This is a clamped/zero-flux-style numerical boundary, chosen for stable
finite tiles; it is not periodic and does not guarantee seamless wrapping.

## Height equations

For each octave `i`, Phacelle noise returns cosine height `gᵢ.x` and a sine-based
derivative. With `Mᵢ` the accumulated combi-mask and `fᵢ` the fade target:

`fadedᵢ = mix([fᵢ, 0, 0], gᵢ * gullyWeight, Mᵢ)`

`heightAndSlopeᵢ₊₁ = heightAndSlopeᵢ + strengthᵢ * fadedᵢ`

`fᵢ₊₁ = fadedᵢ.x`

`Mᵢ₊₁ = powInv(Mᵢ, detail) * newMaskᵢ`

where `powInv(t,p) = 1 - (1-clamp(t,0,1))^p`. Strength is multiplied by
`gain` and frequency by `lacunarity` after every octave. The existing Phase 7
height path is unchanged in Phase 8; only parallel ridge bookkeeping and a
second output buffer were added.

## Ridge equations

The advanced method tracks an unrounded, unweighted copy of fade state so
ridge analysis is not degraded by height styling controls:

`R_f,0 = fadeTarget`

`R_M,0 = easeOut(|∇h| * ridgeTerrainOnset)`

For each octave:

`R_f,i+1 = mix(R_f,i, gᵢ.x, R_M,i)`

`R_M,i+1 = R_M,i * easeOut(|sinPhaseᵢ| * ridgeGullyOnset)`

The last octave is faded toward neutral because it has not yet passed through a
following mask:

`ridgeSigned = R_f,n * (1 - R_M,n)`

Theia currently fixes `ridgeTerrainOnset = 2.8` and
`ridgeGullyOnset = 1.5`, matching the reference shader defaults. The ridge
result is produced in the same Metal dispatch as height.

## Parameter mapping

| Theia parameter | Reference role | Accepted range |
|---|---|---:|
| `seed` | deterministic cell offsets | uint32 |
| `scale` | base gully scale and strength scale | `[0.005,0.06]` |
| `strength` | height contribution | `[0,1]` |
| `octaves` | repeated gully layers | `[0,8]` |
| `lacunarity` | frequency multiplier | `[1,4]` |
| `gain` | strength multiplier | `[0,1]` |
| `gullyWeight` | raw-gully contribution | `[0,0.65]` |
| `detail` | inverse-power combi-mask shaping | `[0.05,6]` |
| `ridgeRounding`, `creaseRounding` | height-path edge rounding | `[0,1]` |
| `onset` | height-path slope mask onset | `[0.05,8]` |
| `assumedSlope`, `slopeMix` | straight-gully direction control | `[0,8]`, `[0,1]` |
| `cellScale`, `normalization` | Phacelle cell/phase normalization | `[0.1,4]`, `[0,0.5]` |
| `heightOffset` | accumulated height bias | `[-1,1]` |
| `fadeCenter`, `fadeRange` | height-to-fade-target mapping | `[0,1]`, `[0.01,1]` |

The narrower `scale`, `gullyWeight`, and `normalization` limits are Theia's
safe authoring envelope for normalized raster heightfields. They intentionally
do not claim to be limits of the reference algorithm in other coordinate
systems.

## Stability addendum (2026-07-14)

### Evidence and failure mechanism

The primary article identifies three constraints that apply directly to the
reported spike, hole, and curled-fold artifacts:

- A cell that is large relative to the stripe width accumulates rotational
  distortion, especially when the input gradient changes substantially inside
  that cell. A cell that is too small becomes grainy.
- Fully normalizing near-cancelled interpolated waves creates loops that appear
  as spiky protrusions and holes. The author's recommended partial
  normalization only fully normalizes raw magnitudes at or above `0.5`.
- The fade target is expected to vary from approximately `-1` in valleys to
  `+1` at peaks. Hard saturation of an aggressively shifted altitude mapping
  creates a non-smooth transition that is particularly visible where the
  analytic gully slope does not include the fade target's derivative.

In the published equations, `strength` is multiplied by `scale` before the
octave loop. Theia therefore exposed two coupled amplitude controls: increasing
`scale` made the cells broader and increased displacement at the same time.
`gullyWeight` also affects both the visible height contribution and the
recursive internal direction field. On Theia's normalized `[0,1]^2` domain,
the former default `scale=0.15` was outside the empirically stable range for
detail-bearing inputs and made the reference method's known singular regions
large enough to become visible mesh spikes.

### Audited stabilization

The stabilization keeps the reference octave equations intact and applies
three boundary guards around them:

1. `scale`, `gullyWeight`, and `normalization` are clamped to the safe envelope
   in the evaluator, not only in the viewer. The default profile uses
   `scale=0.05`, `gullyWeight=0.35`, and `normalization=0.4`.
2. The altitude fade uses a cubic Hermite transition. With
   `t = clamp(0.5 + 0.5 (h-c)/r, 0, 1)`, the signed fade is
   `f = 2 t²(3-2t) - 1`. It preserves `[-1,1]`, the requested center, and zero
   derivative at both saturation boundaries.
3. The final displacement is compressed into the remaining normalized height
   headroom instead of hard-clipped. For positive delta `d` and upper headroom
   `q=1-h`, `d_safe = d q/(q+d)`; the negative case uses lower headroom `q=h`
   symmetrically. This is identity to first order at `d=0`, never crosses the
   `[0,1]` boundary, and prevents a finite negative/positive delta from creating
   a new flat zero/one hole or spike.

### Addendum invariants

- Default and maximum accepted scale must not create a new adjacent-sample jump
  larger than the input jump plus the audited displacement budget.
- Extreme accepted fade centers must not create new samples exactly at `0` or
  `1` unless the input sample was already at that boundary.
- Values above the evaluator's safe envelope behave exactly like the maximum
  accepted value, so JSON/CLI use cannot bypass viewer safety.
- The ridge output remains the reference parallel analysis path; final height
  headroom compression does not alter it.

## Sampling addendum (2026-07-14)

Audit status: **approved before anti-aliasing implementation**

### Observed failure

The remaining small pyramidal points are not large displacement overshoots.
They are under-sampled final octaves. In normalized domain units, the dominant
stripe frequency of octave `i` is

`νᵢ = lacunarityⁱ / scale` cycles per terrain width/height.

`cellScale` cancels because the domain is first multiplied by
`1/(scale·cellScale)` and the stripe wave inside each cell is multiplied by
`cellScale`. With the stabilized default `scale=0.05`, `lacunarity=2`, and five
octaves, the frequencies are `20, 40, 80, 160, 320` cycles per domain. The last
octaves therefore become one- or two-vertex features on common 256–512 grids
and appear as isolated triangles after mesh tessellation.

Shannon's sampling theorem states that a band-limited signal with maximum
frequency `W` requires sample spacing `1/(2W)`, or at least two samples per
cycle, for theoretical reconstruction. A directly tessellated height grid has
no sinc reconstruction filter and needs additional margin for visually smooth
slopes, so Theia uses a conservative transition from 2.5 to 4 samples per
cycle rather than emitting content at the theoretical two-sample boundary.

### Resolution-aware octave weight

Let `S = min(width-1, height-1)` be the available samples per normalized-domain
unit and `qᵢ = S/νᵢ` the samples per stripe cycle. Each octave receives

`bᵢ = smoothstep(2.5, 4.0, qᵢ)`.

`bᵢ` multiplies the octave's height, slope, magnitude, fade-state, mask-state,
and ridge-state contribution. Once `bᵢ=0`, later octaves are skipped because
their frequencies only increase. This is a deterministic procedural
band-limit, not a spatial blur, and it preserves broad gullies.

The default ridge and crease rounding are also increased to `0.18` and `0.10`
respectively. This uses the reference algorithm's existing rounding mechanism
and avoids adding a separate smoothing pass.

### Sampling invariants and limitations

- No fully rejected octave may change height, internal slope, mask, magnitude,
  or ridge output.
- Increasing resolution may reveal additional legitimate octaves; the result
  is intentionally resolution-dependent in its highest represented frequency.
- At a fixed resolution and parameter set, output remains bitwise deterministic.
- Boundary sampling and `[0,1]` height normalization are unchanged.
- This filter is not a general anti-aliaser for high-frequency detail already
  present in the input terrain; it only band-limits detail introduced by
  `erosionfilter`.

## Gradient and fade calibration addendum (2026-07-14)

Audit status: **implemented with the sampling addendum, kernel `v4`**

### Gradient sampling at the gully-cell scale

The stability addendum's first mechanism—rotational distortion when the input
gradient changes substantially inside one Phacelle cell—is driven on raster
inputs by the derivative stencil as well as cell size. The reference
demonstrations use analytic derivatives of a smooth, low-gain terrain. A
per-texel central difference on a detail-bearing raster can instead rotate the
stripe direction at every pixel, shredding gullies into short unaligned dabs
and inflating the slope-mask onset with high-frequency slope energy.

Theia therefore estimates `dh/du, dh/dv` with bilinear taps at

`e = max(1/S, scale · cellScale / 4)`

on each side of the evaluated point, where `S = min(width-1, height-1)`. This
measures the gradient at a quarter of the gully-cell size—the scale the stripes
must align to—and reduces exactly to the previous per-texel central difference
when the cell is at or below four texels. The stencil changes the slope estimate
that feeds stripe direction and mask onset; it does not prefilter or replace the
input height sample used as the output base.

This is a Theia raster adaptation inferred from the reference author's stated
cell-coherence limitation. It is not presented as part of the original shader's
public parameterization.

### Amplitude-calibrated fade target (`fadeAuto`)

The reference derives its fade target from altitude normalized by terrain
amplitude, saturating at 60% of it, so valleys approach `-1` and peaks `+1`
regardless of the terrain's absolute range. A fixed `fadeCenter/fadeRange` of
`0.5/0.5` only reaches about `±0.4` on a typical `[0.3,0.7]` input,
under-driving peak and valley preservation.

With `fadeAuto = 1` (default), the evaluator scans the input once and substitutes

`fadeCenter = (min + max) / 2`, `fadeRange = 0.6 · (max - min) / 2`

before dispatch. The mapping remains the C1 Hermite transition from the
stability addendum. Inputs with a span at or below `1e-4` retain the manual
mapping because fitting a near-flat input would amplify noise into a full-range
fade. `fadeAuto = 0` restores manual `fadeCenter/fadeRange`. The scan uses the
same shared-buffer samples that already determine the upstream content key;
`strength=0` and `octaves=0` skip it entirely.

### Calibration invariants and limitations

- `fadeAuto` must be deterministic for identical input samples and parameters.
- Auto calibration must not alter the `strength=0` identity result.
- Near-flat or invalid-span inputs must retain the finite manual mapping.
- Gradient taps clamp at terrain edges, preserving the existing boundary rule.
- The CPU min/max pass is linear in sample count and adds no additional Metal
  dispatch, but it does add a shared-buffer read on cache misses.

## Required invariants

- `height` remains finite and clamped to `[0,1]`.
- `ridge` remains finite and clamped to `[0,1]`.
- Identical input and parameters produce bitwise deterministic outputs on the
  same supported Metal device/toolchain.
- Requesting `height` and then `ridge` cannot dispatch the node twice while the
  atomic cache entry remains valid.
- Changing any upstream content invalidates both outputs together.
- `strength = 0` preserves every height sample; ridge is neutral `0.5`.
- The output buffers have the same dimensions as the input scalar grid.

## Limitations

- Ridge is analysis/material data, not a river network. Lines can end on a
  slope and have no connectivity, downstream-flow, or conservation guarantee.
- Numerical derivatives at tile edges use clamped sampling and can differ from
  adjacent independently generated tiles unless their border samples agree.
- Partial normalization deliberately tolerates some second-order derivative
  discontinuity; the reference author reports it as visually negligible with
  multiple octaves.
- The filter works best over smooth broad landforms. Feeding detail-heavy fBm
  stacks unrelated high-frequency structures and can look noisy.
- Multi-channel surface shading and physically based erosion outputs are outside
  Phase 8.
