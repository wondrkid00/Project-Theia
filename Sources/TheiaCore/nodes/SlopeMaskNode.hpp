#pragma once
#include "Node.hpp"

namespace theia {

// Filter node (1 input): emit a [0,1] mask from terrain steepness.
class SlopeMaskNode : public Node {
public:
    explicit SlopeMaskNode(std::string id) : Node(std::move(id), "slopemask") {
        params.set("low", 15.0);          // degrees: mask starts ramping here
        params.set("high", 50.0);         // degrees: fully masked at/above
    }
    std::size_t inputCount() const override { return 1; }
    bool evaluate(GPUContext& ctx,
                  const std::vector<const Heightfield*>& inputs,
                  Heightfield& out, std::string& error) override;
};

} // namespace theia
