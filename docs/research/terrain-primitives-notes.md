# Metal-Native Terrain Primitive Library Reference Audit

Status: **approved for Terrain Primitive Library implementation**
Reviewed: 2026-07-26
Scope: fourteen new zero-input, deterministic terrain generators with
Metal-native analytic upland construction:
`rollinghills`, `canyon`, `crater`, `craterfield`, `dunesea`, `mountain`,
`mountainrange`, `mountainside`, `plates`, `ridge`, `rugged`, `slump`,
`uplift`, and `volcano`. The existing `perlin` generator remains supported and
numerically unchanged. The legacy `ridged` generator is removed rather than
renamed. `island` is deferred.

This note authorizes only scalar heightfield generation, including Canyon's
specific hybrid composition of a Metal upland base with the already-audited
deterministic River/RiverCarve path. It does not authorize erosion changes, new
hydrology, stratigraphy, material masks, multi-field graph outputs, tectonic
simulation, any other CPU primitive/fallback path, or UI implementation.

## Decision summary

- Every accepted primitive is a zero-input generator with one finite normalized
  heightfield output in `[0,1]`. Analytic fields execute in 2D Metal kernels.
  `canyon` is the deliberate hybrid exception: Metal generates its upland base,
  then the node reuses Theia's already-audited deterministic `RiverNode` /
  `RiverCarveNode` routing and carving path (or shared functions extracted
  without changing their equations).
- All new analytic stochastic choices come from the exact unsigned 32-bit hash
  specified below. There is no mutable RNG state, thread-order dependence,
  atomic scatter, permutation texture, or host-language random source.
  Canyon routing retains `RiverNode`'s existing deterministic seeded hash
  unchanged as part of the approved hybrid reuse boundary.
- The shared mathematical vocabulary is deterministic Perlin fBm, exact
  two-nearest Worley distances, analytic signed-distance constructions, and
  analytic domain warping. These constructs are independently implemented from
  the publications below; no third-party source code is copied.
- `canyon` is the only drainage-aware primitive. It generates a broad base
  surface, then reuses the connected route and bounded carve behavior already
  implemented by `RiverNode` and `RiverCarveNode`, whose depression
  conditioning and drainage basis is documented in
  `metal-and-hydrology-notes.md` and the approved fluvial research. It does not
  introduce a second hydrology formulation.
- `ridge` means a finite, authored ridge landform built from a warped capsule
  SDF. It is not the old `ridged` multifractal and there is no silent migration
  between the two node ids.
- Craters and dunes are morphology-inspired procedural approximations. Their
  parameters are normalized authoring controls, not claims of planetary age,
  impact energy, sediment size, wind speed, or geological time.
- Output-dependent min/max normalization is forbidden. It makes one pixel or a
  seed change rescale the whole terrain and breaks resolution comparisons.
  Every primitive instead has a fixed analytic baseline and amplitude mapping.

## Primary and official references

1. Perlin, K. (1985). *An Image Synthesizer*. SIGGRAPH Computer Graphics,
   19(3), 287–296. <https://doi.org/10.1145/325165.325247>
   - Original gradient-noise construction and use of procedural noise as a
     continuous function.
2. Perlin, K. (2002). *Improving Noise*. ACM Transactions on Graphics, 21(3),
   681–682. <https://doi.org/10.1145/566654.566636>
   - Quintic fade polynomial with zero first and second derivatives at lattice
     boundaries.
3. Worley, S. (1996). *A Cellular Texture Basis Function*. Proceedings of
   SIGGRAPH 96, 291–294. <https://doi.org/10.1145/237170.237267>
   - Cellular feature points and ordered nearest-feature distances `F1`, `F2`.
4. Hart, J. C. (1996). *Sphere Tracing: A Geometric Method for the Antialiased
   Ray Tracing of Implicit Surfaces*. The Visual Computer, 12, 527–545.
   <https://doi.org/10.1007/s003710050084>
   - Distance-function primitives and constructive composition. This note uses
     the distance representation, not Hart's renderer.
5. McGetchin, T. R., Settle, M., & Head, J. W. (1973). *Radial Thickness
   Variation in Impact Crater Ejecta: Implications for Lunar Basin Deposits*.
   Earth and Planetary Science Letters, 20(2), 226–236.
   <https://doi.org/10.1016/0012-821X(73)90162-3>
   - Ejecta thickness decreases approximately as an inverse third power of
     radial distance.
6. Pike, R. J. (1977). *Size-dependence in the Shape of Fresh Impact Craters
   on the Moon*. In *Impact and Explosion Cratering*, 489–509.
   <https://ntrs.nasa.gov/citations/19780005083>
   - Fresh crater morphology separates floor/cavity, wall, rim, and exterior
     ejecta; simple and complex crater proportions depend on diameter.
7. Werner, B. T. (1995). *Eolian Dunes: Computer Simulations and Attractor
   Interpretation*. Geology, 23(12), 1107–1110.
   <https://doi.org/10.1130/0091-7613(1995)023%3C1107:EDCSAA%3E2.3.CO;2>
   - Dune fields arise from local transport and develop organized crest
     spacing. The present node reproduces morphology only, not this transport
     simulation.
8. Parteli, E. J. R., Durán, O., Tsoar, H., Schwämmle, V., & Herrmann, H. J.
   (2009). *Dune Formation on the Present Mars*. Physical Review E, 80,
   011301. <https://doi.org/10.1103/PhysRevE.80.011301>
   - Relates dune wavelength and shape to flux adaptation and documents the
     long stoss/short slip-face asymmetry represented procedurally below.
9. Whipple, K. X., & Tucker, G. E. (1999). *Dynamics of the Stream-Power River
   Incision Model*. Journal of Geophysical Research, 104(B8), 17661–17674.
   <https://doi.org/10.1029/1999JB900120>
   - Drainage area and downstream slope organize channels. The canyon node uses
     the approved drainage-area construct, not a new incision law.
10. Freeman, T. G. (1991). *Calculating Catchment Area with Divergent Flow
    Based on a Regular Grid*. Computers & Geosciences, 17(3), 413–422.
    <https://doi.org/10.1016/0098-3004(91)90048-I>
    - Multiple-flow-direction weights proportional to a power of slope.
11. Planchon, O., & Darboux, F. (2002). *A Fast, Simple and Versatile Algorithm
    to Fill the Depressions of Digital Elevation Models*. Catena, 46(2–3),
    159–176. <https://doi.org/10.1016/S0341-8162(01)00164-3>
    - Depression conditioning used by `canyon`, already approved in the
      fluvial audit.
12. Apple, *Metal Shading Language Specification*.
    <https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf>
    - Official execution and numeric-language contract for the independent
      kernels.

The Gaea Rivers and HydroFix documentation already recorded in
`metal-and-hydrology-notes.md` is an interoperability/authoring reference, not
an algorithm source:
<https://docs.gaea.app/reference/nodes/simulate/rivers.html> and
<https://docs.gaea.app/reference/nodes/simulate/hydrofix.html>.

## Coordinates, quantities, and normalization

For output sample `(x,y)` in a `W` by `H` heightfield:

```
u = x / max(W - 1, 1)
v = y / max(H - 1, 1)
q = (u, v)                  in [0,1]^2
p = q - (0.5, 0.5)         centered normalized world coordinates
```

The separate `W-1` and `H-1` denominators are mandatory. Dividing both axes by
`W`, as the current Perlin kernel does, distorts frequency and radial features
on a non-square grid and fails to sample the exact upper domain boundary.
This correction applies to new primitives only: `perlin` remains numerically
unchanged until a separately approved compatibility change.

The graph's world domain is a square, consistent with
`terrain-horizontal-scale-notes.md`; consequently Euclidean length in `p` is
the physical normalized planimetric metric even when a rectangular raster is
requested. A circle in that metric remains a circle on the square terrain
surface. No assumption of square pixel counts is allowed in a kernel.

Quantities used by the library:

- `q`, `p`, centers, radii, widths, wavelengths, and warp displacement are
  dimensionless fractions of the domain side.
- `frequency` is cycles or feature cells per domain side.
- Public `direction` is authored in degrees and converted once to radians.
- `height`, `depth`, `rimHeight`, and other normalized shape controls are
  dimensionless `[0,1]` authoring quantities. They do not represent metres.
- `octaves` and `count`/`density` controls are dimensionless integers.
- Canyon drainage `A` is normalized by total domain area after accumulation:
  `a = clamp(A / A_domain, 0, 1)`. It is therefore comparable across
  resolutions.
- For canyon routing, `dx=1/max(W-1,1)`, `dy=1/max(H-1,1)`, orthogonal and
  diagonal neighbor distances are computed from those two spacings, and every
  sample contributes `cellArea=1/(W*H)`. Thus `A_domain=1` exactly. On a square
  grid this differs from the audited `cell^2` source only by a global scalar,
  which cancels in the normalized area; on a rectangular grid it prevents
  direction and coverage from inheriting pixel-count aspect.
- New primitive output is `h = clamp(b + height*z, 0, 1)`, where `b` is the
  fixed analytic baseline for a signed morphology or zero for a positive
  morphology. The existing `perlin.heightScale` remains a separate compatibility
  parameter. Saturation is permitted; data-dependent renormalization is not.

## Deterministic shared constructs

### Unsigned hash and unit conversion

All integer arithmetic below is modulo `2^32` and uses Metal `uint`. Negative
lattice coordinates are converted to `uint` by their two's-complement bit
pattern.

```
hash2(x, y, seed):
    h = seed + 0x9E3779B9
    h = (h xor (x * 0x85EBCA77))
    h = (h xor (h >> 15)) * 0xC2B2AE3D
    h = (h xor (y * 0x27D4EB2F))
    h = (h xor (h >> 13)) * 0x165667B1
    return h xor (h >> 16)

unit24(h) = float(h >> 8) / 16777216
```

`unit24` is exactly in `[0,1)` and avoids relying on conversion of all 32 random
bits to single-precision float. Independent channels use documented seed xors,
not repeated calls to mutable state:

```
rx = unit24(hash2(cx, cy, seed xor 0xA511E9B3))
ry = unit24(hash2(cx, cy, seed xor 0x63D83595))
rv = unit24(hash2(cx, cy, seed xor 0xB5297A4D))
```

The operation order and constants form serialized behavior. Changing them
requires a migration and new reference fixtures.

### Gradient noise and fBm

The existing `perlin` behavior is the compatibility baseline:

```
fade(t) = 6t^5 - 15t^4 + 10t^3
g(i,j)  = (cos(theta), sin(theta))
theta   = 2*pi*hash2(i,j,seed) / 2^32
n(p)    = bilinear interpolation, using fade(fract(p)),
          of the four dot(g, p - latticeCorner) values

fbm(p) = (sum[o=0..O-1] a_o * sqrt(2) * n(f_o*p, seed + 1013*o))
         / sum[o=0..O-1] a_o
a_0 = 1; a_(o+1) = gain * a_o
f_0 = frequency; f_(o+1) = lacunarity * f_o
```

New kernels may place this logic in one shared MSL source string, but the
`perlin` output must first pass its existing fixed-seed fixture. The `sqrt(2)`
factor maps the observed 2D gradient-noise envelope toward `[-1,1]`; every
consumer clamps or analytically bounds the result.

Within one device and OS/runtime, identical parameters must produce identical
floats. Across Apple GPU families, trigonometric implementation differences may
change low bits, so portable tests use `1e-6` element tolerance plus stable
summary statistics rather than byte identity. Atomics, `fast::` math, and
unordered reductions are forbidden.

### Worley `F1` and `F2`

For point `r` expressed in feature-cell coordinates, each integer cell `c`
contains exactly one feature:

```
feature(c) = c + (rx(c), ry(c))
d(c)       = length(r - feature(c))
F1, F2     = the smallest and second-smallest d(c)
cellValue  = rv(cell that supplied F1)
```

The kernel searches the full `5x5` cell neighborhood centered at `floor(r)`.
This conservative neighborhood makes the second-nearest result exact for
unit-bounded jitter; a `3x3` shortcut is not accepted for `F2`. Ties are broken
lexicographically by `(cy,cx)`, making cell ownership deterministic.

Required identities:

```
0 <= F1 <= F2
edgeDistance = F2 - F1 >= 0
```

`plates`, `craterfield`, and `uplift` use these results. Cellular points are
defined on the whole integer plane and the output is merely cropped, so feature
cells at an image boundary are not truncated or reflected.

### Domain warp

Warp is a vector field made from decorrelated low-octave fBm:

```
w(p) = (fbm(p + (17.1, 31.7), seed xor 0x68BC21EB),
        fbm(p + (43.6, 11.9), seed xor 0x02E5BE93))
p'   = p + warp * w(p)
```

`warp` is a normalized domain displacement. The analytic source field is
sampled at `p'`, including outside `[−0.5,0.5]^2`; it is not clamped back to the
border. This avoids edge plateaus. One warp stage is the default. Recursive
warping is out of scope because it makes frequency and displacement controls
hard to bound.

### Signed-distance primitives and composition

The primitive library uses:

```
sdCircle(p,c,r) = length(p-c) - r

sdSegment(p,a,b,r):
    t = clamp(dot(p-a,b-a) / max(dot(b-a,b-a), 1e-12), 0, 1)
    return length(p - mix(a,b,t)) - r

smin(a,b,k):
    h = clamp(0.5 + 0.5*(b-a)/max(k,1e-6), 0, 1)
    return mix(b,a,h) - k*h*(1-h)
```

The first two are exact Euclidean distances to a circle and capsule. `smin` is
a bounded polynomial soft union used only for visual composition; it is not
treated as an exact distance after blending. A landform shell is
`exp2(-abs(d)/width)` and a filled form is
`1-smoothstep(-width,width,d)`. Every width is clamped above `1e-5`.

## Morphology constructs

### Crater

Let `rho = length(p' - center) / radius`. A simple crater displacement is:

```
cavity(rho) = -depth * (1 - rho^2)^2                  for rho < 1, else 0
rim(rho)    = rimHeight * exp(-((rho - 1)/rimWidth)^2)
ejecta(rho) = ejecta * rimHeight * max(rho,1)^(-3)
              * (1 - smoothstep(1, 1 + ejectaExtent, rho))
rays        = 1 + roughness * fbm_polar(angle, log2(max(rho,1)), seed)
z           = cavity + rim + ejecta*rays
h           = clamp(0.5 + height*z, 0, 1)
```

The inverse-cube exterior term follows McGetchin et al.; the finite support
prevents one crater from lifting the whole tile. The quartic bowl and Gaussian
rim are smooth procedural approximations to the cavity/rim regions measured by
Pike, not a ballistic impact simulation. At `rho=0`, the bowl is exactly
`-depth`; at `rho=1`, the cavity is zero and the rim is at its maximum.

`craterfield` hashes one crater center in each Worley feature cell. Public
`density` maps to a feature grid frequency `ceil(sqrt(density))`; it is an
expected population control rather than an exact count. A separately hashed
occupancy test accepts each candidate with probability
`density / ceil(sqrt(density))^2`, avoiding the square-count bias. Domain radius
is `0.15*scale*mix(1-sizeVariation,1+sizeVariation,rv)`. The search
neighborhood is derived from the largest supported radius and bounded to
`[-10,10]` cells rather than fixed to image edges. Rim width is at least 1.25
output pixels in radial coordinates to prevent undersampled spike rings.
Contributions are added in fixed row-major cell order. Overlap is deliberate
and deterministic.

### Dune field

For wind unit vector `e=(cos(theta),sin(theta))` and crosswind vector
`t=(-e.y,e.x)`:

```
phase = fract(dot(p,e)/wavelength
              + 0.45*warp*fbm((dot(p,t)/scale,
                               dot(p,e)/(4*scale)), seed)
              + 0.18*chaos*fbm(p, 1.2/scale,
                               seed xor phaseConstant))

rise = smoothstep(0, 1, phase/stoss)                  if phase <= stoss
fall = 1 - smoothstep(0, 1, (phase-stoss)/(1-stoss))  otherwise
dune = rise or fall
envelope = (0.75 + 0.25*fbm(p*0.5*frequency, seed xor constant))
           * (1 + roughness*fbm(p*4*frequency, seed xor otherConstant))
h = clamp(height * dune * envelope, 0, 1)
```

`stoss > 0.5` gives a long upwind stoss slope and short lee/slip face, the key
cross-section invariant. The two bounded phase terms bend crest planform and
break mechanically straight repetition without changing the authored mean
wavelength. This is a stationary morphology generator, not Werner's or Parteli
et al.'s sediment-transport solver; no conservation or wind-time claim is made.

### Drainage-conditioned canyon

`canyon` generates a broad warped rolling surface `b(q)` in Metal from
three-octave fBm. To keep cell-based routing widths resolution-independent, it
does this work on a bounded internal raster whose longest axis is 256 samples
and whose shorter axis preserves the requested aspect ratio. It then invokes
the same deterministic connected-network path as `RiverNode`, or a
byte-for-byte/shared-function refactor of that path:

```
route = RiverNode.conditionedConnectedMask(
    terrain=b,
    seed=seed,
    water=clamp(branches/32, 0, 1),
    widthCells=clamp(0.5 + 12.5*width, 0.5, 8),
    headwaters=branches)
```

This path conditions depressions to keep downstream traces connected to an
outlet, estimates drainage area, selects deterministic headwaters, and traces
through valley/flow corridors. The final terrain reuses the bounded
`RiverCarveNode` operation:

```
carved = RiverCarveNode(
    terrain=b,
    mask=route,
    depth=depth,
    downcutting=wallSharpness,
    riverValleyWidth=clamp(2 + (20/3)*width, 2, 6),
    shorelineWidth=clamp(1 + 5*width, 1, 4),
    shorelineSharpness=wallSharpness)
enhanced = max(0, base - 5.5*max(base-carved, 0))
h = clamp(height * bilinearResample(enhanced), 0, 1)
```

Routing uses open boundary outlets. Its exact priority-flood/connected-path
behavior and tie ordering remain those of the existing nodes. The fixed
authoring mappings and bounded monotone post-carve gain above are specific to
the Canyon primitive; they do not alter the public River or River Carve nodes.
A visually similar noise groove is not conforming. An implementation may call
the two nodes internally or extract shared deterministic functions, but must
prove equivalence with the executable fixtures below.

The node does **not** apply stream-power incision, sediment deposition,
diffusion, or iterative landscape evolution. This keeps it a bounded primitive
and avoids duplicating `fluvial`. The hybrid is permitted even though the other
thirteen primitives are one-pass Metal analytics: connected routes are more
important than pretending an arbitrary noise groove is a canyon.

## Exact node and parameter mapping

The public schema below is authoritative. Internal `frequency`, `radius`,
octave, persistence, SDF, routing, and carve quantities are derived and must
not appear as additional serialized parameters.

Shared ranges are: `seed` integer `[0,9999]`; `scale` `[0.05,1.5]`; `direction`
`[0,360]` degrees; `x`,`y` `[-1,1]`; `length` `[0.25,2]`; `width`
`[0.02,0.6]`; `branches` integer `[1,32]`; `density` integer `[1,64]`; `peaks`
integer `[1,12]`; `lobes` integer `[1,8]`; `folds` integer `[1,12]`;
`foldWidth` `[0.01,0.5]`. Every other named shape control in the table has
range `[0,1]`. Finite out-of-range file/API values clamp to these limits;
non-finite values fail with node and parameter name. Integer controls round to
nearest integer after validation.

| Node id | Authoritative public parameters and defaults |
|---|---|
| `rollinghills` | `scale=0.65`, `height=0.55`, `softness=0.70`, `undulation=0.40`, `warp=0.15`, `seed=1337` |
| `canyon` | `scale=0.75`, `height=0.78`, `depth=0.55`, `width=0.10`, `branches=12`, `wallSharpness=0.65`, `roughness=0.25`, `seed=1337` |
| `crater` | `scale=0.45`, `height=0.80`, `depth=0.55`, `rimHeight=0.22`, `rimWidth=0.18`, `irregularity=0.15`, `ejecta=0.20`, `x=0`, `y=0`, `seed=1337` |
| `craterfield` | `scale=0.22`, `height=0.75`, `density=18`, `sizeVariation=0.60`, `rimHeight=0.20`, `age=0.35`, `irregularity=0.18`, `seed=1337` |
| `dunesea` | `scale=0.18`, `height=0.42`, `direction=0`, `asymmetry=0.65`, `sharpness=0.55`, `chaos=0.25`, `warp=0.15`, `seed=1337` |
| `mountain` | `scale=0.65`, `height=0.90`, `bulk=0.58`, `roughness=0.38`, `warp=0.20`, `x=0`, `y=0`, `seed=1337` |
| `mountainrange` | `scale=0.70`, `height=0.90`, `length=1.25`, `width=0.24`, `direction=25`, `peaks=5`, `roughness=0.40`, `warp=0.25`, `x=0`, `y=0`, `seed=1337` |
| `mountainside` | `scale=0.90`, `height=0.85`, `slope=0.65`, `direction=25`, `peak=0.50`, `detail=0.35`, `warp=0.15`, `x=0`, `y=0`, `seed=1337` |
| `plates` | `scale=0.35`, `height=0.70`, `flatness=0.75`, `boundaryUplift=0.35`, `tilt=0.20`, `warp=0.10`, `seed=1337` |
| `ridge` | `scale=0.75`, `height=0.85`, `length=1.30`, `width=0.12`, `direction=20`, `definition=0.70`, `fractures=0.35`, `warp=0.25`, `x=0`, `y=0`, `seed=1337` |
| `rugged` | `scale=0.55`, `height=0.85`, `bulk=0.60`, `roughness=0.70`, `fractures=0.45`, `warp=0.25`, `seed=1337` |
| `slump` | `scale=0.65`, `height=0.65`, `collapse=0.45`, `direction=20`, `softness=0.55`, `lobes=4`, `warp=0.15`, `seed=1337` |
| `uplift` | `scale=0.70`, `height=0.85`, `direction=20`, `folds=5`, `foldWidth=0.12`, `jitter=0.25`, `roughness=0.30`, `seed=1337` |
| `volcano` | `scale=0.55`, `height=0.90`, `mouth=0.22`, `calderaDepth=0.45`, `bulk=0.60`, `radialErosion=0.35`, `roughness=0.30`, `x=0`, `y=0`, `seed=1337` |

`perlin` retains its current exact public mapping and defaults:
`seed=1337`, `octaves=6`, `frequency=4`, `lacunarity=2`, `gain=0.5`,
`heightScale=1`. This gate does not authorize changing its coordinate
denominator, hash, gradients, defaults, output, or serialized parameter names.

### Per-node evaluation recipes

The table is the serialized contract. Derived variables below remove remaining
implementation choice without expanding it. Define:

```
sat(x)     = clamp(x,0,1)
smooth5(x) = x^3 * (x*(6x-15)+10)
center     = 0.5*(x,y) when x/y exist; otherwise (0,0)
frequency  = 1/max(scale,0.05)
noise(p)   = fbm(p, frequency, 5, 2, 0.5, seed)
rough(p,s) = clamp(1 + s*fbm(8p, seed xor 0xC13FA9A9), 0, 1+s)
warpDistance = 0.25*scale*warp
```

- `rollinghills`: compute `p'` with the shared warp,
  `n=mix(fbm(p',frequency,3,2,0.45,seed),
  fbm(p',0.5*frequency,2,2,0.5,seed xor 0x7F4A7C15),undulation)`,
  `x=pow(sat(0.5+0.5*n),mix(2.5,0.55,softness))`, and
  `h=sat(1.35*height*smooth5(x))`. The fixed gain keeps the deliberately
  low-frequency default readable without changing its spectrum.
- `canyon`: use
  `b=sat(0.5+0.5*fbm(p,frequency,3,2,0.5,seed))
  *rough(p,0.35*roughness)` as the Metal upland base, then apply the fixed-grid
  River/RiverCarve mapping stated in the canyon section. `branches` maps
  exactly to `headwaters`; `width` uses the bounded artist mapping there.
  `height` is the final vertical multiplier.
- `crater`: derive `radius=0.35*scale`, center as above,
  physical rim width `radius*mix(0.025,0.30,rimWidth)`, and ejecta extent
  `radius*mix(0.5,3,ejecta)`. Use the crater equations with cavity amplitude
  `height*depth`, rim amplitude `height*rimHeight`, ray amplitude
  `irregularity`, and final baseline `0.5`.
- `craterfield`: use a Worley grid frequency `ceil(sqrt(density))` and accept
  each candidate with probability `density/grid^2`. Derive
  `R_j=0.15*scale*mix(1-sizeVariation,1+sizeVariation,rv_j)`.
  Age scales cavity depth by `mix(1,0.45,age)`, rim by `mix(1,0.2,age)`, and
  ejecta by `mix(0.35,0,age)`. The radial rim width is
  `max(0.16,2.25/(R_j*min(W,H)))`, while
  `smoothstep(2,5,R_j*min(W,H))` attenuates rims that cannot be represented
  cleanly at the requested resolution. Sum fixed-order crater profiles with
  ray amplitude `irregularity`, then `h=sat(0.5+height*z)`.
- `dunesea`: use the dune equations above in oriented coordinates
  `q=(cross,along)`. Along-wind phase is
  `fract((along/scale)*clamp(1+0.75*chaos*
  fbm((q.x,0.35q.y),0.45/scale),0.55,1.45)
  +1.10*warp*fbm((q.x,0.22q.y),0.85/scale)
  +0.35*chaos*fbm((q.x,0.55q.y),1.20/scale))`. A broad continuity field
  derived from `fbm((q.x,0.55q.y),0.38/scale)` smoothly attenuates selected
  crest sections as `chaos` rises. This local wavelength variation, meander,
  and segmentation prevent an uninterrupted mechanical stripe field without
  obscuring wind direction. Clamp the final envelope to `[0,1+chaos]`, with
  wind angle `direction`,
  `stoss=0.5+0.45*asymmetry`, envelope roughness `chaos`, and cross-section
  exponent `mix(2.5,0.45,sharpness)`. The final amplitude is `height`.
- `mountain`: with `rho=length(p'-center)/radius`, use
  `radius=0.5*scale`, `shape=mix(3,0.55,bulk)`,
  `z=pow(sat(1-rho),shape)*rough(p',roughness)`, and `h=sat(height*z)`.
- `mountainrange`: let `e` be the angle direction, `t` its perpendicular, and
  endpoints `a=center-0.5*length*scale*e`,
  `b=center+0.5*length*scale*e`. The capsule envelope is
  `E=pow(sat(-sdSegment(p',a,b,width*scale)/(width*scale)),1.35)`. For summit `j`,
  `tau_j=(j+0.5+0.35*(2*rv_j-1))/peaks`, axial center
  `c_j=mix(a,b,tau_j)`, axial distance `s_j=dot(p'-c_j,e)`, and
  `P_j=exp2(-s_j^2/sigma_j^2)` where
  `sigma_j=max(0.18*width*scale,0.28*length*scale/peaks)`.
  `P=max_j(P_j)`, `z=E*(0.55+0.45*P)*rough(p',roughness)`, and
  `h=sat(height*z)`.
- `mountainside`: with direction normal `e`, local
  `d=dot(p'-center,e)/(0.5*scale)`, compute
  `side=pow(sat(0.5+0.5*d),mix(3,0.5,slope))` and summit influence
  `summit=peak*exp2(-length(p'-center)^2/(0.2*scale)^2)`.
  Add `detail*noise(4p')*side*(1-side)`, apply the shared warp, and
  `h=sat(height*sat(side+summit+detailTerm))`.
- `plates`: evaluate Worley at `(p'+0.5)/scale`.
  `boundary=1-smoothstep(0,mix(0.02,0.35,1-flatness),F2-F1)`,
  cell tilt is `tilt*dot(p'-featureCenter,unitHashDirection)`, and
  `z=0.15+0.55*cellValue+cellTilt+boundaryUplift*boundary`;
  `h=sat(height*z)`.
- `ridge`: use range-style endpoints
  `a=center-0.5*length*scale*e`, `b=center+0.5*length*scale*e`; equivalently
  evaluate axial coordinate `s` and lateral coordinate `q` in the `(e,t)`
  basis. Low-frequency axial fBm bends the centerline by at most
  `0.45*scale*warp`; let `d=abs(q-bend)` and `r=width*scale`.
  The C1 cross-section combines
  `E=exp2(-(d/(r*mix(1.25,0.70,definition)))^2)` and
  `S=exp2(-(d/(2.25r))^2)` as `0.25E+0.75S`, with support fading from
  `3r...4r`. The endpoint fades over normalized half-length `0.68...0.98`;
  bounded axial fBm modulates the crest between `0.88...1`. Fractures form
  smooth transverse saddles from an axial/lateral fBm signal and reduce the
  supported profile by at most `0.55*fractures`. Then apply `height` and
  saturate.
- `rugged`: let `n0=noise(p')` and
  `n1=fbm(3p',frequency,6,2.15,0.58,seed xor 0x91E10DA5)`.
  Use `x=sat(bulk*(0.5+0.5*n0)+roughness*0.5*abs(n1)
  +fractures*0.25*(1-smoothstep(0.02,0.18,F2-F1)))` and
  `h=sat(height*smooth5(x))`.
- `slump`: in local downslope/cross-slope basis `(e,t)`, use `L=lobes` pairs
  of equal-integral anisotropic Gaussians. For
  `tau_j=(j+0.5)/L-0.5`, place scarp centers
  `s_j=-0.18*scale*(1-4*tau_j^2)*e+1.2*scale*tau_j*t`
  and toe centers
  `d_j=(0.38+0.10*rv_j)*scale*e+
  (0.75*tau_j+0.08*(2*rv2_j-1))*scale*t`. Both use standard deviations
  `(mix(0.14,0.24,softness)*scale,
  mix(0.09,0.14,softness)*scale)` in `(e,t)`.
  With `G` the unit-height Gaussian,
  `z=(2.25*collapse/sqrt(L))*sum_j(G(p',d_j)-G(p',s_j))` and
  `h=sat(0.5+height*z)`. Equal covariance and equal weights make the
  continuous unbounded-domain displacement integral zero when `warp=0`;
  the shared bounded warp deliberately perturbs that idealized balance.
- `uplift`: let `e` follow `direction`, `t` be perpendicular, and place
  `folds` parallel capsule/line SDF crests across an envelope of length
  `scale`. Crest `j` is offset by
  `mix(-0.5,0.5,(j+0.5)/folds)*scale*t
  +jitter*0.15*scale*(2*rv_j-1)*e`; sample the line field through a shared
  warp of amplitude `0.25*jitter`, vary each fold width by a deterministic
  factor in `[0.75,1.25]` and its amplitude in `[0.70,1]`, and use profile
  `amplitude_j*exp2(-(distance/width_j)^2)`. Use maximum composition,
  multiply by `rough(p',0.35*roughness)`, and `h=sat(height*z)`.
- `volcano`: with `radius=0.5*scale` and
  `rho=length(p'-center)/radius`,
  `cone=pow(sat(1-rho),mix(2.5,0.5,bulk))`,
  mouth radius `R_m=radius*mix(0.03,0.45,mouth)`, and
  `bowl=calderaDepth*(1-(length(p'-center)/R_m)^2)^2` inside the mouth.
  Radial erosion subtracts
  `radialErosion*sat(fbm((12*angle,4*rho),seed xor 0xDB4F0B91))*
  rho*(1-rho)`. Set
  `z=max(0,cone*rough(p',roughness)-bowl-radialTerm)` and `h=sat(height*z)`.

## Boundary and failure policy

- Procedural noise, Worley cells, and SDFs are defined on the entire real plane
  and cropped to the requested domain. They neither wrap nor mirror.
- Analytic domain-warp samples may leave the unit domain. Clamping a warped
  coordinate is forbidden because it creates flat bands at boundaries.
- `canyon` alone uses neighbors. Its reused River path treats edges as open
  outlets, preserves the existing priority-flood/path tie ordering, and keeps
  all mask/carve sampling inside the crop.
- `W<2` or `H<2` remains mathematically defined for analytic generators through
  the `max(size-1,1)` denominator. `canyon` requires at least `3x3` and fails
  explicitly below that size.
- Any non-finite parameter fails evaluation. All intermediates and final samples
  must be finite; an unexpected non-finite value fails the node rather than
  silently writing zero.
- Divisors use the explicit lower bounds stated above. `pow` bases are clamped
  non-negative. `acos`, `log(0)`, and undefined normalization are not needed.
- Metal kernels dispatch a 2D grid and guard both dimensions. No analytic
  thread writes any output element other than its own. Canyon's subsequent
  connected-route/carve stages use the existing deterministic implementation.

## Executable invariant mapping

Approval requires the following obligations to become executable tests. Names
are descriptive; they may be integrated into `Tests/theia-tests/main.swift`.

| Requirement | Executable test obligation |
|---|---|
| Registry scope | Catalog contains `perlin` plus all 14 ids above; `ridged` and `island` are absent; each new id reports zero inputs and one scalar output. |
| No silent legacy substitution | Loading a document containing `ridged` fails with an explicit unsupported-node error; it is never interpreted as `ridge`. |
| Parameter contract | For each id, catalog defaults and ranges equal the mapping table; every parameter at min/default/max evaluates. |
| Finite/range invariant | Every default node at `3x3`, `64x64`, `97x61`, and `256x256` has only finite values in `[0,1]`. |
| Non-degeneracy | Every default primitive at `128x128` has variance `>1e-5` and range `>0.02`. |
| Fixed-seed determinism | Two cold evaluations with identical graph, size, seed, and parameters agree elementwise to `1e-6`; warm-cache output agrees too. |
| Seed sensitivity | For every seeded stochastic node, seeds `1337` and `1338` differ in at least 1% of samples by `>1e-5`. `crater` with `irregularity=0` is exempt because seed then has no effect. |
| Existing Perlin compatibility | Existing fixed-seed Perlin fixture and graph tests pass unchanged; its default summary statistics do not move. |
| Hash reference | A CPU test of ten `(x,y,seed)` tuples matches literal expected `hash2` words and `unit24` values. |
| Worley ordering | Reference points, cell corners, and random points satisfy finite `0<=F1<=F2`; GPU values match a small CPU `5x5` reference within `1e-6`. |
| Cellular boundary completeness | A feature just outside each crop edge influences `F1/F2` inside the edge; no edge reflection or missing-neighbor band appears. |
| Aspect-correct coordinates | Radial fixtures (`crater`, `mountain`, `volcano`) evaluated at `129x65` have equal world-space half-height radii on x/y within one sample; oriented wavelengths do not change when width and height are swapped. |
| Resolution stability | Downsampled 257² results agree with direct 129² results in mean within `0.03` and variance within 10% for band-limited parameter fixtures. Exact equality is not required because finer grids resolve additional detail. |
| No data-dependent normalization | Evaluating a crop and the corresponding region of a larger domain with identical world coordinates gives the same unsaturated primitive values within `1e-6`. |
| Crater landmarks | With `irregularity=0` and `ejecta=0`: the `x,y`-derived center is `0.5-height*depth` within rim-tail tolerance, the maximum rim is within one sample of derived radius `0.35*scale`, outside support equals baseline, and radial error is bounded on a non-square grid. |
| Craterfield determinism and size bounds | Extracted centers match hashed Worley centers; inferred radii satisfy `0.15*scale*mix(1-sizeVariation,1+sizeVariation,rv)`; overlap remains finite at `density=64`. |
| Dune asymmetry | A 1D section along wind has mean stoss run longer than lee run, wavelength equals public `scale` within one sample, and crest orientation rotates with public `direction`. |
| SDF landmarks | `sdCircle` and `sdSegment` are zero at analytic boundaries and have correct sign inside/outside; `smin(a,b,k)` stays within its documented bounded blend. |
| `ridge` semantics | Default `ridge` is finite in length and width and decays to baseline outside its capsule; it is not statistically equal to the removed `ridged` fixture. |
| Slump mass pairing | At `warp=0` and without output saturation, numerical integral of displacement over a high-resolution tile is within 2% of zero; crown is negative and toes are positive in public `direction`. |
| Volcano structure | The `x,y`-derived center is below an annulus inside mouth radius `0.5*scale*mix(0.03,0.45,mouth)`; the cone declines monotonically when `radialErosion=0` and `roughness=0`. |
| Canyon routing | Conditioned routing has no interior sink; every interior cell has a strictly descending route to an edge; `F1/F2` are not involved. |
| Canyon drainage hierarchy | Accumulated area is positive, total routed area is conserved to the open boundary within solver tolerance, and its distribution is heavy-tailed rather than uniform. |
| Canyon conditioning effect | At default settings, at least 90% of the deepest 10% carved samples overlap the highest 20% drainage-area samples; replacing area with unconditioned noise must fail this fixture. |
| Canyon resolution scaling | Normalized area threshold produces channel coverage within 15% across 128², 256², and 512² on the same band-limited base. |
| Failure policy | NaN/Inf for every exposed floating parameter fails with node and parameter name; `canyon` fails below `3x3`; finite out-of-range values clamp. |
| Execution boundary | All analytic nodes and Canyon's upland base execute through Metal and reuse the pipeline cache. Canyon alone then exercises the existing deterministic River/RiverCarve path; disabling that path fails explicitly rather than substituting a new fallback. |

Visual golden images may supplement these obligations but cannot replace the
numeric tests.

## Limitations and explicit non-goals

- These generators create plausible shapes, not reconstructions of measured
  terrain and not calibrated geophysical simulations.
- A scalar 2.5D heightfield cannot represent caves, overhangs, overturned slump
  material, buried crater structure, or dune sediment layers.
- The crater profile omits shock physics, excavation flow, oblique impact,
  target strength, gravity scaling, melt, secondary craters, and the
  simple-to-complex transition except for a user-shaped summit/crater profile.
- `dunesea` has no sediment conservation, saltation, changing wind, grain-size
  distribution, dune migration, collision, or boundary influx. It generates
  transverse morphology only.
- `canyon` uses drainage area to locate a connected valley network but does not
  solve stream-power incision. Authors needing evolved channels should compose
  a generator with the existing `fluvial` node.
- `plates` is a cellular plateau motif, not plate tectonics. `uplift` is a set
  of authored fold bands, not crustal flexure or the fluvial node's temporal
  uplift rate. These names describe visual authoring primitives.
- Hash-angle Perlin uses Metal trigonometric functions; low-bit cross-device
  identity is not promised. The graph-level determinism contract is fixed
  device/runtime equality and cross-device tolerance.
- Frequencies above the grid Nyquist limit alias. Parameters are bounded but a
  small requested grid can still undersample legal high-frequency settings;
  no automatic frequency reduction is performed because that would change a
  graph with output resolution.
- Saturation at `[0,1]` can flatten deliberately extreme parameter combinations.
  This is preferable to global renormalization and is visible to the author.
- Connected River routing and carving make Canyon more expensive than the
  one-pass analytic nodes. Its bounded 256-sample longest-axis working grid
  keeps that cost stable; requested higher resolutions resample the routed
  landform rather than adding new channel detail.
- Seamless tiling is not part of this gate. The continuous fields can be
  sampled across adjacent domains if a future graph adds world-origin
  parameters, but the present nodes expose one cropped unit domain.

## Clean-room Gaea boundary, attribution, and license audit

Project Theia is MIT-licensed. The mathematical descriptions in the academic
papers above are used as references; their prose, figures, tables, and source
code are not copied. The implementation must be written independently in
Theia's C++/MSL style from the equations in this note.

Gaea is proprietary third-party software and documentation. Its Rivers and
HydroFix public documentation was consulted previously to understand expected
workflow vocabulary: connected rivers and depression conditioning. It is not
the source of the algorithms in this gate. The actual canyon algorithm is
traceable to Planchon & Darboux, Freeman, Whipple & Tucker, and Theia's already
approved independent fluvial implementation.

Clean-room rules for implementation:

1. Do not inspect, decompile, disassemble, trace, or copy Gaea binaries,
   shaders, presets, serialized graphs, sample heightfields, icons, screenshots,
   or bundled assets.
2. Do not transcribe Gaea documentation prose, parameter lists, defaults,
   tooltips, visual layouts, or screenshots. Generic landform terms do not
   grant permission to duplicate a product's presentation.
3. Do not attempt numeric black-box matching against Gaea output. Acceptance is
   against the equations and tests in this note.
4. Every implementation comment that cites an algorithm should name the
   original paper or this research note, not Gaea.
5. Do not copy code from libnoise, FastNoiseLite, SimpleHydrology, shader
   websites, or any other reference implementation. Their presence as possible
   comparison material does not change this clean-room decision.
6. If future work imports any code or asset, stop and perform a separate
   dependency license review with the exact version, copyright notice, license
   text, and attribution requirements.

No new runtime dependency, third-party source file, copied shader, font, icon,
texture, heightfield, or notice obligation is authorized here. On that basis,
the independently reviewed implementation is compatible with Theia's MIT
license. The gate is approved under the status recorded at the top of this
note.

## Landform context and artifact avoidance

Three findings from reviewing the rendered primitives, each recorded because the
failure mode is easy to reintroduce.

### A landform must not clip to zero at its own radius

`mountain`, `mountainrange` and `crater` derived their profile from
`sat(1 - rho)` or an equivalent, which is exactly zero outside the feature
radius. Measured corner relief on all three was **0.00000**: the landform read
as a shape stamped onto a dead-flat plane, which is the most obviously synthetic
result a generator can produce.

Two additions fix it, and they are separate concerns:

- **`surroundings`** adds low-relief ground everywhere, which the landform then
  grades into. It is faded under the feature (`ground * (1 - 0.65 z)`) so it
  does not fight the summit.
- A **footslope skirt**, `0.24 exp(-1.1 rho^2)`, extends a decaying piedmont
  past the radius. This belongs to the landform, not the surroundings, and so
  remains present at `surroundings = 0`.

Roughness must multiply the landform term alone. Applied to the whole field it
inherits the profile's zero and leaves the surrounding ground perfectly smooth.

### Never sample noise in polar coordinates

The crater used `fbm(float2(angle * k, rho * k))` for its rays and rim wander.
The angular coordinate varies infinitely fast as radius approaches zero, so the
result was a starburst of spokes converging on the centre — visible immediately
in a hillshade. All azimuthal variation is now sampled in **cartesian** space:
`gradientNoise(dir * k)` for rim scalloping, which is continuous around the
circle, and `fbm(d * k)` for ejecta texture.

A regression test compares angular variation on a ring near the centre against
one further out; a starburst concentrates variation as the radius shrinks.

### `max()` over overlapping features creases

`mountainrange` combined its per-summit gaussians with `max()`, which is only C0
where two summits' influence crosses. That crease rendered as hard straight cuts
running across the ridge. The probabilistic union `a + b - ab` is smooth,
bounded to `[0,1]`, and order independent.

Summits were also evenly spaced at identical height, reading as a manufactured
comb. `peakVariation` widens the spacing jitter and varies each summit's height
and width.

## Detail and carve interactions

`rollinghills` used three fbm octaves, band-limiting the surface far below the
sampling grid; it read as blurred rather than smooth. `detail` scales the octave
count from 3 to 7.

The same change applied to the `canyon` upland was **reverted**. Canyon is a
composite — upland surface, then a traced river mask, then `rivercarve` — and a
fourth octave perturbs the traced channels enough to weaken the carve measurably
(1828 to 1485 carved cells on the test fixture). Wall character comes from
`benching` instead, which quantizes the upland into weathered sedimentary
benches at roughly a fifth of that cost. Benching uses `smooth5` within each
band; the resulting near-zero gradient at band edges is why the effect is mixed
rather than applied outright, since flats stall the river tracing.

## Reference-grounded morphology

Three primitives were rebuilt against published morphometry rather than tuned by
eye, because tuning alone reproduces the silhouette without the structure.

### Crater — Pike (1977) and lunar morphometry

A **simple** crater is a paraboloid bowl at a depth/diameter ratio of about
**0.2**. Flat floors, wall terraces and a central peak belong to **complex**
craters past the simple-to-complex transition (~10-20 km on the Moon), and
terrace zone width grows with diameter. Applying all of them at once, as the
first rebuild did, produces a form that exists nowhere.

`complexity` now morphs between the two regimes: at 0 the cavity is a plain
paraboloid; raising it opens a flat floor, enables terracing and raises a
central peak. Default `depth` dropped 0.55 -> 0.26 to approach the observed
d/D. The earlier flat floor joined to a `smooth5` wall had zero gradient at both
ends and rendered as a punched cylinder.

References: Pike, R. J. (1977), *Size-dependence in the shape of fresh impact
craters on the Moon*; Krüger et al. (2018), JGR Planets 123, deriving
morphometric parameters and the simple-to-complex transition diameter.

### Crater field — size-frequency distribution and superposition

Impact populations follow a steep power law: many small craters, very few large.
Sampling radius uniformly gave a field of near-identical stamps, which is the
clearest signature of generation rather than accumulation. Radius is now drawn
through `pow(u, exponent)` with the exponent driven by `sizeVariation`.

Craters also accumulate over time, so each carries its own degradation state;
one global `age` made every crater a contemporary of the others. Age is now
jittered per crater, shallowing the cavity and muting rim and ejecta.

### Dune sea — seif morphology

Seif dunes **meander**: crests are sinuous, with a meander wavelength roughly an
order of magnitude larger than dune height. Straight parallel crests are the
signature of a periodic function, not of wind.

Real fields are also measured by **defect density** — crests terminate and
neighbours take over, producing Y-junctions. `crestMeander` bends the crest
line; `defects` opens the terminations; and each crest draws its own amplitude
so neighbours differ. The defect threshold must be centred on the noise range:
an early version offset it by `(1 - defects)`, which put the threshold outside
the range the noise could reach, so no crest ever terminated.

### Mountain range — fold-thrust belt geometry

Fold-and-thrust belts are **linear, sinuous** (salients and recesses) or
**arcuate** (oroclines) in map view. A perfectly straight axis is the least
common of the three and reads as a manufactured wall. `arc` bows the spine and
`sinuosity` makes it wander along-strike.

Two implementation traps, both of which rendered as hard slashes across the
ridge:

- Distance must be taken to the spine's **segments**, not to sampled points.
  Nearest-point-of-N is piecewise constant and creases along the Voronoi
  boundaries between samples.
- Summit influence must use **true 2D distance to the summit position**, not a
  parameter derived from the nearest-segment search. That parameter jumps
  wherever the nearest segment changes.

Distance to a line also has a gradient discontinuity *on* the line, which
renders as a razor-thin bright crest; the distance is softened near zero so the
ridge has a real summit width.
