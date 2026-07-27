#pragma once
//
// Metal Shading Language kernel sources, stored as C++ string constants and
// compiled at runtime via MTL::Device::newLibrary(source, ...).
//
// We compile at runtime (not the SwiftPM .metal -> .metallib path) because the
// offline `metal`/`metallib` compilers require full Xcode / the Metal toolchain,
// and this project targets a Command-Line-Tools-only environment.
//
namespace theia {
namespace kernels {

// M0 smoke test: write a constant value into every element of an output buffer.
inline constexpr const char* kFill = R"METAL(
#include <metal_stdlib>
using namespace metal;

kernel void fill(device float*    out   [[buffer(0)]],
                 constant float&  value [[buffer(1)]],
                 constant uint&   count [[buffer(2)]],
                 uint             gid   [[thread_position_in_grid]])
{
    if (gid >= count) { return; }
    out[gid] = value;
}
)METAL";

// fBm gradient (Perlin) noise generator. One thread per heightmap texel.
//
// Math references:
//   - Quintic fade f(t)=6t^5-15t^4+10t^3 (Perlin, "Improving Noise", 2002):
//     C2-continuous, removes 2nd-derivative artifacts of the cubic smoothstep.
//   - Value = bilinear interp (via fade weights) of corner gradient·distance
//     dot products.
//   - fBm: sum of `octaves`, frequency *= lacunarity, amplitude *= gain.
// Gradients are derived from an integer hash (no permutation table / texture
// lookup) so results are deterministic and GPU-parallel. Output is normalized
// to [0,1].
inline constexpr const char* kPerlinFbm = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct PerlinParams {
    uint  width;
    uint  height;
    uint  octaves;
    uint  seed;
    float frequency;    // base cells across the unit domain
    float lacunarity;   // frequency multiplier per octave
    float gain;         // amplitude multiplier per octave (persistence)
    float heightScale;  // per-node amplitude for graph authoring
};

// Integer hash (Wang/xxHash-style mixing) -> uint.
static inline uint hash2(uint x, uint y, uint seed) {
    uint h = seed + 0x9E3779B9u;
    h ^= x * 0x85EBCA77u; h = (h ^ (h >> 15)) * 0xC2B2AE3Du;
    h ^= y * 0x27D4EB2Fu; h = (h ^ (h >> 13)) * 0x165667B1u;
    return h ^ (h >> 16);
}

// Unit-length gradient from a lattice point, via a hashed angle.
static inline float2 grad2(int2 i, uint seed) {
    uint h = hash2(uint(i.x), uint(i.y), seed);
    float ang = float(h) * (6.28318530718 / 4294967296.0);
    return float2(cos(ang), sin(ang));
}

static inline float perlin2(float2 p, uint seed) {
    int2 ip = int2(floor(p));
    float2 f = p - float2(ip);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);  // quintic fade

    float n00 = dot(grad2(ip + int2(0, 0), seed), f - float2(0.0, 0.0));
    float n10 = dot(grad2(ip + int2(1, 0), seed), f - float2(1.0, 0.0));
    float n01 = dot(grad2(ip + int2(0, 1), seed), f - float2(0.0, 1.0));
    float n11 = dot(grad2(ip + int2(1, 1), seed), f - float2(1.0, 1.0));

    float nx0 = mix(n00, n10, u.x);
    float nx1 = mix(n01, n11, u.x);
    return mix(nx0, nx1, u.y);  // ~[-0.707, 0.707]
}

kernel void perlin_fbm(device float*           out [[buffer(0)]],
                       constant PerlinParams&  P   [[buffer(1)]],
                       uint2                   gid [[thread_position_in_grid]])
{
    if (gid.x >= P.width || gid.y >= P.height) { return; }

    // Sample in a normalized domain so the result is resolution-independent.
    float2 uv = float2(gid) / float2(P.width, P.height);

    float sum = 0.0, amp = 1.0, freq = P.frequency, norm = 0.0;
    for (uint o = 0; o < P.octaves; ++o) {
        sum  += amp * perlin2(uv * freq, P.seed + o * 1013u);
        norm += amp;
        amp  *= P.gain;
        freq *= P.lacunarity;
    }
    float n = (norm > 0.0) ? (sum / norm) : 0.0;   // ~[-0.707, 0.707]
    n *= 1.41421356;                               // -> ~[-1, 1]
    out[gid.y * P.width + gid.x] =
        clamp((0.5 * n + 0.5) * P.heightScale, 0.0, 1.0);  // -> [0,1]
}
)METAL";

// Elementwise affine remap: out = clamp(in * scale + bias, 0, 1).
inline constexpr const char* kScaleBias = R"METAL(
#include <metal_stdlib>
using namespace metal;

kernel void scalebias(device float*         out [[buffer(0)]],
                      device const float*   in  [[buffer(1)]],
                      constant float2&      sb  [[buffer(2)]],  // x=scale, y=bias
                      constant uint2&       dim [[buffer(3)]],
                      uint2                 gid [[thread_position_in_grid]])
{
    if (gid.x >= dim.x || gid.y >= dim.y) { return; }
    uint i = gid.y * dim.x + gid.x;
    out[i] = clamp(in[i] * sb.x + sb.y, 0.0, 1.0);
}
)METAL";

// Linear blend of two inputs: out = clamp(mix(a, b, t), 0, 1).
inline constexpr const char* kCombine = R"METAL(
#include <metal_stdlib>
using namespace metal;

kernel void combine(device float*         out [[buffer(0)]],
                    device const float*   a   [[buffer(1)]],
                    device const float*   b   [[buffer(2)]],
                    constant float&       t   [[buffer(3)]],
                    constant uint2&       dim [[buffer(4)]],
                    uint2                 gid [[thread_position_in_grid]])
{
    if (gid.x >= dim.x || gid.y >= dim.y) { return; }
    uint i = gid.y * dim.x + gid.x;
    out[i] = clamp(mix(a[i], b[i], t), 0.0, 1.0);
}
)METAL";

// Terrace: quantize heights into N bands with a shaped riser between them,
// producing stratified plateaus. sharpness >= 1 flattens band tops and steepens
// the risers.
inline constexpr const char* kTerrace = R"METAL(
#include <metal_stdlib>
using namespace metal;

kernel void terrace(device float*        out [[buffer(0)]],
                    device const float*  in  [[buffer(1)]],
                    constant float2&     ps  [[buffer(2)]],  // x=steps, y=sharpness
                    constant uint2&      dim [[buffer(3)]],
                    uint2                gid [[thread_position_in_grid]])
{
    if (gid.x >= dim.x || gid.y >= dim.y) { return; }
    uint i = gid.y * dim.x + gid.x;
    float steps = max(1.0, ps.x);
    float sharp = max(0.001, ps.y);
    float h = clamp(in[i], 0.0, 1.0);
    float s = h * steps;
    float f = floor(s);
    float r = s - f;                 // position within band [0,1)
    float shaped = pow(r, sharp);    // flat low, steep riser
    out[i] = clamp((f + shaped) / steps, 0.0, 1.0);
}
)METAL";

// Slope mask: Horn/ArcGIS-style 3x3 finite differences produce dz/dx,dz/dy,
// then slope angle = atan(sqrt(dx^2 + dy^2)). The low/high params are degrees
// and map through smoothstep -> [0,1], similar to mature terrain slope selectors.
inline constexpr const char* kSlopeMask = R"METAL(
#include <metal_stdlib>
using namespace metal;

kernel void slopemask(device float*        out [[buffer(0)]],
                      device const float*  in  [[buffer(1)]],
                      constant float4&     pr  [[buffer(2)]],  // x=lowDeg, y=highDeg, z=heightScale, w=terrainSize
                      constant uint2&      dim [[buffer(3)]],
                      uint2                gid [[thread_position_in_grid]])
{
    uint W = dim.x, H = dim.y;
    if (gid.x >= W || gid.y >= H) { return; }
    uint x = gid.x, y = gid.y, i = y * W + x;

    uint xm = (x > 0) ? x - 1 : x;
    uint xp = (x < W - 1) ? x + 1 : x;
    uint ym = (y > 0) ? y - 1 : y;
    uint yp = (y < H - 1) ? y + 1 : y;

    float z1 = in[ym * W + xm] * pr.z;
    float z2 = in[ym * W + x]  * pr.z;
    float z3 = in[ym * W + xp] * pr.z;
    float z4 = in[y  * W + xm] * pr.z;
    float z6 = in[y  * W + xp] * pr.z;
    float z7 = in[yp * W + xm] * pr.z;
    float z8 = in[yp * W + x]  * pr.z;
    float z9 = in[yp * W + xp] * pr.z;

    // Horn (1981) third-order estimator, as in gdaldem slope. The denominator
    // is ground distance, so spacing comes from the terrain's world extent and
    // never from the sampling grid — see terrain-horizontal-scale-notes.md.
    float cell = max(pr.w / float(max(W, 2u) - 1u), 1e-6);
    float dzdx = ((z3 + 2.0 * z6 + z9) - (z1 + 2.0 * z4 + z7)) / (8.0 * cell);
    float dzdy = ((z7 + 2.0 * z8 + z9) - (z1 + 2.0 * z2 + z3)) / (8.0 * cell);
    float slopeDeg = atan(sqrt(dzdx * dzdx + dzdy * dzdy)) * 57.2957795131;

    float lo = clamp(min(pr.x, pr.y), 0.0, 90.0);
    float hi = clamp(max(pr.x, pr.y), 0.0, 90.0);
    hi = max(hi, lo + 0.001);
    out[i] = smoothstep(lo, hi, slopeDeg);
}
)METAL";

// Utility remaps. The formulas mirror common shader/color operations:
// - linear remap/normalization is the same affine interval transform used by
//   GLSL-style smoothstep/remap workflows.
// - blend "screen" follows W3C Compositing and Blending Level 1:
//   B(Cb,Cs)=Cb+Cs-(Cb*Cs), with opacity applied as source mix.
//   Ref: https://www.w3.org/TR/compositing-1/
inline constexpr const char* kInvert = R"METAL(
#include <metal_stdlib>
using namespace metal;

kernel void invert(device float*        out    [[buffer(0)]],
                   device const float*  in     [[buffer(1)]],
                   constant float&      amount [[buffer(2)]],
                   constant uint2&      dim    [[buffer(3)]],
                   uint2                gid    [[thread_position_in_grid]])
{
    if (gid.x >= dim.x || gid.y >= dim.y) { return; }
    uint i = gid.y * dim.x + gid.x;
    float a = clamp(amount, 0.0, 1.0);
    out[i] = clamp(mix(in[i], 1.0 - in[i], a), 0.0, 1.0);
}
)METAL";

inline constexpr const char* kClampNode = R"METAL(
#include <metal_stdlib>
using namespace metal;

kernel void clamp_node(device float*        out   [[buffer(0)]],
                       device const float*  in    [[buffer(1)]],
                       constant float2&     range [[buffer(2)]],
                       constant uint2&      dim   [[buffer(3)]],
                       uint2                gid   [[thread_position_in_grid]])
{
    if (gid.x >= dim.x || gid.y >= dim.y) { return; }
    uint i = gid.y * dim.x + gid.x;
    out[i] = clamp(in[i], clamp(range.x, 0.0, 1.0), clamp(range.y, 0.0, 1.0));
}
)METAL";

inline constexpr const char* kRemap = R"METAL(
#include <metal_stdlib>
using namespace metal;

kernel void remap(device float*        out [[buffer(0)]],
                  device const float*  in  [[buffer(1)]],
                  constant float*      pr  [[buffer(2)]],
                  constant uint2&      dim [[buffer(3)]],
                  uint2                gid [[thread_position_in_grid]])
{
    if (gid.x >= dim.x || gid.y >= dim.y) { return; }
    uint i = gid.y * dim.x + gid.x;
    float inLow = pr[0], inHigh = pr[1], outLow = pr[2], outHigh = pr[3];
    float gamma = max(0.001, pr[4]);
    bool doClamp = pr[5] >= 0.5;
    float denom = max(abs(inHigh - inLow), 1e-6);
    float t = (in[i] - inLow) / denom;
    if (inHigh < inLow) { t = 1.0 - t; }
    if (doClamp) { t = clamp(t, 0.0, 1.0); }
    t = pow(max(t, 0.0), gamma);
    out[i] = clamp(mix(outLow, outHigh, t), 0.0, 1.0);
}
)METAL";

// Box blur reference: a normalized box filter averages a square footprint.
// This intentionally uses one deterministic clamped-edge pass for V1 node
// authoring rather than a faster two-pass separable implementation.
// Ref: https://en.wikipedia.org/wiki/Box_blur
inline constexpr const char* kBlur = R"METAL(
#include <metal_stdlib>
using namespace metal;

kernel void blur(device float*        out [[buffer(0)]],
                 device const float*  in  [[buffer(1)]],
                 constant float2&     pr  [[buffer(2)]],  // x=radius, y=strength
                 constant uint2&      dim [[buffer(3)]],
                 uint2                gid [[thread_position_in_grid]])
{
    uint W = dim.x, H = dim.y;
    if (gid.x >= W || gid.y >= H) { return; }
    uint i = gid.y * W + gid.x;
    int radius = int(clamp(round(pr.x), 0.0, 16.0));
    float sum = 0.0;
    uint count = 0;
    for (int oy = -radius; oy <= radius; ++oy) {
        int sy = clamp(int(gid.y) + oy, 0, int(H) - 1);
        for (int ox = -radius; ox <= radius; ++ox) {
            int sx = clamp(int(gid.x) + ox, 0, int(W) - 1);
            sum += in[uint(sy) * W + uint(sx)];
            count += 1;
        }
    }
    float avg = (count > 0) ? (sum / float(count)) : in[i];
    out[i] = clamp(mix(in[i], avg, clamp(pr.y, 0.0, 1.0)), 0.0, 1.0);
}
)METAL";

// Domain warping reference: mature procedural-noise workflows perturb the input
// domain before sampling, e.g. Book of Shaders / Quilez-style warped noise.
// Ref: https://thebookofshaders.com/13/
inline constexpr const char* kWarp = R"METAL(
#include <metal_stdlib>
using namespace metal;

static inline uint hash2(uint x, uint y, uint seed) {
    uint h = seed + 0x9E3779B9u;
    h ^= x * 0x85EBCA77u; h = (h ^ (h >> 15)) * 0xC2B2AE3Du;
    h ^= y * 0x27D4EB2Fu; h = (h ^ (h >> 13)) * 0x165667B1u;
    return h ^ (h >> 16);
}

static inline float2 grad2(int2 i, uint seed) {
    uint h = hash2(uint(i.x), uint(i.y), seed);
    float ang = float(h) * (6.28318530718 / 4294967296.0);
    return float2(cos(ang), sin(ang));
}

static inline float perlin2(float2 p, uint seed) {
    int2 ip = int2(floor(p));
    float2 f = p - float2(ip);
    float2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float n00 = dot(grad2(ip + int2(0, 0), seed), f);
    float n10 = dot(grad2(ip + int2(1, 0), seed), f - float2(1.0, 0.0));
    float n01 = dot(grad2(ip + int2(0, 1), seed), f - float2(0.0, 1.0));
    float n11 = dot(grad2(ip + int2(1, 1), seed), f - float2(1.0, 1.0));
    return mix(mix(n00, n10, u.x), mix(n01, n11, u.x), u.y);
}

static inline float fbm(float2 uv, float freq, uint octaves, uint seed) {
    float sum = 0.0, amp = 1.0, norm = 0.0;
    for (uint o = 0; o < octaves; ++o) {
        sum += amp * perlin2(uv * freq, seed + o * 1013u) * 1.41421356;
        norm += amp;
        amp *= 0.5;
        freq *= 2.0;
    }
    return (norm > 0.0) ? (sum / norm) : 0.0;
}

static inline float sampleBilinear(device const float* src, uint W, uint H, float2 uv) {
    float2 p = clamp(uv, 0.0, 1.0) * float2(W - 1, H - 1);
    uint x0 = uint(floor(p.x));
    uint y0 = uint(floor(p.y));
    uint x1 = min(x0 + 1, W - 1);
    uint y1 = min(y0 + 1, H - 1);
    float2 f = p - floor(p);
    float a = src[y0 * W + x0];
    float b = src[y0 * W + x1];
    float c = src[y1 * W + x0];
    float d = src[y1 * W + x1];
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

kernel void warp(device float*        out [[buffer(0)]],
                 device const float*  in  [[buffer(1)]],
                 constant uint4&      ui  [[buffer(2)]], // w,h,octaves,seed
                 constant float2&     pr  [[buffer(3)]], // frequency,strength
                 uint2                gid [[thread_position_in_grid]])
{
    uint W = ui.x, H = ui.y;
    if (gid.x >= W || gid.y >= H) { return; }
    float2 uv = float2(gid) / float2(W - 1, H - 1);
    float wx = fbm(uv + float2(17.31, 4.71), pr.x, ui.z, ui.w);
    float wy = fbm(uv + float2(3.13, 29.9), pr.x, ui.z, ui.w + 7919u);
    float2 warped = uv + float2(wx, wy) * pr.y;
    out[gid.y * W + gid.x] = clamp(sampleBilinear(in, W, H, warped), 0.0, 1.0);
}
)METAL";

inline constexpr const char* kBlend = R"METAL(
#include <metal_stdlib>
using namespace metal;

kernel void blend(device float*        out [[buffer(0)]],
                  device const float*  a   [[buffer(1)]],
                  device const float*  b   [[buffer(2)]],
                  constant float2&     pr  [[buffer(3)]], // x=mode, y=opacity
                  constant uint2&      dim [[buffer(4)]],
                  uint2                gid [[thread_position_in_grid]])
{
    if (gid.x >= dim.x || gid.y >= dim.y) { return; }
    uint i = gid.y * dim.x + gid.x;
    float base = clamp(a[i], 0.0, 1.0);
    float top = clamp(b[i], 0.0, 1.0);
    int mode = int(round(pr.x));
    float blended = top;
    if (mode == 1) {
        blended = base + top;
    } else if (mode == 2) {
        blended = base * top;
    } else if (mode == 3) {
        blended = max(base, top);
    } else if (mode == 4) {
        blended = min(base, top);
    } else if (mode == 5) {
        blended = base + top - base * top;
    } else {
        blended = top;
    }
    out[i] = clamp(mix(base, clamp(blended, 0.0, 1.0), clamp(pr.y, 0.0, 1.0)),
                   0.0, 1.0);
}
)METAL";

} // namespace kernels
} // namespace theia
