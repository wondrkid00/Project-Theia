#include "nodes/ThermalErosionNode.hpp"

#include <Foundation/Foundation.hpp>
#include <Metal/Metal.hpp>
#include <algorithm>
#include <cmath>

#include "GPUContext.hpp"
#include "Heightfield.hpp"
#include "kernels/Erosion.metal.hpp"

namespace theia {

namespace {
// Must match `struct ThermalParams` in kernels::kThermal exactly.
struct ThermalParamsGPU {
    std::uint32_t width;
    std::uint32_t height;
    float talusTan;
    float strength;
    float cellSize;
    float heightScale;
};
} // namespace

bool ThermalErosionNode::evaluate(GPUContext& ctx,
                                  const std::vector<const Heightfield*>& inputs,
                                  Heightfield& out, std::string& error) {
    if (inputs.size() != 1 || !inputs[0]) {
        error = "thermal '" + id() + "' requires 1 input";
        return false;
    }
    const Heightfield* in = inputs[0];
    const std::uint32_t W = out.width(), H = out.height();
    const std::size_t n = std::size_t(W) * H;
    const int iterations =
        std::max(1, static_cast<int>(params.get("iterations", 40)));

    ThermalParamsGPU P{};
    P.width = W;
    P.height = H;
    const double angleDeg = params.get("talusAngle", 33.0);
    P.talusTan = static_cast<float>(std::tan(angleDeg * 3.14159265358979 / 180.0));
    P.strength = static_cast<float>(params.get("strength", 0.5));
    // Ground spacing comes from the terrain's world width, never from the
    // sampling grid, so the authored talus angle means the same thing at every
    // resolution, and it is graph state so every operator agrees about the same
    // surface. See docs/research/terrain-horizontal-scale-notes.md.
    P.cellSize = static_cast<float>(world.terrainSize / std::max(1u, W - 1));
    P.heightScale = static_cast<float>(world.heightScale);

    struct Pass { const char* fn; MTL::ComputePipelineState* pso; };
    Pass passes[] = {
        {"thermal_init", nullptr},  {"thermal_flux", nullptr},
        {"thermal_apply", nullptr}, {"thermal_finish", nullptr},
    };
    for (auto& p : passes) {
        p.pso = ctx.pipeline(p.fn, kernels::kThermal, p.fn, error);
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
    MTL::Buffer* tflux = mk(n * sizeof(float) * 4);

    MTL::Buffer* owned[] = {terrainA, terrainB, tflux};
    for (auto* b : owned) {
        if (!b) {
            for (auto* q : owned) if (q) q->release();
            error = "thermal: buffer allocation failed";
            pool->release();
            return false;
        }
    }

    MTL::CommandBuffer* cb = ctx.queue()->commandBuffer();
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

    enc->setBuffer(in->buffer(), 0, 8);
    enc->setBuffer(terrainA, 0, 0);
    enc->setBytes(&P, sizeof(P), 7);
    disp(pso("thermal_init"));

    MTL::Buffer* tSrc = terrainA;
    MTL::Buffer* tDst = terrainB;
    for (int it = 0; it < iterations; ++it) {
        enc->setBuffer(tSrc, 0, 0);
        enc->setBuffer(tflux, 0, 3);
        enc->setBytes(&P, sizeof(P), 7);
        disp(pso("thermal_flux"));

        enc->setBuffer(tSrc, 0, 0);
        enc->setBuffer(tDst, 0, 1);
        enc->setBuffer(tflux, 0, 3);
        disp(pso("thermal_apply"));

        std::swap(tSrc, tDst);
    }

    enc->setBuffer(tSrc, 0, 0);
    enc->setBuffer(out.buffer(), 0, 9);
    enc->setBytes(&P, sizeof(P), 7);
    disp(pso("thermal_finish"));

    enc->endEncoding();
    cb->commit();
    cb->waitUntilCompleted();

    const bool ok = cb->status() == MTL::CommandBufferStatusCompleted;
    if (!ok) {
        error = "thermal: command buffer did not complete (status " +
                std::to_string(static_cast<int>(cb->status())) + ")";
    }
    for (auto* b : owned) b->release();
    pool->release();
    return ok;
}

} // namespace theia
