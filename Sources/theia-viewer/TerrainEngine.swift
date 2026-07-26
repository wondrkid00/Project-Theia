import Foundation
import TheiaCore

// Wraps a TheiaCore graph handle: loads a graph (or builds a default one) and
// evaluates it to a CPU float heightfield for the renderer.
final class TerrainEngine {
    let handle: OpaquePointer
    private(set) var graphPath: String?
    private let sinkId: String
    private var lastGraphMTime: Date?

    init?(graphPath: String?) {
        guard let g = theia.graph_create() else { return nil }
        handle = g
        self.graphPath = graphPath

        if let p = graphPath {
            sinkId = ""
            if !theia.graph_load_json_file(g, p) {
                FileHandle.standardError.write(
                    Data("failed to load \(p): \(self.lastError())\n".utf8))
                return nil
            }
            lastGraphMTime = graphModificationDate()
        } else {
            sinkId = ""
        }
    }

    deinit { theia.graph_destroy(handle) }

    // perlin -> hydraulic -> thermal -> normalize, sink "out".
    private func buildDefaultGraph() {
        let g = handle
        _ = theia.graph_add_node(g, "base", "perlin")
        _ = theia.graph_set_param(g, "base", "octaves", 7)
        _ = theia.graph_set_param(g, "base", "frequency", 4.0)
        _ = theia.graph_add_node(g, "ero", "hydraulic")
        _ = theia.graph_set_param(g, "ero", "iterations", 150)
        _ = theia.graph_add_node(g, "settle", "thermal")
        _ = theia.graph_add_node(g, "out", "normalize")
        _ = theia.graph_connect(g, "base", "ero", 0)
        _ = theia.graph_connect(g, "ero", "settle", 0)
        _ = theia.graph_connect(g, "settle", "out", 0)
    }

    func lastError() -> String {
        readCxxString { theia.graph_last_error(handle, $0, $1) }
    }

    func loadJSONText(_ text: String) -> Bool {
        theia.graph_load_json_text(handle, text)
    }

    func setGraphPath(_ path: String?) {
        graphPath = path
        lastGraphMTime = graphModificationDate()
    }

    private func graphModificationDate() -> Date? {
        guard let graphPath else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: graphPath)
        return attrs?[.modificationDate] as? Date
    }

    func reloadIfChanged() -> Bool {
        guard let graphPath, let mtime = graphModificationDate() else { return false }
        guard lastGraphMTime == nil || mtime > lastGraphMTime! else { return false }
        lastGraphMTime = mtime

        if theia.graph_load_json_file(handle, graphPath) {
            return true
        }

        FileHandle.standardError.write(
            Data("hot reload failed for \(graphPath): \(lastError())\n".utf8))
        return false
    }

    // Evaluate the (default) sink at `size` x `size`. Returns heights + result.
    func evaluate(size: UInt32, sink: String = "", output: String = "")
        -> (heights: [Float], result: theia.GraphEvalResult)? {
        let evalSink = sink.isEmpty ? sinkId : sink
        if size > 0 {
            let n = Int(size) * Int(size)
            guard n > 0 else { return nil }
            var buf = [Float](repeating: 0, count: n)
            let r = buf.withUnsafeMutableBufferPointer {
                theia.graph_evaluate_heights_output(handle, evalSink, output,
                                                    size, size,
                                                    $0.baseAddress, $0.count)
            }
            guard r.ok else { return nil }
            return (buf, r)
        }

        // Probe to learn the resolution (cheap: a second pass reuses the cache).
        let probe = theia.graph_evaluate_heights_output(handle, evalSink, output,
                                                        size, size, nil, 0)
        guard probe.ok else { return nil }
        let n = Int(probe.width) * Int(probe.height)
        guard n > 0 else { return nil }

        var buf = [Float](repeating: 0, count: n)
        let r = buf.withUnsafeMutableBufferPointer {
            theia.graph_evaluate_heights_output(handle, evalSink, output,
                                                size, size,
                                                $0.baseAddress, $0.count)
        }
        guard r.ok else { return nil }
        return (buf, r)
    }
}
