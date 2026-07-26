#include "nodes/HydraulicErosionNode.hpp"

#include <Foundation/Foundation.hpp>
#include <Metal/Metal.hpp>
#include <algorithm>
#include <cmath>

#include "GPUContext.hpp"
#include "Heightfield.hpp"
#include "kernels/Erosion.metal.hpp"

namespace theia {

namespace {
// Must match `struct HydroParams` in kernels::kHydraulic exactly.
struct HydroParamsGPU {
    std::uint32_t width;
    std::uint32_t height;
    float dt;
    float rain;
    float evaporation;
    float gravity;
    float pipeArea;
    float pipeLength;
    float cellSize;
    float sedimentCap;
    float suspension;
    float deposition;
    float minTilt;
    float heightScale;
};

bool finiteParam(const ParamSet& params, const char* name, double fallback,
                 float& value, std::string& error) {
    const double raw = params.get(name, fallback);
    if (!std::isfinite(raw)) {
        error = std::string("hydraulic: parameter '") + name +
                "' must be finite";
        return false;
    }
    value = static_cast<float>(raw);
    return true;
}
} // namespace

bool HydraulicErosionNode::evaluate(GPUContext& ctx,
                                    const std::vector<const Heightfield*>& inputs,
                                    Heightfield& out, std::string& error) {
    if (inputs.size() != 1 || !inputs[0]) {
        error = "hydraulic '" + id() + "' requires 1 input";
        return false;
    }
    const Heightfield* in = inputs[0];
    const std::uint32_t W = out.width(), H = out.height();
    if (in->width() != W || in->height() != H) {
        error = "hydraulic: input size differs from output";
        return false;
    }
    const std::size_t n = std::size_t(W) * H;

    const double rawIterations = params.get("iterations", 200.0);
    if (!std::isfinite(rawIterations)) {
        error = "hydraulic: parameter 'iterations' must be finite";
        return false;
    }
    // Clamp while the value is still a double. Converting a finite value outside
    // the range of int before clamping would itself be undefined behavior.
    const int iterations = static_cast<int>(std::clamp(rawIterations, 1.0, 1000.0));

    HydroParamsGPU P{};
    P.width = W;
    P.height = H;
    float terrainSize = 1024.0f;
    if (!finiteParam(params, "dt", 0.015, P.dt, error) ||
        !finiteParam(params, "rain", 0.010, P.rain, error) ||
        !finiteParam(params, "evaporation", 0.020, P.evaporation, error) ||
        !finiteParam(params, "gravity", 9.81, P.gravity, error) ||
        !finiteParam(params, "pipeArea", 1.0, P.pipeArea, error) ||
        !finiteParam(params, "pipeLength", 1.0, P.pipeLength, error) ||
        !finiteParam(params, "terrainSize", 1024.0, terrainSize, error) ||
        !finiteParam(params, "sedimentCapacity", 0.65, P.sedimentCap, error) ||
        !finiteParam(params, "suspension", 0.60, P.suspension, error) ||
        !finiteParam(params, "deposition", 0.45, P.deposition, error) ||
        !finiteParam(params, "minTilt", 0.005, P.minTilt, error) ||
        !finiteParam(params, "heightScale", 80.0, P.heightScale, error)) {
        return false;
    }

    // The public API accepts legacy/out-of-range graph values. Clamp them to
    // a finite procedural envelope before the explicit solver sees them.
    P.dt = std::clamp(P.dt, 0.0001f, 0.1f);
    P.rain = std::clamp(P.rain, 0.0f, 1.0f);
    P.evaporation = std::clamp(P.evaporation, 0.0f, 1.0f);
    P.gravity = std::clamp(P.gravity, 0.0f, 20.0f);
    P.pipeArea = std::clamp(P.pipeArea, 0.05f, 4.0f);
    P.pipeLength = std::clamp(P.pipeLength, 0.05f, 4.0f);
    // Ground spacing is derived from the terrain's world width and the grid, so
    // the solver's length system no longer shifts with resolution. The upper
    // bound spans the derived range for authored sizes across usable grids;
    // small cells stay bounded below because they tighten the Courant limit.
    terrainSize = std::clamp(terrainSize, 1.0f, 65536.0f);
    P.cellSize = std::clamp(terrainSize / float(std::max(1u, W - 1)),
                            0.05f, 64.0f);
    P.sedimentCap = std::clamp(P.sedimentCap, 0.0f, 4.0f);
    P.suspension = std::clamp(P.suspension, 0.0f, 4.0f);
    P.deposition = std::clamp(P.deposition, 0.0f, 4.0f);
    P.minTilt = std::clamp(P.minTilt, 0.0f, 1.0f);
    P.heightScale = std::clamp(P.heightScale, 1.0f, 300.0f);

    // Compile all passes (cached after first use).
    struct Pass { const char* fn; MTL::ComputePipelineState* pso; };
    Pass passes[] = {
        {"hydro_init", nullptr},  {"hydro_rain", nullptr},
        {"hydro_flux", nullptr},  {"hydro_water", nullptr},
        {"hydro_erode", nullptr}, {"hydro_advect", nullptr},
        {"hydro_evap", nullptr},  {"hydro_settle_flux", nullptr},
        {"hydro_settle_apply", nullptr}, {"hydro_finish", nullptr},
    };
    for (auto& p : passes) {
        p.pso = ctx.pipeline(p.fn, kernels::kHydraulic, p.fn, error);
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
    MTL::Buffer* water = mk(n * sizeof(float));
    MTL::Buffer* flux = mk(n * sizeof(float) * 4);
    MTL::Buffer* vel = mk(n * sizeof(float) * 2);
    MTL::Buffer* sedA = mk(n * sizeof(float));
    MTL::Buffer* sedB = mk(n * sizeof(float));

    MTL::Buffer* owned[] = {terrainA, terrainB, water, flux, vel, sedA, sedB};
    bool allocOk = true;
    for (auto* b : owned) allocOk = allocOk && (b != nullptr);
    if (!allocOk) {
        for (auto* b : owned) if (b) b->release();
        error = "hydraulic: buffer allocation failed";
        pool->release();
        return false;
    }

    MTL::CommandBuffer* cb = ctx.queue()->commandBuffer();

    // Zero the dynamic state buffers.
    MTL::BlitCommandEncoder* blit = cb->blitCommandEncoder();
    blit->fillBuffer(water, NS::Range(0, n * sizeof(float)), 0);
    blit->fillBuffer(flux, NS::Range(0, n * sizeof(float) * 4), 0);
    blit->fillBuffer(vel, NS::Range(0, n * sizeof(float) * 2), 0);
    blit->fillBuffer(sedA, NS::Range(0, n * sizeof(float)), 0);
    blit->fillBuffer(sedB, NS::Range(0, n * sizeof(float)), 0);
    blit->endEncoding();

    MTL::ComputeCommandEncoder* enc = cb->computeCommandEncoder();
    const MTL::Size grid(W, H, 1);
    auto disp = [&](MTL::ComputePipelineState* p) {
        const NS::UInteger tw = p->threadExecutionWidth();
        const NS::UInteger th =
            std::max<NS::UInteger>(1, p->maxTotalThreadsPerThreadgroup() / tw);
        enc->setComputePipelineState(p);
        enc->dispatchThreads(grid, MTL::Size(tw, th, 1));
        enc->memoryBarrier(MTL::BarrierScopeBuffers);
    };

    // init: terrainA = input * heightScale
    enc->setBuffer(in->buffer(), 0, 8);
    enc->setBuffer(terrainA, 0, 0);
    enc->setBytes(&P, sizeof(P), 7);
    disp(pso("hydro_init"));

    MTL::Buffer* tSrc = terrainA;
    MTL::Buffer* tDst = terrainB;
    for (int it = 0; it < iterations; ++it) {
        // rain
        enc->setBuffer(water, 0, 2);
        enc->setBytes(&P, sizeof(P), 7);
        disp(pso("hydro_rain"));
        // flux
        enc->setBuffer(tSrc, 0, 0);
        enc->setBuffer(water, 0, 2);
        enc->setBuffer(flux, 0, 3);
        disp(pso("hydro_flux"));
        // water + velocity
        enc->setBuffer(water, 0, 2);
        enc->setBuffer(flux, 0, 3);
        enc->setBuffer(vel, 0, 4);
        disp(pso("hydro_water"));
        // erode/deposit: tSrc->tDst, sedA->sedB
        enc->setBuffer(tSrc, 0, 0);
        enc->setBuffer(tDst, 0, 1);
        enc->setBuffer(water, 0, 2);
        enc->setBuffer(vel, 0, 4);
        enc->setBuffer(sedA, 0, 5);
        enc->setBuffer(sedB, 0, 6);
        enc->setBuffer(in->buffer(), 0, 8);
        disp(pso("hydro_erode"));
        // advect sediment: sedB->sedA
        enc->setBuffer(sedB, 0, 5);
        enc->setBuffer(sedA, 0, 6);
        enc->setBuffer(vel, 0, 4);
        disp(pso("hydro_advect"));
        // evaporate
        enc->setBuffer(water, 0, 2);
        disp(pso("hydro_evap"));

        std::swap(tSrc, tDst);  // tSrc now holds the latest terrain
    }

    // A few conservative high-talus passes remove only slopes newly steepened
    // beyond the source terrain. `flux` can be reused now that water transport
    // has finished.
    const int settlingIterations = std::clamp(iterations / 30, 4, 12);
    for (int it = 0; it < settlingIterations; ++it) {
        enc->setBuffer(tSrc, 0, 0);
        enc->setBuffer(flux, 0, 3);
        enc->setBuffer(in->buffer(), 0, 8);
        disp(pso("hydro_settle_flux"));

        enc->setBuffer(tSrc, 0, 0);
        enc->setBuffer(tDst, 0, 1);
        enc->setBuffer(flux, 0, 3);
        disp(pso("hydro_settle_apply"));
        std::swap(tSrc, tDst);
    }

    // finish: out = tSrc / heightScale
    enc->setBuffer(tSrc, 0, 0);
    enc->setBuffer(out.buffer(), 0, 9);
    enc->setBytes(&P, sizeof(P), 7);
    disp(pso("hydro_finish"));

    enc->endEncoding();
    cb->commit();
    cb->waitUntilCompleted();

    const bool ok = cb->status() == MTL::CommandBufferStatusCompleted;
    if (!ok) {
        error = "hydraulic: command buffer did not complete (status " +
                std::to_string(static_cast<int>(cb->status())) + ")";
    }
    for (auto* b : owned) b->release();
    pool->release();
    return ok;
}

} // namespace theia
