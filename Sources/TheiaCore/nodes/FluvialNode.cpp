#include "nodes/FluvialNode.hpp"

#include <Foundation/Foundation.hpp>
#include <Metal/Metal.hpp>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <vector>

#include "GPUContext.hpp"
#include "Heightfield.hpp"
#include "kernels/Fluvial.metal.hpp"

namespace theia {

namespace {

// Must match `struct FluvialParams` in kernels::kFluvial exactly.
struct FluvialParamsGPU {
    std::uint32_t width;
    std::uint32_t height;
    float cellSize;
    float heightScale;
    float erodibility;
    float areaExponent;
    float slopeExponent;
    float deposition;
    float dt;
    float rain;
    float mfdExponent;
    float fillEpsilon;
    float uplift;
    float minSlope;
    float criticalSlope;
};

bool finiteParam(const ParamSet& params, const char* name, double fallback,
                 float& value, std::string& error) {
    const double raw = params.get(name, fallback);
    if (!std::isfinite(raw)) {
        error = std::string("fluvial: parameter '") + name + "' must be finite";
        return false;
    }
    value = static_cast<float>(raw);
    return true;
}

} // namespace

bool FluvialNode::evaluate(GPUContext& ctx,
                           const std::vector<const Heightfield*>& inputs,
                           Heightfield& out, std::string& error) {
    return simulate(ctx, inputs, out, nullptr, error);
}

bool FluvialNode::evaluateOutputs(GPUContext& ctx,
                                  const std::vector<const Heightfield*>& inputs,
                                  const std::vector<Heightfield*>& outputs,
                                  std::string& error) {
    if (outputs.empty() || !outputs[0]) {
        error = "fluvial '" + id() + "' has no allocated default output";
        return false;
    }
    Heightfield* flow = outputs.size() > 1 ? outputs[1] : nullptr;
    return simulate(ctx, inputs, *outputs[0], flow, error);
}

bool FluvialNode::simulate(GPUContext& ctx,
                           const std::vector<const Heightfield*>& inputs,
                           Heightfield& height, Heightfield* flow,
                           std::string& error) {
    if (inputs.size() != 1 || !inputs[0]) {
        error = "fluvial '" + id() + "' requires 1 input";
        return false;
    }
    const Heightfield* in = inputs[0];
    const std::uint32_t W = height.width(), H = height.height();
    if (in->width() != W || in->height() != H) {
        error = "fluvial: input size differs from output";
        return false;
    }
    if (W < 3 || H < 3) {
        error = "fluvial: requires at least a 3x3 grid";
        return false;
    }
    const std::size_t n = std::size_t(W) * H;

    const double rawIterations = params.get("iterations", 60.0);
    if (!std::isfinite(rawIterations)) {
        error = "fluvial: parameter 'iterations' must be finite";
        return false;
    }
    const int iterations =
        static_cast<int>(std::clamp(rawIterations, 1.0, 400.0));

    FluvialParamsGPU P{};
    P.width = W;
    P.height = H;
    float terrainSize = 1024.0f;
    float accuracy = 1.0f;
    float diffusivity = 1.2f;
    if (!finiteParam(params, "terrainSize", 1024.0, terrainSize, error) ||
        !finiteParam(params, "heightScale", 100.0, P.heightScale, error) ||
        !finiteParam(params, "erodibility", 0.5, P.erodibility, error) ||
        !finiteParam(params, "areaExponent", 0.5, P.areaExponent, error) ||
        !finiteParam(params, "slopeExponent", 1.0, P.slopeExponent, error) ||
        !finiteParam(params, "deposition", 1.0, P.deposition, error) ||
        !finiteParam(params, "dt", 0.6, P.dt, error) ||
        !finiteParam(params, "rain", 1.0, P.rain, error) ||
        !finiteParam(params, "mfdExponent", 3.0, P.mfdExponent, error) ||
        !finiteParam(params, "uplift", 0.0, P.uplift, error) ||
        !finiteParam(params, "diffusion", 0.3, diffusivity, error) ||
        !finiteParam(params, "minSlope", 0.004, P.minSlope, error) ||
        !finiteParam(params, "criticalSlope", 0.6, P.criticalSlope, error) ||
        !finiteParam(params, "accuracy", 1.0, accuracy, error)) {
        return false;
    }

    // Files and the public API may carry out-of-range values; clamp to the
    // documented procedural envelope before the explicit solver sees them.
    terrainSize = std::clamp(terrainSize, 1.0f, 65536.0f);
    P.cellSize = terrainSize / float(std::max(1u, W - 1));
    P.heightScale = std::clamp(P.heightScale, 1.0f, 4096.0f);
    // These bounds are the node's authoring envelope and the viewer's slider
    // ranges are identical, so a value set in the UI is never silently clamped
    // to something else by the core.
    P.erodibility = std::clamp(P.erodibility, 0.0f, 2.0f);
    // m above 1 makes incision grow superlinearly with discharge, so trunk
    // channels run away and cut through the whole surface. Published values sit
    // near 0.5; 1 is already the generous end of the plausible range.
    P.areaExponent = std::clamp(P.areaExponent, 0.0f, 1.0f);
    P.slopeExponent = std::clamp(P.slopeExponent, 0.1f, 4.0f);
    P.deposition = std::clamp(P.deposition, 0.0f, 4.0f);
    P.dt = std::clamp(P.dt, 0.01f, 2.0f);
    P.rain = std::clamp(P.rain, 0.0f, 8.0f);
    P.mfdExponent = std::clamp(P.mfdExponent, 0.5f, 6.0f);
    P.uplift = std::clamp(P.uplift, 0.0f, 1.0f);
    diffusivity = std::clamp(diffusivity, 0.0f, 0.5f);
    P.minSlope = std::clamp(P.minSlope, 0.0f, 0.1f);
    P.criticalSlope = std::clamp(P.criticalSlope, 0.1f, 4.0f);
    accuracy = std::clamp(accuracy, 0.25f, 4.0f);
    // A slope of this magnitude is imperceptible in the output but guarantees
    // the filled surface descends strictly, so routing always terminates.
    P.fillEpsilon = 1.0e-5f;

    // The flow solvers propagate one cell per pass, so the budget scales with
    // the grid's linear extent. The first step pays the full traversal; later
    // steps warm-start from the converged field and need far less.
    const std::uint32_t span = std::max(W, H);
    const int fillPasses =
        std::max(8, int(float(span) * 2.0f * accuracy));
    const int primeAreaPasses =
        std::max(8, int(float(span) * 1.5f * accuracy));
    const int stepAreaPasses = std::max(4, int(24.0f * accuracy));
    const int fluxPasses = std::max(4, int(24.0f * accuracy));

    // Explicit five-point diffusion is stable only while the effective
    // diffusion number stays under ~0.25; the per-step amount is split into
    // substeps held under a conservative 0.2 rather than clamping the
    // coefficient, so raising `diffusion` keeps having an effect.
    //
    // The nonlinear law multiplies the Laplacian by up to the amplification cap
    // near the critical slope, so the effective number is nu*amplify. The cap
    // therefore belongs in the substep COUNT but NOT in `nu` itself -- folding
    // it into both double-counts it and lets the effective number reach 2.0,
    // eight times the limit. That stayed hidden while a missing heightScale
    // left the amplification inert.
    const float kNonlinearAmplificationCap = 10.0f;
    const float baseDiffusionNumber =
        diffusivity * P.dt / std::max(P.cellSize * P.cellSize, 1e-12f);
    const int diffusionSubsteps =
        (baseDiffusionNumber > 0.0f)
            ? std::clamp(int(std::ceil(baseDiffusionNumber *
                                       kNonlinearAmplificationCap / 0.2f)),
                         1, 64)
            : 0;
    const float diffusionNu =
        diffusionSubsteps > 0 ? baseDiffusionNumber / float(diffusionSubsteps)
                              : 0.0f;

    struct Pass { const char* fn; MTL::ComputePipelineState* pso; };
    Pass passes[] = {
        {"fluvial_fill_init", nullptr},   {"fluvial_fill_step", nullptr},
        {"fluvial_weights", nullptr},     {"fluvial_area_seed", nullptr},
        {"fluvial_area_step", nullptr},   {"fluvial_incise", nullptr},
        {"fluvial_flux_seed", nullptr},   {"fluvial_flux_step", nullptr},
        {"fluvial_apply", nullptr},       {"fluvial_flow_output", nullptr},
        {"fluvial_diffuse", nullptr},    {"fluvial_boundary", nullptr},
    };
    for (auto& p : passes) {
        p.pso = ctx.pipeline(p.fn, kernels::kFluvial, p.fn, error);
        if (!p.pso) return false;
    }
    auto pso = [&](const char* fn) -> MTL::ComputePipelineState* {
        for (auto& p : passes) if (std::string(fn) == p.fn) return p.pso;
        return nullptr;
    };

    NS::AutoreleasePool* pool = NS::AutoreleasePool::alloc()->init();
    MTL::Device* dev = ctx.device();
    auto mk = [&](std::size_t bytes) {
        return dev->newBuffer(bytes, MTL::ResourceStorageModeShared);
    };
    MTL::Buffer* terrainA = mk(n * sizeof(float));
    MTL::Buffer* terrainB = mk(n * sizeof(float));
    MTL::Buffer* fillA = mk(n * sizeof(float));
    MTL::Buffer* fillB = mk(n * sizeof(float));
    MTL::Buffer* areaA = mk(n * sizeof(float));
    MTL::Buffer* areaB = mk(n * sizeof(float));
    MTL::Buffer* fluxA = mk(n * sizeof(float));
    MTL::Buffer* fluxB = mk(n * sizeof(float));
    MTL::Buffer* incision = mk(n * sizeof(float));
    MTL::Buffer* weights = mk(n * 8 * sizeof(float));
    // Immutable copy of the input, used to preserve the rim profile.
    MTL::Buffer* original = mk(n * sizeof(float));

    MTL::Buffer* owned[] = {terrainA, terrainB, fillA, fillB, areaA, areaB,
                            fluxA, fluxB, incision, weights, original};
    for (auto* b : owned) {
        if (!b) {
            for (auto* q : owned) if (q) q->release();
            error = "fluvial: buffer allocation failed";
            pool->release();
            return false;
        }
    }

    std::memcpy(terrainA->contents(), in->data(), n * sizeof(float));
    std::memcpy(original->contents(), in->data(), n * sizeof(float));

    const MTL::Size grid(W, H, 1);
    MTL::CommandBuffer* cb = ctx.queue()->commandBuffer();
    MTL::ComputeCommandEncoder* enc = cb->computeCommandEncoder();
    auto disp = [&](MTL::ComputePipelineState* p) {
        const NS::UInteger tw = p->threadExecutionWidth();
        const NS::UInteger th =
            std::max<NS::UInteger>(1, p->maxTotalThreadsPerThreadgroup() / tw);
        enc->setComputePipelineState(p);
        enc->dispatchThreads(grid, MTL::Size(tw, th, 1));
        enc->memoryBarrier(MTL::BarrierScopeBuffers);
    };

    MTL::Buffer* tSrc = terrainA;
    MTL::Buffer* tDst = terrainB;
    MTL::Buffer* aSrc = areaA;
    MTL::Buffer* aDst = areaB;

    // Seed drainage area once; every step warm-starts from the previous result.
    enc->setBuffer(aSrc, 0, 0);
    enc->setBytes(&P, sizeof(P), 1);
    disp(pso("fluvial_area_seed"));

    for (int step = 0; step < iterations; ++step) {
        // --- depression-filled routing surface -----------------------------
        enc->setBuffer(fillA, 0, 0);
        enc->setBuffer(tSrc, 0, 1);
        enc->setBytes(&P, sizeof(P), 2);
        disp(pso("fluvial_fill_init"));

        MTL::Buffer* fSrc = fillA;
        MTL::Buffer* fDst = fillB;
        for (int k = 0; k < fillPasses; ++k) {
            enc->setBuffer(fDst, 0, 0);
            enc->setBuffer(fSrc, 0, 1);
            enc->setBuffer(tSrc, 0, 2);
            enc->setBytes(&P, sizeof(P), 3);
            disp(pso("fluvial_fill_step"));
            std::swap(fSrc, fDst);
        }

        // --- flow partition ------------------------------------------------
        enc->setBuffer(weights, 0, 0);
        enc->setBuffer(fSrc, 0, 1);
        enc->setBytes(&P, sizeof(P), 2);
        disp(pso("fluvial_weights"));

        // --- drainage area -------------------------------------------------
        const int areaPasses = (step == 0) ? primeAreaPasses : stepAreaPasses;
        for (int k = 0; k < areaPasses; ++k) {
            enc->setBuffer(aDst, 0, 0);
            enc->setBuffer(aSrc, 0, 1);
            enc->setBuffer(weights, 0, 2);
            enc->setBytes(&P, sizeof(P), 3);
            disp(pso("fluvial_area_step"));
            std::swap(aSrc, aDst);
        }

        // --- incision ------------------------------------------------------
        enc->setBuffer(incision, 0, 0);
        enc->setBuffer(fSrc, 0, 1);
        enc->setBuffer(aSrc, 0, 2);
        enc->setBuffer(weights, 0, 3);
        enc->setBuffer(tSrc, 0, 4);
        enc->setBytes(&P, sizeof(P), 5);
        disp(pso("fluvial_incise"));

        // --- sediment flux --------------------------------------------------
        MTL::Buffer* qSrc = fluxA;
        MTL::Buffer* qDst = fluxB;
        enc->setBuffer(qSrc, 0, 0);
        enc->setBytes(&P, sizeof(P), 1);
        disp(pso("fluvial_flux_seed"));
        for (int k = 0; k < fluxPasses; ++k) {
            enc->setBuffer(qDst, 0, 0);
            enc->setBuffer(qSrc, 0, 1);
            enc->setBuffer(weights, 0, 2);
            enc->setBuffer(incision, 0, 3);
            enc->setBuffer(aSrc, 0, 4);
            enc->setBytes(&P, sizeof(P), 5);
            disp(pso("fluvial_flux_step"));
            std::swap(qSrc, qDst);
        }

        // --- surface update -------------------------------------------------
        enc->setBuffer(tDst, 0, 0);
        enc->setBuffer(tSrc, 0, 1);
        enc->setBuffer(incision, 0, 2);
        enc->setBuffer(qSrc, 0, 3);
        enc->setBuffer(aSrc, 0, 4);
        enc->setBuffer(weights, 0, 5);
        enc->setBytes(&P, sizeof(P), 6);
        disp(pso("fluvial_apply"));

        std::swap(tSrc, tDst);

        enc->setBuffer(tSrc, 0, 0);
        enc->setBuffer(original, 0, 1);
        enc->setBytes(&P, sizeof(P), 2);
        disp(pso("fluvial_boundary"));

        // --- hillslope diffusion --------------------------------------------
        for (int k = 0; k < diffusionSubsteps; ++k) {
            enc->setBuffer(tDst, 0, 0);
            enc->setBuffer(tSrc, 0, 1);
            enc->setBytes(&P, sizeof(P), 2);
            enc->setBytes(&diffusionNu, sizeof(diffusionNu), 3);
            disp(pso("fluvial_diffuse"));
            std::swap(tSrc, tDst);
        }
        if (diffusionSubsteps > 0) {
            enc->setBuffer(tSrc, 0, 0);
            enc->setBuffer(original, 0, 1);
            enc->setBytes(&P, sizeof(P), 2);
            disp(pso("fluvial_boundary"));
        }
    }

    enc->endEncoding();
    cb->commit();
    cb->waitUntilCompleted();

    bool ok = cb->status() == MTL::CommandBufferStatusCompleted;
    if (!ok) {
        error = "fluvial: command buffer did not complete (status " +
                std::to_string(static_cast<int>(cb->status())) + ")";
    }

    if (ok) {
        std::memcpy(height.buffer()->contents(), tSrc->contents(),
                    n * sizeof(float));

        if (flow) {
            // Drainage area spans many orders of magnitude, so the exposed
            // field is log-compressed against its own range. Doing the
            // reduction on the CPU keeps the kernel branch-free and the range
            // exact.
            const float* areaValues =
                static_cast<const float*>(aSrc->contents());
            float lo = std::numeric_limits<float>::infinity();
            float hi = -std::numeric_limits<float>::infinity();
            for (std::size_t i = 0; i < n; ++i) {
                const float v = std::log(std::max(areaValues[i], 1e-12f));
                if (std::isfinite(v)) {
                    lo = std::min(lo, v);
                    hi = std::max(hi, v);
                }
            }
            if (!std::isfinite(lo) || !std::isfinite(hi) || hi <= lo) {
                lo = 0.0f;
                hi = 1.0f;
            }
            const float range[2] = {lo, hi};

            MTL::CommandBuffer* cb2 = ctx.queue()->commandBuffer();
            MTL::ComputeCommandEncoder* enc2 = cb2->computeCommandEncoder();
            MTL::ComputePipelineState* p = pso("fluvial_flow_output");
            const NS::UInteger tw = p->threadExecutionWidth();
            const NS::UInteger th = std::max<NS::UInteger>(
                1, p->maxTotalThreadsPerThreadgroup() / tw);
            enc2->setComputePipelineState(p);
            enc2->setBuffer(flow->buffer(), 0, 0);
            enc2->setBuffer(aSrc, 0, 1);
            enc2->setBytes(&P, sizeof(P), 2);
            enc2->setBytes(range, sizeof(range), 3);
            enc2->dispatchThreads(grid, MTL::Size(tw, th, 1));
            enc2->endEncoding();
            cb2->commit();
            cb2->waitUntilCompleted();
            ok = cb2->status() == MTL::CommandBufferStatusCompleted;
            if (!ok) {
                error = "fluvial: flow output pass did not complete";
            }
        }
    }

    for (auto* b : owned) b->release();
    pool->release();
    return ok;
}

} // namespace theia
