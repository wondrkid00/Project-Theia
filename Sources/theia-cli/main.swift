// Theia CLI: thin Swift shell over the C++ core through Swift/C++ interop.

import Foundation
import TheiaCore

private struct GlobalOptions {
    var json = false
    var quiet = false
    var noColor = false
    var verbose = false
    var help = false
    var version = false
}

private enum CLIError: Error {
    case usage(String)
    case runtime(String)
}

private func readCxxString(
    _ accessor: (UnsafeMutablePointer<CChar>?, Int) -> Int
) -> String {
    var buf = [CChar](repeating: 0, count: 1024)
    let n = buf.withUnsafeMutableBufferPointer { accessor($0.baseAddress, $0.count) }
    let len = min(max(n, 0), buf.count - 1)
    return String(decoding: buf[0..<len].map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private func readCxxLongString(
    _ accessor: (UnsafeMutablePointer<CChar>?, Int) -> Int
) -> String {
    var cap = 4096
    while true {
        var buf = [CChar](repeating: 0, count: cap)
        let n = buf.withUnsafeMutableBufferPointer { accessor($0.baseAddress, $0.count) }
        if n < cap {
            let len = max(n, 0)
            return String(decoding: buf[0..<len].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        cap = max(cap * 2, n + 1)
    }
}

private func theiaVersion() -> String {
    readCxxString { theia.theia_version_string($0, $1) }
}

private func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func emitJSON(_ object: Any) {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
          ),
          let text = String(data: data, encoding: .utf8) else {
        print("{}")
        return
    }
    print(text)
}

private func emitJSONText(_ text: String) {
    if let data = text.data(using: .utf8),
       (try? JSONSerialization.jsonObject(with: data)) != nil {
        print(text)
    } else {
        emitJSON(["ok": false, "error": ["message": "invalid JSON text"]])
    }
}

private func statsObject(_ r: theia.GraphEvalResult) -> [String: Any] {
    [
        "ok": r.ok,
        "width": Int(r.width),
        "height": Int(r.height),
        "evaluated": Int(r.evaluated),
        "reused": Int(r.reused),
        "minHeight": Double(r.minHeight),
        "maxHeight": Double(r.maxHeight),
        "mean": Double(r.mean),
        "variance": Double(r.variance),
    ]
}

private func usage() -> String {
    """
    theia-cli 0.12.0-alpha.1

    USAGE:
      theia-cli [--json] [--quiet] [--no-color] [--verbose] COMMAND [ARGS]

    COMMANDS:
      version                         Print CLI/core version.
      doctor                          Check core capabilities and Metal smoke test.
      nodes [--json]                  List registered node types.
      diagnose GRAPH.json [--sink ID] Analyze graph health.
      run GRAPH.json [--sink ID] [--output NAME] [--size N] [--out PATH]
                                      Evaluate a graph to PNG16 + PFM.
      export GRAPH.json [--sink ID] [--output NAME] [--size N] [--out-dir DIR]
             [--basename NAME] [--heightmap png16|r16|pfm32|none]
             [--mesh obj|none] [--vertical-scale V] [--mesh-stride S]
                                      Export engine-ready heightmap and mesh.
      export-material GRAPH.json [--size N] [--out-dir DIR] [--basename NAME]
             [--heightmap png16|r16|pfm32|none] [--mesh obj|none]
             [--vertical-scale V] [--mesh-stride S]
                                      Export material weights + manifest bundle.
      smoke [count] [value]           Run the Metal smoke test.
      demo [--size N] [--out PATH] [--seed S]
                                      Generate standalone Perlin terrain.

    LEGACY:
      export still accepts --maps height,pfm,normal,slope,mask as a temporary
      alias for the Phase 6 multi-map exporter.
    """
}

private func splitGlobalArgs(_ raw: [String]) -> (GlobalOptions, [String]) {
    var options = GlobalOptions()
    var commandArgs: [String] = []
    for arg in raw {
        switch arg {
        case "--json":
            options.json = true
        case "--quiet":
            options.quiet = true
        case "--no-color":
            options.noColor = true
        case "--verbose":
            options.verbose = true
        case "-h", "--help":
            options.help = true
        case "--version":
            options.version = true
        default:
            commandArgs.append(arg)
        }
    }
    return (options, commandArgs)
}

private func requireValue(_ args: [String], _ index: Int, _ flag: String) throws -> String {
    guard index + 1 < args.count else {
        throw CLIError.usage("\(flag) requires a value")
    }
    let value = args[index + 1]
    guard !value.hasPrefix("--") else {
        throw CLIError.usage("\(flag) requires a value")
    }
    return value
}

private func parseUInt32(_ text: String, flag: String, min: UInt32 = 0) throws -> UInt32 {
    guard let value = UInt32(text), value >= min else {
        throw CLIError.usage("\(flag) must be an integer >= \(min)")
    }
    return value
}

private func parseFloat(_ text: String, flag: String, minExclusive: Float? = nil) throws -> Float {
    guard let value = Float(text), value.isFinite else {
        throw CLIError.usage("\(flag) must be a finite number")
    }
    if let minExclusive, !(value > minExclusive) {
        throw CLIError.usage("\(flag) must be > \(minExclusive)")
    }
    return value
}

private func loadGraph(path: String) throws -> OpaquePointer {
    guard let g = theia.graph_create() else {
        throw CLIError.runtime("failed to create graph")
    }
    guard theia.graph_load_json_file(g, path) else {
        let err = readCxxString { theia.graph_last_error(g, $0, $1) }
        theia.graph_destroy(g)
        throw CLIError.runtime("failed to load \(path): \(err)")
    }
    return g
}

private func capabilitiesObject() -> [String: Any] {
    let text = readCxxLongString { theia.theia_capabilities_json($0, $1) }
    guard let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let dict = object as? [String: Any] else {
        return [:]
    }
    return dict
}

private func nodeCatalog() -> [[String: Any]] {
    let types = readCxxString { theia.node_type_list($0, $1) }
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

    return types.map { type in
        let inputCount = theia.graph_node_type_input_count(type)
        let inputs: [[String: Any]] = (0..<inputCount).map { index in
            let name = readCxxString {
                theia.graph_node_type_input_name(type, index, $0, $1)
            }
            let kinds = readCxxString {
                theia.graph_node_type_input_kinds(type, index, $0, $1)
            }.split(separator: ",").map(String.init)
            return ["name": name, "kinds": kinds]
        }
        let outputCount = theia.graph_node_type_output_count(type)
        let outputs: [[String: Any]] = (0..<outputCount).map { index in
            let name = readCxxString {
                theia.graph_node_type_output_name(type, index, $0, $1)
            }
            let kind = readCxxString {
                theia.graph_node_type_output_kind(type, index, $0, $1)
            }
            let inheritInput = theia.graph_node_type_output_inherit_input(type, index)
            var output: [String: Any] = [
                "name": name,
                "kind": kind,
                "default": theia.graph_node_type_output_is_default(type, index),
            ]
            if inheritInput >= 0 { output["inheritsInput"] = Int(inheritInput) }
            return output
        }
        let count = theia.graph_default_param_count(type)
        let params: [[String: Any]] = (0..<count).map { index in
            let name = readCxxString {
                theia.graph_default_param_name(type, index, $0, $1)
            }
            let value = theia.graph_default_param_value(type, name, 0.0)
            return ["name": name, "default": value]
        }
        return [
            "type": type,
            "inputCount": Int(inputCount),
            "inputs": inputs,
            "outputs": outputs,
            "defaultParams": params,
        ]
    }
}

private func printNodeCatalog(json: Bool, quiet: Bool) {
    let catalog = nodeCatalog()
    if json {
        emitJSON(["nodes": catalog])
        return
    }
    guard !quiet else { return }
    print("Available node types")
    for item in catalog {
        let type = item["type"] as? String ?? ""
        let inputs = item["inputCount"] as? Int ?? 0
        let outputs = item["outputs"] as? [[String: Any]] ?? []
        let outputNames = outputs.compactMap { $0["name"] as? String }.joined(separator: ",")
        let params = item["defaultParams"] as? [[String: Any]] ?? []
        let names = params.compactMap { $0["name"] as? String }.joined(separator: ", ")
        print("  \(type)  inputs=\(inputs)  outputs=\(outputNames)\(names.isEmpty ? "" : "  params=\(names)")")
    }
}

private func commandVersion(options: GlobalOptions) -> Int32 {
    let version = theiaVersion()
    let apiVersion = Int(theia.theia_api_version())
    if options.json {
        emitJSON([
            "version": version,
            "apiVersion": apiVersion,
            "capabilities": capabilitiesObject(),
        ])
    } else if !options.quiet {
        print("Theia \(version)")
        print("API \(apiVersion)")
    }
    return 0
}

private func commandDoctor(options: GlobalOptions) -> Int32 {
    let smoke = theia.gpu_smoke_fill(16, 1.0)
    let device = readCxxString { theia.smoke_device_name(smoke, $0, $1) }
    let error = readCxxString { theia.smoke_error(smoke, $0, $1) }
    if options.json {
        emitJSON([
            "ok": smoke.ok,
            "version": theiaVersion(),
            "apiVersion": Int(theia.theia_api_version()),
            "device": device,
            "metalSmoke": [
                "ok": smoke.ok,
                "count": Int(smoke.count),
                "allMatch": smoke.allMatch,
                "error": error,
            ],
            "capabilities": capabilitiesObject(),
        ])
    } else if !options.quiet {
        print("Theia doctor")
        print("  version: \(theiaVersion())")
        print("  api:     \(theia.theia_api_version())")
        print("  device:  \(device.isEmpty ? "<none>" : device)")
        print("  metal:   \(smoke.ok ? "ok" : "failed")")
        if !smoke.ok { print("  error:   \(error)") }
    }
    return smoke.ok ? 0 : 1
}

private func commandSmoke(args: [String], options: GlobalOptions) throws -> Int32 {
    var count: UInt32 = 1024
    var value: Float = 42.0
    if args.count > 2 {
        throw CLIError.usage("usage: theia-cli smoke [count] [value]")
    }
    if args.count >= 1 {
        count = try parseUInt32(args[0], flag: "count")
    }
    if args.count == 2 {
        value = try parseFloat(args[1], flag: "value")
    }
    let r = theia.gpu_smoke_fill(count, value)
    let device = readCxxString { theia.smoke_device_name(r, $0, $1) }
    let err = readCxxString { theia.smoke_error(r, $0, $1) }
    if options.json {
        emitJSON([
            "ok": r.ok,
            "device": device,
            "count": Int(r.count),
            "value": value,
            "first": r.first,
            "last": r.last,
            "allMatch": r.allMatch,
            "error": err,
        ])
    } else if !options.quiet {
        print(r.ok ? "GPU smoke test passed" : "GPU smoke test failed")
        print("  device: \(device.isEmpty ? "<none>" : device)")
        print("  count:  \(r.count)")
        print("  value:  \(value)")
        if !r.ok { print("  error:  \(err)") }
    }
    return r.ok ? 0 : 1
}

private func commandDemo(args: [String], options: GlobalOptions) throws -> Int32 {
    var size: UInt32 = 1024
    var out = "terrain.png"
    var seed: UInt32 = 1337
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--size":
            size = try parseUInt32(try requireValue(args, i, "--size"), flag: "--size", min: 2)
            i += 2
        case "--out":
            out = try requireValue(args, i, "--out")
            i += 2
        case "--seed":
            seed = try parseUInt32(try requireValue(args, i, "--seed"), flag: "--seed")
            i += 2
        default:
            throw CLIError.usage("unknown option for demo: \(args[i])")
        }
    }

    var params = theia.PerlinParams()
    params.width = size
    params.height = size
    params.seed = seed
    let pfm = out.hasSuffix(".png") ? String(out.dropLast(4)) + ".pfm" : out + ".pfm"
    let r = theia.generate_perlin(params, out, pfm)
    let err = readCxxString { theia.generate_error(r, $0, $1) }
    if options.json {
        emitJSON([
            "ok": r.ok,
            "stats": [
                "width": Int(r.width),
                "height": Int(r.height),
                "minHeight": Double(r.minHeight),
                "maxHeight": Double(r.maxHeight),
                "mean": Double(r.mean),
                "variance": Double(r.variance),
            ],
            "paths": ["png": out, "pfm": pfm],
            "error": err,
        ])
    } else if !options.quiet {
        print(r.ok ? "Generated \(r.width)x\(r.height) Perlin terrain" : "Generation failed")
        if r.ok {
            print("  height range: [\(r.minHeight), \(r.maxHeight)]")
            print("  PNG: \(out)")
            print("  PFM: \(pfm)")
        } else {
            print("  error: \(err)")
        }
    }
    return r.ok ? 0 : 1
}

private func commandRun(args: [String], options: GlobalOptions) throws -> Int32 {
    guard let path = args.first, !path.hasPrefix("--") else {
        throw CLIError.usage("usage: theia-cli run GRAPH.json [--sink ID] [--output NAME] [--size N] [--out PATH]")
    }
    var sink = ""
    var output = ""
    var size: UInt32 = 0
    var out = "terrain.png"
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--sink":
            sink = try requireValue(args, i, "--sink")
            i += 2
        case "--output":
            output = try requireValue(args, i, "--output")
            i += 2
        case "--size":
            size = try parseUInt32(try requireValue(args, i, "--size"), flag: "--size")
            i += 2
        case "--out":
            out = try requireValue(args, i, "--out")
            i += 2
        default:
            throw CLIError.usage("unknown option for run: \(args[i])")
        }
    }

    let pfm = out.hasSuffix(".png") ? String(out.dropLast(4)) + ".pfm" : out + ".pfm"
    let g = try loadGraph(path: path)
    defer { theia.graph_destroy(g) }
    let r = theia.graph_evaluate_output(g, sink, output, size, size, out, pfm)
    let err = readCxxString { theia.graph_last_error(g, $0, $1) }
    if options.json {
        emitJSON([
            "ok": r.ok,
            "graph": path,
            "sink": sink.isEmpty ? NSNull() : sink,
            "output": output.isEmpty ? NSNull() : output,
            "stats": statsObject(r),
            "paths": ["png": out, "pfm": pfm],
            "error": err,
        ])
    } else if !options.quiet {
        print(r.ok ? "Evaluated graph \(path)" : "Evaluation failed")
        if r.ok {
            print("  resolution: \(r.width)x\(r.height)")
            print("  nodes run:  \(r.evaluated) (reused \(r.reused))")
            print("  range:      [\(r.minHeight), \(r.maxHeight)]")
            print("  PNG:        \(out)")
            print("  PFM:        \(pfm)")
        } else {
            print("  error: \(err)")
        }
    }
    return r.ok ? 0 : 1
}

private func graphExport2(
    graph: OpaquePointer,
    sink: String,
    output: String,
    size: UInt32,
    outDir: String,
    basename: String,
    heightmap: String,
    mesh: String,
    verticalScale: Float,
    meshStride: UInt32
) -> theia.GraphEvalResult {
    func heightFormat(_ value: String) -> theia.HeightmapFormat {
        switch value {
        case "none": return theia.HeightmapFormat.none
        case "png16": return theia.HeightmapFormat.png16
        case "r16": return theia.HeightmapFormat.r16
        case "pfm32": return theia.HeightmapFormat.pfm32
        default: return theia.HeightmapFormat.none
        }
    }
    func meshFormat(_ value: String) -> theia.MeshFormat {
        switch value {
        case "none": return theia.MeshFormat.none
        case "obj": return theia.MeshFormat.obj
        default: return theia.MeshFormat.none
        }
    }
    return outDir.withCString { outPtr in
        basename.withCString { basePtr in
            func makeOptions(sinkPtr: UnsafePointer<CChar>?,
                             outputPtr: UnsafePointer<CChar>?) -> theia.GraphExportOptions {
                var opts = theia.GraphExportOptions()
                opts.sinkId = sinkPtr
                opts.outputName = outputPtr
                opts.width = size
                opts.height = size
                opts.outDir = outPtr
                opts.basename = basePtr
                opts.heightmapFormat = heightFormat(heightmap)
                opts.meshFormat = meshFormat(mesh)
                opts.verticalScale = verticalScale
                opts.meshStride = meshStride
                return opts
            }
            if sink.isEmpty && output.isEmpty {
                return theia.graph_export2(graph, makeOptions(sinkPtr: nil, outputPtr: nil))
            }
            if sink.isEmpty {
                return output.withCString { outputPtr in
                    theia.graph_export2(graph, makeOptions(sinkPtr: nil, outputPtr: outputPtr))
                }
            }
            if output.isEmpty {
                return sink.withCString { sinkPtr in
                    theia.graph_export2(graph, makeOptions(sinkPtr: sinkPtr, outputPtr: nil))
                }
            }
            return sink.withCString { sinkPtr in
                output.withCString { outputPtr in
                    theia.graph_export2(graph, makeOptions(sinkPtr: sinkPtr,
                                                            outputPtr: outputPtr))
                }
            }
        }
    }
}

private func commandExport(args: [String], options: GlobalOptions) throws -> Int32 {
    guard let path = args.first, !path.hasPrefix("--") else {
        throw CLIError.usage("usage: theia-cli export GRAPH.json [--heightmap png16|r16|pfm32|none] [--mesh obj|none]")
    }
    var sink = ""
    var output = ""
    var size: UInt32 = 1024
    var outDir = "."
    var basename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    var heightmap = "png16"
    var mesh = "obj"
    var legacyMaps: Set<String>?
    var verticalScale: Float = 1.0
    var meshStride: UInt32 = 1

    var i = 1
    while i < args.count {
        switch args[i] {
        case "--sink":
            sink = try requireValue(args, i, "--sink")
            i += 2
        case "--output":
            output = try requireValue(args, i, "--output")
            i += 2
        case "--size":
            size = try parseUInt32(try requireValue(args, i, "--size"), flag: "--size", min: 2)
            i += 2
        case "--out-dir":
            outDir = try requireValue(args, i, "--out-dir")
            i += 2
        case "--basename":
            basename = try requireValue(args, i, "--basename")
            i += 2
        case "--heightmap":
            heightmap = try requireValue(args, i, "--heightmap")
            guard ["png16", "r16", "pfm32", "none"].contains(heightmap) else {
                throw CLIError.usage("--heightmap must be png16, r16, pfm32, or none")
            }
            i += 2
        case "--mesh":
            mesh = try requireValue(args, i, "--mesh")
            guard ["obj", "none"].contains(mesh) else {
                throw CLIError.usage("--mesh must be obj or none")
            }
            i += 2
        case "--maps":
            let value = try requireValue(args, i, "--maps")
            legacyMaps = Set(value.split(separator: ",").map(String.init))
            i += 2
        case "--vertical-scale":
            verticalScale = try parseFloat(
                try requireValue(args, i, "--vertical-scale"),
                flag: "--vertical-scale",
                minExclusive: 0
            )
            i += 2
        case "--mesh-stride":
            meshStride = try parseUInt32(
                try requireValue(args, i, "--mesh-stride"),
                flag: "--mesh-stride",
                min: 1
            )
            i += 2
        default:
            throw CLIError.usage("unknown option for export: \(args[i])")
        }
    }

    if heightmap == "none" && mesh == "none" && legacyMaps == nil {
        throw CLIError.usage("choose at least one export output")
    }
    if legacyMaps != nil && !output.isEmpty {
        throw CLIError.usage("--output cannot be combined with legacy --maps")
    }

    let g = try loadGraph(path: path)
    defer { theia.graph_destroy(g) }

    let dirURL = URL(fileURLWithPath: outDir)
    func file(_ suffix: String) -> String {
        dirURL.appendingPathComponent("\(basename)\(suffix)").path
    }

    let r: theia.GraphEvalResult
    var paths: [String: String] = [:]
    if let legacyMaps {
        let knownMaps: Set<String> = ["height", "pfm", "normal", "slope", "mask"]
        let unknown = legacyMaps.subtracting(knownMaps)
        guard unknown.isEmpty else {
            throw CLIError.usage("unknown map(s): \(unknown.sorted().joined(separator: ","))")
        }
        let height = legacyMaps.contains("height") ? file("_height.png") : ""
        let pfm = legacyMaps.contains("pfm") ? file(".pfm") : ""
        let normal = legacyMaps.contains("normal") ? file("_normal.png") : ""
        let slope = legacyMaps.contains("slope") ? file("_slope.png") : ""
        let mask = legacyMaps.contains("mask") ? file("_mask.png") : ""
        let obj = mesh == "obj" ? file(".obj") : ""
        r = theia.graph_export(g, sink, size, size, height, pfm, normal, slope, mask, obj,
                               verticalScale, meshStride)
        if !height.isEmpty { paths["height"] = height }
        if !pfm.isEmpty { paths["pfm"] = pfm }
        if !normal.isEmpty { paths["normal"] = normal }
        if !slope.isEmpty { paths["slope"] = slope }
        if !mask.isEmpty { paths["mask"] = mask }
        if !obj.isEmpty { paths["obj"] = obj }
    } else {
        r = graphExport2(graph: g, sink: sink, output: output,
                         size: size, outDir: outDir,
                         basename: basename, heightmap: heightmap, mesh: mesh,
                         verticalScale: verticalScale, meshStride: meshStride)
        let suffix = output.isEmpty || output == "height" ? "_height" : "_\(output)"
        switch heightmap {
        case "png16": paths["heightmap"] = file("\(suffix).png")
        case "r16": paths["heightmap"] = file("\(suffix).r16")
        case "pfm32": paths["heightmap"] = output.isEmpty || output == "height"
            ? file(".pfm") : file("\(suffix).pfm")
        default: break
        }
        if mesh == "obj" { paths["mesh"] = file(".obj") }
    }

    let err = readCxxString { theia.graph_last_error(g, $0, $1) }
    if options.json {
        emitJSON([
            "ok": r.ok,
            "graph": path,
            "sink": sink.isEmpty ? NSNull() : sink,
            "output": output.isEmpty ? NSNull() : output,
            "stats": statsObject(r),
            "paths": paths,
            "error": err,
        ])
    } else if !options.quiet {
        print(r.ok ? "Exported graph \(path)" : "Export failed")
        if r.ok {
            print("  resolution: \(r.width)x\(r.height)")
            print("  sink:       \(sink.isEmpty ? "<default>" : sink)")
            print("  range:      [\(r.minHeight), \(r.maxHeight)]")
            for key in paths.keys.sorted() {
                print("  \(key): \(paths[key] ?? "")")
            }
        } else {
            print("  error: \(err)")
        }
    }
    return r.ok ? 0 : 1
}

private func graphExportMaterial(
    graph: OpaquePointer,
    size: UInt32,
    outDir: String,
    basename: String,
    heightmap: String,
    mesh: String,
    verticalScale: Float,
    meshStride: UInt32
) -> theia.GraphEvalResult {
    func heightFormat(_ value: String) -> theia.HeightmapFormat {
        switch value {
        case "none": return theia.HeightmapFormat.none
        case "png16": return theia.HeightmapFormat.png16
        case "r16": return theia.HeightmapFormat.r16
        case "pfm32": return theia.HeightmapFormat.pfm32
        default: return theia.HeightmapFormat.none
        }
    }
    func meshFormat(_ value: String) -> theia.MeshFormat {
        value == "obj" ? theia.MeshFormat.obj : theia.MeshFormat.none
    }
    return outDir.withCString { outPtr in
        basename.withCString { basePtr in
            var options = theia.GraphMaterialExportOptions()
            options.width = size
            options.height = size
            options.outDir = outPtr
            options.basename = basePtr
            options.heightmapFormat = heightFormat(heightmap)
            options.meshFormat = meshFormat(mesh)
            options.verticalScale = verticalScale
            options.meshStride = meshStride
            return theia.graph_export_material_bundle(graph, options)
        }
    }
}

private func commandExportMaterial(args: [String], options: GlobalOptions) throws -> Int32 {
    guard let path = args.first, !path.hasPrefix("--") else {
        throw CLIError.usage(
            "usage: theia-cli export-material GRAPH.json [--heightmap png16|r16|pfm32|none] [--mesh obj|none]"
        )
    }
    var size: UInt32 = 1024
    var outDir = "."
    var basename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    var heightmap = "png16"
    var mesh = "obj"
    var verticalScale: Float = 1.0
    var meshStride: UInt32 = 1
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--size":
            size = try parseUInt32(try requireValue(args, i, "--size"),
                                   flag: "--size", min: 2)
            i += 2
        case "--out-dir":
            outDir = try requireValue(args, i, "--out-dir")
            i += 2
        case "--basename":
            basename = try requireValue(args, i, "--basename")
            i += 2
        case "--heightmap":
            heightmap = try requireValue(args, i, "--heightmap")
            guard ["png16", "r16", "pfm32", "none"].contains(heightmap) else {
                throw CLIError.usage("--heightmap must be png16, r16, pfm32, or none")
            }
            i += 2
        case "--mesh":
            mesh = try requireValue(args, i, "--mesh")
            guard ["obj", "none"].contains(mesh) else {
                throw CLIError.usage("--mesh must be obj or none")
            }
            i += 2
        case "--vertical-scale":
            verticalScale = try parseFloat(
                try requireValue(args, i, "--vertical-scale"),
                flag: "--vertical-scale", minExclusive: 0
            )
            i += 2
        case "--mesh-stride":
            meshStride = try parseUInt32(
                try requireValue(args, i, "--mesh-stride"),
                flag: "--mesh-stride", min: 1
            )
            i += 2
        default:
            throw CLIError.usage("unknown option for export-material: \(args[i])")
        }
    }

    let graph = try loadGraph(path: path)
    defer { theia.graph_destroy(graph) }
    let result = graphExportMaterial(
        graph: graph, size: size, outDir: outDir, basename: basename,
        heightmap: heightmap, mesh: mesh,
        verticalScale: verticalScale, meshStride: meshStride
    )
    let error = readCxxString { theia.graph_last_error(graph, $0, $1) }
    let directory = URL(fileURLWithPath: outDir)
    func file(_ suffix: String) -> String {
        directory.appendingPathComponent("\(basename)\(suffix)").path
    }
    var paths: [String: String] = [
        "weights": file("_weights.png"),
        "manifest": file("_material.json"),
    ]
    switch heightmap {
    case "png16": paths["heightmap"] = file("_height.png")
    case "r16": paths["heightmap"] = file("_height.r16")
    case "pfm32": paths["heightmap"] = file("_height.pfm")
    default: break
    }
    if mesh == "obj" { paths["mesh"] = file(".obj") }

    if options.json {
        emitJSON([
            "ok": result.ok,
            "graph": path,
            "stats": statsObject(result),
            "paths": paths,
            "error": error,
        ])
    } else if !options.quiet {
        print(result.ok ? "Exported material bundle \(path)" : "Material export failed")
        if result.ok {
            print("  resolution: \(result.width)x\(result.height)")
            print("  range:      [\(result.minHeight), \(result.maxHeight)]")
            for key in paths.keys.sorted() {
                print("  \(key): \(paths[key] ?? "")")
            }
        } else {
            print("  error: \(error)")
        }
    }
    return result.ok ? 0 : 1
}

private func diagnosticSource(path: String, sink: String) throws -> String {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    guard !sink.isEmpty,
          let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
    var dict = object as? [String: Any],
          JSONSerialization.isValidJSONObject(dict) else {
        return text
    }
    dict["sink"] = sink
    dict.removeValue(forKey: "sinkOutput")
    guard let encoded = try? JSONSerialization.data(withJSONObject: dict),
          let updated = String(data: encoded, encoding: .utf8) else {
        return text
    }
    return updated
}

private func commandDiagnose(args: [String], options: GlobalOptions) throws -> Int32 {
    guard let path = args.first, !path.hasPrefix("--") else {
        throw CLIError.usage("usage: theia-cli diagnose GRAPH.json [--sink ID]")
    }
    var sink = ""
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--sink":
            sink = try requireValue(args, i, "--sink")
            i += 2
        default:
            throw CLIError.usage("unknown option for diagnose: \(args[i])")
        }
    }

    let source = try diagnosticSource(path: path, sink: sink)
    let jsonText = readCxxLongString { theia.graph_diagnostics_json_text(source, $0, $1) }
    guard let data = jsonText.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let root = object as? [String: Any],
          let summary = root["summary"] as? [String: Any],
          let issues = root["issues"] as? [[String: Any]] else {
        throw CLIError.runtime("diagnostics failed to return readable JSON")
    }

    if options.json {
        emitJSONText(jsonText)
        return ((summary["errors"] as? Int) ?? 0) > 0 ? 1 : 0
    }
    guard !options.quiet else {
        return ((summary["errors"] as? Int) ?? 0) > 0 ? 1 : 0
    }
    let errors = summary["errors"] as? Int ?? 0
    let warnings = summary["warnings"] as? Int ?? 0
    let nodes = summary["nodes"] as? Int ?? 0
    let connections = summary["connections"] as? Int ?? 0
    let activeSink = summary["sink"] as? String ?? ""
    print(errors == 0 ? "Graph diagnostics OK" : "Graph diagnostics found \(errors) error\(errors == 1 ? "" : "s")")
    print("  graph:       \(path)")
    print("  sink:        \(activeSink.isEmpty ? "<none>" : activeSink)")
    print("  nodes:       \(nodes)")
    print("  connections: \(connections)")
    print("  warnings:    \(warnings)")
    for issue in issues {
        let severity = issue["severity"] as? String ?? "info"
        let code = issue["code"] as? String ?? "issue"
        let message = issue["message"] as? String ?? ""
        let node = issue["node"] as? String
        let input = issue["input"] as? Int
        var location = ""
        if let node { location += " node=\(node)" }
        if let input { location += " input=\(input)" }
        print("  \(severity) \(code)\(location): \(message)")
    }
    return errors > 0 ? 1 : 0
}

private func runMain() -> Int32 {
    let (options, args) = splitGlobalArgs(Array(CommandLine.arguments.dropFirst()))
    if options.version && args.isEmpty {
        return commandVersion(options: options)
    }
    if options.help || args.isEmpty {
        if options.json {
            emitJSON(["usage": usage()])
        } else {
            print(usage())
        }
        return options.help ? 0 : 2
    }

    let command = args[0]
    let commandArgs = Array(args.dropFirst())
    do {
        switch command {
        case "version":
            if !commandArgs.isEmpty {
                throw CLIError.usage("usage: theia-cli version")
            }
            return commandVersion(options: options)
        case "doctor":
            if !commandArgs.isEmpty {
                throw CLIError.usage("usage: theia-cli doctor")
            }
            return commandDoctor(options: options)
        case "nodes":
            if !commandArgs.isEmpty {
                throw CLIError.usage("usage: theia-cli nodes [--json]")
            }
            printNodeCatalog(json: options.json, quiet: options.quiet)
            return 0
        case "smoke":
            return try commandSmoke(args: commandArgs, options: options)
        case "demo":
            return try commandDemo(args: commandArgs, options: options)
        case "run":
            return try commandRun(args: commandArgs, options: options)
        case "export":
            return try commandExport(args: commandArgs, options: options)
        case "export-material":
            return try commandExportMaterial(args: commandArgs, options: options)
        case "diagnose":
            return try commandDiagnose(args: commandArgs, options: options)
        case "help":
            print(usage())
            return 0
        default:
            throw CLIError.usage("unknown command: \(command)")
        }
    } catch CLIError.usage(let message) {
        if options.json {
            emitJSON(["ok": false, "error": ["kind": "usage", "message": message]])
        } else {
            printErr(message)
        }
        return 2
    } catch CLIError.runtime(let message) {
        if options.json {
            emitJSON(["ok": false, "error": ["kind": "runtime", "message": message]])
        } else {
            printErr(message)
        }
        return 1
    } catch {
        if options.json {
            emitJSON(["ok": false, "error": ["kind": "runtime", "message": error.localizedDescription]])
        } else {
            printErr(error.localizedDescription)
        }
        return 1
    }
}

exit(runMain())
