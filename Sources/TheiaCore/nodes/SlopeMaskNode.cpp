#include "nodes/SlopeMaskNode.hpp"

#include <Metal/Metal.hpp>

#include <cmath>

#include "GPUContext.hpp"
#include "Heightfield.hpp"
#include "kernels/Kernels.metal.hpp"

namespace theia {

bool SlopeMaskNode::evaluate(GPUContext& ctx,
                             const std::vector<const Heightfield*>& inputs,
                             Heightfield& out, std::string& error) {
    if (inputs.size() != 1 || !inputs[0]) {
        error = "slopemask '" + id() + "' requires 1 input";
        return false;
    }
    // Scale comes from the graph, so the mask agrees with the erosion nodes.
    const float pr[4] = {static_cast<float>(params.get("low", 15.0)),
                         static_cast<float>(params.get("high", 55.0)),
                         static_cast<float>(world.heightScale),
                         static_cast<float>(world.terrainSize)};
    const std::uint32_t dim[2] = {out.width(), out.height()};
    const Heightfield* in = inputs[0];

    return ctx.dispatch2D(
        "slopemask", kernels::kSlopeMask, "slopemask", out.width(), out.height(),
        [&](MTL::ComputeCommandEncoder* enc) {
            enc->setBuffer(out.buffer(), 0, 0);
            enc->setBuffer(in->buffer(), 0, 1);
            enc->setBytes(pr, sizeof(pr), 2);
            enc->setBytes(dim, sizeof(dim), 3);
        },
        error);
}

} // namespace theia
