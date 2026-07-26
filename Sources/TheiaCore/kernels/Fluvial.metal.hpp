#pragma once
//
// Fluvial landscape evolution kernels (MSL source, compiled at runtime).
//
// Implements the stream power incision model with linear sediment deposition
// over a multiple-flow-direction routing graph. See
// docs/research/fluvial-landscape-evolution-notes.md for the audited equations,
// primary sources, invariants, and limitations.
//
// Unlike the virtual-pipes `hydraulic` node, erosion here is driven by upstream
// drainage area, which is what organizes a surface into a branching channel
// network with sharp divides between basins.
//
namespace theia {
namespace kernels {

inline constexpr const char* kFluvial = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct FluvialParams {
    uint  width;
    uint  height;
    float cellSize;      // ground spacing, derived from terrainSize and the grid
    float heightScale;   // normalized height -> world vertical units
    float erodibility;   // K in E = K A^m S^n
    float areaExponent;  // m
    float slopeExponent; // n
    float deposition;    // G in D = G Qs / A
    float dt;
    float rain;          // scalar precipitation multiplier on cell contribution
    float mfdExponent;   // p in Freeman's S^p partition
    float fillEpsilon;   // strictly-descending increment for depression filling
    float uplift;        // U; sustains relief against incision (steady state U = K A^m S^n)
    float minSlope;      // lower bound on the slope used for incision
    float criticalSlope; // Sc in the nonlinear hillslope transport law
};

constant int2 kOffsets[8] = {
    int2(-1, -1), int2(0, -1), int2(1, -1),
    int2(-1,  0),              int2(1,  0),
    int2(-1,  1), int2(0,  1), int2(1,  1)
};

static inline bool inBounds(int2 p, uint W, uint H) {
    return p.x >= 0 && p.y >= 0 && uint(p.x) < W && uint(p.y) < H;
}

static inline bool isBoundary(uint x, uint y, uint W, uint H) {
    return x == 0u || y == 0u || x == W - 1u || y == H - 1u;
}

// ---------------------------------------------------------------------------
// Depression filling (Planchon & Darboux 2002, relaxation form)
//
// The routing surface starts far above the terrain everywhere except the open
// boundary, then relaxes downward toward
//   w = max(h, min over neighbours(w + eps)).
// Interior minima are removed while the boundary stays pinned to the true
// surface, guaranteeing every cell has a strictly descending path off the grid.
// ---------------------------------------------------------------------------

kernel void fluvial_fill_init(device float*             fill [[buffer(0)]],
                              device const float*       terrain [[buffer(1)]],
                              constant FluvialParams&   P [[buffer(2)]],
                              uint2                     gid [[thread_position_in_grid]])
{
    uint W = P.width, H = P.height;
    if (gid.x >= W || gid.y >= H) { return; }
    uint i = gid.y * W + gid.x;
    float h = terrain[i] * P.heightScale;
    // 1e6 is far above any scaled terrain value; the relaxation only descends,
    // so an over-raised start is what makes the fixed point the filled surface.
    fill[i] = isBoundary(gid.x, gid.y, W, H) ? h : 1.0e6;
}

kernel void fluvial_fill_step(device float*             dst [[buffer(0)]],
                              device const float*       src [[buffer(1)]],
                              device const float*       terrain [[buffer(2)]],
                              constant FluvialParams&   P [[buffer(3)]],
                              uint2                     gid [[thread_position_in_grid]])
{
    uint W = P.width, H = P.height;
    if (gid.x >= W || gid.y >= H) { return; }
    uint i = gid.y * W + gid.x;
    float h = terrain[i] * P.heightScale;
    if (isBoundary(gid.x, gid.y, W, H)) { dst[i] = h; return; }

    float current = src[i];
    if (current <= h) { dst[i] = h; return; }

    float diagonal = P.cellSize * 1.41421356;
    float best = current;
    for (int k = 0; k < 8; ++k) {
        int2 n = int2(gid) + kOffsets[k];
        if (!inBounds(n, W, H)) { continue; }
        float step = (kOffsets[k].x != 0 && kOffsets[k].y != 0)
                     ? diagonal : P.cellSize;
        // eps scales with spacing so the enforced gradient is a slope, not a
        // per-texel constant, keeping fills resolution-stable.
        float candidate = src[uint(n.y) * W + uint(n.x)]
                          + P.fillEpsilon * step;
        best = min(best, candidate);
    }
    dst[i] = max(h, best);
}

// ---------------------------------------------------------------------------
// Multiple-flow-direction weights (Freeman 1991)
//
// Flow is partitioned across every downslope neighbour in proportion to S^p.
// D8 would quantize discharge into eight directions and streak the result along
// the grid diagonals; sharing the flow keeps channel planform off-axis.
// ---------------------------------------------------------------------------

kernel void fluvial_weights(device float*             weights [[buffer(0)]],  // 8 per cell
                            device const float*       fill [[buffer(1)]],
                            constant FluvialParams&   P [[buffer(2)]],
                            uint2                     gid [[thread_position_in_grid]])
{
    uint W = P.width, H = P.height;
    if (gid.x >= W || gid.y >= H) { return; }
    uint i = gid.y * W + gid.x;
    float here = fill[i];
    float diagonal = P.cellSize * 1.41421356;

    float w[8];
    float total = 0.0;
    for (int k = 0; k < 8; ++k) {
        int2 n = int2(gid) + kOffsets[k];
        float value = 0.0;
        if (inBounds(n, W, H)) {
            float step = (kOffsets[k].x != 0 && kOffsets[k].y != 0)
                         ? diagonal : P.cellSize;
            float drop = (here - fill[uint(n.y) * W + uint(n.x)]) / step;
            if (drop > 0.0) { value = pow(drop, P.mfdExponent); }
        }
        w[k] = value;
        total += value;
    }

    float inv = (total > 0.0) ? (1.0 / total) : 0.0;
    for (int k = 0; k < 8; ++k) { weights[i * 8 + uint(k)] = w[k] * inv; }
}

// ---------------------------------------------------------------------------
// Flow accumulation by Jacobi relaxation
//
// A(x) = cell^2 * rain + sum over upslope u of r(u->x) * A(u).
// The filled surface has no interior minima, so the receiver graph is a DAG and
// this converges in at most the longest flow path. Warm-starting from the
// previous step's area means only the first step pays that full cost.
// ---------------------------------------------------------------------------

kernel void fluvial_area_seed(device float*             area [[buffer(0)]],
                              constant FluvialParams&   P [[buffer(1)]],
                              uint2                     gid [[thread_position_in_grid]])
{
    uint W = P.width, H = P.height;
    if (gid.x >= W || gid.y >= H) { return; }
    area[gid.y * W + gid.x] = P.cellSize * P.cellSize * P.rain;
}

kernel void fluvial_area_step(device float*             dst [[buffer(0)]],
                              device const float*       src [[buffer(1)]],
                              device const float*       weights [[buffer(2)]],
                              constant FluvialParams&   P [[buffer(3)]],
                              uint2                     gid [[thread_position_in_grid]])
{
    uint W = P.width, H = P.height;
    if (gid.x >= W || gid.y >= H) { return; }
    uint i = gid.y * W + gid.x;

    float sum = P.cellSize * P.cellSize * P.rain;
    for (int k = 0; k < 8; ++k) {
        int2 n = int2(gid) + kOffsets[k];
        if (!inBounds(n, W, H)) { continue; }
        uint j = uint(n.y) * W + uint(n.x);
        // Neighbour k of this cell sends flow back along the opposite offset;
        // kOffsets is symmetric so index 7-k is that reverse direction.
        float share = weights[j * 8 + uint(7 - k)];
        sum += share * src[j];
    }
    dst[i] = sum;
}

// ---------------------------------------------------------------------------
// Incision and sediment flux
//
// E = K A^m S^n            (Whipple & Tucker 1999)
// D = G Qs / A             (Yuan et al. 2019)
//
// Slope is measured on the TRUE surface, never the filled one, so depression
// filling changes routing without fabricating relief in the exported terrain.
// ---------------------------------------------------------------------------

kernel void fluvial_incise(device float*             incision [[buffer(0)]],
                           device const float*       fill [[buffer(1)]],
                           device const float*       area [[buffer(2)]],
                           device const float*       weights [[buffer(3)]],
                           device const float*       terrain [[buffer(4)]],
                           constant FluvialParams&   P [[buffer(5)]],
                           uint2                     gid [[thread_position_in_grid]])
{
    uint W = P.width, H = P.height;
    if (gid.x >= W || gid.y >= H) { return; }
    uint i = gid.y * W + gid.x;

    // Slope is measured on the routing (depression-filled) surface, which is
    // the water surface. Inside a lake that gradient is ~fillEpsilon, so the
    // lake bed does not incise -- correct, standing water does not cut rock.
    // At the lake outlet the filled surface regains a true gradient, so the
    // outlet incises and the basin drains over the run. Using the raw surface
    // here instead would leave every depression frozen while the terrain
    // around it eroded away, which is what produced the untouched polygonal
    // shelves in the first implementation.
    float here = fill[i];
    float diagonal = P.cellSize * 1.41421356;

    // Flow-weighted downstream slope: the gradient the discharge actually sees.
    float slope = 0.0;
    for (int k = 0; k < 8; ++k) {
        float share = weights[i * 8 + uint(k)];
        if (share <= 0.0) { continue; }
        int2 n = int2(gid) + kOffsets[k];
        if (!inBounds(n, W, H)) { continue; }
        float step = (kOffsets[k].x != 0 && kOffsets[k].y != 0)
                     ? diagonal : P.cellSize;
        float drop = (here - fill[uint(n.y) * W + uint(n.x)]) / step;
        slope += share * max(0.0, drop);
    }

    // Slope floor, the same device as `minTilt` in the audited hydraulic node:
    // it stands in for sub-grid gradient the sampled surface cannot resolve, so
    // low-relief ground keeps incising instead of freezing.
    //
    // It must NOT apply to submerged cells. Inside a filled depression the
    // routing surface is a distance field radiating from the outlet, and the
    // gradient of a distance field on a grid runs in straight geodesics. With a
    // floor there those synthetic lines incise and carve a dead-straight canyon
    // across the basin -- a routing artifact, not a landform. Below the
    // waterline the raw (near-zero) slope is used, so a lake bed stays flat,
    // which is what a lake bed does.
    float submergence = fill[i] - terrain[i] * P.heightScale;
    bool submerged = submergence > 1e-4 * P.heightScale;
    float effectiveSlope = submerged ? slope : max(slope, P.minSlope);
    float a = max(area[i], 1e-12);
    incision[i] = P.erodibility * pow(a, P.areaExponent)
                                * pow(effectiveSlope, P.slopeExponent);
}

kernel void fluvial_flux_seed(device float*             flux [[buffer(0)]],
                              constant FluvialParams&   P [[buffer(1)]],
                              uint2                     gid [[thread_position_in_grid]])
{
    uint W = P.width, H = P.height;
    if (gid.x >= W || gid.y >= H) { return; }
    flux[gid.y * W + gid.x] = 0.0;
}

// Qs(x) = sum upslope r * ( Qs(u) + (E(u) - D(u)) * cell^2 ), clamped at zero.
kernel void fluvial_flux_step(device float*             dst [[buffer(0)]],
                              device const float*       src [[buffer(1)]],
                              device const float*       weights [[buffer(2)]],
                              device const float*       incision [[buffer(3)]],
                              device const float*       area [[buffer(4)]],
                              constant FluvialParams&   P [[buffer(5)]],
                              uint2                     gid [[thread_position_in_grid]])
{
    uint W = P.width, H = P.height;
    if (gid.x >= W || gid.y >= H) { return; }
    uint i = gid.y * W + gid.x;
    float cellArea = P.cellSize * P.cellSize;

    float sum = 0.0;
    for (int k = 0; k < 8; ++k) {
        int2 n = int2(gid) + kOffsets[k];
        if (!inBounds(n, W, H)) { continue; }
        uint j = uint(n.y) * W + uint(n.x);
        float share = weights[j * 8 + uint(7 - k)];
        if (share <= 0.0) { continue; }
        float upstreamFlux = src[j];
        float deposited = P.deposition * upstreamFlux / max(area[j], 1e-12);
        float net = incision[j] - deposited;
        sum += share * max(0.0, upstreamFlux + net * cellArea);
    }
    dst[i] = sum;
}

// ---------------------------------------------------------------------------
// Surface update
//
// dh = dt * (D - E), then two guards from the audit: a cell may not incise more
// than half its drop to the receiver in one step, and may never end below it.
// Together these keep the surface monotone along every flow path, which is what
// prevents the spike/checkerboard mode seen in explicit erosion schemes.
// ---------------------------------------------------------------------------

kernel void fluvial_apply(device float*             dst [[buffer(0)]],
                          device const float*       src [[buffer(1)]],
                          device const float*       incision [[buffer(2)]],
                          device const float*       flux [[buffer(3)]],
                          device const float*       area [[buffer(4)]],
                          device const float*       weights [[buffer(5)]],
                          constant FluvialParams&   P [[buffer(6)]],
                          uint2                     gid [[thread_position_in_grid]])
{
    uint W = P.width, H = P.height;
    if (gid.x >= W || gid.y >= H) { return; }
    uint i = gid.y * W + gid.x;

    float here = src[i] * P.heightScale;
    if (isBoundary(gid.x, gid.y, W, H)) { dst[i] = src[i]; return; }

    // dh/dt = U - E + D. Without the uplift term the surface simply denudes
    // toward base level and loses all relief; with it the terrain approaches
    // the stream-power steady state U = K A^m S^n, which is what sustains
    // ridges while channels keep incising.
    float deposited = P.deposition * flux[i] / max(area[i], 1e-12);
    float change = P.dt * (P.uplift + deposited - incision[i]);

    // Lowest elevation among the cells this one drains into. Routing follows
    // the depression-filled surface, so inside a basin the receiver can sit
    // ABOVE this cell on the true surface. The guards below must then not fire:
    // clamping up to such a receiver would aggrade the basin into a flat shelf,
    // which is a fabricated landform rather than a stability correction.
    float receiver = here;
    bool hasLowerReceiver = false;
    for (int k = 0; k < 8; ++k) {
        if (weights[i * 8 + uint(k)] <= 0.0) { continue; }
        int2 n = int2(gid) + kOffsets[k];
        if (!inBounds(n, W, H)) { continue; }
        float nh = src[uint(n.y) * W + uint(n.x)] * P.heightScale;
        if (nh >= here) { continue; }
        receiver = hasLowerReceiver ? min(receiver, nh) : nh;
        hasLowerReceiver = true;
    }

    if (hasLowerReceiver && change < 0.0) {
        // Courant-like limit: incise at most half the drop to the receiver in
        // one step, so the surface stays monotone along every flow path.
        change = max(change, -0.5 * (here - receiver));
    }
    float updated = here + change;
    if (hasLowerReceiver) { updated = max(updated, receiver); }
    dst[i] = updated / max(P.heightScale, 1e-6);
}

// ---------------------------------------------------------------------------
// Hillslope diffusion (Culling 1960): dh/dt += D * laplacian(h).
//
// This is what stops channels forming at every cell. Fluvial incision alone is
// scale-free and will cut a gully at one-cell drainage area, packing the whole
// surface with parallel grid-scale grooves. Diffusion dominates at small
// drainage areas and smooths those out; the crossover between the two sets the
// valley spacing, so `diffusion` is effectively the drainage-density control.
//
// `nu` is the dimensionless diffusion number D*dt/cell^2 for ONE substep. The
// caller splits the per-step amount so nu stays inside the explicit stability
// limit of 0.25 for a five-point Laplacian on a 2D grid.
// ---------------------------------------------------------------------------

kernel void fluvial_diffuse(device float*             dst [[buffer(0)]],
                            device const float*       src [[buffer(1)]],
                            constant FluvialParams&   P [[buffer(2)]],
                            constant float&           nu [[buffer(3)]],
                            uint2                     gid [[thread_position_in_grid]])
{
    uint W = P.width, H = P.height;
    if (gid.x >= W || gid.y >= H) { return; }
    uint i = gid.y * W + gid.x;
    if (isBoundary(gid.x, gid.y, W, H)) { dst[i] = src[i]; return; }

    float here = src[i];
    float sc = max(P.criticalSlope, 1e-3);

    // Nonlinear hillslope transport (Roering, Kirchner & Dietrich 1999):
    //
    //     qs = Kd * S / (1 - (S/Sc)^2)
    //
    // Linear diffusion (the Sc -> infinity limit of this) smooths every scale
    // at the same rate, so the coefficient needed to erase one-cell grooves
    // also flattens broad terrain. The nonlinear law makes transport diverge as
    // the gradient nears the critical slope Sc, so steep groove walls are
    // smoothed far faster than gentle ground at the SAME Kd -- which is what
    // lets the base coefficient drop and leave broad relief intact.
    //
    // The amplification is capped: the true law is singular at S = Sc, and an
    // unbounded effective diffusivity has no stable explicit timestep. The cap
    // is the same factor the host uses to size its substep budget, so the two
    // cannot disagree.
    float sum = 0.0;
    int2 neighbours[4] = { int2(-1,0), int2(1,0), int2(0,-1), int2(0,1) };
    for (int k = 0; k < 4; ++k) {
        int2 n = int2(gid) + neighbours[k];
        float there = src[uint(n.y) * W + uint(n.x)];
        float drop = here - there;
        // Slope must be in WORLD units to compare against criticalSlope, same
        // as every other kernel in this file (fill/weights/incise all read
        // terrain*heightScale). Without this factor the drop here is a
        // normalized-height delta, ~100x smaller than the physical slope at the
        // default heightScale, so the amplification this law depends on never
        // engages and criticalSlope is inert across its whole authoring range.
        float slope = fabs(drop) * P.heightScale / max(P.cellSize, 1e-6);
        float ratio = min(slope / sc, 0.9486833);   // caps amplification at 10x
        float amplify = 1.0 / (1.0 - ratio * ratio);
        sum += -drop * amplify;
    }
    dst[i] = here + nu * sum;
}

// ---------------------------------------------------------------------------
// Boundary reconciliation
//
// Routing needs the domain edge pinned as a fixed outlet, but leaving the edge
// elevation pinned too makes it stand proud of the interior as that interior
// erodes -- a raised lip around the whole tile. Instead the edge tracks its
// inward neighbour while preserving the offset the two had in the input, so the
// original rim shape survives and the edge subsides with the terrain behind it.
// ---------------------------------------------------------------------------

kernel void fluvial_boundary(device float*             field [[buffer(0)]],
                             device const float*       original [[buffer(1)]],
                             constant FluvialParams&   P [[buffer(2)]],
                             uint2                     gid [[thread_position_in_grid]])
{
    uint W = P.width, H = P.height;
    if (gid.x >= W || gid.y >= H) { return; }
    if (!isBoundary(gid.x, gid.y, W, H)) { return; }
    uint i = gid.y * W + gid.x;

    // Step one cell inward; corners move diagonally.
    uint ix = gid.x == 0u ? 1u : (gid.x == W - 1u ? W - 2u : gid.x);
    uint iy = gid.y == 0u ? 1u : (gid.y == H - 1u ? H - 2u : gid.y);
    uint j = iy * W + ix;
    if (j == i) { return; }

    field[i] = field[j] + (original[i] - original[j]);
}

// Normalized log-scaled flow accumulation, exposed as a data output. Drainage
// area is heavy-tailed, so a linear encoding would show only the trunk stream;
// log compression makes the whole network legible as a mask or material source.
kernel void fluvial_flow_output(device float*             out [[buffer(0)]],
                                device const float*       area [[buffer(1)]],
                                constant FluvialParams&   P [[buffer(2)]],
                                constant float2&          range [[buffer(3)]],
                                uint2                     gid [[thread_position_in_grid]])
{
    uint W = P.width, H = P.height;
    if (gid.x >= W || gid.y >= H) { return; }
    uint i = gid.y * W + gid.x;
    float lo = range.x, hi = range.y;
    float v = log(max(area[i], 1e-12));
    float span = max(hi - lo, 1e-6);
    out[i] = clamp((v - lo) / span, 0.0, 1.0);
}
)METAL";

} // namespace kernels
} // namespace theia
