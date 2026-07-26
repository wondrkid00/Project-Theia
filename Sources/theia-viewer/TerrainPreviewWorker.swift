import Foundation
import TheiaCore

struct TerrainPreviewEvaluation: Sendable {
    let geometry: [Float]
    let data: [Float]
    let dataMatchesGeometry: Bool
    let width: Int
    let height: Int
    let evaluated: UInt32
    let reused: UInt32
}

struct TerrainPreviewWorkerActivity: Equatable, Sendable {
    var submitted = 0
    var started = 0
    var skippedBeforeStart = 0
    var delivered = 0
}

enum TerrainPreviewOutcome: Sendable {
    case success(TerrainPreviewEvaluation)
    case failure(String)
}

// Owns a second graph handle used only on a serial background queue. New
// snapshots supersede queued work; an in-flight GPU evaluation is allowed to
// finish, but its stale result is dropped before reaching the renderer.
final class TerrainPreviewWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.theia.preview", qos: .userInitiated)
    private let revisionLock = NSLock()
    private var latestRevision: UInt64 = 0
    private var activity = TerrainPreviewWorkerActivity()
    private var handle: OpaquePointer?
    private let coalescingDelay: DispatchTimeInterval = .milliseconds(60)

    deinit {
        if let handle { theia.graph_destroy(handle) }
    }

    func cancelPending() {
        revisionLock.lock()
        latestRevision &+= 1
        revisionLock.unlock()
    }

    func activitySnapshot() -> TerrainPreviewWorkerActivity {
        revisionLock.lock()
        defer { revisionLock.unlock() }
        return activity
    }

    func submit(jsonText: String,
                geometry: GraphOutputReference,
                data: GraphOutputReference,
                size: UInt32,
                completion: @escaping @MainActor @Sendable (TerrainPreviewOutcome) -> Void) {
        revisionLock.lock()
        latestRevision &+= 1
        let revision = latestRevision
        activity.submitted += 1
        revisionLock.unlock()

        queue.asyncAfter(deadline: .now() + coalescingDelay) { [weak self] in
            guard let self else { return }
            guard self.beginIfLatest(revision) else { return }
            guard let graph = self.graphHandle() else {
                self.finish(.failure("preview graph creation failed"),
                            revision: revision, completion: completion)
                return
            }
            guard theia.graph_load_json_text(graph, jsonText) else {
                let message = readCxxString { theia.graph_last_error(graph, $0, $1) }
                self.finish(.failure(message), revision: revision, completion: completion)
                return
            }
            guard let geometryResult = self.evaluate(graph: graph, reference: geometry,
                                                     size: size)
            else {
                let message = readCxxString { theia.graph_last_error(graph, $0, $1) }
                self.finish(.failure(message), revision: revision, completion: completion)
                return
            }

            let dataResult: (values: [Float], result: theia.GraphEvalResult)
            if geometry == data {
                dataResult = geometryResult
            } else {
                guard let evaluated = self.evaluate(graph: graph, reference: data,
                                                    size: size)
                else {
                    let message = readCxxString { theia.graph_last_error(graph, $0, $1) }
                    self.finish(.failure(message), revision: revision, completion: completion)
                    return
                }
                dataResult = evaluated
            }

            let result = TerrainPreviewEvaluation(
                geometry: geometryResult.values,
                data: dataResult.values,
                dataMatchesGeometry: geometry == data,
                width: Int(geometryResult.result.width),
                height: Int(geometryResult.result.height),
                evaluated: geometryResult.result.evaluated +
                    (geometry == data ? 0 : dataResult.result.evaluated),
                reused: geometryResult.result.reused +
                    (geometry == data ? 0 : dataResult.result.reused))
            self.finish(.success(result), revision: revision, completion: completion)
        }
    }

    private func graphHandle() -> OpaquePointer? {
        if handle == nil { handle = theia.graph_create() }
        return handle
    }

    private func evaluate(graph: OpaquePointer, reference: GraphOutputReference,
                          size: UInt32) -> (values: [Float], result: theia.GraphEvalResult)? {
        guard size > 0 else { return nil }
        let count = Int(size) * Int(size)
        guard count > 0 else { return nil }
        var values = [Float](repeating: 0, count: count)
        let result = values.withUnsafeMutableBufferPointer {
            theia.graph_evaluate_heights_output(graph, reference.node,
                                                reference.output,
                                                size, size,
                                                $0.baseAddress, $0.count)
        }
        return result.ok ? (values, result) : nil
    }

    private func isLatest(_ revision: UInt64) -> Bool {
        revisionLock.lock()
        defer { revisionLock.unlock() }
        return revision == latestRevision
    }

    private func beginIfLatest(_ revision: UInt64) -> Bool {
        revisionLock.lock()
        defer { revisionLock.unlock() }
        guard revision == latestRevision else {
            activity.skippedBeforeStart += 1
            return false
        }
        activity.started += 1
        return true
    }

    private func finish(_ outcome: TerrainPreviewOutcome,
                        revision: UInt64,
                        completion: @escaping @MainActor @Sendable (TerrainPreviewOutcome) -> Void) {
        guard isLatest(revision) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.isLatest(revision) else { return }
            self.recordDelivered()
            completion(outcome)
        }
    }

    private func recordDelivered() {
        revisionLock.lock()
        activity.delivered += 1
        revisionLock.unlock()
    }
}
