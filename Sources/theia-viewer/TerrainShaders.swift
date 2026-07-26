// Terrain render shaders (MSL), compiled at runtime via device.makeLibrary —
// the offline `metal` compiler isn't available with Command Line Tools alone.
//
// The mesh has no vertex buffer: each vertex derives its grid (x,z) from
// vertex_id, reads its height from a shared buffer, displaces Y, and computes
// the surface normal from neighbor heights for lighting.
let terrainShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float4x4 mvp;
    float4 lightDirection;
    float4 viewportParams; // x=heightScale, y=maskOpacity, z=displayMode, w=materialPreset
    float4 terrainParams;  // x=base height offset for geometry
    float4 brushParams;    // xy=center UV, z=radius UV, w=visible
    uint4  gridParams;     // x=gridW, y=gridH
};

struct VOut {
    float4 position [[position]];
    float3 normal;
    float  height;
    float  data;
    float2 uv;
};

struct LineVertexIn {
    float3 position;
    float4 color;
};

struct LineOut {
    float4 position [[position]];
    float4 color;
};

vertex VOut terrain_vertex(uint vid [[vertex_id]],
                           const device float* heights [[buffer(0)]],
                           constant Uniforms& U [[buffer(1)]],
                           const device float* dataValues [[buffer(2)]]) {
    uint gridW = U.gridParams.x;
    uint gridH = U.gridParams.y;
    float heightScale = U.viewportParams.x;

    uint gx = vid % gridW;
    uint gz = vid / gridW;
    float h = heights[gz * gridW + gx];
    float d = dataValues[gz * gridW + gx];

    float fx = (float(gx) / float(gridW - 1)) * 2.0 - 1.0;
    float fz = (float(gz) / float(gridH - 1)) * 2.0 - 1.0;
    float y = (h - U.terrainParams.x) * heightScale;

    uint gxl = gx > 0 ? gx - 1 : gx;
    uint gxr = gx < gridW - 1 ? gx + 1 : gx;
    uint gzd = gz > 0 ? gz - 1 : gz;
    uint gzu = gz < gridH - 1 ? gz + 1 : gz;
    float hl = heights[gz * gridW + gxl];
    float hr = heights[gz * gridW + gxr];
    float hd = heights[gzd * gridW + gx];
    float hu = heights[gzu * gridW + gx];
    float sx = 2.0 / float(gridW - 1);
    float sz = 2.0 / float(gridH - 1);
    float slopeX = (hr - hl) * heightScale / (2.0 * sx);
    float slopeZ = (hu - hd) * heightScale / (2.0 * sz);
    float3 N = normalize(float3(-slopeX, 1.0, -slopeZ));

    VOut o;
    o.position = U.mvp * float4(fx, y, fz, 1.0);
    o.normal = N;
    o.height = h;
    o.data = d;
    o.uv = float2(float(gx) / float(gridW - 1),
                  float(gz) / float(gridH - 1));
    return o;
}

vertex LineOut line_vertex(uint vid [[vertex_id]],
                           const device LineVertexIn* vertices [[buffer(0)]],
                           constant Uniforms& U [[buffer(1)]]) {
    LineVertexIn v = vertices[vid];
    LineOut o;
    o.position = U.mvp * float4(v.position, 1.0);
    o.color = v.color;
    return o;
}

fragment float4 line_fragment(LineOut in [[stage_in]]) {
    return in.color;
}

float3 terrainRamp(float h, float slope) {
    float3 low = float3(0.24, 0.43, 0.22);   // lowland green
    float3 mid = float3(0.50, 0.39, 0.28);   // rock brown
    float3 hi  = float3(0.93, 0.94, 0.97);   // snow
    float3 col = mix(low, mid, smoothstep(0.20, 0.55, h));
    col = mix(col, hi, smoothstep(0.76, 0.94, h));
    return mix(col, float3(0.32, 0.31, 0.29), smoothstep(0.32, 0.72, slope));
}

float3 materialRamp(float h, float slope, float mask, uint preset) {
    if (preset == 1) {
        float3 meadow = float3(0.22, 0.42, 0.25);
        float3 cliff = float3(0.42, 0.43, 0.42);
        float3 snow = float3(0.91, 0.94, 0.98);
        float3 col = mix(meadow, cliff, smoothstep(0.24, 0.70, slope));
        col = mix(col, snow, smoothstep(0.55, 0.90, h));
        return mix(col, snow, mask * 0.55);
    }
    if (preset == 2) {
        float3 sand = float3(0.66, 0.52, 0.32);
        float3 scrub = float3(0.40, 0.45, 0.25);
        float3 rock = float3(0.36, 0.32, 0.27);
        float3 col = mix(sand, scrub, smoothstep(0.18, 0.45, h));
        col = mix(col, rock, smoothstep(0.22, 0.68, slope));
        return mix(col, float3(0.48, 0.32, 0.22), mask * 0.45);
    }
    if (preset == 3) {
        float3 low = float3(0.07, 0.18, 0.62);
        float3 mid = float3(0.10, 0.62, 0.36);
        float3 high = float3(0.92, 0.28, 0.14);
        float3 col = mix(low, mid, smoothstep(0.10, 0.55, h));
        col = mix(col, high, smoothstep(0.52, 0.92, max(h, slope)));
        return mix(col, float3(1.0, 0.88, 0.18), mask * 0.55);
    }

    float3 col = terrainRamp(h, slope);
    return mix(col, float3(0.24, 0.24, 0.23), mask * 0.55);
}

float4 applyBrushDecal(float4 base, float2 uv, constant Uniforms& U) {
    if (U.brushParams.w < 0.5) {
        return base;
    }
    float radius = max(U.brushParams.z, 0.0001);
    float d = distance(uv, U.brushParams.xy);
    float aa = max(fwidth(d) * 1.35, radius * 0.012);
    float inside = 1.0 - smoothstep(radius - aa, radius + aa, d);
    float ringWidth = max(radius * 0.075, aa * 1.5);
    float ring = 1.0 - smoothstep(ringWidth, ringWidth + aa,
                                  abs(d - radius));
    float blend = max(inside * 0.16, ring * 0.92);
    float3 brushBlue = float3(0.05, 0.62, 1.0);
    return float4(mix(base.rgb, brushBlue, clamp(blend, 0.0, 1.0)), base.a);
}

fragment float4 terrain_fragment(VOut in [[stage_in]],
                                 constant Uniforms& U [[buffer(1)]]) {
    float3 N = normalize(in.normal);
    float3 L = normalize(U.lightDirection.xyz);
    float diff = max(0.0, dot(N, L));
    float amb = 0.32;

    float h = in.height;
    float slope = 1.0 - N.y;
    float mask = clamp(in.data, 0.0, 1.0);
    uint mode = uint(U.viewportParams.z + 0.5);
    uint preset = uint(U.viewportParams.w + 0.5);
    float opacity = clamp(U.viewportParams.y, 0.0, 1.0);
    float lit = amb + diff * 0.95;
    float3 shaded = terrainRamp(h, slope) * lit;

    if (mode == 1) {
        return applyBrushDecal(float4(float3(h), 1.0), in.uv, U);
    }

    if (mode == 2) {
        float3 lowMask = float3(0.04, 0.07, 0.10);
        float3 highMask = float3(0.06, 0.52, 1.00);
        float3 maskRamp = mix(lowMask, highMask, smoothstep(0.0, 1.0, mask));
        return applyBrushDecal(float4(mix(shaded, maskRamp, opacity), 1.0),
                               in.uv, U);
    }

    // Slope/normal preview follows the same terrain-derived-map idea as GDAL's
    // gdaldem slope/hillshade tools: derive analysis color from local gradient.
    if (mode == 3) {
        float slopeDeg = acos(clamp(N.y, 0.0, 1.0)) * 57.2957795;
        float slope01 = smoothstep(0.0, 70.0, slopeDeg);
        float3 lowSlope = float3(0.08, 0.20, 0.30);
        float3 midSlope = float3(0.83, 0.68, 0.30);
        float3 highSlope = float3(0.86, 0.22, 0.16);
        float3 col = mix(lowSlope, midSlope, smoothstep(0.0, 0.55, slope01));
        col = mix(col, highSlope, smoothstep(0.50, 1.0, slope01));
        return applyBrushDecal(float4(col, 1.0), in.uv, U);
    }

    if (mode == 4) {
        return applyBrushDecal(float4(N * 0.5 + 0.5, 1.0), in.uv, U);
    }

    if (mode == 5) {
        float3 col = materialRamp(h, slope, mask, preset);
        return applyBrushDecal(float4(col * lit, 1.0), in.uv, U);
    }

    if (mode == 6) {
        float value = clamp(in.data, 0.0, 1.0);
        float3 crease = float3(0.08, 0.32, 0.78);
        float3 neutral = float3(0.48, 0.50, 0.52);
        float3 ridge = float3(0.94, 0.36, 0.12);
        float3 lower = mix(crease, neutral, smoothstep(0.0, 0.5, value));
        float3 upper = mix(neutral, ridge, smoothstep(0.5, 1.0, value));
        float3 col = value < 0.5 ? lower : upper;
        return applyBrushDecal(float4(col * (0.68 + 0.32 * lit), 1.0),
                               in.uv, U);
    }

    return applyBrushDecal(float4(shaded, 1.0), in.uv, U);
}
"""
