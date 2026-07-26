#pragma once
#include "Node.hpp"

namespace theia {

// Filter node (1 input): emit a [0,1] mask from terrain steepness.
class SlopeMaskNode : public Node {
public:
    explicit SlopeMaskNode(std::string id) : Node(std::move(id), "slopemask") {
        params.set("low", 15.0);          // degrees: mask starts ramping here
        params.set("high", 50.0);         // degrees: fully masked at/above
        params.set("heightScale", 100.0); // vertical exaggeration for the slope calc
        // World width of the whole terrain. Ground spacing is derived from this
        // and the grid, so slope is resolution-independent.
        params.set("terrainSize", 1024.0);
    }
    std::size_t inputCount() const override { return 1; }
    bool evaluate(GPUContext& ctx,
                  const std::vector<const Heightfield*>& inputs,
                  Heightfield& out, std::string& error) override;
};

} // namespace theia
