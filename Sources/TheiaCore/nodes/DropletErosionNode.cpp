#include "nodes/DropletErosionNode.hpp"

#include <algorithm>
#include <cstring>

#include "Heightfield.hpp"
#include "HydrologySimulator.hpp"

namespace theia {
namespace {

HydrologyParams hydrologyParams(const ParamSet& params) {
    HydrologyParams p;
    p.seed = static_cast<std::uint32_t>(std::max(0.0, params.get("seed", 1337)));
    p.particles =
        static_cast<std::uint32_t>(std::max(1.0, params.get("particles", 40000)));
    p.maxAge =
        static_cast<std::uint32_t>(std::max(1.0, params.get("maxAge", 300)));
    p.evaporation = static_cast<float>(params.get("evaporation", 0.01));
    p.deposition = static_cast<float>(params.get("deposition", 0.20));
    p.entrainment = static_cast<float>(params.get("entrainment", 1.0));
    p.gravity = static_cast<float>(params.get("gravity", 1.0));
    p.momentumTransfer =
        static_cast<float>(params.get("momentumTransfer", 1.0));
    p.settling = static_cast<float>(params.get("settling", 0.50));
    p.maxDiff = static_cast<float>(params.get("maxDiff", 0.10));
    p.heightScale = static_cast<float>(params.get("heightScale", 100.0));
    return p;
}

bool evaluateHydrology(const Node& node, const std::vector<const Heightfield*>& inputs,
                       HydrologyResult& result, std::string& error) {
    if (inputs.size() != 1 || !inputs[0]) {
        error = node.type() + " '" + node.id() + "' requires 1 input";
        return false;
    }
    const Heightfield* in = inputs[0];
    return runHydrologySimulation(in->data(), in->width(), in->height(),
                                  hydrologyParams(node.params), result, error);
}

} // namespace

void setHydrologyDefaults(ParamSet& params) {
    params.set("seed", 1337);
    params.set("particles", 40000);
    params.set("maxAge", 300);
    params.set("evaporation", 0.010);
    params.set("deposition", 0.20);
    params.set("entrainment", 1.0);
    params.set("gravity", 1.0);
    params.set("momentumTransfer", 1.0);
    params.set("settling", 0.50);
    params.set("maxDiff", 0.100);
    params.set("heightScale", 100.0);
}

DropletErosionNode::DropletErosionNode(std::string id)
    : Node(std::move(id), "dropleterosion") {
    setHydrologyDefaults(params);
}

bool DropletErosionNode::evaluate(GPUContext&,
                                  const std::vector<const Heightfield*>& inputs,
                                  Heightfield& out, std::string& error) {
    HydrologyResult result;
    if (!evaluateHydrology(*this, inputs, result, error)) return false;
    if (result.terrain.size() != out.count()) {
        error = "dropleterosion: result size mismatch";
        return false;
    }
    std::memcpy(out.data(), result.terrain.data(),
                result.terrain.size() * sizeof(float));
    return true;
}

} // namespace theia
