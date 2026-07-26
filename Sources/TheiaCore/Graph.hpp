#pragma once
//
// Graph — a DAG of nodes evaluated demand-driven from a sink, with
// content-hash memoization (a node recomputes only when its own params or any
// upstream output's hash changes). PRIVATE header.
//
#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "Node.hpp"

namespace theia {

class GPUContext;
class Heightfield;

struct EvalStats {
    std::uint32_t evaluated = 0;  // nodes (re)computed this pass
    std::uint32_t reused = 0;     // nodes served from cache this pass
};

class Graph {
public:
    Graph();
    ~Graph();

    Graph(const Graph&) = delete;
    Graph& operator=(const Graph&) = delete;

    // Add a node of `type` with unique `id`. Returns nullptr + sets error on
    // duplicate id or unknown type.
    Node* addNode(const std::string& id, const std::string& type, std::string& error);
    Node* node(const std::string& id);

    bool setParam(const std::string& id, const std::string& key, double value,
                  std::string& error);

    // Connect fromId's output to toId's input port `inputIndex`.
    bool connect(const std::string& fromId, const std::string& toId,
                 std::uint32_t inputIndex, std::string& error);
    bool connect(const std::string& fromId, const std::string& outputName,
                 const std::string& toId, std::uint32_t inputIndex,
                 std::string& error);

    // Demand-driven evaluation of `sinkId` at resolution w x h. Returns the
    // sink's cached output (owned by the graph) or nullptr + error. `stats`
    // reports how many nodes were recomputed vs reused.
    const Heightfield* evaluate(GPUContext& ctx, const std::string& sinkId,
                                std::uint32_t w, std::uint32_t h,
                                EvalStats& stats, std::string& error);
    const Heightfield* evaluate(GPUContext& ctx, const std::string& sinkId,
                                const std::string& outputName,
                                std::uint32_t w, std::uint32_t h,
                                EvalStats& stats, std::string& error);

    // Serialization. fromJSON replaces all current contents.
    std::string toJSON() const;
    bool fromJSON(const std::string& text, std::string& error);

    const std::string& defaultSink() const { return defaultSink_; }
    const std::string& defaultSinkOutput() const { return defaultSinkOutput_; }
    std::uint32_t defaultWidth() const { return defaultWidth_; }
    std::uint32_t defaultHeight() const { return defaultHeight_; }
    void setDefaults(const std::string& sink, std::uint32_t w, std::uint32_t h,
                     const std::string& sinkOutput = {});

    std::size_t nodeCount() const;
    const Node* nodeAt(std::size_t index) const;
    std::size_t paramCount(const std::string& id) const;
    bool paramAt(const std::string& id, std::size_t index,
                 std::string& key, double& value) const;
    double paramValue(const std::string& id, const std::string& key,
                      double fallback) const;
    std::size_t outputCount(const std::string& id) const;
    bool outputAt(const std::string& id, std::size_t index,
                  OutputPortDescriptor& descriptor) const;
    bool resolvedOutputKind(const std::string& id, const std::string& outputName,
                            FieldKind& kind, std::string& error) const;

private:
    // Post-order DFS from `sinkId` over connected inputs => topological order
    // (dependencies first). Detects cycles and missing nodes.
    bool topoOrder(const std::string& sinkId, std::vector<std::string>& order,
                   std::string& error) const;
    bool validateSink(const std::string& sinkId, std::string& error) const;

    struct SourceRef {
        std::string node;
        std::string output;
    };

    bool resolvedOutputKind(const std::string& id, const std::string& outputName,
                            FieldKind& kind, std::map<std::string, int>& visiting,
                            std::string& error) const;
    bool outputIndex(const Node& node, const std::string& outputName,
                     std::size_t& index, std::string& error) const;
    std::string defaultOutputName(const Node& node) const;

    struct CacheEntry {
        std::uint64_t key = 0;
        std::vector<std::unique_ptr<Heightfield>> outputs;
        std::vector<std::uint64_t> outputKeys;
        std::vector<FieldKind> outputKinds;
    };

    struct MaskEraseStroke {
        double x = 0.0;
        double y = 0.0;
        double radius = 0.0;
        double strength = 1.0;
    };

    std::uint64_t maskEditSignature(const std::string& id,
                                    const std::string& output) const;
    void applyMaskEdits(const std::string& id, const std::string& outputName,
                        Heightfield& output) const;

    std::map<std::string, std::unique_ptr<Node>> nodes_;
    std::map<std::string, std::vector<SourceRef>> inputs_;  // id -> src per port
    std::map<std::string, CacheEntry> cache_;
    std::map<std::string,
             std::map<std::string, std::vector<MaskEraseStroke>>> maskErases_;
    std::string uiMetadataJSON_;

    std::string defaultSink_;
    std::string defaultSinkOutput_;
    std::uint32_t defaultWidth_ = 1024;
    std::uint32_t defaultHeight_ = 1024;
};

} // namespace theia
