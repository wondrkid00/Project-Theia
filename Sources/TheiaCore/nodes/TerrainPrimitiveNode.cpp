#include "nodes/TerrainPrimitiveNode.hpp"

#include <Metal/Metal.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <limits>

#include "GPUContext.hpp"
#include "Heightfield.hpp"
#include "kernels/TerrainPrimitives.metal.hpp"
#include "nodes/FluvialNode.hpp"
#include "nodes/RiverCarveNode.hpp"
#include "nodes/RiverNode.hpp"

namespace theia {
namespace {

using P = TerrainPrimitiveParamDescriptor;

constexpr P kRollingHills[] = {
    {"scale",0.65,0.05,1.5,false}, {"height",0.55,0,1,false},
    {"softness",0.70,0,1,false}, {"undulation",0.40,0,1,false},
    {"warp",0.15,0,1,false}, {"detail",0.55,0,1,false},
    {"seed",1337,0,9999,true},
};
constexpr P kCanyon[] = {
    {"scale",0.75,0.05,1.5,false}, {"height",0.78,0,1,false},
    {"depth",0.55,0,1,false}, {"width",0.10,0.02,0.6,false},
    {"branches",12,1,32,true}, {"wallSharpness",0.65,0,1,false},
    {"roughness",0.25,0,1,false}, {"benching",0.45,0,1,false},
    {"seed",1337,0,9999,true},
};
constexpr P kCrater[] = {
    {"scale",0.45,0.05,1.5,false}, {"height",0.80,0,1,false},
    {"depth",0.26,0,1,false}, {"rimHeight",0.14,0,1,false},
    {"rimWidth",0.18,0,1,false}, {"irregularity",0.45,0,1,false},
    {"ejecta",0.35,0,1,false}, {"x",0,-1,1,false},
    {"y",0,-1,1,false}, {"complexity",0.30,0,1,false},
    {"terraces",0.50,0,1,false}, {"surroundings",0.30,0,1,false},
    {"seed",1337,0,9999,true},
};
constexpr P kMountain[] = {
    {"scale",0.65,0.05,1.5,false}, {"height",0.90,0,1,false},
    {"bulk",0.58,0,1,false}, {"roughness",0.38,0,1,false},
    {"warp",0.20,0,1,false}, {"x",0,-1,1,false},
    {"y",0,-1,1,false}, {"surroundings",0.30,0,1,false},
    {"seed",1337,0,9999,true},
};
constexpr P kMountainRange[] = {
    {"scale",0.70,0.05,1.5,false}, {"height",0.90,0,1,false},
    {"length",1.25,0.25,2,false}, {"width",0.24,0.02,0.6,false},
    {"direction",25,0,360,false}, {"peaks",5,1,12,true},
    {"roughness",0.40,0,1,false}, {"warp",0.25,0,1,false},
    {"x",0,-1,1,false}, {"y",0,-1,1,false},
    {"surroundings",0.30,0,1,false}, {"peakVariation",0.65,0,1,false},
    {"arc",0.35,-1,1,false}, {"sinuosity",0.45,0,1,false},
    {"seed",1337,0,9999,true},
};
constexpr P kVolcano[] = {
    {"scale",0.96,0.05,1.5,false}, {"height",1.00,0,1,false},
    {"mouth",0.66,0,1,false}, {"calderaDepth",0.57,0,1,false},
    {"bulk",0.70,0,1,false}, {"radialErosion",0.45,0,1,false},
    {"roughness",0.25,0,1,false}, {"x",0,-1,1,false},
    {"y",0,-1,1,false}, {"surroundings",0.45,0,1,false},
    {"seed",1337,0,9999,true},
};

template <std::size_t N>
constexpr TerrainPrimitiveDescriptor descriptor(
    const char* type, TerrainPrimitiveFamily family, std::uint32_t kind,
    const P (&params)[N]) {
    return {type, family, kind, params, N};
}

constexpr TerrainPrimitiveDescriptor kDescriptors[] = {
    descriptor("rollinghills", TerrainPrimitiveFamily::massLine, 0, kRollingHills),
    descriptor("canyon", TerrainPrimitiveFamily::massLine, 1, kCanyon),
    descriptor("crater", TerrainPrimitiveFamily::radialImpact, 9, kCrater),
    descriptor("mountain", TerrainPrimitiveFamily::massLine, 2, kMountain),
    descriptor("mountainrange", TerrainPrimitiveFamily::massLine, 3, kMountainRange),
    descriptor("volcano", TerrainPrimitiveFamily::radialImpact, 10, kVolcano),
};

struct PrimitiveParamsGPU {
    std::uint32_t width;
    std::uint32_t height;
    std::uint32_t kind;
    std::uint32_t seed;
    float values[16];
};

bool readParams(const TerrainPrimitiveNode& node,
                const TerrainPrimitiveDescriptor& d,
                std::uint32_t width, std::uint32_t height,
                PrimitiveParamsGPU& gpu, std::string& error) {
    gpu = {};
    gpu.width = width;
    gpu.height = height;
    gpu.kind = d.kind;
    std::size_t valueIndex = 0;
    for (std::size_t i = 0; i < d.paramCount; ++i) {
        const P& p = d.params[i];
        double raw = node.params.get(p.name, p.defaultValue);
        if (!std::isfinite(raw)) {
            error = node.type() + " '" + node.id() + "': parameter '" +
                    p.name + "' must be finite";
            return false;
        }
        raw = std::clamp(raw, p.minimum, p.maximum);
        if (p.integer) raw = std::round(raw);
        if (std::strcmp(p.name, "seed") == 0) {
            gpu.seed = static_cast<std::uint32_t>(raw);
        } else {
            if (valueIndex >= std::size(gpu.values)) {
                error = node.type() + ": internal parameter packing overflow";
                return false;
            }
            gpu.values[valueIndex++] = static_cast<float>(raw);
        }
    }
    return true;
}

const char* familyEntry(TerrainPrimitiveFamily family) {
    switch (family) {
    case TerrainPrimitiveFamily::massLine: return "terrain_mass_line";
    case TerrainPrimitiveFamily::radialImpact: return "terrain_radial_impact";
    }
    return "terrain_mass_line";
}

bool dispatchPrimitive(GPUContext& ctx,
                       const TerrainPrimitiveDescriptor& d,
                       const PrimitiveParamsGPU& gpu,
                       Heightfield& out, std::string& error) {
    const char* entry = familyEntry(d.family);
    if (!ctx.dispatch2D(
        std::string("terrain-primitives:") + entry,
        kernels::kTerrainPrimitives, entry, out.width(), out.height(),
        [&](MTL::ComputeCommandEncoder* encoder) {
            encoder->setBuffer(out.buffer(), 0, 0);
            encoder->setBytes(&gpu, sizeof(gpu), 1);
        },
        error)) {
        return false;
    }
    for (std::size_t i = 0; i < out.count(); ++i) {
        const float value = out.data()[i];
        if (!std::isfinite(value)) {
            error = std::string(d.type) +
                    ": Metal kernel produced a non-finite height";
            return false;
        }
        if (value < 0.0f || value > 1.0f) {
            error = std::string(d.type) +
                    ": Metal kernel produced a height outside [0,1]";
            return false;
        }
    }
    return true;
}

bool evaluateCanyon(GPUContext& ctx, const TerrainPrimitiveNode& node,
                    const TerrainPrimitiveDescriptor& d,
                    const PrimitiveParamsGPU& gpu,
                    Heightfield& out, std::string& error) {
    if (out.width() < 3 || out.height() < 3) {
        error = "canyon '" + node.id() + "' requires at least a 3x3 grid";
        return false;
    }

    // RiverNode and RiverCarveNode expose widths in cells. Evaluate their
    // unchanged behavior at one fixed longest-axis resolution so those cell
    // controls represent the same fraction of the domain at every requested
    // output size. Derive the short side from sample intervals, not sample
    // counts, and clamp it to the routing minimum for extreme aspect ratios.
    constexpr std::uint32_t kInternalLongest = 256;
    std::uint32_t internalWidth = kInternalLongest;
    std::uint32_t internalHeight = kInternalLongest;
    if (out.width() >= out.height()) {
        const double ratio =
            double(out.height() - 1) / double(out.width() - 1);
        internalHeight = std::clamp(
            std::uint32_t(std::llround(ratio * double(kInternalLongest - 1))) + 1,
            3u, kInternalLongest);
    } else {
        const double ratio =
            double(out.width() - 1) / double(out.height() - 1);
        internalWidth = std::clamp(
            std::uint32_t(std::llround(ratio * double(kInternalLongest - 1))) + 1,
            3u, kInternalLongest);
    }
    if (std::size_t(internalWidth) * internalHeight >
        std::size_t(kInternalLongest) * kInternalLongest) {
        error = "canyon '" + node.id() + "': internal grid exceeds bound";
        return false;
    }

    Heightfield base(ctx, internalWidth, internalHeight);
    Heightfield mask(ctx, internalWidth, internalHeight);
    Heightfield carved(ctx, internalWidth, internalHeight);
    if (!base.valid() || !mask.valid() || !carved.valid()) {
        error = "canyon '" + node.id() + "': temporary allocation failed";
        return false;
    }
    PrimitiveParamsGPU internalGPU = gpu;
    internalGPU.width = internalWidth;
    internalGPU.height = internalHeight;
    if (!dispatchPrimitive(ctx, d, internalGPU, base, error)) {
        error = "canyon '" + node.id() + "' upland: " + error;
        return false;
    }

    const float width = gpu.values[3];
    const float branches = gpu.values[4];
    const float wallSharpness = gpu.values[5];

    RiverNode river(node.id() + ":river");
    river.params.set("seed", double(gpu.seed));
    river.params.set("water", std::clamp(double(branches / 32.0f), 0.0, 1.0));
    river.params.set("width",
                     std::clamp(0.5 + 12.5 * double(width), 0.5, 8.0));
    river.params.set("headwaters", double(branches));
    std::vector<const Heightfield*> riverInputs{&base};
    if (!river.evaluate(ctx, riverInputs, mask, error)) {
        error = "canyon '" + node.id() + "' routing: " + error;
        return false;
    }

    RiverCarveNode carve(node.id() + ":carve");
    carve.params.set("depth", gpu.values[2]);
    carve.params.set("downcutting", wallSharpness);
    carve.params.set(
        "riverValleyWidth",
        std::clamp(2.0 + (20.0 / 3.0) * double(width), 2.0, 6.0));
    carve.params.set("shorelineWidth",
                     std::clamp(1.0 + 5.0 * double(width), 1.0, 4.0));
    carve.params.set("shorelineSharpness", wallSharpness);
    std::vector<const Heightfield*> carveInputs{&base, &mask};
    if (!carve.evaluate(ctx, carveInputs, carved, error)) {
        error = "canyon '" + node.id() + "' carve: " + error;
        return false;
    }

    const float height = gpu.values[1];
    const float* sourceBase = base.data();
    const float* sourceCarved = carved.data();
    // The public Canyon is a landform generator, not a direct RiverCarve alias.
    // Its narrow calibrated network needs a deeper bounded relief transform to
    // remain legible after resampling; depth==0 remains an exact identity.
    constexpr float kPrimitiveCarveGain = 5.50f;
    for (std::uint32_t y = 0; y < out.height(); ++y) {
        const float sy = float(y) * float(internalHeight - 1) /
                         float(out.height() - 1);
        const std::uint32_t y0 = std::uint32_t(std::floor(sy));
        const std::uint32_t y1 = std::min(y0 + 1, internalHeight - 1);
        const float fy = sy - float(y0);
        for (std::uint32_t x = 0; x < out.width(); ++x) {
            const float sx = float(x) * float(internalWidth - 1) /
                             float(out.width() - 1);
            const std::uint32_t x0 = std::uint32_t(std::floor(sx));
            const std::uint32_t x1 = std::min(x0 + 1, internalWidth - 1);
            const float fx = sx - float(x0);
            auto bilinear = [&](const float* source) {
                const float a = source[std::size_t(y0) * internalWidth + x0];
                const float b = source[std::size_t(y0) * internalWidth + x1];
                const float c = source[std::size_t(y1) * internalWidth + x0];
                const float e = source[std::size_t(y1) * internalWidth + x1];
                return (a * (1.0f - fx) + b * fx) * (1.0f - fy) +
                       (c * (1.0f - fx) + e * fx) * fy;
            };
            const float baseSample = bilinear(sourceBase);
            const float carvedSample = bilinear(sourceCarved);
            const float enhancedCarve =
                std::max(0.0f, baseSample -
                                   kPrimitiveCarveGain *
                                       std::max(baseSample - carvedSample, 0.0f));
            const float value = height * enhancedCarve;
            if (!std::isfinite(value)) {
                error =
                    "canyon '" + node.id() + "': non-finite composed height";
                return false;
            }
            out.data()[std::size_t(y) * out.width() + x] =
                std::clamp(value, 0.0f, 1.0f);
        }
    }
    return true;
}

bool evaluateVolcano(GPUContext& ctx, const TerrainPrimitiveNode& node,
                     const TerrainPrimitiveDescriptor& d,
                     const PrimitiveParamsGPU& gpu,
                     Heightfield& out, std::string& error) {
    const float erosionAmount = gpu.values[5];
    if (erosionAmount <= 0.0f) {
        return dispatchPrimitive(ctx, d, gpu, out, error);
    }

    Heightfield base(ctx, out.width(), out.height());
    if (!base.valid()) {
        error = "volcano '" + node.id() +
                "': temporary terrain allocation failed";
        return false;
    }
    if (!dispatchPrimitive(ctx, d, gpu, base, error)) {
        error = "volcano '" + node.id() + "' base: " + error;
        return false;
    }

    // Reuse the exact default drainage-area-driven landscape evolution
    // implementation exposed by the Fluvial node. The public 0...1 control is
    // the blend amount against that result; zero remains an exact analytic
    // Volcano bypass and one matches a standalone default Fluvial pass.
    FluvialNode fluvial(node.id() + ":fluvial");
    std::vector<const Heightfield*> fluvialInputs{&base};
    if (!fluvial.evaluate(ctx, fluvialInputs, out, error)) {
        error = "volcano '" + node.id() + "' fluvial erosion: " + error;
        return false;
    }

    for (std::size_t i = 0; i < out.count(); ++i) {
        const float eroded = out.data()[i];
        if (!std::isfinite(eroded)) {
            error = "volcano '" + node.id() +
                    "': fluvial erosion produced non-finite terrain";
            return false;
        }
        const float boundedErosion = std::clamp(eroded, 0.0f, 1.0f);
        out.data()[i] = std::clamp(
            base.data()[i] * (1.0f - erosionAmount) +
                boundedErosion * erosionAmount,
            0.0f, 1.0f);
    }
    return true;
}

} // namespace

const TerrainPrimitiveDescriptor* terrainPrimitiveDescriptor(
    const std::string& type) {
    for (const auto& d : kDescriptors) {
        if (type == d.type) return &d;
    }
    return nullptr;
}

std::vector<std::string> terrainPrimitiveTypes() {
    std::vector<std::string> types;
    types.reserve(std::size(kDescriptors));
    for (const auto& d : kDescriptors) types.emplace_back(d.type);
    return types;
}

std::unique_ptr<Node> createTerrainPrimitiveNode(const std::string& type,
                                                 const std::string& id) {
    const auto* d = terrainPrimitiveDescriptor(type);
    if (!d) return nullptr;
    return std::make_unique<TerrainPrimitiveNode>(id, *d);
}

TerrainPrimitiveNode::TerrainPrimitiveNode(
    std::string id, const TerrainPrimitiveDescriptor& descriptor)
    : Node(std::move(id), descriptor.type), descriptor_(&descriptor) {
    for (std::size_t i = 0; i < descriptor.paramCount; ++i) {
        params.set(descriptor.params[i].name, descriptor.params[i].defaultValue);
    }
}

bool TerrainPrimitiveNode::evaluate(
    GPUContext& ctx, const std::vector<const Heightfield*>& inputs,
    Heightfield& out, std::string& error) {
    if (!inputs.empty()) {
        error = type() + " '" + id() + "' requires no inputs";
        return false;
    }
    PrimitiveParamsGPU gpu{};
    if (!readParams(*this, *descriptor_, out.width(), out.height(), gpu, error)) {
        return false;
    }
    if (descriptor_->kind == 1) {
        return evaluateCanyon(ctx, *this, *descriptor_, gpu, out, error);
    }
    if (descriptor_->kind == 10) {
        return evaluateVolcano(ctx, *this, *descriptor_, gpu, out, error);
    }
    return dispatchPrimitive(ctx, *descriptor_, gpu, out, error);
}

} // namespace theia
