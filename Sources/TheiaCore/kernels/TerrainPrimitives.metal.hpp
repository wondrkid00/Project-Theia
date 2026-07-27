#pragma once

namespace theia {
namespace kernels {

// Shared deterministic terrain toolkit and three grouped primitive families.
// See docs/research/terrain-primitives-notes.md.
inline constexpr const char* kTerrainPrimitives = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct PrimitiveParams {
    uint width;
    uint height;
    uint kind;
    uint seed;
    float v[12];
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

static inline float2 featurePoint(int2 c, uint seed) {
    float x = randCell(c, seed ^ 0xA511E9B3u);
    float y = randCell(c, seed ^ 0x63D83595u);
    return float2(c) + float2(x, y);
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

static inline float billowNoise(float2 p, uint seed) {
    return 2.0f * abs(gradientNoise(p, seed)) - 1.0f;
}

static inline float ridgedBasis(float2 p, uint seed) {
    return sat(1.0f - abs(gradientNoise(p, seed)));
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

struct WorleyResult {
    float f1;
    float f2;
    float value;
    uint id;
    float2 owner;
};

static inline WorleyResult worley(float2 p, uint seed) {
    int2 base = int2(floor(p));
    WorleyResult r{INFINITY, INFINITY, 0.0f, 0u, float2(0.0f)};
    int2 owner = int2(0);
    for (int oy = -2; oy <= 2; ++oy) {
        for (int ox = -2; ox <= 2; ++ox) {
            int2 c = base + int2(ox,oy);
            float d = length(p - featurePoint(c, seed));
            bool before = (c.y < owner.y) || (c.y == owner.y && c.x < owner.x);
            if (d < r.f1 || (d == r.f1 && before)) {
                r.f2 = r.f1;
                r.f1 = d;
                owner = c;
                r.owner = featurePoint(c, seed);
                r.value = randCell(c, seed ^ 0xB5297A4Du);
                r.id = hash2(uint(c.x), uint(c.y), seed);
            } else if (d < r.f2) {
                r.f2 = d;
            }
        }
    }
    return r;
}

static inline float sdSegment(float2 p, float2 a, float2 b, float radius) {
    float2 ab = b-a;
    float t = clamp(dot(p-a,ab)/max(dot(ab,ab),1.0e-12f),0.0f,1.0f);
    return length(p-mix(a,b,t))-radius;
}

static inline float smoothMin(float a, float b, float k) {
    k = max(k, 1.0e-6f);
    float h = clamp(0.5f+0.5f*(b-a)/k,0.0f,1.0f);
    return mix(b,a,h)-k*h*(1.0f-h);
}

static inline float2 domainPoint(uint2 gid, uint width, uint height) {
    float2 denominator = float2(max(width-1u,1u), max(height-1u,1u));
    return float2(gid)/denominator - 0.5f;
}

static inline float gaussian2(float2 p, float2 c, float2 e, float2 t,
                              float sigmaE, float sigmaT) {
    float2 d = p-c;
    float u = dot(d,e)/max(sigmaE,1.0e-5f);
    float v = dot(d,t)/max(sigmaT,1.0e-5f);
    return exp(-0.5f*(u*u+v*v));
}

static inline float massLineValue(float2 p, constant PrimitiveParams& P) {
    uint kind = P.kind;

    if (kind == 0u) { // rollinghills: scale,height,softness,undulation,warp
        float scale=P.v[0], height=P.v[1], softness=P.v[2];
        float undulation=P.v[3], warp=P.v[4];
        float2 w=warpPoint(p,scale,warp,P.seed);
        float f=1.0f/scale;
        float a=fbm(w,f,3u,2.0f,0.45f,P.seed);
        float b=fbm(w,0.5f*f,2u,2.0f,0.5f,P.seed^0x7F4A7C15u);
        float x=pow(sat(0.5f+0.5f*mix(a,b,undulation)),
                    mix(2.5f,0.55f,softness));
        return sat(1.35f*height*smooth5(x));
    }
    if (kind == 1u) { // canyon upland: scale,height,depth,width,branches,wall,rough
        float scale=P.v[0], rough=P.v[6];
        float2 w=warpPoint(p,scale,0.16f,P.seed);
        float n=fbm(w,1.0f/scale,3u,2.0f,0.5f,P.seed);
        return sat(sat(0.5f+0.5f*n)*roughFactor(w,0.35f*rough,P.seed));
    }
    if (kind == 2u) { // mountain: scale,height,bulk,roughness,warp,x,y
        float scale=P.v[0], height=P.v[1], bulk=P.v[2], rough=P.v[3];
        float2 center=0.5f*float2(P.v[5],P.v[6]);
        float2 w=warpPoint(p,scale,P.v[4],P.seed);
        float rho=length(w-center)/max(0.5f*scale,1.0e-5f);
        float z=pow(sat(1.0f-rho),mix(3.0f,0.55f,bulk));
        return sat(height*z*roughFactor(w,rough,P.seed));
    }
    if (kind == 3u) { // mountainrange
        float scale=P.v[0], height=P.v[1], len=P.v[2], width=P.v[3];
        float angle=toRadians(P.v[4]), peaks=P.v[5], rough=P.v[6];
        float2 center=0.5f*float2(P.v[8],P.v[9]);
        float2 e=float2(cos(angle),sin(angle));
        float2 a=center-0.5f*len*scale*e;
        float2 b=center+0.5f*len*scale*e;
        float2 w=warpPoint(p,scale,P.v[7],P.seed);
        float radius=max(width*scale,1.0e-4f);
        float envelope=pow(sat(-sdSegment(w,a,b,radius)/radius),1.35f);
        float peakModulation=0.0f;
        uint count=uint(peaks);
        for (uint j=0u;j<12u;++j) {
            if (j>=count) break;
            int2 hc=int2(int(j),int(P.seed & 0x7fffffffu));
            float rv=randCell(hc,P.seed^0xB5297A4Du);
            float tau=(float(j)+0.5f+0.35f*(2.0f*rv-1.0f))/max(peaks,1.0f);
            float2 c=mix(a,b,sat(tau));
            float along=dot(w-c,e);
            float sigma=max(0.18f*radius,0.28f*len*scale/max(peaks,1.0f));
            float peak=exp2(-(along*along)/max(sigma*sigma,1.0e-7f));
            peakModulation=max(peakModulation,peak);
        }
        float summit=0.55f+0.45f*peakModulation;
        return sat(height*envelope*summit*roughFactor(w,rough,P.seed));
    }
    if (kind == 4u) { // mountainside
        float scale=P.v[0], height=P.v[1], slope=P.v[2];
        float angle=toRadians(P.v[3]), peak=P.v[4], detail=P.v[5];
        float2 center=0.5f*float2(P.v[7],P.v[8]);
        float2 e=float2(cos(angle),sin(angle));
        float2 w=warpPoint(p,scale,P.v[6],P.seed);
        float d=dot(w-center,e)/max(0.5f*scale,1.0e-5f);
        float side=pow(sat(0.5f+0.5f*d),mix(3.0f,0.5f,slope));
        float summit=peak*exp2(-dot(w-center,w-center)/
                               max(0.04f*scale*scale,1.0e-6f));
        float detailTerm=detail*fbm(4.0f*w,1.0f/scale,4u,2.0f,0.5f,P.seed)
                         *side*(1.0f-side);
        return sat(height*sat(side+summit+detailTerm));
    }
    if (kind == 5u) { // ridge
        float scale=P.v[0], height=P.v[1], len=P.v[2], width=P.v[3];
        float angle=toRadians(P.v[4]), definition=P.v[5], fractures=P.v[6];
        float2 center=0.5f*float2(P.v[8],P.v[9]);
        float2 e=float2(cos(angle),sin(angle));
        float2 t=float2(-e.y,e.x);
        float halfLength=max(0.5f*len*scale,1.0e-5f);
        float s=dot(p-center,e);
        float axial=s/halfLength;
        float q=dot(p-center,t);
        float bendNoise=fbm(float2(0.90f*axial+13.1f,7.7f),1.0f,
                            3u,2.0f,0.5f,P.seed^0x68BC21EBu);
        float bend=0.45f*scale*P.v[7]*bendNoise;
        float lateral=q-bend;
        float radius=max(width*scale,1.0e-5f);
        float d=abs(lateral);
        float coreSigma=radius*mix(1.25f,0.70f,definition);
        float core=exp2(-pow(d/max(coreSigma,1.0e-5f),2.0f));
        float shoulder=exp2(-pow(d/max(2.25f*radius,1.0e-5f),2.0f));
        float support=1.0f-smoothstep(3.0f*radius,4.0f*radius,d);
        float endpoint=1.0f-smoothstep(0.68f,0.98f,abs(axial));
        float axialNoise=fbm(float2(1.35f*axial,5.2f),1.0f,
                             3u,2.0f,0.5f,P.seed^0x4F1BBCDCu);
        float alongModulation=0.88f+0.12f*
            sat(0.5f+0.5f*axialNoise);
        float fractureSignal=abs(fbm(
            float2(2.4f*axial+0.18f*lateral/radius,19.7f),1.0f,
            3u,2.0f,0.5f,P.seed^0x91E10DA5u));
        float crack=1.0f-smoothstep(0.035f,0.14f,fractureSignal);
        float profile=(0.25f*core+0.75f*shoulder)*support;
        float fractureGain=1.0f-0.55f*fractures*crack*
                           smoothstep(0.08f,0.45f,profile);
        return sat(height*profile*endpoint*alongModulation*fractureGain);
    }
    if (kind == 6u) { // rugged
        float scale=P.v[0], height=P.v[1], bulk=P.v[2], rough=P.v[3];
        float fractures=P.v[4];
        float2 w=warpPoint(p,scale,P.v[5],P.seed);
        float f=1.0f/scale;
        float n0=fbm(w,f,5u,2.0f,0.5f,P.seed);
        float n1=0.5f+0.5f*billowNoise(3.0f*w, P.seed^0x91E10DA5u);
        WorleyResult wr=worley((w+0.5f)*(1.5f*f),P.seed^0xDB4F0B91u);
        float crack=1.0f-smoothstep(0.02f,0.18f,wr.f2-wr.f1);
        float ridge=ridgedBasis(2.0f*w*f,P.seed^0x6C8E9CF5u);
        float x=sat(bulk*(0.5f+0.5f*n0)+0.35f*rough*n1+
                    0.20f*rough*ridge-0.25f*fractures*crack);
        return sat(height*smooth5(x));
    }
    if (kind == 7u) { // slump
        float scale=P.v[0], height=P.v[1], collapse=P.v[2];
        float angle=toRadians(P.v[3]), softness=P.v[4], lobes=P.v[5];
        float2 e=float2(cos(angle),sin(angle));
        float2 t=float2(-e.y,e.x);
        float2 w=warpPoint(p,scale,P.v[6],P.seed);
        float sigmaE=mix(0.14f,0.24f,softness)*scale;
        float sigmaT=mix(0.09f,0.14f,softness)*scale;
        float z=0.0f;
        uint count=uint(lobes);
        for (uint j=0u;j<8u;++j) {
            if (j>=count) break;
            float tau=(float(j)+0.5f)/max(lobes,1.0f)-0.5f;
            float rv=randCell(int2(int(j),17),P.seed^0xB5297A4Du);
            float rv2=randCell(int2(int(j),19),P.seed^0x63D83595u);
            float2 scar=-0.18f*scale*(1.0f-4.0f*tau*tau)*e+
                        1.2f*scale*tau*t;
            float2 toe=(0.38f+0.10f*rv)*scale*e+
                       (0.75f*tau+0.08f*(2.0f*rv2-1.0f))*scale*t;
            z += gaussian2(w,toe,e,t,sigmaE,sigmaT)-
                 gaussian2(w,scar,e,t,sigmaE,sigmaT);
        }
        z *= 2.25f*collapse/sqrt(max(lobes,1.0f));
        return sat(0.5f+height*z);
    }
    if (kind == 8u) { // uplift
        float scale=P.v[0], height=P.v[1], angle=toRadians(P.v[2]);
        float folds=P.v[3], foldWidth=P.v[4], jitter=P.v[5], rough=P.v[6];
        float2 e=float2(cos(angle),sin(angle));
        float2 t=float2(-e.y,e.x);
        float2 w=warpPoint(p,scale,0.25f*jitter,P.seed^0x68BC21EBu);
        float z=0.0f;
        uint count=uint(folds);
        for (uint j=0u;j<12u;++j) {
            if (j>=count) break;
            float rv=randCell(int2(int(j),29),P.seed^0xB5297A4Du);
            float rv2=randCell(int2(int(j),31),P.seed^0x63D83595u);
            float offset=mix(-0.5f,0.5f,(float(j)+0.5f)/max(folds,1.0f))*scale;
            float axial=jitter*0.15f*scale*(2.0f*rv-1.0f);
            float2 c=offset*t+axial*e;
            float2 a=c-0.5f*scale*e;
            float2 b=c+0.5f*scale*e;
            float d=max(sdSegment(w,a,b,0.0f),0.0f);
            float localWidth=foldWidth*mix(0.75f,1.25f,rv2);
            float localAmplitude=mix(0.70f,1.0f,rv);
            z=max(z,localAmplitude*
                  exp2(-(d*d)/max(localWidth*localWidth,1.0e-6f)));
        }
        return sat(height*z*roughFactor(w,0.35f*rough,P.seed));
    }
    return 0.0f;
}

static inline float radialImpactValue(float2 p, constant PrimitiveParams& P) {
    if (P.kind == 9u) { // crater
        float scale=P.v[0], height=P.v[1], depth=P.v[2], rimHeight=P.v[3];
        float rimWidth=P.v[4], irregularity=P.v[5], ejecta=P.v[6];
        float2 center=0.5f*float2(P.v[7],P.v[8]);
        float radius=max(0.35f*scale,1.0e-5f);
        float2 d=p-center;
        float angle=atan2(d.y,d.x);
        float radialWarp=1.0f+0.12f*irregularity*
            gradientNoise(float2(cos(angle),sin(angle))*3.0f,P.seed);
        float rho=length(d)/(radius*max(radialWarp,0.7f));
        float cavity=rho<1.0f ? -depth*pow(1.0f-rho*rho,2.0f) : 0.0f;
        float rw=mix(0.025f,0.30f,rimWidth);
        float rim=rimHeight*exp(-pow((rho-1.0f)/max(rw,0.01f),2.0f));
        float extent=mix(0.5f,3.0f,ejecta);
        float ext=ejecta*rimHeight*pow(max(rho,1.0f),-3.0f)*
                  (1.0f-smoothstep(1.0f,1.0f+extent,rho));
        float rays=1.0f+irregularity*
            fbm(float2(angle*0.75f,log2(max(rho,1.0f))),1.0f,3u,2.0f,0.5f,
                P.seed^0xDB4F0B91u);
        return sat(0.5f+height*(cavity+rim+ext*rays));
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

static inline float repeatingFieldValue(float2 p, constant PrimitiveParams& P) {
    if (P.kind == 11u) { // craterfield
        float scale=P.v[0], height=P.v[1], density=P.v[2];
        float variation=P.v[3], rimHeight=P.v[4], age=P.v[5], irregular=P.v[6];
        float grid=ceil(sqrt(max(density,1.0f)));
        float2 cellP=(p+0.5f)*grid;
        int2 base=int2(floor(cellP));
        float maximumRadius=0.15f*scale*(1.0f+variation);
        int lookupRadius=clamp(int(ceil(2.0f*maximumRadius*grid))+1,1,10);
        float z=0.0f;
        for (int oy=-10;oy<=10;++oy) {
            if (abs(oy)>lookupRadius) continue;
            for (int ox=-10;ox<=10;++ox) {
                if (abs(ox)>lookupRadius) continue;
                int2 c=base+int2(ox,oy);
                float occupancy=density/(grid*grid);
                if (randCell(c,P.seed^0x4F1BBCDCu)>=occupancy) continue;
                float2 center=featurePoint(c,P.seed)/grid-0.5f;
                float rv=randCell(c,P.seed^0xB5297A4Du);
                float radius=max(0.15f*scale*mix(1.0f-variation,
                                                1.0f+variation,rv),1.0e-4f);
                float2 d=p-center;
                float a=atan2(d.y,d.x);
                float rho=length(d)/radius;
                float shape=1.0f+0.10f*irregular*
                    gradientNoise(float2(cos(a),sin(a))*3.0f,P.seed^uint(c.x*31+c.y));
                rho/=max(shape,0.75f);
                float cavity=rho<1.0f ?
                    -mix(1.0f,0.45f,age)*pow(1.0f-rho*rho,2.0f) : 0.0f;
                float pixelRadius=
                    radius*float(min(P.width,P.height));
                float pixelRim=2.25f/max(pixelRadius,1.0f);
                float normalizedRimWidth=max(0.16f,pixelRim);
                float rimResolution=smoothstep(2.0f,5.0f,pixelRadius);
                float rim=mix(1.0f,0.2f,age)*rimHeight*rimResolution*
                          exp(-pow((rho-1.0f)/normalizedRimWidth,2.0f));
                float ejecta=mix(0.35f,0.0f,age)*rimHeight*
                             pow(max(rho,1.0f),-3.0f)*
                             (1.0f-smoothstep(1.0f,2.0f,rho));
                z += cavity+rim+ejecta;
            }
        }
        return sat(0.5f+height*z);
    }
    if (P.kind == 12u) { // dunesea
        float scale=P.v[0], height=P.v[1], angle=toRadians(P.v[2]);
        float asym=P.v[3], sharp=P.v[4], chaos=P.v[5], warp=P.v[6];
        float2 e=float2(cos(angle),sin(angle));
        float2 t=float2(-e.y,e.x);
        float cross=dot(p,t);
        float along=dot(p,e);
        float2 q=float2(cross,along);
        float stretchNoise=fbm(float2(q.x,0.35f*q.y),0.45f/scale,
                               3u,2.0f,0.5f,P.seed^0x7F4A7C15u);
        float localFrequency=clamp(1.0f+0.75f*chaos*stretchNoise,
                                   0.55f,1.45f);
        float meander=1.10f*warp*
            fbm(float2(q.x,0.22f*q.y),0.85f/scale,
                3u,2.0f,0.5f,P.seed);
        float phaseChaos=0.35f*chaos*
            fbm(float2(q.x,0.55f*q.y),1.20f/scale,
                4u,2.0f,0.5f,P.seed^0x4F1BBCDCu);
        float phase=fract((along/scale)*localFrequency+meander+phaseChaos);
        float stoss=0.5f+0.45f*asym;
        float rise=smoothstep(0.0f,1.0f,phase/stoss);
        float fall=1.0f-smoothstep(0.0f,1.0f,(phase-stoss)/(1.0f-stoss));
        float dune=phase<=stoss ? rise : fall;
        dune=pow(sat(dune),mix(2.5f,0.45f,sharp));
        float envelope=clamp((0.75f+0.25f*fbm(p,0.5f/scale,3u,2.0f,0.5f,
                                             P.seed^0xC13FA9A9u))*
                             (1.0f+chaos*fbm(p,4.0f/scale,3u,2.0f,0.5f,
                                            P.seed^0x91E10DA5u)),
                             0.0f,1.0f+chaos);
        float segmentNoise=fbm(float2(q.x,0.55f*q.y),0.38f/scale,
                               3u,2.0f,0.5f,P.seed^0xD1B54A35u);
        float segment=smoothstep(-0.18f,0.18f,segmentNoise);
        float continuity=mix(1.0f,0.12f+0.88f*segment,
                             smoothstep(0.0f,0.35f,chaos));
        return sat(height*dune*envelope*continuity);
    }
    if (P.kind == 13u) { // plates
        float scale=P.v[0], height=P.v[1], flat=P.v[2], uplift=P.v[3];
        float tilt=P.v[4];
        float2 w=warpPoint(p,scale,P.v[5],P.seed);
        float2 cellP=(w+0.5f)/scale;
        WorleyResult wr=worley(cellP,P.seed);
        float edgeWidth=mix(0.02f,0.35f,1.0f-flat);
        float boundary=1.0f-smoothstep(0.0f,edgeWidth,wr.f2-wr.f1);
        float a=6.28318530718f*unit24(wr.id);
        float2 dir=float2(cos(a),sin(a));
        float2 ownerOffset=(cellP-wr.owner)*scale;
        float cellTilt=tilt*dot(ownerOffset,dir);
        float z=0.15f+0.55f*wr.value+cellTilt+uplift*boundary;
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

kernel void terrain_repeating_field(device float* out [[buffer(0)]],
                                    constant PrimitiveParams& P [[buffer(1)]],
                                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x>=P.width || gid.y>=P.height) return;
    float v=repeatingFieldValue(domainPoint(gid,P.width,P.height),P);
    out[gid.y*P.width+gid.x]=isfinite(v)?sat(v):v;
}
)METAL";

} // namespace kernels
} // namespace theia
