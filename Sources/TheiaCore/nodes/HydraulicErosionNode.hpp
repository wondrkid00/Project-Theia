#pragma once
#include "Node.hpp"

namespace theia {

// Filter node (1 input): hydraulic erosion via the Mei et al. 2007 virtual-pipes
// shallow-water model. Carves drainage networks and deposits sediment.
class HydraulicErosionNode : public Node {
public:
    explicit HydraulicErosionNode(std::string id)
        : Node(std::move(id), "hydraulic") {
        params.set("iterations", 200);
        params.set("rain", 0.010);
        params.set("evaporation", 0.020);
        params.set("sedimentCapacity", 0.65);
        params.set("suspension", 0.60);
        params.set("deposition", 0.45);
        params.set("gravity", 9.81);
        params.set("dt", 0.015);
        params.set("minTilt", 0.005);
        params.set("pipeArea", 1.0);
        params.set("pipeLength", 1.0);
    }
    std::size_t inputCount() const override { return 1; }
    bool evaluate(GPUContext& ctx,
                  const std::vector<const Heightfield*>& inputs,
                  Heightfield& out, std::string& error) override;
};

} // namespace theia
