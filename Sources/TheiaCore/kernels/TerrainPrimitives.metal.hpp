#pragma once

namespace theia {
namespace kernels {

// Shared deterministic terrain toolkit and two grouped primitive families.
// See docs/research/terrain-primitives-notes.md.
inline constexpr const char* kTerrainPrimitives = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct PrimitiveParams {
    uint width;
    uint height;
    uint kind;
    uint seed;
    float v[16];
};

static inline float sat(float x) {
    return clamp(x, 0.0f, 1.0f);
}

static inline float smooth5(float x) {
    x = sat(x);
    return x*x*x*(x*(x*6.0f-15.0f)+10.0f);
}

static inline float toRadians(float degrees) {
    return degrees * 0.017453292519943295f;
}

static inline uint hash2(uint x, uint y, uint seed) {
    uint h = seed + 0x9E3779B9u;
    h ^= x * 0x85EBCA77u;
    h = (h ^ (h >> 15)) * 0xC2B2AE3Du;
    h ^= y * 0x27D4EB2Fu;
    h = (h ^ (h >> 13)) * 0x165667B1u;
    return h ^ (h >> 16);
}

static inline float unit24(uint h) {
    return float(h >> 8) * (1.0f / 16777216.0f);
}

static inline float randCell(int2 c, uint seed) {
    return unit24(hash2(uint(c.x), uint(c.y), seed));
}

static inline float2 grad2(int2 i, uint seed) {
    uint h = hash2(uint(i.x), uint(i.y), seed);
    float a = float(h) * (6.28318530718f / 4294967296.0f);
    return float2(cos(a), sin(a));
}

static inline float gradientNoise(float2 p, uint seed) {
    int2 i = int2(floor(p));
    float2 f = p - float2(i);
    float2 u = f*f*f*(f*(f*6.0f-15.0f)+10.0f);
    float n00 = dot(grad2(i, seed), f);
    float n10 = dot(grad2(i + int2(1,0), seed), f-float2(1,0));
    float n01 = dot(grad2(i + int2(0,1), seed), f-float2(0,1));
    float n11 = dot(grad2(i + int2(1,1), seed), f-float2(1,1));
    return mix(mix(n00,n10,u.x), mix(n01,n11,u.x), u.y) * 1.41421356f;
}

static inline float fbm(float2 p, float frequency, uint octaves,
                        float lacunarity, float gain, uint seed) {
    float sum = 0.0f;
    float norm = 0.0f;
    float amp = 1.0f;
    float freq = frequency;
    for (uint o = 0; o < 8; ++o) {
        if (o >= octaves) break;
        sum += amp * gradientNoise(p * freq, seed + 1013u*o);
        norm += amp;
        amp *= gain;
        freq *= lacunarity;
    }
    return norm > 0.0f ? sum / norm : 0.0f;
}

static inline float2 warpPoint(float2 p, float scale, float amount, uint seed) {
    float displacement = 0.25f * scale * amount;
    float wx = fbm(p + float2(17.1f,31.7f), 1.0f/max(scale,0.05f),
                   3u, 2.0f, 0.5f, seed ^ 0x68BC21EBu);
    float wy = fbm(p + float2(43.6f,11.9f), 1.0f/max(scale,0.05f),
                   3u, 2.0f, 0.5f, seed ^ 0x02E5BE93u);
    return p + displacement * float2(wx,wy);
}

static inline float roughFactor(float2 p, float amount, uint seed) {
    return clamp(1.0f + amount * fbm(p, 8.0f, 4u, 2.0f, 0.5f,
                                    seed ^ 0xC13FA9A9u),
                 0.0f, 1.0f + amount);
}

// Low-relief ground the landform sits in. A primitive whose profile clips to
// exactly zero outside its radius renders as a shape stamped on a dead-flat
// plane, which is the most artificial thing a generator can do; measured corner
// relief on mountain/mountainrange/crater was 0.00000 before this existed.
static inline float surroundingRelief(float2 p, float amount, float scale,
                                      uint seed) {
    if (amount <= 0.0f) return 0.0f;
    float f = 1.0f/max(scale, 0.05f);
    float broad = fbm(p, 0.55f*f, 4u, 2.05f, 0.5f, seed ^ 0x9E3779B9u);
    float fine  = fbm(p, 2.20f*f, 3u, 2.00f, 0.45f, seed ^ 0x85EBCA6Bu);
    return amount * sat(0.5f + 0.5f*(0.75f*broad + 0.25f*fine));
}

static inline float2 domainPoint(uint2 gid, uint width, uint height) {
    float2 denominator = float2(max(width-1u,1u), max(height-1u,1u));
    return float2(gid)/denominator - 0.5f;
}

static inline float massLineValue(float2 p, constant PrimitiveParams& P) {
    uint kind = P.kind;

    if (kind == 0u) { // rollinghills: scale,height,softness,undulation,warp,detail
        float scale=P.v[0], height=P.v[1], softness=P.v[2];
        float undulation=P.v[3], warp=P.v[4], detail=P.v[5];
        float2 w=warpPoint(p,scale,warp,P.seed);
        float f=1.0f/scale;
        // Three octaves band-limits the surface far below the sampling grid, so
        // it reads as blurred rather than smooth. `detail` extends the spectrum
        // without changing the landform's character.
        uint oct=3u+uint(clamp(detail,0.0f,1.0f)*4.0f+0.5f);
        float a=fbm(w,f,oct,2.0f,0.45f,P.seed);
        float b=fbm(w,0.5f*f,2u,2.0f,0.5f,P.seed^0x7F4A7C15u);
        float x=pow(sat(0.5f+0.5f*mix(a,b,undulation)),
                    mix(2.5f,0.55f,softness));
        return sat(1.35f*height*smooth5(x));
    }
    if (kind == 1u) { // canyon upland: scale,height,depth,width,branches,wall,rough,benching
        float scale=P.v[0], rough=P.v[6], benching=P.v[7];
        float2 w=warpPoint(p,scale,0.16f,P.seed);
        // Deliberately 3 octaves. A 4th measurably weakened the carve (1828 ->
        // 1485 carved cells at the test fixture) because the extra fine relief
        // perturbs the traced channels; benching supplies the wall character
        // instead, at a fraction of that cost.
        float n=fbm(w,1.0f/scale,3u,2.0f,0.5f,P.seed);
        float s=sat(0.5f+0.5f*n);
        // Sedimentary uplands weather into benches, and that stepped profile is
        // what reads as "canyon" rather than "valley". Quantizing the upland
        // before the carve makes the walls inherit the steps.
        if (benching>0.0f) {
            float steps=mix(3.0f,14.0f,benching);
            float band=fract(s*steps);
            float stepped=(floor(s*steps)+smooth5(band))/steps;
            s=mix(s,stepped,sat(benching)*0.8f);
        }
        return sat(s*roughFactor(w,0.35f*rough,P.seed));
    }
    if (kind == 2u) { // mountain: scale,height,bulk,roughness,warp,x,y,surroundings
        float scale=P.v[0], height=P.v[1], bulk=P.v[2], rough=P.v[3];
        float surroundings=P.v[7];
        float2 center=0.5f*float2(P.v[5],P.v[6]);
        float2 w=warpPoint(p,scale,P.v[4],P.seed);
        float rho=length(w-center)/max(0.5f*scale,1.0e-5f);
        // `sat(1-rho)` is exactly zero past the radius, ending the massif on a
        // circle. The gaussian skirt keeps a decaying piedmont beyond it, the
        // way a real mountain grades into its plain.
        float core=pow(sat(1.0f-rho),mix(3.0f,0.55f,bulk));
        float foot=0.24f*exp(-1.1f*rho*rho);
        float z=sat(core+foot);
        // Roughness multiplies the LANDFORM only. Applied to the whole field it
        // would inherit the cone's zero and leave the surroundings smooth.
        float ground=surroundingRelief(w,surroundings,scale,P.seed);
        return sat(ground*(1.0f-0.65f*z)
                   + height*z*roughFactor(w,rough,P.seed));
    }
    if (kind == 3u) { // mountainrange
        float scale=P.v[0], height=P.v[1], len=P.v[2], width=P.v[3];
        float angle=toRadians(P.v[4]), peaks=P.v[5], rough=P.v[6];
        float2 center=0.5f*float2(P.v[8],P.v[9]);
        float surroundings=P.v[10], peakVariation=P.v[11];
        float arc=P.v[12], sinuosity=P.v[13];
        float2 e=float2(cos(angle),sin(angle));
        float2 t=float2(-e.y,e.x);
        float2 w=warpPoint(p,scale,P.v[7],P.seed);
        float span=len*scale;
        float radius=max(width*scale,1.0e-4f);

        // Fold-thrust belts are linear, sinuous (salients and recesses) or
        // arcuate (oroclines) in map view; a perfectly straight axis is the
        // least common of the three and reads as a manufactured wall. The spine
        // bows by `arc` and wanders along-strike by `sinuosity`.
        // Distance to the SEGMENTS of the spine, not to sampled points.
        // Nearest-point-of-N is piecewise constant, so the field creases along
        // the Voronoi boundaries between samples and renders as hard slashes
        // radiating from the ridge.
        const uint kSpineSegments=20u;
        float bestDistance=1.0e9f;
        float2 previous=center-0.5f*span*e;
        for (uint k=1u;k<=kSpineSegments;++k) {
            float s0=float(k)/float(kSpineSegments);
            float centred=2.0f*s0-1.0f;
            float bow=arc*span*0.45f*(1.0f-centred*centred);
            float wander=sinuosity*span*0.22f*
                gradientNoise(float2(s0*2.6f,7.3f),P.seed^0x6C8E9CF5u);
            float2 current=center+span*(s0-0.5f)*e+(bow+wander)*t;
            float2 pa=w-previous;
            float2 ba=current-previous;
            float hh=sat(dot(pa,ba)/max(dot(ba,ba),1.0e-9f));
            float dist=length(pa-ba*hh);
            if (dist<bestDistance) {
                bestDistance=dist;
            }
            previous=current;
        }
        // Distance to a line has a gradient discontinuity ON the line, which
        // renders as a razor-thin bright crest. Rounding the distance near zero
        // gives the ridge a real summit width instead of a knife edge.
        float rounded=sqrt(bestDistance*bestDistance+0.010f*radius*radius);
        float envelope=pow(sat(1.0f-rounded/radius),1.35f);
        float outside=max(bestDistance/radius-1.0f,0.0f);
        float foot=0.22f*exp(-1.6f*outside*outside);

        float peakModulation=0.0f;
        uint count=uint(peaks);
        for (uint j=0u;j<12u;++j) {
            if (j>=count) break;
            int2 hc=int2(int(j),int(P.seed & 0x7fffffffu));
            float rv=randCell(hc,P.seed^0xB5297A4Du);
            float rvAmp=randCell(int2(int(j),911),P.seed^0x27D4EB2Fu);
            float rvSig=randCell(int2(int(j),523),P.seed^0x165667B1u);
            // Summits were evenly spaced at identical height, which reads as a
            // manufactured comb rather than a range.
            float jitter=mix(0.35f,0.95f,sat(peakVariation));
            float tau=sat((float(j)+0.5f+jitter*(2.0f*rv-1.0f))
                          /max(peaks,1.0f));
            // Summit position is the actual point on the spine, and influence
            // is true 2D distance to it. Deriving it from the nearest-segment
            // parameter inherited a jump wherever the nearest segment changes,
            // which rendered as thin slashes across the ridge.
            float centredTau=2.0f*tau-1.0f;
            float bowTau=arc*span*0.45f*(1.0f-centredTau*centredTau);
            float wanderTau=sinuosity*span*0.22f*
                gradientNoise(float2(tau*2.6f,7.3f),P.seed^0x6C8E9CF5u);
            float2 summitPoint=center+span*(tau-0.5f)*e+(bowTau+wanderTau)*t;
            float along=length(w-summitPoint);
            float sigma=max(0.18f*radius,0.28f*span/max(peaks,1.0f))
                        *mix(1.0f,mix(0.55f,1.60f,rvSig),sat(peakVariation));
            float peak=exp2(-(along*along)/max(sigma*sigma,1.0e-7f));
            float amp=mix(1.0f,mix(0.30f,1.0f,rvAmp),sat(peakVariation));
            // Probabilistic union, not max(): max() is only C0 where two
            // summits' influence crosses and that crease showed as hard
            // straight cuts running across the ridge.
            float v=sat(amp*peak);
            peakModulation=peakModulation+v-peakModulation*v;
        }
        float summit=0.55f+0.45f*peakModulation;
        float z=sat(envelope*summit+0.6f*foot);
        float ground=surroundingRelief(w,surroundings,scale,P.seed);
        return sat(ground*(1.0f-0.65f*z)
                   + height*z*roughFactor(w,rough,P.seed));
    }
    return 0.0f;
}

static inline float radialImpactValue(float2 p, constant PrimitiveParams& P) {
    if (P.kind == 9u) { // crater
        float scale=P.v[0], height=P.v[1], depth=P.v[2], rimHeight=P.v[3];
        float rimWidth=P.v[4], irregularity=P.v[5], ejecta=P.v[6];
        float2 center=0.5f*float2(P.v[7],P.v[8]);
        float complexity=P.v[9], terraces=P.v[10], surroundings=P.v[11];
        float radius=max(0.35f*scale,1.0e-5f);
        float2 d=p-center;
        float invR=1.0f/max(radius,1.0e-5f);

        // Azimuthal variation is sampled in CARTESIAN space. Feeding atan2(y,x)
        // into noise makes the angular coordinate vary infinitely fast near the
        // centre and produces a starburst of spokes converging on a point.
        float2 dir=d/max(length(d),1.0e-5f);
        float rimNoise=gradientNoise(dir*2.6f,P.seed)
                      +0.5f*gradientNoise(dir*5.3f,P.seed^0x51ED270Bu);
        float rho=length(d)/(radius*max(1.0f+0.14f*irregularity*rimNoise,0.7f));

        // Pike (1977) and the lunar morphometry that follows it: a SIMPLE
        // crater is a paraboloid bowl at d/D ~ 0.2. Flat floors, wall terraces
        // and a central peak belong to COMPLEX craters past the simple-to-
        // complex transition, so `complexity` morphs between the two regimes
        // rather than both being present at once. An earlier flat floor plus a
        // smooth5 wall gave zero gradient at both ends, which rendered as a
        // punched cylinder rather than an impact.
        float floorFrac=sat(complexity)*0.45f;
        float bowl=0.0f;
        float terrace=0.0f;
        if (rho<=floorFrac) {
            bowl=-depth;
        } else if (rho<1.0f) {
            float wall=(rho-floorFrac)/max(1.0f-floorFrac,1.0e-5f);
            bowl=-depth*(1.0f-wall*wall);
            // Terrace zone width grows with crater size, so terracing is tied
            // to complexity rather than applied to every crater.
            float benches=mix(2.0f,4.5f,sat(terraces));
            float phase=wall*benches
                       +0.35f*gradientNoise(d*(9.0f*invR),P.seed^0x2545F491u);
            terrace=sat(terraces)*sat(complexity)*depth*0.09f
                    *sin(6.2831853f*phase)*sat(1.0f-wall)
                    *smooth5(sat(wall*2.5f));
        }
        // Central peak: complex craters only.
        float peak=sat(complexity)*depth*0.42f
                   *exp(-(rho*rho)/max(0.055f,1.0e-5f));

        float rw=mix(0.03f,0.30f,rimWidth);
        float rim=rimHeight*exp(-pow((rho-1.0f)/max(rw,0.01f),2.0f));

        // Ejecta thins roughly as r^-3 and is hummocky, not a smooth glacis.
        float extent=mix(0.6f,3.5f,ejecta);
        float texture=1.0f+0.6f*irregularity*
            fbm(d*(7.0f*invR),1.0f,3u,2.0f,0.5f,P.seed^0xDB4F0B91u);
        float blanket=ejecta*rimHeight*pow(max(rho,1.0f),-3.0f)
                      *(1.0f-smoothstep(1.0f,1.0f+extent,rho))*texture;

        float ground=surroundingRelief(p,surroundings,scale,P.seed);
        float inside=sat(1.0f-rho);
        return sat(0.5f + ground*(1.0f-0.8f*inside)
                   + height*(bowl+terrace+peak+rim+blanket));
    }
    if (P.kind == 10u) { // volcano
        float scale=P.v[0], height=P.v[1], mouth=P.v[2];
        float caldera=P.v[3], bulk=P.v[4], radial=P.v[5], rough=P.v[6];
        float2 center=0.5f*float2(P.v[7],P.v[8]);
        float radius=max(0.5f*scale,1.0e-5f);
        float2 d=p-center;
        float rho=length(d)/radius;
        float cone=pow(sat(1.0f-rho),mix(2.5f,0.5f,bulk));
        float mouthRadius=radius*mix(0.03f,0.45f,mouth);
        float rm=length(d)/max(mouthRadius,1.0e-5f);
        float bowl=rm<1.0f ? caldera*pow(1.0f-rm*rm,2.0f) : 0.0f;
        float angle=atan2(d.y,d.x);
        float ravine=radial*sat(gradientNoise(float2(12.0f*angle,4.0f*rho),
                                              P.seed^0xDB4F0B91u))
                     *rho*sat(1.0f-rho);
        float z=max(0.0f,cone*roughFactor(p,rough,P.seed)-bowl-ravine);
        return sat(height*z);
    }
    return 0.0f;
}

kernel void terrain_mass_line(device float* out [[buffer(0)]],
                              constant PrimitiveParams& P [[buffer(1)]],
                              uint2 gid [[thread_position_in_grid]]) {
    if (gid.x>=P.width || gid.y>=P.height) return;
    float v=massLineValue(domainPoint(gid,P.width,P.height),P);
    out[gid.y*P.width+gid.x]=isfinite(v)?sat(v):v;
}

kernel void terrain_radial_impact(device float* out [[buffer(0)]],
                                 constant PrimitiveParams& P [[buffer(1)]],
                                 uint2 gid [[thread_position_in_grid]]) {
    if (gid.x>=P.width || gid.y>=P.height) return;
    float v=radialImpactValue(domainPoint(gid,P.width,P.height),P);
    out[gid.y*P.width+gid.x]=isfinite(v)?sat(v):v;
}

)METAL";

} // namespace kernels
} // namespace theia
