# Hydraulic Erosion Stability Reference Gate

Date: 2026-07-16  
Status: audited before implementation

This note gates the July 2026 repair of Theia's `hydraulic` node. The goal is
an artist-facing, deterministic GPU approximation of rainfall erosion. It is
not a scientific watershed or flood solver.

## Primary sources

1. Xing Mei, Philippe Decaudin, Bao-Gang Hu, **Fast Hydraulic Erosion
   Simulation and Visualization on GPU**, Pacific Graphics 2007,
   DOI [`10.1109/PG.2007.15`](https://doi.org/10.1109/PG.2007.15),
   [author/lab publication page](https://evasion.imag.fr/Publications/2007/MDH07/).
   This is the governing reference for the five-stage virtual-pipe algorithm,
   flux limiting, velocity reconstruction, empirical sediment capacity,
   semi-Lagrangian sediment transport, evaporation, closed boundaries, and its
   stated time-step/scaling limitations.
2. James F. O'Brien and Jessica K. Hodgins, **Dynamic Simulation of Splashing
   Fluids**, Computer Animation 1995, DOI
   [`10.1109/CA.1995.393532`](https://doi.org/10.1109/CA.1995.393532),
   [author-hosted PDF](https://graphics.berkeley.edu/papers/Obrien-DSS-1995-04/Obrien-DSS-1995-04.pdf).
   This is the primary source for pressure-driven exchange between height
   columns connected by virtual pipes.
3. Jos Stam, **Stable Fluids**, SIGGRAPH 1999, DOI
   [`10.1145/311535.311548`](https://doi.org/10.1145/311535.311548),
   [author publication page](https://www.josstam.com/publications).
   This is the primary reference for backward semi-Lagrangian advection. Its
   unconditional stability does not make the separate explicit pipe solver
   unconditionally stable.
4. Xin Liu, Jason Albright, Yekaterina Epshteyn, Alexander Kurganov,
   **Well-balanced positivity preserving central-upwind scheme with a novel
   wet/dry reconstruction on triangular grids for the Saint-Venant system**,
   Journal of Computational Physics 374 (2018), DOI
   [`10.1016/j.jcp.2018.07.038`](https://doi.org/10.1016/j.jcp.2018.07.038),
   [author-hosted PDF](https://www.math.utah.edu/~epshteyn/Liu-Albright-Epshteyn-Kurganov.pdf).
   Theia does not implement this finite-volume scheme. It is used to audit the
   required non-negative water-depth, wet/dry, and lake-at-rest invariants.

The papers are copyrighted publications, not software dependencies. Equations
and algorithmic ideas are reimplemented independently; no paper source code is
copied. The Theia implementation remains covered by the repository's MIT
License. Citations and limitations must remain in the kernel and this note.

## State, units, and normalization

For each grid cell:

- `b` — bed/terrain elevation in simulation length units;
- `d` — non-negative water depth in simulation length units;
- `s` — suspended sediment expressed as equivalent bed-height amount;
- `f=(fL,fR,fT,fB)` — outward volume flux, length cubed per time;
- `v=(u,v)` — horizontal velocity, length per time.

The graph input and output are scalar heights in `[0,1]`. Internally,
`b = input * heightScale`; the output divides by the same positive scale.
`cellSize`, `pipeLength`, and terrain/water heights therefore share one
procedural length system. The parameter names are public compatibility names,
not calibrated SI quantities.

`cellSize` below denotes the solver's internal ground spacing. Since Phase 9 it
is no longer an authored per-texel constant: it is derived from the authored
`terrainSize` (the terrain's world width) and the evaluation grid as
`cellSize = terrainSize / (W - 1)`, so the length system stops shifting with
resolution. See `terrain-horizontal-scale-notes.md`. All equations in this note
are unchanged and continue to refer to that physical length.

`heightScale` is vertical scale **inside the simulation**. It must not be
presented as an output-height multiplier. `minTilt` is a lower bound on
`sin(alpha)`, not an erosion-strength control. `dt` is a numerical time step,
not an effect-strength control.

## Governing update

The five stages follow Mei et al.:

1. Rain: `d1 = d + rain * dt`.
2. Pressure-driven virtual-pipe flow.
3. Bed erosion/deposition from transport capacity.
4. Backward semi-Lagrangian sediment advection.
5. Evaporation: `dNext = d2 * max(0, 1 - evaporation * dt)`.

For direction `i`, surface difference `deltaH_i` and pipe cross section `A`:

```text
f_i' = max(0, f_i + dt * A * gravity * deltaH_i / pipeLength)
K    = min(1, d1 * cellSize^2 / (dt * sum(f')))
f_i  = K * f_i'
```

The `K` limiter is the discrete draining-time constraint: a cell cannot send
more water than it contains during one step. The water update is

```text
d2 = d1 + dt * (sum(inflow) - sum(outflow)) / cellSize^2.
```

Velocity is reconstructed from opposing pipe fluxes and mean water depth as in
Mei equations 8–9. For a first-order backtrace, Theia additionally enforces

```text
dt * |v| / cellSize <= 0.5
```

before sediment advection. This conservative half-cell Courant limit prevents
the velocity/capacity field from alternating between cells when users choose a
large `dt`; it is a numerical guard, not a claim from the paper.

Sediment capacity is the paper's empirical model:

```text
C = sedimentCapacity * max(minTilt, sin(alpha)) * |v| * wetness
sin(alpha) = |grad(b)| / sqrt(1 + |grad(b)|^2)
```

Theia's `wetness` smoothly tends to zero at a dry cell. This avoids erosion by
a numerically large velocity divided by a near-zero water depth. Spatial
gradients and backtraces are divided by `cellSize`.

The exchange between bed and suspended sediment is equal and opposite. Instead
of the unstable explicit fraction `rate * dt`, the repaired implementation
uses the bounded exact relaxation fraction

```text
response(rate, dt) = 1 - exp(-max(rate, 0) * dt),  0 <= response < 1.
```

Transfer is additionally limited by a small normalized per-step bed-change
budget and local relief. This only constrains under-resolved single-cell
impulses; ordinary default erosion remains below the limiter.

The curvature guard is direction preserving. An erosion candidate is clamped
to at most the current bed, and a deposition candidate is clamped to at least
the current bed:

```text
bErode  = min(b, max(b - amount, curvatureFloor))
bDeposit = max(b, min(b + amount, curvatureCeiling))
```

Without these outer clamps, a curvature floor above `b` could create bed while
recording zero sediment removal, or a ceiling below `b` could remove bed while
recording zero deposition. Direction preservation is therefore part of the
bed/sediment conservation invariant, not only an artifact-control heuristic.

Finally, a small fixed number of conservative, high-talus settling passes moves
material from slopes above 55 degrees to lower von Neumann neighbors. This is a
mass-conserving bank-collapse guard for needles created by the coupled solver,
not a Gaussian blur and not a replacement for the user-controlled `thermal`
node.

## Boundary conditions

- Water: closed/no-outflow boundary, matching Mei et al.; outward boundary
  pipe flux is exactly zero.
- Sediment backtrace: clamp to the domain edge. No sediment is sampled from
  outside the graph.
- Terrain settling: no material crosses the domain boundary.
- The closed domain can accumulate water and sediment in depressions. Open
  outlets and river-source boundary controls remain future work.

## Invariants and mapped tests

Implementation may start only with every invariant mapped to a regression:

| Invariant | Regression mapping |
|---|---|
| All accepted parameters and output samples are finite | `Hydraulic rejects non-finite parameters and guards extreme API values` |
| Water depth never becomes negative | draining-limiter equation audit plus `Hydraulic screenshot-risk profile does not create one-cell artifacts` |
| Outflow volume in one step cannot exceed cell water volume | draining-limiter equation audit plus `Hydraulic screenshot-risk profile does not create one-cell artifacts` |
| Velocity backtrace travels at most half a cell per step | `Hydraulic screenshot-risk profile does not create one-cell artifacts` (`dt=0.1`, high tilt and evaporation) |
| Every bed erosion/deposition delta has the opposite sediment delta | exchange update audit plus `Hydraulic erosion alters terrain and is deterministic`, which protects pass/buffer ordering |
| Curvature limiting can reduce an exchange but never reverse its direction | `Hydraulic curvature limiter never reverses erosion exchange` plus the direction-preserving exchange audit above |
| Bounded response and transfer cannot create one-cell needles | `Hydraulic screenshot-risk profile does not create one-cell artifacts`, measuring robust neighbor delta, curvature, and isolated extrema |
| Conservative settling does not move material across the boundary | `Hydraulic flat closed basin remains an exact equilibrium` |
| A flat closed basin under spatially uniform rain remains an equilibrium | `Hydraulic flat closed basin remains an exact equilibrium` |
| Default settings visibly alter terrain without clipping or striping | `Hydraulic erosion default profile avoids spike striping` |
| Same graph, size, and parameters are deterministic | `Hydraulic erosion alters terrain and is deterministic` |
| Output remains a finite scalar terrain in `[0,1]` | `Hydraulic rejects non-finite parameters and guards extreme API values` plus both artifact regressions |

## Parameter mapping and authoring envelope

- `iterations`: number of complete five-stage updates; primary duration/detail
  control.
- `rain`: water-depth rate per step; primary water-supply control.
- `sedimentCapacity`: multiplier `Kc` in the empirical capacity equation.
- `suspension`: bed-to-water relaxation rate when `C > s`.
- `deposition`: water-to-bed relaxation rate when `C <= s`.
- `evaporation`: fractional water-loss rate.
- `dt`: internal integration step. The viewer exposes a conservative range;
  the core still guards files/API values outside that authoring range.
- `minTilt`: lower bound on `sin(alpha)`. Keep small; large values deliberately
  suppress slope selectivity.
- `heightScale`: vertical simulation scale only.
- `gravity`, `pipeArea`, `pipeLength`: advanced virtual-pipe geometry/dynamics
  controls.
- `terrainSize`: the terrain's world width, from which ground spacing is
  derived. Refining the grid at a fixed `terrainSize` tightens the Courant
  limit, so authors who refine and want identical character should reduce `dt`
  proportionally.

The viewer should make `iterations`, `rain`, capacity, suspension, and
deposition the understandable primary controls. Numerical and pipe geometry
parameters remain Advanced.

## Limitations

- This is a visual, first-order, four-neighbor heightfield approximation, not a
  calibrated geophysical model.
- Semi-Lagrangian sediment advection is stable but diffusive and is not exactly
  globally conservative.
- The virtual-pipe flux scaling is positivity preserving locally but not a
  fully well-balanced Saint-Venant discretization. A true lake-at-rest state is
  not guaranteed to machine precision on arbitrary wet/dry topography.
- Closed boundaries can create artificial pools.
- There is no soil stratigraphy, hardness, vegetation, open-channel boundary,
  lateral bank undercutting, or exposed water/sediment output.
- Four-neighbor routing retains some grid anisotropy. The repair targets
  catastrophic spikes/checkerboards, not every directional signature.
