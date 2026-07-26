#include "Node.hpp"

#include "Hash.hpp"
#include "nodes/BlendNode.hpp"
#include "nodes/BlurNode.hpp"
#include "nodes/ClampNode.hpp"
#include "nodes/CombineNode.hpp"
#include "nodes/DropletErosionNode.hpp"
#include "nodes/ErosionFilterNode.hpp"
#include "nodes/FluvialNode.hpp"
#include "nodes/ExportNode.hpp"
#include "nodes/HydraulicErosionNode.hpp"
#include "nodes/InvertNode.hpp"
#include "nodes/NormalizeNode.hpp"
#include "nodes/PerlinNode.hpp"
#include "nodes/RemapNode.hpp"
#include "nodes/RiverNode.hpp"
#include "nodes/RiverCarveNode.hpp"
#include "nodes/RidgedNode.hpp"
#include "nodes/ScaleBiasNode.hpp"
#include "nodes/SlopeMaskNode.hpp"
#include "nodes/TerraceNode.hpp"
#include "nodes/ThermalErosionNode.hpp"
#include "nodes/WarpNode.hpp"

namespace theia {

namespace {

std::vector<FieldKind> anyFieldKinds() {
    return {FieldKind::terrain, FieldKind::mask, FieldKind::data};
}

} // namespace

const char* fieldKindName(FieldKind kind) {
    switch (kind) {
    case FieldKind::terrain: return "terrain";
    case FieldKind::mask: return "mask";
    case FieldKind::data: return "data";
    }
    return "data";
}

std::vector<InputPortDescriptor> Node::inputPorts() const {
    std::vector<InputPortDescriptor> ports;
    ports.reserve(inputCount());
    for (std::size_t i = 0; i < inputCount(); ++i) {
        ports.push_back({"field", anyFieldKinds()});
    }
    if (ports.empty()) return ports;

    if (type_ == "rivercarve") {
        ports[0] = {"terrain", {FieldKind::terrain}};
        ports[1] = {"mask", {FieldKind::mask, FieldKind::data}};
    } else if (type_ == "combine" || type_ == "blend") {
        ports[0].name = "base";
        ports[1].name = "source";
    } else if (type_ == "river" || type_ == "slopemask" ||
               type_ == "hydraulic" || type_ == "dropleterosion" ||
               type_ == "thermal" || type_ == "terrace" ||
               type_ == "warp" || type_ == "erosionfilter" ||
               type_ == "fluvial") {
        ports[0] = {"terrain", {FieldKind::terrain}};
    }
    return ports;
}

std::vector<OutputPortDescriptor> Node::outputPorts() const {
    if (type_ == "erosionfilter") {
        return {{"terrain", FieldKind::terrain, -1, true},
                {"ridge", FieldKind::data, -1, false}};
    }
    if (type_ == "fluvial") {
        return {{"terrain", FieldKind::terrain, -1, true},
                {"flow", FieldKind::data, -1, false}};
    }
    if (type_ == "river" || type_ == "slopemask") {
        return {{"mask", FieldKind::mask, -1, true}};
    }
    if (type_ == "scalebias" || type_ == "invert" || type_ == "clamp" ||
        type_ == "remap" || type_ == "blur" || type_ == "normalize" ||
        type_ == "combine" || type_ == "blend" || type_ == "export") {
        return {{"field", FieldKind::data, 0, true}};
    }
    return {{"terrain", FieldKind::terrain, -1, true}};
}

bool Node::evaluateOutputs(GPUContext& ctx,
                           const std::vector<const Heightfield*>& inputs,
                           const std::vector<Heightfield*>& outputs,
                           std::string& error) {
    if (outputs.empty() || !outputs[0]) {
        error = type_ + " '" + id_ + "' has no allocated default output";
        return false;
    }
    return evaluate(ctx, inputs, *outputs[0], error);
}

std::uint64_t Node::signature() const {
    std::uint64_t h = hashString(0, type_);
    // params is an ordered map => deterministic traversal.
    for (const auto& kv : params.values) {
        h = hashString(h, kv.first);
        h = hashDouble(h, kv.second);
    }
    return h;
}

std::unique_ptr<Node> createNode(const std::string& type, const std::string& id) {
    if (type == "perlin") return std::make_unique<PerlinNode>(id);
    if (type == "ridged") return std::make_unique<RidgedNode>(id);
    if (type == "scalebias") return std::make_unique<ScaleBiasNode>(id);
    if (type == "combine") return std::make_unique<CombineNode>(id);
    if (type == "blend") return std::make_unique<BlendNode>(id);
    if (type == "invert") return std::make_unique<InvertNode>(id);
    if (type == "clamp") return std::make_unique<ClampNode>(id);
    if (type == "remap") return std::make_unique<RemapNode>(id);
    if (type == "blur") return std::make_unique<BlurNode>(id);
    if (type == "warp") return std::make_unique<WarpNode>(id);
    if (type == "dropleterosion") return std::make_unique<DropletErosionNode>(id);
    if (type == "erosionfilter") return std::make_unique<ErosionFilterNode>(id);
    if (type == "fluvial") return std::make_unique<FluvialNode>(id);
    if (type == "river") return std::make_unique<RiverNode>(id);
    if (type == "rivercarve") return std::make_unique<RiverCarveNode>(id);
    if (type == "export") return std::make_unique<ExportNode>(id);
    if (type == "hydraulic") return std::make_unique<HydraulicErosionNode>(id);
    if (type == "thermal") return std::make_unique<ThermalErosionNode>(id);
    if (type == "terrace") return std::make_unique<TerraceNode>(id);
    if (type == "normalize") return std::make_unique<NormalizeNode>(id);
    if (type == "slopemask") return std::make_unique<SlopeMaskNode>(id);
    return nullptr;
}

std::vector<std::string> registeredNodeTypes() {
    return {"perlin",         "ridged",    "scalebias", "combine",
            "blend",          "invert",    "clamp",     "remap",
            "blur",           "warp",      "hydraulic", "dropleterosion",
            "erosionfilter",  "river",     "rivercarve", "export",
            "thermal",        "terrace",   "normalize", "slopemask",
            "fluvial"};
}

} // namespace theia
