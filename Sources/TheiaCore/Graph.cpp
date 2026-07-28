#include "Graph.hpp"

#include <algorithm>
#include <cmath>
#include <functional>
#include <limits>

#include "Hash.hpp"
#include "Heightfield.hpp"
#include "Node.hpp"
#include "json.hpp"

using json = nlohmann::json;

namespace theia {

namespace {

bool nearlyEqual(double a, double b) {
    return std::abs(a - b) < 1e-9;
}

// Phase 9: horizontal spacing became a terrain-wide world width instead of a
// per-texel `cellSize`, so slope-derived operators stop drifting with the
// sampling grid. A legacy cell is converted at the document's own declared
// resolution, which reproduces exactly what that document used to render and
// makes every other resolution agree with it instead of drifting away.
// See docs/research/terrain-horizontal-scale-notes.md.
void migrateLegacyCellSize(Node& n, std::uint32_t documentWidth) {
    const std::string& type = n.type();
    if (type != "slopemask" && type != "thermal" && type != "hydraulic") return;
    auto legacy = n.params.values.find("cellSize");
    if (legacy == n.params.values.end()) return;
    const double cellSize = legacy->second;
    n.params.values.erase(legacy);
    // An unusable authored cell falls back to the node default rather than
    // propagating a degenerate world width into the solver.
    if (!std::isfinite(cellSize) || cellSize <= 0.0) return;
    const double intervals = std::max(1u, documentWidth - 1);
    n.params.set("terrainSize", cellSize * intervals);
}

// `river.width` moved from cells to world units in formatVersion 3. Unlike the
// `cellSize` migration there is no removed key to detect, because `width`
// exists in both schemas — the document's formatVersion is the signal.
void migrateLegacyRiverWidth(Node& n, std::uint32_t documentWidth,
                             std::uint32_t formatVersion) {
    if (formatVersion >= 3) return;
    if (n.type() != "river") return;
    const double terrainSize = n.params.get("terrainSize", 1024.0);
    auto legacy = n.params.values.find("width");
    if (legacy == n.params.values.end()) return;
    const double widthCells = legacy->second;
    // An unusable authored width falls back to the node default rather than
    // propagating a degenerate channel into the mask.
    if (!std::isfinite(widthCells) || widthCells <= 0.0) return;
    const double intervals = std::max(1u, documentWidth - 1);
    n.params.set("width", widthCells * terrainSize / intervals);
}

void migrateLegacySlopeMaskDefaults(Node& n) {
    if (n.type() != "slopemask") return;
    const double low = n.params.get("low", 15.0);
    const double high = n.params.get("high", 50.0);
    const double heightScale = n.params.get("heightScale", 100.0);
    if ((low >= -1.0 && low <= 1.0 && high >= -1.0 && high <= 1.0) ||
        high <= low ||
        nearlyEqual(heightScale, 64.0)) {
        n.params.set("low", 15.0);
        n.params.set("high", 50.0);
        n.params.set("heightScale", 100.0);
    }
}

} // namespace

Graph::Graph() = default;
Graph::~Graph() = default;

Node* Graph::addNode(const std::string& id, const std::string& type,
                     std::string& error) {
    if (id.empty()) {
        error = "node id must not be empty";
        return nullptr;
    }
    if (nodes_.count(id)) {
        error = "duplicate node id: " + id;
        return nullptr;
    }
    auto n = createNode(type, id);
    if (!n) {
        error = "unknown node type: " + type;
        return nullptr;
    }
    Node* raw = n.get();
    nodes_[id] = std::move(n);
    inputs_[id].assign(raw->inputCount(), SourceRef{});
    return raw;
}

Node* Graph::node(const std::string& id) {
    auto it = nodes_.find(id);
    return it == nodes_.end() ? nullptr : it->second.get();
}

std::size_t Graph::nodeCount() const {
    return nodes_.size();
}

const Node* Graph::nodeAt(std::size_t index) const {
    if (index >= nodes_.size()) return nullptr;
    auto it = nodes_.begin();
    std::advance(it, index);
    return it->second.get();
}

std::size_t Graph::paramCount(const std::string& id) const {
    auto it = nodes_.find(id);
    return it == nodes_.end() ? 0 : it->second->params.values.size();
}

bool Graph::paramAt(const std::string& id, std::size_t index,
                    std::string& key, double& value) const {
    auto nit = nodes_.find(id);
    if (nit == nodes_.end() || index >= nit->second->params.values.size()) {
        return false;
    }
    auto pit = nit->second->params.values.begin();
    std::advance(pit, index);
    key = pit->first;
    value = pit->second;
    return true;
}

double Graph::paramValue(const std::string& id, const std::string& key,
                         double fallback) const {
    auto it = nodes_.find(id);
    return it == nodes_.end() ? fallback : it->second->params.get(key, fallback);
}

std::size_t Graph::outputCount(const std::string& id) const {
    auto it = nodes_.find(id);
    return it == nodes_.end() ? 0 : it->second->outputPorts().size();
}

bool Graph::outputAt(const std::string& id, std::size_t index,
                     OutputPortDescriptor& descriptor) const {
    auto it = nodes_.find(id);
    if (it == nodes_.end()) return false;
    const auto ports = it->second->outputPorts();
    if (index >= ports.size()) return false;
    descriptor = ports[index];
    return true;
}

std::string Graph::defaultOutputName(const Node& node) const {
    const auto ports = node.outputPorts();
    for (const auto& port : ports) {
        if (port.isDefault) return port.name;
    }
    return ports.empty() ? std::string{} : ports.front().name;
}

bool Graph::outputIndex(const Node& node, const std::string& outputName,
                        std::size_t& index, std::string& error) const {
    const auto ports = node.outputPorts();
    std::string selected = outputName.empty()
        ? defaultOutputName(node) : outputName;
    // Graph v2 originally called terrain outputs `height`. Keep accepting
    // that serialized/API spelling, while all new metadata and saves use the
    // same `terrain` name as terrain inputs.
    if (selected == "height" &&
        std::none_of(ports.begin(), ports.end(),
                     [](const OutputPortDescriptor& port) {
                         return port.name == "height";
                     }) &&
        std::any_of(ports.begin(), ports.end(),
                    [](const OutputPortDescriptor& port) {
                        return port.name == "terrain" &&
                               port.kind == FieldKind::terrain;
                    })) {
        selected = "terrain";
    }
    for (std::size_t i = 0; i < ports.size(); ++i) {
        if (ports[i].name == selected) {
            index = i;
            return true;
        }
    }
    error = "node '" + node.id() + "' has no output '" + selected + "'";
    return false;
}

bool Graph::setParam(const std::string& id, const std::string& key, double value,
                     std::string& error) {
    Node* n = node(id);
    if (!n) {
        error = "no such node: " + id;
        return false;
    }
    n->params.set(key, value);
    return true;
}

bool Graph::connect(const std::string& fromId, const std::string& toId,
                    std::uint32_t inputIndex, std::string& error) {
    Node* from = node(fromId);
    if (!from) {
        error = "connect: no such source node: " + fromId;
        return false;
    }
    return connect(fromId, defaultOutputName(*from), toId, inputIndex, error);
}

bool Graph::connect(const std::string& fromId, const std::string& outputName,
                    const std::string& toId, std::uint32_t inputIndex,
                    std::string& error) {
    Node* from = node(fromId);
    Node* to = node(toId);
    if (!from) { error = "connect: no such source node: " + fromId; return false; }
    if (!to) { error = "connect: no such target node: " + toId; return false; }
    if (inputIndex >= to->inputCount()) {
        error = "connect: node '" + toId + "' has no input port " +
                std::to_string(inputIndex);
        return false;
    }
    std::size_t selectedOutputIndex = 0;
    if (!outputIndex(*from, outputName, selectedOutputIndex, error)) {
        error = "connect: " + error;
        return false;
    }
    const auto sourceOutputs = from->outputPorts();
    const std::string selectedOutput = sourceOutputs[selectedOutputIndex].name;
    auto& srcs = inputs_[toId];
    if (srcs.size() < to->inputCount()) srcs.resize(to->inputCount());
    srcs[inputIndex] = SourceRef{fromId, selectedOutput};
    return true;
}

bool Graph::topoOrder(const std::string& sinkId, std::vector<std::string>& order,
                      std::string& error) const {
    if (!nodes_.count(sinkId)) {
        error = "sink node not found: " + sinkId;
        return false;
    }
    // 0=unvisited, 1=on-stack (gray), 2=done (black).
    std::map<std::string, int> color;
    bool ok = true;

    std::function<void(const std::string&)> dfs = [&](const std::string& id) {
        if (!ok) return;
        color[id] = 1;
        auto it = inputs_.find(id);
        if (it != inputs_.end()) {
            for (const SourceRef& src : it->second) {
                if (src.node.empty()) continue;  // unconnected port: eval will report
                if (!nodes_.count(src.node)) {
                    error = "node '" + id + "' references missing input '" + src.node + "'";
                    ok = false;
                    return;
                }
                const int c = color[src.node];
                if (c == 1) {
                    error = "cycle detected at node '" + src.node + "'";
                    ok = false;
                    return;
                }
                if (c == 0) dfs(src.node);
            }
        }
        color[id] = 2;
        order.push_back(id);
    };

    dfs(sinkId);
    return ok;
}

bool Graph::validateSink(const std::string& sinkId, std::string& error) const {
    std::vector<std::string> order;
    if (!topoOrder(sinkId, order, error)) return false;
    for (const std::string& id : order) {
        const Node* n = nodes_.at(id).get();
        auto it = inputs_.find(id);
        static const std::vector<SourceRef> emptyInputs;
        const auto& srcs = it == inputs_.end() ? emptyInputs : it->second;
        const auto inputPorts = n->inputPorts();
        std::vector<FieldKind> connectedKinds;
        for (std::size_t p = 0; p < n->inputCount(); ++p) {
            const SourceRef src = (p < srcs.size()) ? srcs[p] : SourceRef{};
            if (src.node.empty()) {
                error = "node '" + id + "' input port " + std::to_string(p) +
                        " is not connected";
                return false;
            }
            FieldKind kind = FieldKind::data;
            if (!resolvedOutputKind(src.node, src.output, kind, error)) return false;
            connectedKinds.push_back(kind);
            if (p < inputPorts.size() &&
                std::find(inputPorts[p].acceptedKinds.begin(),
                          inputPorts[p].acceptedKinds.end(), kind) ==
                    inputPorts[p].acceptedKinds.end()) {
                error = "node '" + id + "' input '" + inputPorts[p].name +
                        "' does not accept " + fieldKindName(kind) +
                        " output '" + src.node + "." + src.output + "'";
                return false;
            }
        }
        if ((n->type() == "combine" || n->type() == "blend") &&
            connectedKinds.size() == 2 && connectedKinds[0] != connectedKinds[1]) {
            error = "node '" + id + "' requires matching field kinds on both inputs";
            return false;
        }
    }
    return true;
}

bool Graph::resolvedOutputKind(const std::string& id,
                               const std::string& outputName,
                               FieldKind& kind, std::string& error) const {
    std::map<std::string, int> visiting;
    return resolvedOutputKind(id, outputName, kind, visiting, error);
}

bool Graph::resolvedOutputKind(const std::string& id,
                               const std::string& outputName,
                               FieldKind& kind,
                               std::map<std::string, int>& visiting,
                               std::string& error) const {
    auto nit = nodes_.find(id);
    if (nit == nodes_.end()) {
        error = "no such node: " + id;
        return false;
    }
    const Node& nodeRef = *nit->second;
    std::size_t outIndex = 0;
    if (!outputIndex(nodeRef, outputName, outIndex, error)) return false;
    const auto ports = nodeRef.outputPorts();
    const auto& descriptor = ports[outIndex];
    if (descriptor.inheritInput < 0) {
        kind = descriptor.kind;
        return true;
    }

    const std::string visitKey = id + ":" + descriptor.name;
    if (visiting[visitKey] == 1) {
        error = "cycle while resolving output kind at '" + visitKey + "'";
        return false;
    }
    visiting[visitKey] = 1;
    auto iit = inputs_.find(id);
    if (iit == inputs_.end() ||
        std::size_t(descriptor.inheritInput) >= iit->second.size() ||
        iit->second[descriptor.inheritInput].node.empty()) {
        // Unconnected authoring graphs still need stable catalog/UI metadata.
        kind = descriptor.kind;
        visiting[visitKey] = 2;
        return true;
    }
    const SourceRef& source = iit->second[descriptor.inheritInput];
    const bool ok = resolvedOutputKind(source.node, source.output, kind,
                                       visiting, error);
    visiting[visitKey] = 2;
    return ok;
}

std::uint64_t Graph::maskEditSignature(const std::string& id,
                                       const std::string& output) const {
    auto nodeIt = maskErases_.find(id);
    if (nodeIt == maskErases_.end()) return 0;
    auto it = nodeIt->second.find(output);
    if (it == nodeIt->second.end()) return 0;
    std::uint64_t hash = hashString(0, "maskErases");
    for (const MaskEraseStroke& stroke : it->second) {
        hash = hashDouble(hash, stroke.x);
        hash = hashDouble(hash, stroke.y);
        hash = hashDouble(hash, stroke.radius);
        hash = hashDouble(hash, stroke.strength);
    }
    return hash;
}

void Graph::applyMaskEdits(const std::string& id,
                           const std::string& outputName,
                           Heightfield& output) const {
    auto nodeIt = maskErases_.find(id);
    if (nodeIt == maskErases_.end()) return;
    auto it = nodeIt->second.find(outputName);
    if (it == nodeIt->second.end() || it->second.empty()) return;

    const std::uint32_t width = output.width();
    const std::uint32_t height = output.height();
    if (width == 0 || height == 0) return;
    const double xDenom = double(std::max<std::uint32_t>(1, width - 1));
    const double yDenom = double(std::max<std::uint32_t>(1, height - 1));

    for (const MaskEraseStroke& stroke : it->second) {
        const double radius = std::clamp(stroke.radius, 0.0001, 1.0);
        const double radius2 = radius * radius;
        const double centerX = std::clamp(stroke.x, 0.0, 1.0);
        const double centerY = std::clamp(stroke.y, 0.0, 1.0);
        const double strength = std::clamp(stroke.strength, 0.0, 1.0);
        const int minX = std::max(0, int(std::floor((centerX - radius) * xDenom)));
        const int maxX = std::min(int(width) - 1,
                                  int(std::ceil((centerX + radius) * xDenom)));
        const int minY = std::max(0, int(std::floor((centerY - radius) * yDenom)));
        const int maxY = std::min(int(height) - 1,
                                  int(std::ceil((centerY + radius) * yDenom)));
        for (int y = minY; y <= maxY; ++y) {
            const double v = double(y) / yDenom;
            for (int x = minX; x <= maxX; ++x) {
                const double u = double(x) / xDenom;
                const double dx = u - centerX;
                const double dy = v - centerY;
                const double distance2 = dx * dx + dy * dy;
                if (distance2 > radius2) continue;
                const double t = 1.0 - std::clamp(std::sqrt(distance2) / radius, 0.0, 1.0);
                const double falloff = t * t * (3.0 - 2.0 * t);
                const float erase = float(std::clamp(strength * falloff, 0.0, 1.0));
                const std::size_t index = std::size_t(y) * width + std::size_t(x);
                output.data()[index] = std::max(0.0f, output.data()[index] * (1.0f - erase));
            }
        }
    }
}

const Heightfield* Graph::evaluate(GPUContext& ctx, const std::string& sinkId,
                                   std::uint32_t w, std::uint32_t h,
                                   EvalStats& stats, std::string& error) {
    return evaluate(ctx, sinkId, {}, w, h, stats, error);
}

const Heightfield* Graph::evaluate(GPUContext& ctx, const std::string& sinkId,
                                   const std::string& outputName,
                                   std::uint32_t w, std::uint32_t h,
                                   EvalStats& stats, std::string& error) {
    stats = {};
    if (w == 0 || h == 0) {
        error = "evaluate: resolution must be > 0";
        return nullptr;
    }
    std::vector<std::string> order;
    if (!topoOrder(sinkId, order, error)) return nullptr;
    if (!validateSink(sinkId, error)) return nullptr;

    auto sinkNodeIt = nodes_.find(sinkId);
    std::size_t sinkOutputIndex = 0;
    if (sinkNodeIt == nodes_.end() ||
        !outputIndex(*sinkNodeIt->second, outputName, sinkOutputIndex, error)) {
        return nullptr;
    }

    for (const std::string& id : order) {
        Node* n = nodes_[id].get();
        const auto& srcs = inputs_[id];
        const auto outputDescriptors = n->outputPorts();
        if (outputDescriptors.empty()) {
            error = "node '" + id + "' declares no outputs";
            return nullptr;
        }

        // Content-hash cache key = node signature + resolution + input keys.
        std::uint64_t key = n->signature();
        key = hashMix(key, w);
        key = hashMix(key, h);
        for (const auto& descriptor : outputDescriptors) {
            key = hashMix(key, maskEditSignature(id, descriptor.name));
        }

        std::vector<const Heightfield*> ins;
        std::vector<FieldKind> inputKinds;
        ins.reserve(n->inputCount());
        inputKinds.reserve(n->inputCount());
        for (std::size_t p = 0; p < n->inputCount(); ++p) {
            const SourceRef src = (p < srcs.size()) ? srcs[p] : SourceRef{};
            if (src.node.empty()) {
                error = "node '" + id + "' input port " + std::to_string(p) +
                        " is not connected";
                return nullptr;
            }
            auto sourceNodeIt = nodes_.find(src.node);
            auto cit = cache_.find(src.node);
            std::size_t sourceOutputIndex = 0;
            if (sourceNodeIt == nodes_.end() ||
                !outputIndex(*sourceNodeIt->second, src.output,
                             sourceOutputIndex, error)) {
                return nullptr;
            }
            if (cit == cache_.end() ||
                sourceOutputIndex >= cit->second.outputs.size() ||
                !cit->second.outputs[sourceOutputIndex]) {
                error = "internal: input '" + src.node + "." + src.output +
                        "' not evaluated before '" + id + "'";
                return nullptr;
            }
            key = hashMix(key, cit->second.outputKeys[sourceOutputIndex]);
            ins.push_back(cit->second.outputs[sourceOutputIndex].get());
            inputKinds.push_back(cit->second.outputKinds[sourceOutputIndex]);
        }

        std::vector<FieldKind> outputKinds;
        outputKinds.reserve(outputDescriptors.size());
        for (const auto& descriptor : outputDescriptors) {
            if (descriptor.inheritInput >= 0 &&
                std::size_t(descriptor.inheritInput) < inputKinds.size()) {
                outputKinds.push_back(inputKinds[descriptor.inheritInput]);
            } else {
                outputKinds.push_back(descriptor.kind);
            }
        }

        // Reuse only when every atomic output is present and correctly sized.
        auto existing = cache_.find(id);
        bool reusable = existing != cache_.end() && existing->second.key == key &&
                        existing->second.outputs.size() == outputDescriptors.size();
        if (reusable) {
            for (const auto& output : existing->second.outputs) {
                if (!output || output->width() != w || output->height() != h) {
                    reusable = false;
                    break;
                }
            }
        }
        if (reusable) {
            stats.reused++;
            continue;
        }

        CacheEntry nextEntry;
        nextEntry.key = key;
        nextEntry.outputKinds = outputKinds;
        nextEntry.outputs.reserve(outputDescriptors.size());
        std::vector<Heightfield*> outputPointers;
        outputPointers.reserve(outputDescriptors.size());
        for (const auto& descriptor : outputDescriptors) {
            auto output = std::make_unique<Heightfield>(ctx, w, h);
            if (!output->valid()) {
                error = "failed to allocate output '" + descriptor.name +
                        "' for node '" + id + "'";
                return nullptr;
            }
            outputPointers.push_back(output.get());
            nextEntry.outputs.push_back(std::move(output));
        }
        if (!n->evaluateOutputs(ctx, ins, outputPointers, error)) return nullptr;

        nextEntry.outputKeys.reserve(outputDescriptors.size());
        for (std::size_t i = 0; i < outputDescriptors.size(); ++i) {
            if (outputKinds[i] == FieldKind::mask) {
                applyMaskEdits(id, outputDescriptors[i].name,
                               *nextEntry.outputs[i]);
            }
            std::uint64_t outputKey = hashString(key, outputDescriptors[i].name);
            outputKey = hashMix(outputKey,
                                static_cast<std::uint32_t>(outputKinds[i]));
            nextEntry.outputKeys.push_back(outputKey);
        }

        cache_[id] = std::move(nextEntry);
        stats.evaluated++;
    }

    auto cacheIt = cache_.find(sinkId);
    if (cacheIt == cache_.end() ||
        sinkOutputIndex >= cacheIt->second.outputs.size()) {
        error = "internal: sink output was not cached";
        return nullptr;
    }
    return cacheIt->second.outputs[sinkOutputIndex].get();
}

void Graph::setDefaults(const std::string& sink, std::uint32_t w, std::uint32_t h,
                        const std::string& sinkOutput) {
    defaultSink_ = sink;
    defaultSinkOutput_ = sinkOutput;
    auto sinkIt = nodes_.find(sink);
    if (sinkIt != nodes_.end() && !sinkOutput.empty()) {
        std::size_t outputIndexValue = 0;
        std::string ignoredError;
        if (outputIndex(*sinkIt->second, sinkOutput,
                        outputIndexValue, ignoredError)) {
            defaultSinkOutput_ =
                sinkIt->second->outputPorts()[outputIndexValue].name;
        }
    }
    if (w > 0) defaultWidth_ = w;
    if (h > 0) defaultHeight_ = h;
}

std::string Graph::toJSON() const {
    json j;
    j["formatVersion"] = 3;
    j["resolution"] = {{"width", defaultWidth_}, {"height", defaultHeight_}};
    if (!defaultSink_.empty()) {
        j["sink"] = defaultSink_;
        auto sinkIt = nodes_.find(defaultSink_);
        if (sinkIt != nodes_.end()) {
            j["sinkOutput"] = defaultSinkOutput_.empty()
                ? defaultOutputName(*sinkIt->second) : defaultSinkOutput_;
        }
    }

    j["nodes"] = json::array();
    for (const auto& kv : nodes_) {
        const Node* n = kv.second.get();
        json params = json::object();
        for (const auto& pv : n->params.values) params[pv.first] = pv.second;
        j["nodes"].push_back({{"id", n->id()}, {"type", n->type()}, {"params", params}});
    }

    j["connections"] = json::array();
    for (const auto& kv : inputs_) {
        const std::string& toId = kv.first;
        const auto& srcs = kv.second;
        for (std::size_t p = 0; p < srcs.size(); ++p) {
            if (srcs[p].node.empty()) continue;
            j["connections"].push_back(
                {{"from", srcs[p].node}, {"output", srcs[p].output},
                 {"to", toId}, {"input", p}});
        }
    }

    json ui = json::parse(uiMetadataJSON_, nullptr, /*allow_exceptions=*/false);
    if (ui.is_discarded() || !ui.is_object()) ui = json::object();
    json eraseNodes = json::object();
    for (const auto& [nodeId, outputs] : maskErases_) {
        json eraseOutputs = json::object();
        for (const auto& [outputName, strokes] : outputs) {
            json encodedStrokes = json::array();
            for (const auto& stroke : strokes) {
                encodedStrokes.push_back({
                    {"x", stroke.x}, {"y", stroke.y},
                    {"radius", stroke.radius}, {"strength", stroke.strength}});
            }
            if (!encodedStrokes.empty()) eraseOutputs[outputName] = std::move(encodedStrokes);
        }
        if (!eraseOutputs.empty()) eraseNodes[nodeId] = std::move(eraseOutputs);
    }
    if (!eraseNodes.empty()) {
        ui["maskErases"] = std::move(eraseNodes);
    } else {
        ui.erase("maskErases");
    }
    if (!ui.empty()) j["ui"] = std::move(ui);
    return j.dump(2);
}

bool Graph::fromJSON(const std::string& text, std::string& error) {
    json j = json::parse(text, nullptr, /*allow_exceptions=*/false);
    if (j.is_discarded()) {
        error = "invalid JSON";
        return false;
    }
    if (!j.is_object()) {
        error = "graph JSON must be an object";
        return false;
    }
    auto readString = [&](const json& obj, const char* key, std::string& out,
                          const std::string& context) -> bool {
        if (!obj.contains(key) || !obj[key].is_string()) {
            error = context + " '" + key + "' must be a string";
            return false;
        }
        out = obj[key].get<std::string>();
        return true;
    };
    auto readOptionalU32 = [&](const json& obj, const char* key,
                               std::uint32_t& out,
                               const std::string& context) -> bool {
        if (!obj.contains(key)) return true;
        const auto& value = obj[key];
        if (!value.is_number_integer()) {
            error = context + " '" + key + "' must be a non-negative integer";
            return false;
        }
        std::uint64_t wide = 0;
        if (value.is_number_unsigned()) {
            wide = value.get<std::uint64_t>();
        } else {
            const auto signedValue = value.get<std::int64_t>();
            if (signedValue < 0) {
                error = context + " '" + key + "' must be a non-negative integer";
                return false;
            }
            wide = static_cast<std::uint64_t>(signedValue);
        }
        if (wide > std::numeric_limits<std::uint32_t>::max()) {
            error = context + " '" + key + "' is too large";
            return false;
        }
        out = static_cast<std::uint32_t>(wide);
        return true;
    };

    Graph next;
    next.defaultWidth_ = defaultWidth_;
    next.defaultHeight_ = defaultHeight_;

    std::uint32_t formatVersion = 1;
    if (j.contains("formatVersion")) {
        if (!readOptionalU32(j, "formatVersion", formatVersion, "graph")) return false;
        // Version 3 documents may have been written by an older Theia build.
        // Its unsupported extension fields are intentionally ignored, and the
        // document is normalized to the current version when serialized.
        if (formatVersion < 1 || formatVersion > 3) {
            error = "unsupported graph formatVersion " + std::to_string(formatVersion);
            return false;
        }
    }

    if (j.contains("resolution")) {
        const auto& r = j["resolution"];
        if (!r.is_object()) {
            error = "resolution must be an object";
            return false;
        }
        if (!readOptionalU32(r, "width", next.defaultWidth_, "resolution")) return false;
        if (!readOptionalU32(r, "height", next.defaultHeight_, "resolution")) return false;
        if (next.defaultWidth_ == 0 || next.defaultHeight_ == 0) {
            error = "resolution width and height must be > 0";
            return false;
        }
    }
    if (j.contains("sink")) {
        if (!j["sink"].is_string()) {
            error = "sink must be a string";
            return false;
        }
        next.defaultSink_ = j["sink"].get<std::string>();
        if (next.defaultSink_.empty()) {
            error = "sink must not be empty";
            return false;
        }
    }
    if (j.contains("sinkOutput")) {
        if (!j["sinkOutput"].is_string()) {
            error = "sinkOutput must be a string";
            return false;
        }
        next.defaultSinkOutput_ = j["sinkOutput"].get<std::string>();
        if (next.defaultSinkOutput_.empty()) {
            error = "sinkOutput must not be empty";
            return false;
        }
    }

    if (j.contains("nodes")) {
        if (!j["nodes"].is_array()) {
            error = "nodes must be an array";
            return false;
        }
        for (const auto& jn : j["nodes"]) {
            if (!jn.is_object()) {
                error = "node entries must be objects";
                return false;
            }
            std::string id;
            std::string type;
            if (!readString(jn, "id", id, "node")) return false;
            if (!readString(jn, "type", type, "node '" + id + "'")) return false;
            Node* n = next.addNode(id, type, error);
            if (!n) return false;
            if (jn.contains("params")) {
                if (!jn["params"].is_object()) {
                    error = "node '" + id + "' params must be an object";
                    return false;
                }
                for (auto it = jn["params"].begin(); it != jn["params"].end(); ++it) {
                    if (!it.value().is_number()) {
                        error = "node '" + id + "' param '" + it.key() +
                                "' must be a number";
                        return false;
                    }
                    n->params.set(it.key(), it.value().get<double>());
                }
            }
            migrateLegacyCellSize(*n, next.defaultWidth_);
            migrateLegacyRiverWidth(*n, next.defaultWidth_, formatVersion);
            migrateLegacySlopeMaskDefaults(*n);
        }
    }

    if (j.contains("connections")) {
        if (!j["connections"].is_array()) {
            error = "connections must be an array";
            return false;
        }
        for (const auto& jc : j["connections"]) {
            if (!jc.is_object()) {
                error = "connection entries must be objects";
                return false;
            }
            std::string from;
            std::string output;
            std::string to;
            std::uint32_t input = 0;
            if (!readString(jc, "from", from, "connection")) return false;
            if (!readString(jc, "to", to, "connection")) return false;
            if (!readOptionalU32(jc, "input", input, "connection")) return false;
            if (jc.contains("output")) {
                if (!readString(jc, "output", output, "connection")) return false;
            } else {
                Node* source = next.node(from);
                if (!source) {
                    error = "connect: no such source node: " + from;
                    return false;
                }
                output = next.defaultOutputName(*source);
            }
            if (!next.connect(from, output, to, input, error)) return false;
        }
    }
    if (j.contains("ui")) {
        next.uiMetadataJSON_ = j["ui"].dump();
        const auto& ui = j["ui"];
        if (ui.is_object() && ui.contains("maskErases") && ui["maskErases"].is_object()) {
            for (auto nodeIt = ui["maskErases"].begin();
                 nodeIt != ui["maskErases"].end(); ++nodeIt) {
                auto nit = next.nodes_.find(nodeIt.key());
                if (nit == next.nodes_.end()) continue;
                std::map<std::string, json> encodedOutputs;
                if (nodeIt.value().is_array()) {
                    // v1: edits belonged to the node's default output.
                    encodedOutputs[next.defaultOutputName(*nit->second)] = nodeIt.value();
                } else if (nodeIt.value().is_object()) {
                    for (auto outputIt = nodeIt.value().begin();
                         outputIt != nodeIt.value().end(); ++outputIt) {
                        encodedOutputs[outputIt.key()] = outputIt.value();
                    }
                }
                for (const auto& [outputName, encodedStrokes] : encodedOutputs) {
                    std::size_t outputIndex = 0;
                    std::string ignoredError;
                    FieldKind outputKind = FieldKind::data;
                    if (!encodedStrokes.is_array() ||
                        !next.outputIndex(*nit->second, outputName,
                                          outputIndex, ignoredError) ||
                        !next.resolvedOutputKind(nodeIt.key(), outputName,
                                                 outputKind, ignoredError) ||
                        outputKind != FieldKind::mask) continue;
                    auto& strokes = next.maskErases_[nodeIt.key()][outputName];
                    for (const auto& item : encodedStrokes) {
                        if (!item.is_object()) continue;
                        auto number = [&](const char* key, double fallback) {
                            return item.contains(key) && item[key].is_number()
                                ? item[key].get<double>() : fallback;
                        };
                        const MaskEraseStroke stroke{
                            number("x", 0.0), number("y", 0.0),
                            number("radius", 0.0), number("strength", 1.0)};
                        if (std::isfinite(stroke.x) && std::isfinite(stroke.y) &&
                            std::isfinite(stroke.radius) && std::isfinite(stroke.strength) &&
                            stroke.radius > 0.0 && stroke.strength > 0.0) {
                            strokes.push_back(stroke);
                        }
                    }
                    if (strokes.empty()) {
                        next.maskErases_[nodeIt.key()].erase(outputName);
                    }
                }
                if (next.maskErases_[nodeIt.key()].empty()) {
                    next.maskErases_.erase(nodeIt.key());
                }
            }
        }
    }
    if (next.defaultSink_.empty() && !next.defaultSinkOutput_.empty()) {
        error = "sinkOutput requires a sink node";
        return false;
    }
    if (!next.defaultSink_.empty()) {
        auto sinkIt = next.nodes_.find(next.defaultSink_);
        if (sinkIt == next.nodes_.end()) {
            error = "sink node not found: " + next.defaultSink_;
            return false;
        }
        if (next.defaultSinkOutput_.empty()) {
            next.defaultSinkOutput_ = next.defaultOutputName(*sinkIt->second);
        }
        std::size_t sinkOutputIndex = 0;
        if (!next.outputIndex(*sinkIt->second, next.defaultSinkOutput_,
                              sinkOutputIndex, error) ||
            !next.validateSink(next.defaultSink_, error)) {
            return false;
        }
        next.defaultSinkOutput_ =
            sinkIt->second->outputPorts()[sinkOutputIndex].name;
    }

    // Preserve the cache across successful reloads: cache keys are content
    // hashes, so unchanged nodes can reuse outputs and changed subgraphs still
    // recompute. Failed reloads leave the previous graph intact.
    nodes_ = std::move(next.nodes_);
    inputs_ = std::move(next.inputs_);
    maskErases_ = std::move(next.maskErases_);
    uiMetadataJSON_ = std::move(next.uiMetadataJSON_);
    defaultSink_ = std::move(next.defaultSink_);
    defaultSinkOutput_ = std::move(next.defaultSinkOutput_);
    defaultWidth_ = next.defaultWidth_;
    defaultHeight_ = next.defaultHeight_;

    // Drop cache entries for nodes that no longer exist.
    for (auto it = cache_.begin(); it != cache_.end();) {
        it = nodes_.count(it->first) ? std::next(it) : cache_.erase(it);
    }
    return true;
}

} // namespace theia
