import Foundation
import TheiaCore

struct ExportSettings: Sendable {
    enum HeightmapFormat: String, CaseIterable, Identifiable, Sendable {
        case png16
        case r16
        case pfm32

        var id: String { rawValue }

        var label: String {
            switch self {
            case .png16: return "PNG 16-bit"
            case .r16: return "RAW R16"
            case .pfm32: return "PFM 32-bit Float"
            }
        }
    }

    enum MeshFormat: String, CaseIterable, Identifiable, Sendable {
        case obj
        case fbx

        var id: String { rawValue }

        var label: String {
            switch self {
            case .obj: return "OBJ"
            case .fbx: return "FBX"
            }
        }

        var isSupported: Bool { self == .obj }
    }

    var outDir = "/private/tmp/theia-export"
    var basename = "terrain"
    var size: UInt32 = 512
    var verticalScale: Double = 1.0
    var meshStride: UInt32 = 1
    var exportHeightmap = true
    var heightmapFormat: HeightmapFormat = .png16
    var exportMesh = true
    var meshFormat: MeshFormat = .obj
    var exportHeight = true
    var exportPFM = false
    var exportNormal = false
    var exportSlope = false
    var exportMask = false
    var exportOBJ = true
}

enum TerrainExporter {
    nonisolated static func perform(text: String, sink: String, output: String,
                                    settings: ExportSettings) -> String {
        guard let graph = theia.graph_create() else { return "export failed: graph create" }
        defer { theia.graph_destroy(graph) }
        guard theia.graph_load_json_text(graph, text) else {
            let error = readCxxString { theia.graph_last_error(graph, $0, $1) }
            return "export failed: \(error)"
        }

        func coreHeightmapFormat(_ format: ExportSettings.HeightmapFormat,
                                 enabled: Bool) -> theia.HeightmapFormat {
            guard enabled else { return theia.HeightmapFormat.none }
            switch format {
            case .png16: return theia.HeightmapFormat.png16
            case .r16: return theia.HeightmapFormat.r16
            case .pfm32: return theia.HeightmapFormat.pfm32
            }
        }

        let result = settings.outDir.withCString { outDirPtr in
            settings.basename.withCString { basenamePtr in
                func options(sinkId: UnsafePointer<CChar>?,
                             outputName: UnsafePointer<CChar>?) -> theia.GraphExportOptions {
                    var value = theia.GraphExportOptions()
                    value.sinkId = sinkId
                    value.outputName = outputName
                    value.width = settings.size
                    value.height = settings.size
                    value.outDir = outDirPtr
                    value.basename = basenamePtr
                    value.heightmapFormat = coreHeightmapFormat(
                        settings.heightmapFormat, enabled: settings.exportHeightmap)
                    value.meshFormat = settings.exportMesh && settings.meshFormat == .obj
                        ? theia.MeshFormat.obj : theia.MeshFormat.none
                    value.verticalScale = Float(settings.verticalScale)
                    value.meshStride = settings.meshStride
                    return value
                }
                if sink.isEmpty && output.isEmpty {
                    return theia.graph_export2(
                        graph, options(sinkId: nil, outputName: nil))
                }
                if sink.isEmpty {
                    return output.withCString { outputPtr in
                        theia.graph_export2(
                            graph, options(sinkId: nil, outputName: outputPtr))
                    }
                }
                if output.isEmpty {
                    return sink.withCString { sinkPtr in
                        theia.graph_export2(
                            graph, options(sinkId: sinkPtr, outputName: nil))
                    }
                }
                return sink.withCString { sinkPtr in
                    output.withCString { outputPtr in
                        theia.graph_export2(
                            graph, options(sinkId: sinkPtr, outputName: outputPtr))
                    }
                }
            }
        }
        guard result.ok else {
            let error = readCxxString { theia.graph_last_error(graph, $0, $1) }
            return "export failed: \(error)"
        }
        return "exported \(settings.basename) \(result.width)x\(result.height)"
    }

}
