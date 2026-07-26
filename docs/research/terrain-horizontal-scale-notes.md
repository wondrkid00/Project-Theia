# Terrain Horizontal Scale Reference Audit

Status: **approved for Phase 9 stabilization**
Reviewed: 2026-07-26 (material layer stack defect audit)
Scope: the ground spacing used by slope-derived operators — `slopemask`,
`thermal`, and `hydraulic`. This note does not authorize a new simulation, a
georeferencing/CRS model, anisotropic cell spacing, or a change to heightfield
normalization.

## Defect this note resolves

Theia's slope operators divided finite differences by a `cellSize` parameter
that defaulted to `1.0` and was interpreted as *one unit per texel*. Grid
spacing therefore tracked the sampling grid rather than the terrain, so the same
graph produced a different slope field at every resolution. Measured on
`examples/material-stack.json`, the `steep` slope mask output range was:

| Grid | `slopemask` output range |
|---|---|
| 128² | `[0.0, 1.0]` |
| 256² | `[0.0, 0.697]` |
| 512² | `[0.0, 0.0028]` |
| 1024² | `[0.0, 0.0]` |

Doubling the grid halves every per-texel height delta, so the computed slope
angle falls monotonically toward zero. A mask authored as "28°–58°" matched real
terrain at 128² and matched nothing at 512². The viewport's own slope preview
divides by true domain spacing and is already resolution-independent, so the
shaded viewport and the mask disagreed.

## Primary and official references

1. Horn, B. K. P. (1981). *Hill Shading and the Reflectance Map*.
   Proceedings of the IEEE, 69(1), 14–47.
   - Third-order finite difference over the eight neighbours of a 3×3 window,
     weighting orthogonal neighbours twice the diagonals.
   - Status: original publication; the equations are restated below, no source
     code is copied.
2. GDAL, *gdaldem* program documentation.
   <https://gdal.org/en/stable/programs/gdaldem.html>
   - `-scale` is defined as the **"Ratio of vertical units to horizontal
     units."**
   - Slope is computed from Horn's formula by default, with Zevenbergen &
     Thorne offered as an alternative for smooth landscapes.
   - Status: official project documentation used as the units contract; no
     source code is copied.
3. Esri, *How Slope works* (ArcGIS Pro, Spatial Analyst).
   <https://pro.arcgis.com/en/pro-app/latest/tool-reference/spatial-analyst/how-slope-works.htm>
   - Confirms the 8-cell Horn estimator and the `8 * cellsize` denominator,
     where cell size is the raster's **ground** resolution.
   - Status: official product documentation; interoperability reference only.
4. Mei, X., Decaudin, P., & Hu, B. (2007). *Fast Hydraulic Erosion Simulation
   and Visualization on GPU*. Pacific Graphics.
   - The virtual-pipes model already treats cell size as a physical length; see
     `hydraulic-erosion-stability-notes.md` for the CFL envelope that depends
     on it.
   - Status: original publication; already audited for Phase 7.

## Quantities, domains, and interpretation

- A Theia heightfield covers a **square world domain of `terrainSize` world
  units on a side, independent of the sampling grid.**
- Ground spacing between adjacent samples is therefore

```
cell = terrainSize / max(W - 1, 1)
```

  using `W - 1` intervals across `W` samples, matching the viewport shader's
  existing `2/(gridW-1)` domain mapping.
- `heightScale` continues to convert normalized height to world vertical units.
  Together `heightScale` and `terrainSize` express exactly the vertical-to-
  horizontal ratio that GDAL's `-scale` denotes.
- Slope is dimensionless before `atan`; the emitted angle is in degrees.
- `terrainSize` is a world length. It is not a georeferenced extent and carries
  no CRS, datum, or projection meaning.

The grid is square in world space, so `cellsize_x == cellsize_y`. Anisotropic
spacing is explicitly out of scope.

## Slope equations

For the 3×3 neighbourhood labelled

```
a b c
d e f
g h i
```

with all samples pre-multiplied by `heightScale`, Horn's third-order estimator is

```
dz/dx = ((c + 2f + i) - (a + 2d + g)) / (8 * cell)
dz/dy = ((g + 2h + i) - (a + 2b + c)) / (8 * cell)
slope = atan(sqrt((dz/dx)^2 + (dz/dy)^2)) * 180/pi
```

Edge samples clamp to the border sample, which is the existing Theia boundary
policy and is preserved unchanged.

The mask then applies the existing authored ramp:

```
mask = smoothstep(lo, hi, slope)
```

with `lo = clamp(min(low, high), 0, 90)` and `hi = max(clamp(max(low, high), 0,
90), lo + 0.001)`.

## Required invariants

For a fixed graph, fixed `terrainSize`, and fixed `heightScale`:

```
isfinite(slope)
0 <= slope <= 90
0 <= mask <= 1
```

**Resolution stability.** For a band-limited input evaluated at two grids `W1`
and `W2`, the mean slope angle must agree to within the terrain's own sampling
error rather than diverging systematically with grid size. The executable
obligation is stated as a bounded ratio of mean mask coverage across
128/256/512/1024, not as exact equality: finer grids legitimately resolve finer
detail, so identity is not the correct contract.

This is the invariant the previous implementation violated — its coverage ratio
across that range was unbounded, collapsing to exactly zero.

## Choice of default

`terrainSize` defaults to **1024.0 world units**, matching `Graph`'s default
grid (`defaultWidth_ = 1024`). At 1024² this yields `cell = 1024/1023 ≈ 1.0`,
so a legacy graph that relied on `cellSize = 1.0` is numerically unchanged at
the core's default resolution, and every other resolution now agrees with that
reference instead of drifting from it.

The default is a calibration convention, not a physical claim. Authors who want
steeper or gentler terrain adjust `heightScale` (vertical) or `terrainSize`
(horizontal); only their ratio affects slope.

## Legacy migration

Graphs that specify `cellSize` are migrated on load using the document's own
declared resolution, which is parsed before the node list:

```
terrainSize = cellSize * max(documentWidth - 1, 1)
```

At that document's declared grid this yields `cell = cellSize` exactly, so a
legacy document renders bit-for-bit as it did before; every *other* resolution
now agrees with it instead of drifting away. Migrating against a fixed
reference grid was rejected: it silently rescaled documents authored at other
sizes, which flattened a 96² test terrain into an empty mask and perturbed the
hydraulic stability profile.

A non-finite or non-positive legacy cell falls back to the node default rather
than propagating a degenerate world width into the solver. Migration follows
the existing `migrateLegacySlopeMaskDefaults` precedent in `Graph.cpp`, so no
document fails to load.

## Effect on the erosion operators

`thermal` compares neighbour height differences against a talus threshold:

```
threshold = tan(talusAngle) * cell
```

This is the same units contract as the slope mask; with a texel-based `cell`,
the effective talus angle drifted with resolution. Deriving `cell` from
`terrainSize` makes the authored `talusAngle` mean what it says at any grid.

`hydraulic` already treats cell size as a physical length throughout the
virtual-pipes formulation, so no equation changes. The CFL bound documented in
`hydraulic-erosion-stability-notes.md`,

```
dt * |v| / cell <= 0.5
```

now tightens as the grid refines, which is the physically correct behaviour for
an explicit scheme: a finer grid genuinely requires a smaller stable timestep.
The existing speed clamp `maxSpeed = min(3, 0.5 * cell / dt)` enforces the bound
automatically, so refinement costs accuracy of the advected velocity rather than
stability. Authors who refine the grid and want the same erosion character
should reduce `dt` proportionally.

The solver's cell clamp widens from `[0.05, 4]` to `[0.05, 64]` because derived
spacing spans a wider range than a per-texel constant did. The lower bound is
unchanged: it is the one that guards the Courant limit. `terrainSize` itself is
clamped to `[1, 65536]` before the division. The audited stability tests pass
unchanged under this change, because migration reproduces each document's prior
cell exactly at its own declared resolution.

## Boundary conditions and failure policy

- `terrainSize` must be finite and strictly positive; non-finite or
  non-positive values are rejected with the node id, consistent with the
  existing `finiteParam` policy in the erosion nodes.
- `cell` is clamped below at `1e-6` to keep the division defined for degenerate
  authored values.
- `W <= 1` degenerates to a single interval so the estimator stays defined.
- Grid resolution is supplied by the evaluation request, so all inputs to one
  material or export pass share a single `terrainSize` and no resampling
  boundary is introduced.

## Executable invariant mapping

| Requirement | Test obligation |
|---|---|
| Horn estimator | fixed 3×3 fixture reproduces the hand-computed gradient |
| Units contract | doubling `terrainSize` and `heightScale` together leaves slope unchanged |
| Resolution stability | mask coverage bounded across 128/256/512/1024 |
| Material consequence | all four example channels hold non-trivial coverage at every tested grid |
| Domain handling | non-finite and non-positive `terrainSize` rejected |
| Legacy migration | `cellSize` documents load and reproduce 1024² behaviour |
| Talus meaning | authored `talusAngle` yields consistent shedding across grids |
| Hydraulic stability | existing envelope tests hold with derived `cell` |

## Limitations

- Square, isotropic, non-georeferenced domain only.
- Horn's estimator smooths more than Zevenbergen & Thorne on smooth surfaces;
  only Horn is implemented, matching the prior behaviour and GDAL's default.
- Resolution independence applies to the *operator*, not to the terrain: finer
  grids still resolve finer detail, so masks legitimately gain fine structure
  as resolution rises. Only the systematic drift is removed.
- Quantization and normalization of the heightfield are unchanged.

## Attribution and license decision

The estimator is restated from Horn (1981) and cross-checked against GDAL and
Esri documentation for the units contract. No third-party source code, shader,
or dataset is imported. Project code remains MIT and this change adds no
redistributable dependency.
