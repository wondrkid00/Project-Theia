#pragma once

#include "Node.hpp"

namespace theia {

// Fluvial landscape evolution: stream power incision driven by upstream
// drainage area, with linear sediment deposition. This is the node that
// produces branching valley networks and depositional fans; the older
// `hydraulic` node routes water over a few hundred storm steps and has no
// concept of drainage area, so it cannot organize a surface at basin scale.
//
// See docs/research/fluvial-landscape-evolution-notes.md.
class FluvialNode : public Node {
public:
    explicit FluvialNode(std::string id) : Node(std::move(id), "fluvial") {
        params.set("iterations", 60);      // landscape evolution steps
        params.set("dt", 0.6);             // step size in abstract time units
        params.set("erodibility", 0.5);    // K
        params.set("areaExponent", 0.5);   // m; 0.5 with n=1 is specific stream power
        params.set("slopeExponent", 1.0);  // n
        params.set("deposition", 1.0);     // G; 0 is purely detachment-limited
        // U. Zero by default: uniform uplift drives the surface toward the
        // model's own steady state, which erases the authored input. Raise it
        // when you want an equilibrium landscape rather than an eroded one.
        params.set("uplift", 0.0);
        // Hillslope diffusion (Culling 1960). Sets valley spacing: without it
        // fluvial incision cuts a channel at every cell and the surface fills
        // with grid-scale grooves instead of smooth hillslopes.
        params.set("diffusion", 0.02);
        params.set("rain", 1.0);
        // Above Freeman's 1.1 default: the lower value disperses flow so widely that
        // channels never sharpen. Higher values steer discharge toward the steepest
        // neighbours, which is the documented remedy for MFD over-dispersion.
        params.set("mfdExponent", 3.0);
        params.set("terrainSize", 1024.0);
        params.set("heightScale", 100.0);
        // Lower bound on the slope used for incision. Without it a filled
        // depression is flat, never incises, and becomes a permanent sink that
        // diffusion enlarges. Mirrors `minTilt` in the hydraulic node.
        params.set("minSlope", 0.004);
        // Sc in the nonlinear transport law. Transport diverges as the gradient
        // approaches it, so steep groove walls smooth far faster than gentle
        // ground -- letting `diffusion` stay low enough to keep broad relief.
        params.set("criticalSlope", 0.6);
        params.set("accuracy", 1.0);       // scales the flow-solver iteration budget
    }

    std::size_t inputCount() const override { return 1; }
    bool evaluate(GPUContext& ctx,
                  const std::vector<const Heightfield*>& inputs,
                  Heightfield& out, std::string& error) override;
    bool evaluateOutputs(GPUContext& ctx,
                         const std::vector<const Heightfield*>& inputs,
                         const std::vector<Heightfield*>& outputs,
                         std::string& error) override;

private:
    bool simulate(GPUContext& ctx,
                  const std::vector<const Heightfield*>& inputs,
                  Heightfield& height, Heightfield* flow,
                  std::string& error);
};

} // namespace theia
