#include "Theia/Theia.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <limits>
#include <map>
#include <memory>
#include <set>
#include <sstream>
#include <vector>

#include "GPUContext.hpp"
#include "Graph.hpp"
#include "Heightfield.hpp"
#include "Node.hpp"
#include "io/ExportWriter.hpp"
#include "io/ImageWriter.hpp"
#include "json.hpp"

using json = nlohmann::json;

namespace theia {

namespace {
constexpr const char* kTheiaVersion = "0.12.0-alpha.1";
constexpr std::uint32_t kTheiaAPIVersion = 3;

std::size_t copyOutStr(const std::string& s, char* out, std::size_t cap) {
    if (out && cap > 0) {
        const std::size_t n = std::min(cap - 1, s.size());
        std::memcpy(out, s.data(), n);
        out[n] = '\0';
    }
    return s.size();
}

struct DiagnosticIssue {
    std::string severity;
    std::string code;
    std::string message;
    std::string node;
    std::string edge;
    std::uint32_t input = std::numeric_limits<std::uint32_t>::max();
};

void addIssue(std::vector<DiagnosticIssue>& issues,
              std::string severity,
              std::string code,
              std::string message,
              std::string node = {},
              std::uint32_t input = std::numeric_limits<std::uint32_t>::max(),
              std::string edge = {}) {
    issues.push_back(DiagnosticIssue{std::move(severity), std::move(code),
                                     std::move(message), std::move(node),
                                     std::move(edge), input});
}

bool readJsonString(const json& obj, const char* key, std::string& out) {
    if (!obj.contains(key) || !obj[key].is_string()) return false;
    out = obj[key].get<std::string>();
    return true;
}

bool readJsonU32(const json& obj, const char* key, std::uint32_t& out) {
    if (!obj.contains(key) || !obj[key].is_number_integer()) return false;
    if (obj[key].is_number_unsigned()) {
        const auto wide = obj[key].get<std::uint64_t>();
        if (wide > std::numeric_limits<std::uint32_t>::max()) return false;
        out = static_cast<std::uint32_t>(wide);
        return true;
    }
    const auto signedValue = obj[key].get<std::int64_t>();
    if (signedValue < 0 ||
        static_cast<std::uint64_t>(signedValue) > std::numeric_limits<std::uint32_t>::max()) {
        return false;
    }
    out = static_cast<std::uint32_t>(signedValue);
    return true;
}

bool isHeavySimulationNode(const std::string& type) {
    return type == "dropleterosion" || type == "hydraulic";
}

double jsonParamValue(const json& params, const char* key, double fallback) {
    if (!params.is_object() || !params.contains(key) || !params[key].is_number()) {
        return fallback;
    }
    return params[key].get<double>();
}

std::string canonicalOutputName(
    const std::vector<OutputPortDescriptor>& ports,
    const std::string& authoredName
) {
    if (authoredName != "height") return authoredName;
    const bool stillHasHeight = std::any_of(
        ports.begin(), ports.end(),
        [](const OutputPortDescriptor& port) { return port.name == "height"; });
    if (stillHasHeight) return authoredName;
    const auto terrain = std::find_if(
        ports.begin(), ports.end(),
        [](const OutputPortDescriptor& port) {
            return port.name == "terrain" && port.kind == FieldKind::terrain;
        });
    return terrain == ports.end() ? authoredName : terrain->name;
}

std::string makeDiagnosticsJSON(const std::string& text) {
    struct DiagnosticSource {
        std::string node;
        std::string output;
    };
    json result;
    std::vector<DiagnosticIssue> issues;
    std::map<std::string, std::string> nodeTypes;
    std::map<std::string, std::uint32_t> inputCounts;
    std::map<std::string, std::vector<InputPortDescriptor>> inputPorts;
    std::map<std::string, std::vector<OutputPortDescriptor>> outputPorts;
    std::map<std::string, json> nodeParams;
    std::map<std::string, std::map<std::uint32_t, DiagnosticSource>> inbound;
    std::map<std::string, std::vector<std::string>> outgoing;
    std::string sink;
    std::string sinkOutput;

    json j = json::parse(text, nullptr, /*allow_exceptions=*/false);
    if (j.is_discarded()) {
        addIssue(issues, "error", "invalid_json", "Graph JSON could not be parsed");
        result["ok"] = false;
        result["summary"] = {
            {"nodes", 0}, {"connections", 0}, {"errors", 1},
            {"warnings", 0}, {"sink", ""}
        };
        result["issues"] = json::array();
        for (const auto& issue : issues) {
            result["issues"].push_back({
                {"severity", issue.severity},
                {"code", issue.code},
                {"message", issue.message}
            });
        }
        return result.dump(2);
    }
    if (!j.is_object()) {
        addIssue(issues, "error", "invalid_shape", "Graph JSON must be an object");
    }

    if (j.is_object() && j.contains("sink")) {
        if (j["sink"].is_string()) {
            sink = j["sink"].get<std::string>();
            if (sink.empty()) {
                addIssue(issues, "warning", "empty_sink", "Graph has no active preview/output sink");
            }
        } else {
            addIssue(issues, "error", "invalid_sink", "Graph sink must be a string");
        }
    } else {
        addIssue(issues, "warning", "empty_sink", "Graph has no active preview/output sink");
    }
    if (j.is_object() && j.contains("sinkOutput")) {
        if (j["sinkOutput"].is_string()) {
            sinkOutput = j["sinkOutput"].get<std::string>();
        } else {
            addIssue(issues, "error", "invalid_sink_output",
                     "Graph sinkOutput must be a string");
        }
    }

    if (!j.is_object() || !j.contains("nodes")) {
        addIssue(issues, "warning", "empty_graph", "Graph contains no nodes");
    } else if (!j["nodes"].is_array()) {
        addIssue(issues, "error", "invalid_nodes", "Graph nodes must be an array");
    } else {
        if (j["nodes"].empty()) {
            addIssue(issues, "warning", "empty_graph", "Graph contains no nodes");
        }
        for (const auto& nodeJson : j["nodes"]) {
            if (!nodeJson.is_object()) {
                addIssue(issues, "error", "invalid_node", "Node entries must be objects");
                continue;
            }
            std::string id;
            std::string type;
            if (!readJsonString(nodeJson, "id", id) || id.empty()) {
                addIssue(issues, "error", "invalid_node_id", "Node id must be a non-empty string");
                continue;
            }
            if (!readJsonString(nodeJson, "type", type) || type.empty()) {
                addIssue(issues, "error", "invalid_node_type",
                         "Node '" + id + "' type must be a non-empty string", id);
                continue;
            }
            if (nodeTypes.count(id)) {
                addIssue(issues, "error", "duplicate_node",
                         "Duplicate node id '" + id + "'", id);
                continue;
            }
            auto defaults = createNode(type, "__diagnostics__");
            if (!defaults) {
                addIssue(issues, "error", "unknown_node_type",
                         "Node '" + id + "' has unknown type '" + type + "'", id);
                continue;
            }
            nodeTypes[id] = type;
            inputCounts[id] = static_cast<std::uint32_t>(defaults->inputCount());
            inputPorts[id] = defaults->inputPorts();
            outputPorts[id] = defaults->outputPorts();
            json params = json::object();
            if (nodeJson.contains("params")) {
                if (!nodeJson["params"].is_object()) {
                    addIssue(issues, "error", "invalid_params",
                             "Node '" + id + "' params must be an object", id);
                } else {
                    params = nodeJson["params"];
                    for (auto it = params.begin(); it != params.end(); ++it) {
                        if (!it.value().is_number()) {
                            addIssue(issues, "error", "invalid_param_value",
                                     "Node '" + id + "' param '" + it.key() +
                                         "' must be numeric",
                                     id);
                        }
                    }
                }
            }
            nodeParams[id] = params;
        }
    }

    int connectionCount = 0;
    if (j.is_object() && j.contains("connections")) {
        if (!j["connections"].is_array()) {
            addIssue(issues, "error", "invalid_connections", "Graph connections must be an array");
        } else {
            for (const auto& connJson : j["connections"]) {
                if (!connJson.is_object()) {
                    addIssue(issues, "error", "invalid_connection",
                             "Connection entries must be objects");
                    continue;
                }
                std::string from;
                std::string output;
                std::string to;
                std::uint32_t input = 0;
                const bool okFrom = readJsonString(connJson, "from", from) && !from.empty();
                const bool okTo = readJsonString(connJson, "to", to) && !to.empty();
                const bool okInput = readJsonU32(connJson, "input", input);
                const std::string edge = from + "->" + to + "." + std::to_string(input);
                if (!okFrom || !okTo || !okInput) {
                    addIssue(issues, "error", "invalid_connection",
                             "Connection requires string from/to and non-negative integer input",
                             to, input, edge);
                    continue;
                }
                if (connJson.contains("output")) {
                    if (!connJson["output"].is_string()) {
                        addIssue(issues, "error", "invalid_output_port",
                                 "Connection output must be a string",
                                 to, input, edge);
                        continue;
                    }
                    output = connJson["output"].get<std::string>();
                }
                ++connectionCount;
                if (!nodeTypes.count(from)) {
                    addIssue(issues, "error", "missing_source",
                             "Connection references missing source node '" + from + "'",
                             to, input, edge);
                } else {
                    const auto& ports = outputPorts[from];
                    if (output.empty()) {
                        auto it = std::find_if(ports.begin(), ports.end(),
                            [](const OutputPortDescriptor& p) { return p.isDefault; });
                        if (it != ports.end()) output = it->name;
                    } else {
                        output = canonicalOutputName(ports, output);
                    }
                    const bool known = std::any_of(ports.begin(), ports.end(),
                        [&](const OutputPortDescriptor& p) { return p.name == output; });
                    if (!known) {
                        addIssue(issues, "error", "unknown_output",
                                 "Connection references unavailable output '" + output +
                                     "' on node '" + from + "'",
                                 from, input, edge);
                    }
                }
                if (!nodeTypes.count(to)) {
                    addIssue(issues, "error", "missing_target",
                             "Connection references missing target node '" + to + "'",
                             to, input, edge);
                    continue;
                }
                if (input >= inputCounts[to]) {
                    addIssue(issues, "error", "invalid_input_port",
                             "Connection targets unavailable input port " +
                                 std::to_string(input) + " on node '" + to + "'",
                             to, input, edge);
                    continue;
                }
                if (inbound[to].count(input)) {
                    addIssue(issues, "warning", "duplicate_input_connection",
                             "Multiple connections target node '" + to + "' input " +
                                 std::to_string(input) + "; last connection wins",
                             to, input, edge);
                }
                inbound[to][input] = {from, output};
                outgoing[from].push_back(to);
            }
        }
    }

    std::set<std::string> reachable;
    std::map<std::string, int> color;
    std::function<void(const std::string&)> markReachable = [&](const std::string& id) {
        if (!nodeTypes.count(id) || color[id] == 2) return;
        if (color[id] == 1) {
            addIssue(issues, "error", "cycle",
                     "Cycle detected while tracing graph dependencies at node '" +
                         id + "'", id);
            return;
        }
        color[id] = 1;
        reachable.insert(id);
        for (const auto& kv : inbound[id]) {
            const std::string& source = kv.second.node;
            if (nodeTypes.count(source)) markReachable(source);
        }
        color[id] = 2;
    };
    if (!sink.empty()) {
        if (!nodeTypes.count(sink)) {
            addIssue(issues, "error", "missing_sink",
                     "Sink node '" + sink + "' does not exist", sink);
        } else {
            markReachable(sink);

            const auto& ports = outputPorts[sink];
            if (sinkOutput.empty()) {
                auto it = std::find_if(ports.begin(), ports.end(),
                    [](const OutputPortDescriptor& p) { return p.isDefault; });
                if (it != ports.end()) sinkOutput = it->name;
            } else {
                sinkOutput = canonicalOutputName(ports, sinkOutput);
            }
            if (!std::any_of(ports.begin(), ports.end(),
                    [&](const OutputPortDescriptor& p) { return p.name == sinkOutput; })) {
                addIssue(issues, "error", "unknown_sink_output",
                         "Sink node '" + sink + "' has no output '" + sinkOutput + "'",
                         sink);
            }
        }
    }

    std::map<std::string, int> kindColor;
    std::function<bool(const DiagnosticSource&, FieldKind&)> resolveKind =
        [&](const DiagnosticSource& source, FieldKind& kind) -> bool {
            const std::string key = source.node + "\n" + source.output;
            if (kindColor[key] == 1 || !nodeTypes.count(source.node)) return false;
            const auto& ports = outputPorts[source.node];
            auto it = std::find_if(ports.begin(), ports.end(),
                [&](const OutputPortDescriptor& p) { return p.name == source.output; });
            if (it == ports.end()) return false;
            kindColor[key] = 1;
            if (it->inheritInput >= 0) {
                const auto inputIt = inbound[source.node].find(
                    static_cast<std::uint32_t>(it->inheritInput));
                if (inputIt == inbound[source.node].end() ||
                    !resolveKind(inputIt->second, kind)) {
                    kindColor[key] = 0;
                    return false;
                }
            } else {
                kind = it->kind;
            }
            kindColor[key] = 2;
            return true;
        };

    for (const auto& target : inbound) {
        if (!inputPorts.count(target.first)) continue;
        for (const auto& inputConnection : target.second) {
            const auto inputIndex = inputConnection.first;
            if (inputIndex >= inputPorts[target.first].size()) continue;
            FieldKind sourceKind = FieldKind::data;
            if (!resolveKind(inputConnection.second, sourceKind)) continue;
            const auto& accepted = inputPorts[target.first][inputIndex].acceptedKinds;
            if (std::find(accepted.begin(), accepted.end(), sourceKind) == accepted.end()) {
                addIssue(issues, "error", "incompatible_kind",
                         "Output '" + inputConnection.second.node + "." +
                             inputConnection.second.output + "' is " +
                             fieldKindName(sourceKind) + ", incompatible with input '" +
                             target.first + "." + inputPorts[target.first][inputIndex].name + "'",
                         target.first, inputIndex);
            }
        }
        const std::string& type = nodeTypes[target.first];
        if ((type == "combine" || type == "blend") &&
            target.second.count(0) && target.second.count(1)) {
            FieldKind a = FieldKind::data;
            FieldKind b = FieldKind::data;
            if (resolveKind(target.second.at(0), a) &&
                resolveKind(target.second.at(1), b) && a != b) {
                addIssue(issues, "error", "incompatible_binary_kinds",
                         "Node '" + target.first +
                             "' requires both inputs to have the same field kind",
                         target.first);
            }
        }
    }

    for (const auto& kv : nodeTypes) {
        const std::string& id = kv.first;
        const std::string& type = kv.second;
        const bool sinkReachable = !sink.empty() && reachable.count(id) > 0;
        for (std::uint32_t input = 0; input < inputCounts[id]; ++input) {
            if (!inbound[id].count(input)) {
                addIssue(issues, sinkReachable ? "error" : "warning", "missing_input",
                         "Node '" + id + "' input " + std::to_string(input) +
                             " is not connected",
                         id, input);
            }
        }
        if (!sink.empty() && !sinkReachable) {
            addIssue(issues, "warning", "orphan_node",
                     "Node '" + id + "' is not upstream of the active sink", id);
        }
        if (type == "export" && !outgoing[id].empty()) {
            addIssue(issues, "warning", "export_not_terminal",
                     "Export node '" + id + "' is connected downstream; export nodes should be graph terminals",
                     id);
        }
        if (isHeavySimulationNode(type)) {
            const json params = nodeParams[id];
            if (type == "dropleterosion") {
                const double particles = jsonParamValue(params, "particles", 8000.0);
                const double maxAge = jsonParamValue(params, "maxAge", 80.0);
                if (particles >= 20000.0 || maxAge >= 220.0) {
                    addIssue(issues, "warning", "heavy_simulation",
                             "Droplet erosion node '" + id +
                                 "' may slow live preview with current particles/maxAge",
                             id);
                }
            } else if (type == "hydraulic") {
                const double iterations = jsonParamValue(params, "iterations", 200.0);
                if (iterations >= 260.0) {
                    addIssue(issues, "warning", "heavy_simulation",
                             "Hydraulic node '" + id +
                                 "' may slow live preview with current iteration count",
                             id);
                }
                const double dt = jsonParamValue(params, "dt", 0.015);
                const double minTilt = jsonParamValue(params, "minTilt", 0.005);
                const double rain = jsonParamValue(params, "rain", 0.010);
                const double evaporation =
                    jsonParamValue(params, "evaporation", 0.020);
                const double heightScale =
                    jsonParamValue(params, "heightScale", 80.0);
                if (dt > 0.025 || minTilt > 0.15 || rain > 0.05 ||
                    evaporation > 0.10 || heightScale > 150.0) {
                    addIssue(issues, "warning", "hydraulic_authoring_envelope",
                             "Hydraulic node '" + id +
                                 "' uses advanced values outside the recommended authoring envelope; "
                                 "the core will stabilize them but slope selectivity may be reduced",
                             id);
                }
            }
        }
    }

    int errors = 0;
    int warnings = 0;
    for (const auto& issue : issues) {
        if (issue.severity == "error") ++errors;
        if (issue.severity == "warning") ++warnings;
    }

    result["ok"] = errors == 0;
    result["summary"] = {
        {"nodes", nodeTypes.size()},
        {"connections", connectionCount},
        {"errors", errors},
        {"warnings", warnings},
        {"sink", sink}
    };
    result["issues"] = json::array();
    for (const auto& issue : issues) {
        json item = {
            {"severity", issue.severity},
            {"code", issue.code},
            {"message", issue.message}
        };
        if (!issue.node.empty()) item["node"] = issue.node;
        if (!issue.edge.empty()) item["edge"] = issue.edge;
        if (issue.input != std::numeric_limits<std::uint32_t>::max()) {
            item["input"] = issue.input;
        }
        result["issues"].push_back(std::move(item));
    }
    return result.dump(2);
}
} // namespace

std::size_t theia_version_string(char* out, std::size_t cap) {
    return copyOutStr(kTheiaVersion, out, cap);
}

std::uint32_t theia_api_version() {
    return kTheiaAPIVersion;
}

std::size_t theia_capabilities_json(char* out, std::size_t cap) {
    json caps;
    caps["version"] = kTheiaVersion;
    caps["apiVersion"] = kTheiaAPIVersion;
    caps["swiftPM"] = true;
    caps["stableCABI"] = false;
    caps["multiOutputGraph"] = true;
    caps["graphFormatVersion"] = 2;
    caps["heightmapFormats"] = {"png16", "r16", "pfm32"};
    caps["meshFormats"] = {"obj"};
    caps["commands"] = {"smoke", "demo", "run", "export", "diagnose",
                        "nodes", "doctor", "version"};
    caps["nodes"] = registeredNodeTypes();
    const std::string text = caps.dump(2);
    return copyOutStr(text, out, cap);
}

// Concrete definition of the opaque handle from the public header. Owns the
// graph and a lazily-created GPU context.
struct GraphHandle {
    Graph graph;
    std::unique_ptr<GPUContext> ctx;  // created on first evaluate
    std::string lastError;
    GraphErrorCode lastErrorCode = GraphErrorCode::none;

    void clearError() {
        lastError.clear();
        lastErrorCode = GraphErrorCode::none;
    }

    void setError(GraphErrorCode code, std::string message) {
        lastErrorCode = code;
        lastError = std::move(message);
    }

    bool ensureGPU() {
        if (ctx) return true;
        ctx = GPUContext::create(lastError);
        if (!ctx) lastErrorCode = GraphErrorCode::evaluation;
        return ctx != nullptr;
    }
};

GraphHandle* graph_create() { return new GraphHandle(); }

void graph_destroy(GraphHandle* g) { delete g; }

bool graph_add_node(GraphHandle* g, const char* id, const char* type) {
    if (!g) return false;
    g->clearError();
    if (g->graph.addNode(id ? id : "", type ? type : "", g->lastError) == nullptr) {
        g->lastErrorCode = GraphErrorCode::validation;
        return false;
    }
    return true;
}

bool graph_set_param(GraphHandle* g, const char* id, const char* key, double value) {
    if (!g) return false;
    g->clearError();
    if (!g->graph.setParam(id ? id : "", key ? key : "", value, g->lastError)) {
        g->lastErrorCode = GraphErrorCode::validation;
        return false;
    }
    return true;
}

bool graph_connect(GraphHandle* g, const char* fromId, const char* toId,
                   std::uint32_t inputIndex) {
    if (!g) return false;
    g->clearError();
    if (!g->graph.connect(fromId ? fromId : "", toId ? toId : "", inputIndex,
                          g->lastError)) {
        g->lastErrorCode = GraphErrorCode::validation;
        return false;
    }
    return true;
}

bool graph_connect_output(GraphHandle* g, const char* fromId,
                          const char* outputName, const char* toId,
                          std::uint32_t inputIndex) {
    if (!g) return false;
    g->clearError();
    if (!g->graph.connect(fromId ? fromId : "", outputName ? outputName : "",
                          toId ? toId : "", inputIndex, g->lastError)) {
        g->lastErrorCode = GraphErrorCode::validation;
        return false;
    }
    return true;
}

bool graph_load_json_file(GraphHandle* g, const char* path) {
    if (!g || !path) return false;
    g->clearError();
    std::ifstream f(path);
    if (!f) {
        g->setError(GraphErrorCode::load, std::string("cannot open ") + path);
        return false;
    }
    std::stringstream ss;
    ss << f.rdbuf();
    if (!g->graph.fromJSON(ss.str(), g->lastError)) {
        g->lastErrorCode = GraphErrorCode::load;
        return false;
    }
    return true;
}

bool graph_load_json_text(GraphHandle* g, const char* text) {
    if (!g || !text) return false;
    g->clearError();
    if (!g->graph.fromJSON(text, g->lastError)) {
        g->lastErrorCode = GraphErrorCode::load;
        return false;
    }
    return true;
}

bool graph_save_json_file(GraphHandle* g, const char* path) {
    if (!g || !path) return false;
    g->clearError();
    std::ofstream f(path);
    if (!f) {
        g->setError(GraphErrorCode::exportError, std::string("cannot write ") + path);
        return false;
    }
    f << g->graph.toJSON();
    if (!f) {
        g->setError(GraphErrorCode::exportError, std::string("cannot write ") + path);
        return false;
    }
    return true;
}

std::size_t graph_diagnostics_json_text(const char* text,
                                        char* out, std::size_t cap) {
    const std::string diagnostics = makeDiagnosticsJSON(text ? text : "");
    return copyOutStr(diagnostics, out, cap);
}

GraphEvalResult graph_evaluate(GraphHandle* g, const char* sinkId,
                               std::uint32_t width, std::uint32_t height,
                               const char* pngPath, const char* pfmPath) {
    return graph_evaluate_output(g, sinkId, nullptr, width, height,
                                 pngPath, pfmPath);
}

GraphEvalResult graph_evaluate_output(GraphHandle* g, const char* sinkId,
                                      const char* outputName,
                                      std::uint32_t width, std::uint32_t height,
                                      const char* pngPath, const char* pfmPath) {
    GraphEvalResult r;
    if (!g) return r;
    g->clearError();

    if (!g->ensureGPU()) {
        // lastError already set by ensureGPU.
        return r;
    }

    std::string sink = (sinkId && sinkId[0]) ? sinkId : g->graph.defaultSink();
    if (sink.empty()) {
        g->setError(GraphErrorCode::validation,
                    "no sink specified and graph has no default sink");
        return r;
    }
    const std::uint32_t w = width ? width : g->graph.defaultWidth();
    const std::uint32_t h = height ? height : g->graph.defaultHeight();
    const std::string output = (outputName && outputName[0])
        ? outputName
        : ((!sinkId || !sinkId[0]) ? g->graph.defaultSinkOutput() : std::string{});

    EvalStats stats;
    const Heightfield* out =
        g->graph.evaluate(*g->ctx, sink, output, w, h, stats, g->lastError);
    if (!out) {
        g->lastErrorCode = GraphErrorCode::evaluation;
        return r;
    }

    r.width = w;
    r.height = h;
    r.evaluated = stats.evaluated;
    r.reused = stats.reused;

    float mn, mx;
    double mean, var;
    out->stats(mn, mx, mean, var);
    r.minHeight = mn;
    r.maxHeight = mx;
    r.mean = mean;
    r.variance = var;

    if (pfmPath && pfmPath[0]) {
        if (!writePFM(pfmPath, out->data(), w, h, g->lastError)) {
            g->lastErrorCode = GraphErrorCode::exportError;
            return r;
        }
    }
    if (pngPath && pngPath[0]) {
        if (!writePNG16(pngPath, out->data(), w, h, mn, mx, g->lastError)) {
            g->lastErrorCode = GraphErrorCode::exportError;
            return r;
        }
    }

    r.ok = true;
    return r;
}

GraphEvalResult graph_evaluate_heights(GraphHandle* g, const char* sinkId,
                                       std::uint32_t width, std::uint32_t height,
                                       float* dst, std::size_t capElems) {
    return graph_evaluate_heights_output(g, sinkId, nullptr, width, height,
                                         dst, capElems);
}

GraphEvalResult graph_evaluate_heights_output(
    GraphHandle* g, const char* sinkId, const char* outputName,
    std::uint32_t width, std::uint32_t height,
    float* dst, std::size_t capElems) {
    GraphEvalResult r;
    if (!g) return r;
    g->clearError();
    if (!g->ensureGPU()) return r;

    std::string sink = (sinkId && sinkId[0]) ? sinkId : g->graph.defaultSink();
    if (sink.empty()) {
        g->setError(GraphErrorCode::validation,
                    "no sink specified and graph has no default sink");
        return r;
    }
    const std::uint32_t w = width ? width : g->graph.defaultWidth();
    const std::uint32_t h = height ? height : g->graph.defaultHeight();
    const std::string output = (outputName && outputName[0])
        ? outputName
        : ((!sinkId || !sinkId[0]) ? g->graph.defaultSinkOutput() : std::string{});

    EvalStats stats;
    const Heightfield* out =
        g->graph.evaluate(*g->ctx, sink, output, w, h, stats, g->lastError);
    if (!out) {
        g->lastErrorCode = GraphErrorCode::evaluation;
        return r;
    }

    r.width = w;
    r.height = h;
    r.evaluated = stats.evaluated;
    r.reused = stats.reused;
    float mn, mx;
    double mean, var;
    out->stats(mn, mx, mean, var);
    r.minHeight = mn;
    r.maxHeight = mx;
    r.mean = mean;
    r.variance = var;

    const std::size_t need = std::size_t(w) * h;
    if (dst && capElems >= need) {
        std::memcpy(dst, out->data(), need * sizeof(float));
    }
    r.ok = true;
    return r;
}

GraphEvalResult graph_export(GraphHandle* g, const char* sinkId,
                             std::uint32_t width, std::uint32_t height,
                             const char* heightPngPath,
                             const char* pfmPath,
                             const char* normalPngPath,
                             const char* slopePngPath,
                             const char* maskPngPath,
                             const char* objPath,
                             float verticalScale,
                             std::uint32_t meshStride) {
    GraphEvalResult r;
    if (!g) return r;
    g->clearError();
    if (!g->ensureGPU()) return r;
    if (width == 0 || height == 0) {
        width = g->graph.defaultWidth();
        height = g->graph.defaultHeight();
    }
    if (width < 2 || height < 2) {
        g->setError(GraphErrorCode::validation, "export resolution must be at least 2x2");
        return r;
    }
    if (meshStride == 0) {
        g->setError(GraphErrorCode::validation, "mesh stride must be > 0");
        return r;
    }
    if (!(verticalScale > 0.0f)) {
        g->setError(GraphErrorCode::validation, "vertical scale must be > 0");
        return r;
    }

    const std::string sink = (sinkId && sinkId[0]) ? sinkId : g->graph.defaultSink();
    if (sink.empty()) {
        g->setError(GraphErrorCode::validation,
                    "no sink specified and graph has no default sink");
        return r;
    }

    EvalStats stats;
    const Heightfield* out =
        g->graph.evaluate(*g->ctx, sink, width, height, stats, g->lastError);
    if (!out) {
        g->lastErrorCode = GraphErrorCode::evaluation;
        return r;
    }

    r.width = width;
    r.height = height;
    r.evaluated = stats.evaluated;
    r.reused = stats.reused;
    float mn, mx;
    double mean, var;
    out->stats(mn, mx, mean, var);
    r.minHeight = mn;
    r.maxHeight = mx;
    r.mean = mean;
    r.variance = var;

    const float* data = out->data();
    if (heightPngPath && heightPngPath[0]) {
        if (!writePNG16(heightPngPath, data, width, height, mn, mx, g->lastError)) {
            g->lastErrorCode = GraphErrorCode::exportError;
            return r;
        }
    }
    if (pfmPath && pfmPath[0]) {
        if (!writePFM(pfmPath, data, width, height, g->lastError)) {
            g->lastErrorCode = GraphErrorCode::exportError;
            return r;
        }
    }
    if (normalPngPath && normalPngPath[0]) {
        if (!writeNormalPNG(normalPngPath, data, width, height, verticalScale,
                            g->lastError)) {
            g->lastErrorCode = GraphErrorCode::exportError;
            return r;
        }
    }
    if (slopePngPath && slopePngPath[0]) {
        if (!writeSlopePNG16(slopePngPath, data, width, height, verticalScale,
                             g->lastError)) {
            g->lastErrorCode = GraphErrorCode::exportError;
            return r;
        }
    }
    if (maskPngPath && maskPngPath[0]) {
        if (!writePNG16(maskPngPath, data, width, height, 0.0f, 1.0f,
                        g->lastError)) {
            g->lastErrorCode = GraphErrorCode::exportError;
            return r;
        }
    }
    if (objPath && objPath[0]) {
        if (!writeOBJ(objPath, data, width, height, verticalScale, meshStride,
                      g->lastError)) {
            g->lastErrorCode = GraphErrorCode::exportError;
            return r;
        }
    }

    r.ok = true;
    return r;
}

GraphEvalResult graph_export2(GraphHandle* g, const GraphExportOptions& options) {
    GraphEvalResult r;
    if (!g) return r;
    g->clearError();

    const bool writeHeight = options.heightmapFormat != HeightmapFormat::none;
    const bool writeMesh = options.meshFormat != MeshFormat::none;
    if (!writeHeight && !writeMesh) {
        g->setError(GraphErrorCode::validation, "choose at least one export output");
        return r;
    }
    if (options.heightmapFormat != HeightmapFormat::none &&
        options.heightmapFormat != HeightmapFormat::png16 &&
        options.heightmapFormat != HeightmapFormat::r16 &&
        options.heightmapFormat != HeightmapFormat::pfm32) {
        g->setError(GraphErrorCode::validation, "unknown heightmap format");
        return r;
    }
    if (options.meshFormat != MeshFormat::none && options.meshFormat != MeshFormat::obj) {
        g->setError(GraphErrorCode::validation, "unknown mesh format");
        return r;
    }
    if (!options.outDir || !options.outDir[0]) {
        g->setError(GraphErrorCode::validation, "export outDir is required");
        return r;
    }
    if (!options.basename || !options.basename[0]) {
        g->setError(GraphErrorCode::validation, "export basename is required");
        return r;
    }
    if (options.meshStride == 0) {
        g->setError(GraphErrorCode::validation, "mesh stride must be > 0");
        return r;
    }
    if (!(options.verticalScale > 0.0f)) {
        g->setError(GraphErrorCode::validation, "vertical scale must be > 0");
        return r;
    }

    const std::string sink = (options.sinkId && options.sinkId[0])
        ? options.sinkId : g->graph.defaultSink();
    if (sink.empty()) {
        g->setError(GraphErrorCode::validation,
                    "no sink specified and graph has no default sink");
        return r;
    }
    const bool explicitNamedOutput = options.outputName && options.outputName[0];
    std::string output = explicitNamedOutput
        ? options.outputName
        : ((!options.sinkId || !options.sinkId[0])
            ? g->graph.defaultSinkOutput() : std::string{});
    if (output.empty()) {
        for (std::size_t i = 0; i < g->graph.outputCount(sink); ++i) {
            OutputPortDescriptor descriptor;
            if (g->graph.outputAt(sink, i, descriptor) && descriptor.isDefault) {
                output = descriptor.name;
                break;
            }
        }
    }
    FieldKind outputKind = FieldKind::data;
    if (!g->graph.resolvedOutputKind(sink, output, outputKind, g->lastError)) {
        g->lastErrorCode = GraphErrorCode::validation;
        return r;
    }
    if (writeMesh && outputKind != FieldKind::terrain) {
        g->setError(GraphErrorCode::validation,
                    "OBJ export requires a terrain output; '" + output +
                    "' is " + fieldKindName(outputKind));
        return r;
    }

    std::error_code ec;
    std::filesystem::create_directories(options.outDir, ec);
    if (ec) {
        g->setError(GraphErrorCode::exportError,
                    std::string("cannot create ") + options.outDir + ": " + ec.message());
        return r;
    }

    const std::filesystem::path dir(options.outDir);
    const std::string base(options.basename);
    // Keep the API 1/2 filename contract when outputName is omitted. Callers that
    // opt into a named output receive a stable suffix derived from that public name.
    const std::string rasterSuffix = explicitNamedOutput && output != "height"
        ? "_" + output : "_height";
    const std::string pngPath =
        options.heightmapFormat == HeightmapFormat::png16
            ? (dir / (base + rasterSuffix + ".png")).string()
            : "";
    const std::string pfmPath =
        options.heightmapFormat == HeightmapFormat::pfm32
            ? (dir / (base + (explicitNamedOutput && output != "height"
                                  ? rasterSuffix : std::string{}) + ".pfm")).string()
            : "";
    const std::string objPath =
        options.meshFormat == MeshFormat::obj
            ? (dir / (base + ".obj")).string()
            : "";

    const std::uint32_t requestedW = options.width ? options.width : g->graph.defaultWidth();
    const std::uint32_t requestedH = options.height ? options.height : g->graph.defaultHeight();
    if (requestedW < 2 || requestedH < 2) {
        g->setError(GraphErrorCode::validation,
                    "export resolution must be at least 2x2");
        return r;
    }
    const std::size_t count = std::size_t(requestedW) * requestedH;
    std::vector<float> values(count);
    r = graph_evaluate_heights_output(g, sink.c_str(), output.c_str(),
                                      requestedW, requestedH,
                                      values.data(), values.size());
    if (!r.ok) return r;

    const float writeMin = outputKind == FieldKind::terrain ? r.minHeight : 0.0f;
    const float writeMax = outputKind == FieldKind::terrain ? r.maxHeight : 1.0f;
    if (!pngPath.empty() &&
        !writePNG16(pngPath.c_str(), values.data(), r.width, r.height,
                    writeMin, writeMax, g->lastError)) {
        g->lastErrorCode = GraphErrorCode::exportError;
        r.ok = false;
        return r;
    }
    if (!pfmPath.empty() &&
        !writePFM(pfmPath.c_str(), values.data(), r.width, r.height,
                  g->lastError)) {
        g->lastErrorCode = GraphErrorCode::exportError;
        r.ok = false;
        return r;
    }
    if (!objPath.empty() &&
        !writeOBJ(objPath.c_str(), values.data(), r.width, r.height,
                  options.verticalScale, options.meshStride, g->lastError)) {
        g->lastErrorCode = GraphErrorCode::exportError;
        r.ok = false;
        return r;
    }
    if (options.heightmapFormat == HeightmapFormat::r16) {
        const std::string rawPath =
            (dir / (base + rasterSuffix + ".r16")).string();
        if (!writeR16(rawPath.c_str(), values.data(), r.width, r.height,
                      writeMin, writeMax, g->lastError)) {
            g->lastErrorCode = GraphErrorCode::exportError;
            r.ok = false;
            return r;
        }
    }
    return r;
}

std::uint32_t graph_node_count(GraphHandle* g) {
    if (!g) return 0;
    return static_cast<std::uint32_t>(g->graph.nodeCount());
}

std::size_t graph_node_id(GraphHandle* g, std::uint32_t index,
                          char* out, std::size_t cap) {
    const Node* n = g ? g->graph.nodeAt(index) : nullptr;
    static const std::string empty;
    return copyOutStr(n ? n->id() : empty, out, cap);
}

std::size_t graph_node_type(GraphHandle* g, std::uint32_t index,
                            char* out, std::size_t cap) {
    const Node* n = g ? g->graph.nodeAt(index) : nullptr;
    static const std::string empty;
    return copyOutStr(n ? n->type() : empty, out, cap);
}

std::uint32_t graph_param_count(GraphHandle* g, const char* nodeId) {
    if (!g) return 0;
    return static_cast<std::uint32_t>(
        g->graph.paramCount(nodeId ? nodeId : ""));
}

std::size_t graph_param_name(GraphHandle* g, const char* nodeId,
                             std::uint32_t index, char* out, std::size_t cap) {
    std::string key;
    double value = 0.0;
    if (g) {
        (void)g->graph.paramAt(nodeId ? nodeId : "", index, key, value);
    }
    return copyOutStr(key, out, cap);
}

double graph_param_value(GraphHandle* g, const char* nodeId, const char* key,
                         double fallback) {
    if (!g) return fallback;
    return g->graph.paramValue(nodeId ? nodeId : "", key ? key : "", fallback);
}

std::uint32_t graph_node_type_input_count(const char* type) {
    auto n = createNode(type ? type : "", "__defaults__");
    return n ? static_cast<std::uint32_t>(n->inputCount()) : 0;
}

std::size_t graph_node_type_input_name(const char* type, std::uint32_t index,
                                       char* out, std::size_t cap) {
    auto node = createNode(type ? type : "", "__defaults__");
    std::string name;
    if (node) {
        const auto ports = node->inputPorts();
        if (index < ports.size()) name = ports[index].name;
    }
    return copyOutStr(name, out, cap);
}

std::size_t graph_node_type_input_kinds(const char* type, std::uint32_t index,
                                        char* out, std::size_t cap) {
    auto node = createNode(type ? type : "", "__defaults__");
    std::string kinds;
    if (node) {
        const auto ports = node->inputPorts();
        if (index < ports.size()) {
            for (FieldKind kind : ports[index].acceptedKinds) {
                if (!kinds.empty()) kinds += ",";
                kinds += fieldKindName(kind);
            }
        }
    }
    return copyOutStr(kinds, out, cap);
}

std::uint32_t graph_node_type_output_count(const char* type) {
    auto node = createNode(type ? type : "", "__defaults__");
    return node ? static_cast<std::uint32_t>(node->outputPorts().size()) : 0;
}

std::size_t graph_node_type_output_name(const char* type, std::uint32_t index,
                                        char* out, std::size_t cap) {
    auto node = createNode(type ? type : "", "__defaults__");
    std::string name;
    if (node) {
        const auto ports = node->outputPorts();
        if (index < ports.size()) name = ports[index].name;
    }
    return copyOutStr(name, out, cap);
}

std::size_t graph_node_type_output_kind(const char* type, std::uint32_t index,
                                        char* out, std::size_t cap) {
    auto node = createNode(type ? type : "", "__defaults__");
    std::string kind;
    if (node) {
        const auto ports = node->outputPorts();
        if (index < ports.size()) kind = fieldKindName(ports[index].kind);
    }
    return copyOutStr(kind, out, cap);
}

bool graph_node_type_output_is_default(const char* type, std::uint32_t index) {
    auto node = createNode(type ? type : "", "__defaults__");
    if (!node) return false;
    const auto ports = node->outputPorts();
    return index < ports.size() && ports[index].isDefault;
}

std::int32_t graph_node_type_output_inherit_input(const char* type,
                                                  std::uint32_t index) {
    auto node = createNode(type ? type : "", "__defaults__");
    if (!node) return -1;
    const auto ports = node->outputPorts();
    return index < ports.size() ? ports[index].inheritInput : -1;
}

std::size_t graph_resolved_output_kind(GraphHandle* g, const char* nodeId,
                                       const char* outputName,
                                       char* out, std::size_t cap) {
    std::string name;
    if (g) {
        FieldKind kind = FieldKind::data;
        std::string error;
        if (g->graph.resolvedOutputKind(nodeId ? nodeId : "",
                                        outputName ? outputName : "",
                                        kind, error)) {
            name = fieldKindName(kind);
        }
    }
    return copyOutStr(name, out, cap);
}

std::uint32_t graph_output_count(GraphHandle* g, const char* nodeId) {
    return g ? static_cast<std::uint32_t>(
        g->graph.outputCount(nodeId ? nodeId : "")) : 0;
}

std::size_t graph_output_name(GraphHandle* g, const char* nodeId,
                              std::uint32_t index, char* out, std::size_t cap) {
    OutputPortDescriptor descriptor;
    const bool found = g && g->graph.outputAt(nodeId ? nodeId : "", index,
                                              descriptor);
    return copyOutStr(found ? descriptor.name : std::string{}, out, cap);
}

std::size_t graph_output_kind(GraphHandle* g, const char* nodeId,
                              const char* outputName,
                              char* out, std::size_t cap) {
    return graph_resolved_output_kind(g, nodeId, outputName, out, cap);
}

bool graph_output_is_default(GraphHandle* g, const char* nodeId,
                             std::uint32_t index) {
    OutputPortDescriptor descriptor;
    return g && g->graph.outputAt(nodeId ? nodeId : "", index, descriptor) &&
           descriptor.isDefault;
}

std::uint32_t graph_default_param_count(const char* type) {
    auto n = createNode(type ? type : "", "__defaults__");
    return n ? static_cast<std::uint32_t>(n->params.values.size()) : 0;
}

std::size_t graph_default_param_name(const char* type, std::uint32_t index,
                                     char* out, std::size_t cap) {
    auto n = createNode(type ? type : "", "__defaults__");
    std::string key;
    if (n && index < n->params.values.size()) {
        auto it = n->params.values.begin();
        std::advance(it, index);
        key = it->first;
    }
    return copyOutStr(key, out, cap);
}

double graph_default_param_value(const char* type, const char* key,
                                 double fallback) {
    auto n = createNode(type ? type : "", "__defaults__");
    return n ? n->params.get(key ? key : "", fallback) : fallback;
}

std::size_t graph_last_error(GraphHandle* g, char* out, std::size_t cap) {
    static const std::string empty;
    return copyOutStr(g ? g->lastError : empty, out, cap);
}

GraphErrorCode graph_last_error_code(GraphHandle* g) {
    return g ? g->lastErrorCode : GraphErrorCode::none;
}

std::size_t node_type_list(char* out, std::size_t cap) {
    std::string joined;
    for (const auto& t : registeredNodeTypes()) {
        if (!joined.empty()) joined += ", ";
        joined += t;
    }
    return copyOutStr(joined, out, cap);
}

} // namespace theia
