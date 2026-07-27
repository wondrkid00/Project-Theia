#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

#include "Node.hpp"

namespace theia {

enum class TerrainPrimitiveFamily : std::uint32_t {
    massLine = 0,
    radialImpact = 1,
};

struct TerrainPrimitiveParamDescriptor {
    const char* name;
    double defaultValue;
    double minimum;
    double maximum;
    bool integer;
};

struct TerrainPrimitiveDescriptor {
    const char* type;
    TerrainPrimitiveFamily family;
    std::uint32_t kind;
    const TerrainPrimitiveParamDescriptor* params;
    std::size_t paramCount;
};

const TerrainPrimitiveDescriptor* terrainPrimitiveDescriptor(
    const std::string& type);
std::vector<std::string> terrainPrimitiveTypes();
std::unique_ptr<Node> createTerrainPrimitiveNode(const std::string& type,
                                                 const std::string& id);

class TerrainPrimitiveNode final : public Node {
public:
    TerrainPrimitiveNode(std::string id,
                         const TerrainPrimitiveDescriptor& descriptor);

    std::size_t inputCount() const override { return 0; }
    bool evaluate(GPUContext& ctx,
                  const std::vector<const Heightfield*>& inputs,
                  Heightfield& out, std::string& error) override;

private:
    const TerrainPrimitiveDescriptor* descriptor_;
};

} // namespace theia
