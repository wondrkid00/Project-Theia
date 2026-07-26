#pragma once
//
// Node — base class for graph nodes. A node has an id, a type string, a set of
// scalar parameters, some number of heightfield inputs, and produces one
// heightfield output. PRIVATE header (uses Heightfield/GPUContext internally).
//
#include <cstddef>
#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace theia {

class GPUContext;
class Heightfield;

enum class FieldKind : std::uint32_t {
    terrain = 0,
    mask = 1,
    data = 2,
};

const char* fieldKindName(FieldKind kind);

struct InputPortDescriptor {
    std::string name;
    std::vector<FieldKind> acceptedKinds;
};

struct OutputPortDescriptor {
    std::string name;
    FieldKind kind = FieldKind::data;
    // Generic transforms use the resolved kind of one input while retaining a
    // concrete fallback kind for type catalog introspection.
    int inheritInput = -1;
    bool isDefault = false;
};

// All node parameters are scalars stored as double (cast as needed by nodes).
// Ordered map => deterministic iteration for hashing/serialization.
struct ParamSet {
    std::map<std::string, double> values;

    double get(const std::string& key, double fallback) const {
        auto it = values.find(key);
        return it == values.end() ? fallback : it->second;
    }
    void set(const std::string& key, double v) { values[key] = v; }
};

class Node {
public:
    Node(std::string id, std::string type)
        : id_(std::move(id)), type_(std::move(type)) {}
    virtual ~Node() = default;

    const std::string& id() const { return id_; }
    const std::string& type() const { return type_; }

    ParamSet params;

    // Number of heightfield inputs this node consumes (0 for generators).
    virtual std::size_t inputCount() const = 0;

    // Stable named port descriptors. Existing nodes use the centralized
    // defaults in Node.cpp; multi-output nodes can override as needed.
    virtual std::vector<InputPortDescriptor> inputPorts() const;
    virtual std::vector<OutputPortDescriptor> outputPorts() const;

    // Produce this node's output into `out` (already allocated at the graph
    // resolution). `inputs` holds inputCount() resolved upstream heightfields.
    virtual bool evaluate(GPUContext& ctx,
                          const std::vector<const Heightfield*>& inputs,
                          Heightfield& out, std::string& error) = 0;

    // Atomic multi-output adapter. The default keeps every legacy node source
    // compatible by evaluating its first/default output only.
    virtual bool evaluateOutputs(GPUContext& ctx,
                                 const std::vector<const Heightfield*>& inputs,
                                 const std::vector<Heightfield*>& outputs,
                                 std::string& error);

    // Content hash of type + parameters. Basis for incremental cache keys: if a
    // param changes, this changes, which changes the node's (and descendants')
    // cache key, triggering recomputation. (Salsa/rustc-query-style memoization.)
    std::uint64_t signature() const;

private:
    std::string id_;
    std::string type_;
};

// Factory: construct a node of `type` with the given `id`, or nullptr if the
// type is unknown.
std::unique_ptr<Node> createNode(const std::string& type, const std::string& id);

// All registered node type names (for diagnostics / validation).
std::vector<std::string> registeredNodeTypes();

} // namespace theia
