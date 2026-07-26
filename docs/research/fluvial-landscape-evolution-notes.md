# Fluvial Landscape Evolution Reference Audit

Status: **approved for Phase 10 implementation**
Reviewed: 2026-07-26 (erosion realism audit)
Scope: drainage-area-driven fluvial incision and deposition on a heightfield —
depression routing, multiple-flow-direction partitioning, flow accumulation,
the stream power incision law, and linear sediment deposition. This note does
not authorize vegetation, lithology/stratigraphy, glacial processes, debris-flow
rheology, groundwater, or a coupled tectonic model.

## Defect this note resolves

Theia's existing `hydraulic` node implements Mei et al. (2007) virtual pipes: a
shallow-water flow simulation over a handful of hundred steps. That model is
correct for what it is — the routing of water during a storm — but it is not a
landscape evolution model. Every cell interacts only with its four neighbours,
and nothing in the formulation represents *upstream drainage area*. The
resulting terrain is locally roughened noise with no channel hierarchy:
measured on `examples/erosion.json` the output shows no dendritic network, no
ridge/valley organization, no depositional landforms, and visible four-neighbour
grid anisotropy.

Real fluvial landscapes are organized by drainage area. A channel incises in
proportion to the discharge it carries, which is set by the area draining into
it; that feedback is what produces branching valley networks separated by sharp
divides, and it operates over geological time rather than over one storm.

## Primary and official references

1. Whipple, K. X., & Tucker, G. E. (1999). *Dynamics of the stream-power river
   incision model: Implications for height limits of mountain ranges, landscape
   response timescales, and research needs.* Journal of Geophysical Research:
   Solid Earth, 104(B8), 17661–17674. <https://doi.org/10.1029/1999JB900120>
   - Detachment-limited incision `E = K A^m S^n`.
   - When erosion is proportional to specific stream power, `m = 0.5, n = 1`;
     theoretical `n` between 2/3 and 7/3 is discussed.
   - `K` aggregates precipitation, channel width, bed roughness, and flood
     frequency; it is not an independently measurable constant.
   - Status: original publication; equations restated, no code copied.
2. Braun, J., & Willett, S. D. (2013). *A very efficient O(n), implicit and
   parallel method to solve the stream power equation governing fluvial
   incision and landscape evolution.* Geomorphology, 180–181, 170–179.
   - Implicit, linear-complexity solution that is unconditionally stable for
     large time steps, unlike explicit schemes.
   - Status: original publication; the implicit update form is restated below.
3. Yuan, X. P., Braun, J., Guerit, L., Rouby, D., & Cordonnier, G. (2019).
   *A New Efficient Method to Solve the Stream Power Law Model Taking Into
   Account Sediment Deposition.* Journal of Geophysical Research: Earth
   Surface, 124(6), 1346–1365. <https://doi.org/10.1029/2018JF004867>
   - Net elevation change is incision plus a deposition rate proportional to
     local suspended sediment flux `Qs`, to a dimensionless coefficient `G`,
     and inversely proportional to drainage area `A`.
   - Governs the transition from detachment-limited to transport-limited
     behaviour, and is the mechanism that forms alluvial fans.
   - Status: original publication; equations restated, no code copied.
4. Freeman, T. G. (1991). *Calculating catchment area with divergent flow based
   on a regular grid.* Computers & Geosciences, 17(3), 413–422.
   - Multiple-flow-direction partitioning: flow is shared among all downslope
     neighbours weighted by `S^p`.
   - Status: original publication. Quinn et al. (1991) is the parallel
     formulation; both are cited in the interoperability literature below.
5. Planchon, O., & Darboux, F. (2002). *A fast, simple and versatile algorithm
   to fill the depressions of digital elevation models.* Catena, 46(2–3),
   159–176.
   - Iterative descending relaxation from an over-raised surface; each cell is
     lowered toward `max(h_original, min(filled neighbours) + epsilon)`.
   - Status: original publication; the relaxation form is data-parallel and is
     restated below.
6. Cordonnier, G., Bovy, B., & Braun, J. (2019). *A versatile, linear complexity
   algorithm for flow routing in topographies with depressions.* Earth Surface
   Dynamics, 7, 549–562. <https://esurf.copernicus.org/articles/7/549/2019/>
   - Establishes that correct handling of depressions is required for a stable
     landscape evolution model, and that filling is one admissible resolution.
   - Status: open-access publication; used to justify the routing policy.

Supporting interoperability reference, not a physics source: Jain et al. (2024),
*FastFlow: GPU Acceleration of Flow and Depression Routing for Landscape
Simulation*, Computer Graphics Forum — confirms that flow and depression routing
are the accepted GPU bottleneck and are addressed by parallel relaxation rather
than by sequential priority queues.

## Quantities, domains, and interpretation

- `h` — bed elevation in world vertical units, `h = input * heightScale`. The
  graph input and output remain normalized heights in `[0,1]`.
- `cell` — ground spacing, derived from the graph's `world.terrainSize` and the
  grid exactly as in `terrain-horizontal-scale-notes.md`. Scale is graph state,
  not a node param, so every operator sees the same terrain. Fluvial results are
  therefore resolution-stable by construction.
- `A` — upstream drainage area in world area units. A cell contributes its own
  footprint `cell^2` plus everything routed into it.
- `S` — downstream slope, dimensionless.
- `Qs` — suspended sediment flux, world volume per unit time.
- `K` — erodibility. Dimensionally dependent on `m` and `n`; it is a
  procedural authoring coefficient here, not a calibrated geological rate.
- `G` — dimensionless deposition coefficient. `G = 0` is purely
  detachment-limited; increasing `G` moves toward transport-limited behaviour
  and builds depositional landforms.
- `dt` — integration step in abstract time units. Together with `iterations` it
  sets total simulated time; neither is a calibrated duration.

No SI calibration is claimed. The parameters are authoring controls whose
*relative* behaviour follows the cited equations.

## Governing equations

### 1. Depression routing

Flow routing requires a surface with no interior minima, or every basin traps
its drainage and incision stops. Following Planchon & Darboux, a routing-only
copy `w` is relaxed from above:

```
w_0(x) = +LARGE            for interior cells
w_0(x) = h(x)              on the domain boundary
w_{k+1}(x) = max( h(x), min over neighbours n of ( w_k(n) + eps ) )
```

`w` converges downward to the depression-filled surface. `eps > 0` guarantees a
strictly descending path to the boundary so routing always terminates. The
relaxation is a pure gather and is therefore data-parallel.

**`w` derives flow directions AND the slope used for incision.** Using the true
surface `h` for slope was tried first and is wrong: inside a basin the routing
weights point toward the outlet while `h` still falls toward the pit, so the
weighted slope collapses to zero, the basin never incises, and the surface
update's monotonicity guard clamps the cell *up* to its routing receiver —
aggrading the basin into a flat polygonal shelf. Measuring slope on `w` treats
the lake surface as the water surface: the bed does not incise (standing water
does not cut rock) while the outlet, where `w` regains a real gradient, does.

Filling never writes into the exported terrain; `w` is a separate buffer.

### 2. Multiple-flow-direction weights

For the eight neighbours of a cell, with `d_i` the centre-to-centre distance
(`cell` orthogonally, `cell*sqrt(2)` diagonally):

```
S_i = max(0, (w(x) - w(n_i)) / d_i)
r_i = S_i^p / sum_j S_j^p          (0 if all S_j are 0)
```

`p = 1.1` is Freeman's default exponent. Larger `p` concentrates flow and
sharpens channels; `p -> inf` degenerates to D8. MFD is used specifically
because D8 quantizes flow into eight directions and produces the diagonal grid
streaking visible in the current `hydraulic` output.

Because `w` has no interior minima, at least one `S_i` is positive at every
interior cell, so `r` is always defined.

### 3. Flow accumulation

Drainage area satisfies

```
A(x) = cell^2 * rain(x)  +  sum over upslope u of  r_{u->x} * A(u)
```

This is a gather over the eight neighbours and is solved by Jacobi relaxation.
Because `w` strictly descends, the dependency graph is a DAG and the iteration
converges in at most the length of the longest flow path. Each solve is warm-
started from the previous timestep's `A`, so only the first timestep pays the
full path length.

Partial convergence is admissible and self-correcting: `A` is monotonically
non-decreasing under the iteration, so an under-converged step under-erodes
rather than producing spurious channels, and the drainage pattern is reinforced
across timesteps.

### 4. Incision and deposition

Following Whipple & Tucker with the Yuan et al. deposition term:

```
E(x)      = K * A(x)^m * S_d(x)^n           incision rate
D(x)      = G * Qs(x) / A(x)                deposition rate
dh/dt     = U - E + D + Kd * laplacian(h)   with hillslope diffusion
```

### Slope floor in depressions

Incision uses `max(S, minSlope)`. Inside a filled depression the routing surface
is flat by construction, so the unfloored slope is `~fillEpsilon` and the basin
can never incise. Measured on a 512 grid, that made closed basins **permanent
sinks**: hillslope diffusion kept transporting material in from the rim with no
fluvial process removing it, and the featureless fraction of the surface *grew*
with run length — 13.5% at 60 steps rising to 18.2% at 250, instead of draining.
Diffusion was the dominant driver (7.8% versus 18.2% at 250 steps with diffusion
off), which is the signature of infill rather than of deposition.

The floor is the same device as `minTilt` in the audited hydraulic node: a lower
bound on the gradient used for transport, standing in for sub-grid relief the
sampled surface cannot resolve.

**It applies only above the waterline.** Applying it inside filled depressions
was tried and is wrong. The filled surface there is a distance field radiating
from the basin outlet, and the gradient of a distance field on a grid runs in
straight geodesics; the floor let those synthetic lines incise, carving a
dead-straight canyon across the basin. Measured on a 512 grid, the longest
perfectly-vertical channel run doubled from 35 rows to 72. Restricting the floor
to cells where the routing surface meets the true surface returns that to the
35-row baseline. A submerged cell keeps its raw near-zero slope, so a lake bed
stays flat — which is what a lake bed does.

The consequence is that the floor no longer mitigates the basins: the featureless
fraction returns to 13.3% from 10.2%. That trade is deliberate. A flat lake bed
is an honest consequence of depression filling; a straight canyon is a routing
artifact, and an artifact that reads as unnatural is worse than a landform that
reads as underdeveloped.

This is a **mitigation, not a complete solution**. The rigorous treatment is
lake-aware routing (Cordonnier et al. 2019), where a depression and its outlet
are identified as one unit and the lake surface lowers with the outlet as it
incises. That requires connected-component labelling of basins, which is not
implemented. Raising `minSlope` further keeps shrinking the flat area but
inflates total relief (at `0.012` the surface exceeds its normalized range),
so it cannot be pushed arbitrarily.

### Nonlinear transport, and why linear was replaced

Hillslope transport follows Roering, Kirchner & Dietrich (1999):

```
qs = Kd * S / (1 - (S/Sc)^2)
```

Linear diffusion (the `Sc -> infinity` limit) is scale-indiscriminate: it smooths
every wavelength at one rate, so the coefficient needed to erase one-cell grooves
also erases broad relief. Measured on a 512 grid at 60 steps, the linear term at
its tuned coefficient left **27.8%** of the surface featureless. The nonlinear
law diverges as the gradient nears `Sc`, so steep groove walls are transported
far faster than gentle ground at the same `Kd`; the base coefficient can drop by
more than an order of magnitude and still suppress grooves. At `Kd = 0.02`,
`Sc = 0.6` the featureless fraction is **12.6%**, against 6.9% with transport
disabled entirely and grooves fully present.

Roering et al. motivate this directly: hillslope curvature is convex near divides
but becomes increasingly planar downslope, which linear diffusion cannot
reproduce.

The amplification is capped at 10x (`S/Sc <= 0.9487`). The true law is singular
at `S = Sc` and an unbounded effective diffusivity has no stable explicit step.
The host sizes its substep budget from the same cap, so the two cannot disagree.

**Resolution sensitivity.** The diffusion number is `Kd*dt/cell^2`, so a fixed
`Kd` smooths a fixed *world* distance and therefore fewer *cells* as the grid
coarsens. Grooves are a grid-scale artifact, so groove suppression is not
resolution-invariant the way the fluvial terms are: the defaults are tuned at
512, and a coarse grid needs a larger `Kd` for the same visual result. This is a
genuine limitation of treating a grid artifact with a physical transport law.

### Hillslope diffusion is not optional

The final term is soil creep, following Culling (1960). It is required, not a
refinement. Stream power incision is **scale-free**: `E = K A^m S^n` is nonzero
at a drainage area of one cell, so incision alone cuts a channel at every cell
and packs the surface with parallel grid-scale grooves. Measured on the first
implementation, which omitted this term, the result was uniform one-cell gullies
covering every hillslope — visually a corduroy texture rather than terrain.

Diffusion dominates where drainage area is small and incision dominates where it
is large. The crossover between them is what sets **valley spacing** and hence
drainage density; Perron, Dietrich & Kirchner, *Controls on the spacing of
first-order valleys* (JGR Earth Surface), establish this competition as the
control on landscape dissection scale. `diffusion` is therefore the practical
drainage-density control, not a smoothing cosmetic.

Explicit five-point diffusion is stable only for `Kd*dt/cell^2 <= 0.25`. The
per-step amount is split into equal substeps each held below `0.2`, rather than
clamping the coefficient, so raising `diffusion` keeps taking effect instead of
silently saturating at the stability bound.

Additional reference:

7. Culling, W. E. H. (1960). *Analytical Theory of Erosion.* Journal of Geology,
   68(3), 336–344 — the diffusion equation for soil creep on hillslopes.

`U` is a uniform uplift rate. It **defaults to zero**, which is a deliberate
departure from the geomorphological use of the model. Non-zero uniform uplift
drives the surface toward the stream-power steady state `U = K A^m S^n`, whose
form is a property of the model rather than of the input; running to that state
measurably erases the authored terrain. Zero uplift instead treats the model as
an erosion operator applied to an existing surface, which is the authoring
behaviour Theia wants. `U > 0` remains available for users who do want an
equilibrium landscape.

`S_d` is the flow-weighted downstream slope measured on the **routing
(depression-filled) surface**, not on the raw bed. Inside a lake the filled
surface is flat to within `fillEpsilon`, so the lake bed does not incise —
standing water does not cut rock — while at the outlet the filled surface
recovers a true gradient, so the outlet incises and the basin drains over the
run. Measuring `S_d` on the raw bed was tried first and is incorrect: every
depression is then frozen at zero slope while the surrounding terrain erodes,
leaving untouched polygonal shelves at the fill boundaries.
Sediment flux is routed with the same weights:

```
Qs(x) = sum over upslope u of r_{u->x} * ( Qs(u) + E(u) * cell^2 - D(u) * cell^2 )
```

`Qs` is clamped at zero; a cell cannot deposit sediment that was never eroded.
Because `D` is inversely proportional to `A`, deposition is negligible in large
trunk channels and dominant where a steep tributary discharges onto a low-slope
surface — which is precisely the alluvial-fan condition.

### 5. Stability

The explicit update `h -= dt * (E - D)` is conditionally stable. Braun & Willett
give the implicit form; Theia additionally enforces two guards:

```
dh per step  <=  frac * (h(x) - h_downstream)          frac = 0.5
h(x)         >=  h_downstream                          after the update
```

The first is a Courant-like limit preventing a cell from incising past its own
receiver in one step. The second forbids drainage reversal outright. Together
they keep the surface monotone along every flow path, which is the property
that prevents the spike/checkerboard failure mode already documented for
`hydraulic` in `hydraulic-erosion-stability-notes.md`.

Both guards apply **only when the receiver lies below the cell on the true
surface**. Because routing follows the filled surface, a cell inside a basin
can have a receiver that is higher than it; clamping up to such a receiver
aggrades the basin into a flat shelf, fabricating a landform under the guise of
a stability correction. Measured effect of the guards as specified: spike count
falls from 126 to 96 and the number of cells with no lower eight-neighbour falls
from 253 to 147 over a 24-step run, i.e. the operator strictly improves both
spike count and drainage connectivity.

Note that these guards do **not** bound the maximum neighbour height difference,
and must not be tested as if they did. Incision deepens channels relative to
their banks, so a correct run raises that statistic; it is the intended output,
not an artifact.

## Boundary conditions and failure policy

- Domain edges are fixed-elevation outlets: flow leaves the grid and is not
  reflected. This is the standard open-boundary condition for a detached
  terrain tile and prevents rim-pooling artifacts.
- `A` is strictly positive everywhere (every cell contributes its own area), so
  the `Qs/A` division is defined without an epsilon guard.
- All parameters are validated finite before dispatch; non-finite values fail
  with the node id rather than propagating NaN into the heightfield.
- `K`, `G`, `dt`, `m`, `n`, and `p` are clamped to a documented procedural
  envelope. Clamping is silent for file/API values, consistent with the
  existing erosion nodes.
- Output is renormalized to `[0,1]` only if the incision drove values outside
  it; the node otherwise preserves the input's vertical placement.

## Executable invariant mapping

| Requirement | Test obligation |
|---|---|
| Finiteness | every output texel finite and within `[0,1]` |
| Determinism | identical input and parameters reproduce bitwise-identical output |
| Non-identity | erosion measurably changes the terrain |
| Drainage monotonicity | accumulated area never decreases downstream |
| Area conservation | total accumulated area equals cell count times rain |
| Flow-path monotonicity | no cell ends below its receiver |
| Channel hierarchy | flow accumulation is heavy-tailed, not uniform — the property distinguishing a drainage network from noise |
| Deposition behaviour | `G > 0` produces net deposition somewhere; `G = 0` produces none |
| Drainage density | raising `diffusion` measurably lowers grid-scale surface curvature |
| Diffusion stability | the maximum allowed coefficient stays finite and bounded |
| Bounded authoring | every parameter's UI range equals its core clamp, contains its own default, and never follows the live value |
| Basin drainage | raising `minSlope` reduces the featureless surface fraction |
| Edge continuity | the domain rim does not stand proud of the interior after erosion |
| Depression handling | a synthetic pit routes to the boundary rather than trapping flow |
| Resolution stability | channel statistics bounded across 128/256/512 at fixed `terrainSize` |
| Stability envelope | no isolated one-cell extrema introduced beyond the input's own |

## Limitations

- Single lithology. No stratigraphy, hardness variation, or regolith depth, so
  the layered mesa benches visible in some references are not reproduced by
  this node; they require a separate stratification pass.
- No explicit hillslope process. Ridge rounding and scree remain the job of the
  existing `thermal` node, which is the intended companion pass.
- Deposition is the linear `G*Qs/A` model. It does not resolve grain size,
  braiding, or channel avulsion, so it produces fan-shaped aggradation rather
  than resolved braided channels.
- `A` is a purely topographic drainage area; there is no infiltration,
  evapotranspiration, or spatially varying precipitation beyond a scalar rain
  multiplier.
- Depression handling is filling plus a slope floor, not lake-aware routing.
  Large closed basins still under-dissect relative to the surrounding terrain,
  and the floor trades that against total relief. Basins are no longer growing
  sinks, but they are not resolved to the standard of Cordonnier et al. (2019).
- Time is abstract. Parameters are not calibrated to erosion rates and must not
  be presented as geological measurements.

## Attribution and license decision

The implementation is an original integration of published equations. No
third-party source code, shader, or dataset from FastScape, fastscapelib,
FastFlow, or any other implementation is copied or adapted. Project code remains
MIT and this feature adds no redistributable dependency.
