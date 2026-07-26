#pragma once
//
// Theia — public C++ API surface.
//
// IMPORTANT: everything reachable from this header must be Swift/C++-interop
// safe. Do NOT include metal-cpp or expose Metal types here — those are
// encapsulated inside the .cpp implementation. Keep this header to standard
// library types and plain structs so the Swift shell can import it cleanly.
//
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace theia {

// --- Version / capability surface -------------------------------------------

// Project version and API version for CLI, viewer, and automation callers.
// The API is stable for SwiftPM/Swift-C++ interop, but is not yet a public C ABI.
std::size_t theia_version_string(char* out, std::size_t cap);
std::uint32_t theia_api_version();
std::size_t theia_capabilities_json(char* out, std::size_t cap);

// Result of the M0 GPU smoke test: compile a tiny kernel at runtime, run it,
// and read the result back. Proves the metal-cpp + runtime-MSL + Swift/C++
// interop toolchain works end-to-end without full Xcode.
struct SmokeResult {
    bool ok = false;            // true if the kernel ran and results verified
    std::string deviceName;     // the Metal device that ran the work
    std::string error;          // populated when ok == false
    std::uint32_t count = 0;    // number of elements processed
    float first = 0.0f;         // out[0]
    float last = 0.0f;          // out[count-1]
    bool allMatch = false;      // every element equals the requested value
};

// Allocate a GPU buffer of `count` floats, fill each with `value` via a Metal
// compute kernel compiled at runtime, then verify the readback.
SmokeResult gpu_smoke_fill(std::uint32_t count, float value);

// --- Outbound-string accessors ----------------------------------------------
// std::string <-> Swift.String bridging is unavailable on the Command-Line-
// Tools toolchain, so std::string is never exposed across the interop boundary.
// Instead, callers pass a buffer and we copy a NUL-terminated C string into it.
// Returns the full length of the source string (excluding NUL), which may exceed
// `cap - 1` if truncated. Pass cap == 0 to query the required length.
std::size_t smoke_device_name(const SmokeResult& r, char* out, std::size_t cap);
std::size_t smoke_error(const SmokeResult& r, char* out, std::size_t cap);

// --- M1: Perlin fBm generation ----------------------------------------------

// Swift-safe parameters for a Perlin fBm heightfield.
struct PerlinParams {
    std::uint32_t width = 1024;
    std::uint32_t height = 1024;
    std::uint32_t seed = 1337;
    std::uint32_t octaves = 6;
    float frequency = 4.0f;     // base cells across the unit domain
    float lacunarity = 2.0f;    // frequency multiplier per octave
    float gain = 0.5f;          // amplitude multiplier per octave (persistence)
};

struct GenerateResult {
    bool ok = false;
    std::string error;          // populated when ok == false (read via accessor)
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    float minHeight = 0.0f;
    float maxHeight = 0.0f;
    double mean = 0.0;          // for verification
    double variance = 0.0;      // for verification (must be > 0 for real terrain)
};

// Generate an fBm Perlin heightfield on the GPU and write it to disk.
// pngPath (8-bit grayscale preview) and pfmPath (32-bit float, lossless) are
// each optional — pass nullptr to skip. Stats are always computed.
GenerateResult generate_perlin(const PerlinParams& p,
                               const char* pngPath, const char* pfmPath);

std::size_t generate_error(const GenerateResult& r, char* out, std::size_t cap);

// --- M2: Node graph engine (opaque-handle C-style API) ----------------------
//
// The graph engine is driven through an opaque handle so nothing non-Swift-safe
// (Metal types, std::string) crosses the interop boundary. Build a graph
// programmatically (add nodes, set params, connect) or load it from JSON, then
// evaluate a sink at a resolution. Bool-returning calls store a message
// retrievable via graph_last_error().
//
// Node types include generators ("perlin", "ridged"), unary filters/remaps
// ("scalebias", "invert", "clamp", "remap", "blur", "warp", "hydraulic",
// "dropleterosion", "erosionfilter", "river", "rivercarve", "export",
// "thermal", "terrace", "normalize", "slopemask"), and binary combiners
// ("combine", "blend").

// Opaque graph state. A handle is intentionally not internally synchronized:
// callers must serialize every load/mutation/evaluation/export operation that
// targets the same handle. Independent handles may be used concurrently.
struct GraphHandle;

GraphHandle* graph_create();
void graph_destroy(GraphHandle* g);

bool graph_add_node(GraphHandle* g, const char* id, const char* type);
bool graph_set_param(GraphHandle* g, const char* id, const char* key, double value);
bool graph_connect(GraphHandle* g, const char* fromId, const char* toId,
                   std::uint32_t inputIndex);
bool graph_connect_output(GraphHandle* g, const char* fromId,
                          const char* outputName, const char* toId,
                          std::uint32_t inputIndex);

bool graph_load_json_file(GraphHandle* g, const char* path);
bool graph_load_json_text(GraphHandle* g, const char* text);
bool graph_save_json_file(GraphHandle* g, const char* path);

// Analyze graph JSON without mutating an existing graph. Returns a diagnostic
// JSON document with { ok, summary, issues }. This is intended for CLI/viewer
// authoring feedback, not as a replacement for graph_load_json_text validation.
std::size_t graph_diagnostics_json_text(const char* text,
                                        char* out, std::size_t cap);

struct GraphEvalResult {
    bool ok = false;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    std::uint32_t evaluated = 0;   // nodes (re)computed this pass
    std::uint32_t reused = 0;      // nodes served from cache this pass
    float minHeight = 0.0f;
    float maxHeight = 0.0f;
    double mean = 0.0;
    double variance = 0.0;
};

enum class GraphErrorCode : std::uint32_t {
    none = 0,
    usage = 1,
    load = 2,
    validation = 3,
    evaluation = 4,
    exportError = 5
};

// Evaluate `sinkId` at `width` x `height`. Pass sinkId == nullptr/"" to use the
// graph's default sink, and width/height == 0 to use the graph's default
// resolution (both come from loaded JSON). Optionally writes PNG/PFM (nullptr to
// skip). The graph's cache persists across calls on the same handle, so a second
// evaluate after changing one param recomputes only the affected subgraph.
GraphEvalResult graph_evaluate(GraphHandle* g, const char* sinkId,
                               std::uint32_t width, std::uint32_t height,
                               const char* pngPath, const char* pfmPath);
GraphEvalResult graph_evaluate_output(GraphHandle* g, const char* sinkId,
                                      const char* outputName,
                                      std::uint32_t width, std::uint32_t height,
                                      const char* pngPath, const char* pfmPath);

std::size_t graph_last_error(GraphHandle* g, char* out, std::size_t cap);
GraphErrorCode graph_last_error_code(GraphHandle* g);

// Like graph_evaluate, but instead of writing image files it copies the sink's
// heightfield into `dst` (row-major float, width*height elements) when `dst` is
// non-null and `capElems >= width*height`. For the 3D viewer.
GraphEvalResult graph_evaluate_heights(GraphHandle* g, const char* sinkId,
                                       std::uint32_t width, std::uint32_t height,
                                       float* dst, std::size_t capElems);
GraphEvalResult graph_evaluate_heights_output(
    GraphHandle* g, const char* sinkId, const char* outputName,
    std::uint32_t width, std::uint32_t height,
    float* dst, std::size_t capElems);

// Canonical JSON for the optional semantic materialStack. Returns "null" when
// no stack is configured.
std::size_t graph_material_stack_json(GraphHandle* g,
                                      char* out, std::size_t cap);

// Evaluate the semantic material stack. `terrainDst` receives width*height
// floats and `weightsRGBADst` receives width*height*4 interleaved normalized
// floats when the corresponding destination and capacity are provided. Each
// requested dimension is limited to 4096 texels.
GraphEvalResult graph_evaluate_material_stack(
    GraphHandle* g, std::uint32_t width, std::uint32_t height,
    float* terrainDst, std::size_t terrainCapElems,
    float* weightsRGBADst, std::size_t weightsCapElems);

// Diagnostic/test API; application behavior must not depend on this counter.
// It increments only when normalized material weights are rebuilt, not when
// the derived-weight cache is reused.
std::uint64_t graph_material_weights_build_count(GraphHandle* g);

// Production export helper. Any path may be nullptr/"" to skip that output.
// `maskPngPath` writes the selected sink normalized over [0,1], intended for
// mask nodes. `objPath` writes a one-sided +Y-up terrain mesh.
GraphEvalResult graph_export(GraphHandle* g, const char* sinkId,
                             std::uint32_t width, std::uint32_t height,
                             const char* heightPngPath,
                             const char* pfmPath,
                             const char* normalPngPath,
                             const char* slopePngPath,
                             const char* maskPngPath,
                             const char* objPath,
                             float verticalScale,
                             std::uint32_t meshStride);

enum class HeightmapFormat : std::uint32_t {
    none = 0,
    png16 = 1,
    r16 = 2,
    pfm32 = 3
};

enum class MeshFormat : std::uint32_t {
    none = 0,
    obj = 1
};

struct GraphExportOptions {
    const char* sinkId = nullptr;
    const char* outputName = nullptr;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    const char* outDir = nullptr;
    const char* basename = nullptr;
    HeightmapFormat heightmapFormat = HeightmapFormat::png16;
    MeshFormat meshFormat = MeshFormat::obj;
    float verticalScale = 1.0f;
    std::uint32_t meshStride = 1;
};

struct GraphMaterialExportOptions {
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    const char* outDir = nullptr;
    const char* basename = nullptr;
    HeightmapFormat heightmapFormat = HeightmapFormat::png16;
    MeshFormat meshFormat = MeshFormat::obj;
    float verticalScale = 1.0f;
    std::uint32_t meshStride = 1;
};

// Structured export helper. Writes engine-facing scalar and mesh outputs.
// Legacy/default output filenames keep `_height`; an explicit non-height
// output uses `_<outputName>`. R16 is little-endian unsigned 16-bit.
//   obj   -> <basename>.obj
// OBJ is valid only when the selected output resolves to terrain.
GraphEvalResult graph_export2(GraphHandle* g, const GraphExportOptions& options);

// Transactional material bundle export. Writes the stack terrain artifact(s),
// `<basename>_weights.png`, and `<basename>_material.json`. Each requested
// dimension is limited to 4096 texels.
GraphEvalResult graph_export_material_bundle(
    GraphHandle* g, const GraphMaterialExportOptions& options);

// Node/parameter enumeration for the viewer inspector. Strings use the same
// copy-into-caller-buffer convention as the other Swift-facing accessors.
std::uint32_t graph_node_count(GraphHandle* g);
std::size_t graph_node_id(GraphHandle* g, std::uint32_t index,
                          char* out, std::size_t cap);
std::size_t graph_node_type(GraphHandle* g, std::uint32_t index,
                            char* out, std::size_t cap);
std::uint32_t graph_param_count(GraphHandle* g, const char* nodeId);
std::size_t graph_param_name(GraphHandle* g, const char* nodeId,
                             std::uint32_t index, char* out, std::size_t cap);
double graph_param_value(GraphHandle* g, const char* nodeId, const char* key,
                         double fallback);
std::uint32_t graph_node_type_input_count(const char* type);
std::size_t graph_node_type_input_name(const char* type, std::uint32_t index,
                                       char* out, std::size_t cap);
std::size_t graph_node_type_input_kinds(const char* type, std::uint32_t index,
                                        char* out, std::size_t cap);
std::uint32_t graph_node_type_output_count(const char* type);
std::size_t graph_node_type_output_name(const char* type, std::uint32_t index,
                                        char* out, std::size_t cap);
std::size_t graph_node_type_output_kind(const char* type, std::uint32_t index,
                                        char* out, std::size_t cap);
bool graph_node_type_output_is_default(const char* type, std::uint32_t index);
std::int32_t graph_node_type_output_inherit_input(const char* type,
                                                  std::uint32_t index);
std::size_t graph_resolved_output_kind(GraphHandle* g, const char* nodeId,
                                       const char* outputName,
                                       char* out, std::size_t cap);
std::uint32_t graph_output_count(GraphHandle* g, const char* nodeId);
std::size_t graph_output_name(GraphHandle* g, const char* nodeId,
                              std::uint32_t index, char* out, std::size_t cap);
std::size_t graph_output_kind(GraphHandle* g, const char* nodeId,
                              const char* outputName,
                              char* out, std::size_t cap);
bool graph_output_is_default(GraphHandle* g, const char* nodeId,
                             std::uint32_t index);
std::uint32_t graph_default_param_count(const char* type);
std::size_t graph_default_param_name(const char* type, std::uint32_t index,
                                     char* out, std::size_t cap);
double graph_default_param_value(const char* type, const char* key,
                                 double fallback);

// Comma-separated list of registered node type names (for CLI/help).
std::size_t node_type_list(char* out, std::size_t cap);

} // namespace theia
