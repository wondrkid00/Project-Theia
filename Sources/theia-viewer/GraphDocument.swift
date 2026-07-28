import Foundation
import TheiaCore

struct GraphResolution: Codable {
    var width: UInt32
    var height: UInt32
}

struct GraphDocumentNode: Codable, Identifiable {
    var id: String
    var type: String
    var params: [String: Double]
}

struct GraphDocumentConnection: Codable, Identifiable, Equatable {
    var from: String
    var output: String
    var to: String
    var input: UInt32

    var id: String { "\(from).\(output)->\(to).\(input)" }

    enum CodingKeys: String, CodingKey { case from, output, to, input }

    init(from: String, output: String = "", to: String, input: UInt32) {
        self.from = from
        self.output = output
        self.to = to
        self.input = input
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        from = try c.decode(String.self, forKey: .from)
        output = try c.decodeIfPresent(String.self, forKey: .output) ?? ""
        to = try c.decode(String.self, forKey: .to)
        input = try c.decodeIfPresent(UInt32.self, forKey: .input) ?? 0
    }
}

enum GraphFieldKind: String, Codable, CaseIterable {
    case terrain
    case mask
    case data
}

struct GraphInputPort: Identifiable, Equatable {
    let index: UInt32
    let name: String
    let acceptedKinds: Set<GraphFieldKind>

    var id: UInt32 { index }
    var acceptsEveryKind: Bool {
        acceptedKinds == Set(GraphFieldKind.allCases)
    }
}

struct GraphOutputPort: Identifiable, Equatable {
    let name: String
    let declaredKind: GraphFieldKind
    let inheritInput: Int?
    let isDefault: Bool

    var id: String { name }
}

struct GraphOutputReference: Codable, Hashable, Sendable {
    var node: String
    var output: String
}

enum GraphConnectionCompatibility: Equatable {
    case compatible(replacesExisting: Bool)
    case pending(message: String, replacesExisting: Bool)
    case incompatible(message: String)

    var isAllowed: Bool {
        switch self {
        case .compatible, .pending: return true
        case .incompatible: return false
        }
    }

    var replacesExisting: Bool {
        switch self {
        case .compatible(let replaces), .pending(_, let replaces):
            return replaces
        case .incompatible:
            return false
        }
    }

    var message: String? {
        switch self {
        case .compatible:
            return nil
        case .pending(let message, _), .incompatible(let message):
            return message
        }
    }
}

struct GraphCompatibleNodeTarget: Identifiable, Equatable {
    let nodeType: String
    let input: GraphInputPort
    let priority: Int
    let reason: String

    var id: String { "\(nodeType).\(input.index)" }
    var isRecommended: Bool { priority < 20 }
}

struct GraphNodePosition: Codable, Equatable {
    var x: Double
    var y: Double
}

struct GraphMaskEraseStroke: Codable, Equatable {
    var x: Double
    var y: Double
    var radius: Double
    var strength: Double
}

enum ViewportDisplayMode: String, CaseIterable, Identifiable {
    case auto
    case terrain
    case height
    case mask
    case slope
    case normal
    case material
    case data

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "auto"
        case .terrain: return "terrain"
        case .height: return "height"
        case .mask: return "mask"
        case .slope: return "slope"
        case .normal: return "normal"
        case .material: return "material"
        case .data: return "data"
        }
    }

    var rendererMode: UInt32 {
        switch self {
        case .auto, .terrain: return 0
        case .height: return 1
        case .mask: return 2
        case .slope: return 3
        case .normal: return 4
        case .material: return 5
        case .data: return 6
        }
    }
}

extension ViewportDisplayMode: Codable {
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = ViewportDisplayMode(rawValue: value) ?? .auto
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

enum MaterialPreset: String, CaseIterable, Identifiable {
    case natural
    case alpine
    case arid
    case analysis

    var id: String { rawValue }

    var label: String { rawValue }

    var rendererPreset: UInt32 {
        switch self {
        case .natural: return 0
        case .alpine: return 1
        case .arid: return 2
        case .analysis: return 3
        }
    }
}

extension MaterialPreset: Codable {
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = MaterialPreset(rawValue: value) ?? .natural
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

struct GraphPreviewSettings: Codable {
    var displayMode: ViewportDisplayMode = .auto
    var materialPreset: MaterialPreset = .natural
    var maskOpacity: Double = 0.65

    enum CodingKeys: String, CodingKey {
        case displayMode, materialPreset, maskOpacity
    }

    init(displayMode: ViewportDisplayMode = .auto,
         materialPreset: MaterialPreset = .natural,
         maskOpacity: Double = 0.65) {
        self.displayMode = displayMode
        self.materialPreset = materialPreset
        self.maskOpacity = min(max(maskOpacity, 0), 1)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayMode = try c.decodeIfPresent(ViewportDisplayMode.self,
                                            forKey: .displayMode) ?? .auto
        materialPreset = try c.decodeIfPresent(MaterialPreset.self,
                                               forKey: .materialPreset) ?? .natural
        let opacity = try c.decodeIfPresent(Double.self, forKey: .maskOpacity) ?? 0.65
        maskOpacity = min(max(opacity, 0), 1)
    }
}

struct GraphDocumentUI: Codable {
    var positions: [String: GraphNodePosition] = [:]
    var preview = GraphPreviewSettings()
    var maskErases: [String: [String: [GraphMaskEraseStroke]]] = [:]

    enum CodingKeys: String, CodingKey {
        case positions, preview, maskErases
    }

    init(positions: [String: GraphNodePosition] = [:],
         preview: GraphPreviewSettings = GraphPreviewSettings(),
         maskErases: [String: [String: [GraphMaskEraseStroke]]] = [:]) {
        self.positions = positions
        self.preview = preview
        self.maskErases = maskErases
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        positions = try c.decodeIfPresent([String: GraphNodePosition].self,
                                          forKey: .positions) ?? [:]
        preview = try c.decodeIfPresent(GraphPreviewSettings.self,
                                        forKey: .preview) ?? GraphPreviewSettings()
        if let nested = try? c.decodeIfPresent(
            [String: [String: [GraphMaskEraseStroke]]].self,
            forKey: .maskErases) {
            maskErases = nested
        } else if let legacy = try? c.decodeIfPresent(
            [String: [GraphMaskEraseStroke]].self,
            forKey: .maskErases) {
            maskErases = legacy.mapValues { ["": $0] }
        } else {
            maskErases = [:]
        }
    }
}

/// Memoizes per-node-type metadata: default parameters and port declarations.
///
/// These are fixed by the core's node registry, but every lookup crosses into
/// C++ and builds a throwaway node — `defaultParams` alone constructs `1 + 2N`
/// of them, and `outputPorts` builds `1 + 4N`. The inspector re-derives defaults
/// once per visible row and the canvas asks for both port lists several times
/// per node, on every SwiftUI body pass, which lands squarely in the
/// drag-a-slider loop. Caching turns each of those into a dictionary read.
///
/// Values depend only on the type string and never change at runtime, so the
/// cache never needs invalidating.
private final class NodeTypeMetadataCache: @unchecked Sendable {
    static let shared = NodeTypeMetadataCache()

    private let lock = NSLock()
    private var defaults: [String: [String: Double]] = [:]
    private var outputs: [String: [GraphOutputPort]] = [:]
    private var inputs: [String: [GraphInputPort]] = [:]

    func defaultParams(for type: String,
                       build: () -> [String: Double]) -> [String: Double] {
        if let hit = read({ $0.defaults[type] }) { return hit }
        let value = build()
        write { $0.defaults[type] = value }
        return value
    }

    func outputPorts(for type: String,
                     build: () -> [GraphOutputPort]) -> [GraphOutputPort] {
        if let hit = read({ $0.outputs[type] }) { return hit }
        let value = build()
        write { $0.outputs[type] = value }
        return value
    }

    func inputPorts(for type: String,
                    build: () -> [GraphInputPort]) -> [GraphInputPort] {
        if let hit = read({ $0.inputs[type] }) { return hit }
        let value = build()
        write { $0.inputs[type] = value }
        return value
    }

    /// `build` runs outside the lock. Two threads racing a cold type may both
    /// compute it, which is harmless — these are pure functions of the type —
    /// and it keeps C++ calls from ever running under the lock.
    private func read<T>(_ body: (NodeTypeMetadataCache) -> T?) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return body(self)
    }

    private func write(_ body: (NodeTypeMetadataCache) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(self)
    }
}

struct GraphDocument: Codable {
    static let defaultResolution: UInt32 = 1024

    var formatVersion: Int
    var resolution: GraphResolution
    var sink: String
    var sinkOutput: String
    var nodes: [GraphDocumentNode]
    var connections: [GraphDocumentConnection]
    var ui: GraphDocumentUI?

    enum CodingKeys: String, CodingKey {
        case formatVersion, resolution, sink, sinkOutput, nodes, connections, ui
    }

    init(formatVersion: Int = 3,
         resolution: GraphResolution,
         sink: String,
         sinkOutput: String = "",
         nodes: [GraphDocumentNode],
         connections: [GraphDocumentConnection],
         ui: GraphDocumentUI?) {
        self.formatVersion = formatVersion
        self.resolution = resolution
        self.sink = sink
        self.sinkOutput = sinkOutput
        self.nodes = nodes
        self.connections = connections
        self.ui = ui
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        resolution = try c.decodeIfPresent(GraphResolution.self, forKey: .resolution)
            ?? GraphResolution(width: Self.defaultResolution,
                               height: Self.defaultResolution)
        sink = try c.decodeIfPresent(String.self, forKey: .sink) ?? ""
        sinkOutput = try c.decodeIfPresent(String.self, forKey: .sinkOutput) ?? ""
        nodes = try c.decodeIfPresent([GraphDocumentNode].self, forKey: .nodes) ?? []
        connections = try c.decodeIfPresent([GraphDocumentConnection].self, forKey: .connections) ?? []
        // Accept v3 as a legacy input format. Codable ignores extension fields
        // that are no longer supported, and encoding normalizes the file to v2.
        guard (1...3).contains(formatVersion) else {
            throw DecodingError.dataCorruptedError(forKey: .formatVersion, in: c,
                debugDescription: "unsupported graph formatVersion \(formatVersion)")
        }
        ui = try c.decodeIfPresent(GraphDocumentUI.self, forKey: .ui)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(3, forKey: .formatVersion)
        try c.encode(resolution, forKey: .resolution)
        if !sink.isEmpty {
            try c.encode(sink, forKey: .sink)
            try c.encode(sinkOutput, forKey: .sinkOutput)
        }
        try c.encode(nodes, forKey: .nodes)
        try c.encode(connections, forKey: .connections)
        if let ui {
            try c.encode(ui, forKey: .ui)
        }
    }

    static func load(path: String) throws -> GraphDocument {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var doc = try JSONDecoder().decode(GraphDocument.self, from: data)
        doc.ensureNodeDefaults()
        doc.ensureLayout()
        return doc
    }

    static func defaultDocument() -> GraphDocument {
        var doc = GraphDocument.emptyDocument()
        doc.ensureLayout()
        return doc
    }

    static func emptyDocument(width: UInt32 = defaultResolution,
                              height: UInt32 = defaultResolution) -> GraphDocument {
        GraphDocument(formatVersion: 3,
                      resolution: GraphResolution(width: width, height: height),
                      sink: "",
                      sinkOutput: "",
                      nodes: [],
                      connections: [],
                      ui: GraphDocumentUI())
    }

    mutating func ensureLayout() {
        formatVersion = 2
        ensureNodeDefaults()
        migrateNamedOutputs()
        repairRiverCarveConnections()
        if ui == nil { ui = GraphDocumentUI() }
        var positions = ui?.positions ?? [:]
        for (index, node) in nodes.enumerated() where positions[node.id] == nil {
            positions[node.id] = GraphNodePosition(x: 80 + Double(index % 4) * 210,
                                                   y: 80 + Double(index / 4) * 150)
        }
        for key in Array(positions.keys) where !nodes.contains(where: { $0.id == key }) {
            positions.removeValue(forKey: key)
        }
        ui?.positions = positions
        if let eraseKeys = ui?.maskErases.keys {
            for key in Array(eraseKeys) where !nodes.contains(where: { $0.id == key }) {
                ui?.maskErases.removeValue(forKey: key)
            }
        }
    }

    private mutating func migrateNamedOutputs() {
        for index in connections.indices {
            guard let source = node(id: connections[index].from) else { continue }
            connections[index].output = Self.canonicalOutputName(
                connections[index].output, for: source.type)
        }
        if sink.isEmpty {
            sinkOutput = ""
        } else if let sinkNode = node(id: sink) {
            let names = Set(Self.outputPorts(for: sinkNode.type).map(\.name))
            sinkOutput = Self.canonicalOutputName(sinkOutput,
                                                  for: sinkNode.type)
            if !names.contains(sinkOutput) {
                sinkOutput = Self.defaultOutputName(for: sinkNode.type)
            }
        }
        guard var eraseNodes = ui?.maskErases else { return }
        for (nodeId, var outputs) in eraseNodes {
            guard let graphNode = node(id: nodeId) else {
                eraseNodes.removeValue(forKey: nodeId)
                continue
            }
            let defaultOutput = Self.defaultOutputName(for: graphNode.type)
            if let legacy = outputs.removeValue(forKey: ""), !legacy.isEmpty {
                outputs[defaultOutput, default: []].append(contentsOf: legacy)
            }
            let validMaskOutputs = Set(Self.outputPorts(for: graphNode.type)
                .filter {
                    resolvedOutputKind(nodeId: nodeId, output: $0.name) == .mask
                }
                .map(\.name))
            outputs = outputs.filter { validMaskOutputs.contains($0.key) }
            if outputs.isEmpty {
                eraseNodes.removeValue(forKey: nodeId)
            } else {
                eraseNodes[nodeId] = outputs
            }
        }
        ui?.maskErases = eraseNodes
    }

    mutating func ensureNodeDefaults() {
        for index in nodes.indices {
            let defaults = Self.defaultParams(for: nodes[index].type)
            nodes[index].params = defaults.merging(nodes[index].params) { _, saved in saved }
            migrateLegacySlopeMaskDefaults(index: index)
            migrateLegacyRiverMaskParams(index: index)
        }
    }

    private mutating func migrateLegacyRiverMaskParams(index: Int) {
        guard nodes[index].type == "river" else { return }
        for key in ["depth", "downcutting", "renderSurface", "riverValleyWidth"] {
            nodes[index].params.removeValue(forKey: key)
        }
    }

    private mutating func migrateLegacySlopeMaskDefaults(index: Int) {
        guard nodes[index].type == "slopemask" else { return }
        let defaults = Self.defaultParams(for: "slopemask")
        let params = nodes[index].params
        let low = params["low"] ?? defaults["low"] ?? 15.0
        let high = params["high"] ?? defaults["high"] ?? 50.0
        let heightScale = params["heightScale"] ?? defaults["heightScale"] ?? 100.0
        if (low >= -1.0 && low <= 1.0 && high >= -1.0 && high <= 1.0) ||
            high <= low ||
            heightScale == 64.0 {
            nodes[index].params["low"] = defaults["low"] ?? 15.0
            nodes[index].params["high"] = defaults["high"] ?? 50.0
            nodes[index].params["heightScale"] = defaults["heightScale"] ?? 100.0
        }
    }

    func encodedString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    mutating func addNode(type: String, after previousId: String? = nil,
                          at position: GraphNodePosition? = nil) -> String {
        let id = uniqueNodeId(base: type)
        nodes.append(GraphDocumentNode(id: id, type: type, params: Self.defaultParams(for: type)))
        if ui == nil { ui = GraphDocumentUI() }
        if let position {
            ui?.positions[id] = position
        } else if let previousId, let previous = ui?.positions[previousId] {
            ui?.positions[id] = GraphNodePosition(x: previous.x + 220, y: previous.y)
        } else if let last = nodes.dropLast().last,
                  let previous = ui?.positions[last.id] {
            ui?.positions[id] = GraphNodePosition(x: previous.x + 220, y: previous.y)
        } else {
            ui?.positions[id] = GraphNodePosition(x: 120, y: 120)
        }
        if sink.isEmpty && inputCount(for: type) == 0 {
            sink = id
            sinkOutput = Self.defaultOutputName(for: type)
        }
        return id
    }

    mutating func duplicateNodes(ids: Set<String>) -> [String] {
        let originals = nodes.filter { ids.contains($0.id) }
        guard !originals.isEmpty else { return [] }
        if ui == nil { ui = GraphDocumentUI() }
        var idMap: [String: String] = [:]
        var duplicatedIds: [String] = []
        for original in originals {
            let newId = uniqueNodeId(base: "\(original.id)Copy")
            idMap[original.id] = newId
            duplicatedIds.append(newId)
            nodes.append(GraphDocumentNode(id: newId,
                                           type: original.type,
                                           params: original.params))
            let p = ui?.positions[original.id] ?? GraphNodePosition(x: 120, y: 120)
            ui?.positions[newId] = GraphNodePosition(x: p.x + 36, y: p.y + 36)
        }
        for edge in connections where ids.contains(edge.from) && ids.contains(edge.to) {
            guard let from = idMap[edge.from], let to = idMap[edge.to] else { continue }
            connections.append(GraphDocumentConnection(from: from,
                                                       output: edge.output,
                                                       to: to,
                                                       input: edge.input))
        }
        return duplicatedIds
    }

    mutating func deleteNode(id: String) {
        nodes.removeAll { $0.id == id }
        connections.removeAll { $0.from == id || $0.to == id }
        ui?.positions.removeValue(forKey: id)
        ui?.maskErases.removeValue(forKey: id)
        if sink == id {
            sink = nodes.last?.id ?? ""
            sinkOutput = node(id: sink).map { Self.defaultOutputName(for: $0.type) } ?? ""
        }
    }

    mutating func deleteNodes(ids: Set<String>) {
        nodes.removeAll { ids.contains($0.id) }
        connections.removeAll { ids.contains($0.from) || ids.contains($0.to) }
        for id in ids {
            ui?.positions.removeValue(forKey: id)
            ui?.maskErases.removeValue(forKey: id)
        }
        if ids.contains(sink) {
            sink = nodes.last?.id ?? ""
            sinkOutput = node(id: sink).map { Self.defaultOutputName(for: $0.type) } ?? ""
        }
    }

    mutating func setParam(nodeId: String, key: String, value: Double) {
        guard let idx = nodes.firstIndex(where: { $0.id == nodeId }) else { return }
        nodes[idx].params[key] = value
    }

    mutating func setPosition(nodeId: String, x: Double, y: Double) {
        if ui == nil { ui = GraphDocumentUI() }
        ui?.positions[nodeId] = GraphNodePosition(x: x, y: y)
    }

    mutating func setPreviewSettings(_ settings: GraphPreviewSettings) {
        if ui == nil { ui = GraphDocumentUI() }
        ui?.preview = settings
    }

    mutating func addMaskEraseStroke(nodeId: String, output: String,
                                     stroke: GraphMaskEraseStroke) {
        addMaskEraseStrokes(nodeId: nodeId, output: output, strokes: [stroke])
    }

    mutating func addMaskEraseStroke(nodeId: String, stroke: GraphMaskEraseStroke) {
        guard let type = node(id: nodeId)?.type else { return }
        addMaskEraseStroke(nodeId: nodeId,
                           output: Self.defaultOutputName(for: type),
                           stroke: stroke)
    }

    mutating func addMaskEraseStrokes(nodeId: String, output: String,
                                      strokes: [GraphMaskEraseStroke]) {
        guard !strokes.isEmpty else { return }
        if ui == nil { ui = GraphDocumentUI() }
        ui?.maskErases[nodeId, default: [:]][output, default: []]
            .append(contentsOf: strokes)
    }

    mutating func addMaskEraseStrokes(nodeId: String,
                                      strokes: [GraphMaskEraseStroke]) {
        guard let type = node(id: nodeId)?.type else { return }
        addMaskEraseStrokes(nodeId: nodeId,
                            output: Self.defaultOutputName(for: type),
                            strokes: strokes)
    }

    mutating func clearMaskEraseStrokes(nodeId: String, output: String? = nil) {
        if let output {
            ui?.maskErases[nodeId]?.removeValue(forKey: output)
            if ui?.maskErases[nodeId]?.isEmpty == true {
                ui?.maskErases.removeValue(forKey: nodeId)
            }
        } else {
            ui?.maskErases.removeValue(forKey: nodeId)
        }
    }

    @discardableResult
    mutating func resetNodeState(nodeId: String) -> Bool {
        guard let index = nodes.firstIndex(where: { $0.id == nodeId }) else {
            return false
        }
        nodes[index].params = Self.defaultParams(for: nodes[index].type)
        clearMaskEraseStrokes(nodeId: nodeId)
        return true
    }

    func maskEraseStrokes(nodeId: String, output: String) -> [GraphMaskEraseStroke] {
        ui?.maskErases[nodeId]?[output] ?? []
    }

    func maskEraseStrokes(nodeId: String) -> [GraphMaskEraseStroke] {
        guard let type = node(id: nodeId)?.type else { return [] }
        return maskEraseStrokes(nodeId: nodeId,
                                output: Self.defaultOutputName(for: type))
    }

    mutating func connect(from: String, output: String = "",
                          to: String, input: UInt32) {
        connections.removeAll { $0.to == to && $0.input == input }
        let resolvedOutput = node(id: from).map {
            Self.canonicalOutputName(output, for: $0.type)
        } ?? output
        let edge = GraphDocumentConnection(from: from, output: resolvedOutput,
                                           to: to, input: input)
        if !connections.contains(edge) {
            connections.append(edge)
        }
    }

    mutating func repairRiverCarveConnections() {
        for carve in nodes where carve.type == "rivercarve" {
            guard let misplacedMask = connections.first(where: {
                $0.to == carve.id && $0.input == 0 && node(id: $0.from)?.type == "river"
            }) else { continue }
            guard let upstreamTerrain = upstreamNodeId(to: misplacedMask.from, input: 0)
            else { continue }
            connect(from: upstreamTerrain, to: carve.id, input: 0)
            connect(from: misplacedMask.from, to: carve.id, input: 1)
        }
    }

    mutating func disconnect(_ edge: GraphDocumentConnection) {
        connections.removeAll { $0 == edge }
    }

    func inputCount(for type: String) -> UInt32 {
        theia.graph_node_type_input_count(type)
    }

    func inputPorts(nodeId: String) -> [GraphInputPort] {
        guard let node = node(id: nodeId) else { return [] }
        return Self.inputPorts(for: node.type)
    }

    func node(id: String) -> GraphDocumentNode? {
        nodes.first { $0.id == id }
    }

    func upstreamNodeId(to nodeId: String, input: UInt32) -> String? {
        connections.last { $0.to == nodeId && $0.input == input }?.from
    }

    func outputPorts(nodeId: String) -> [GraphOutputPort] {
        guard let node = node(id: nodeId) else { return [] }
        return Self.outputPorts(for: node.type)
    }

    func possibleOutputKinds(
        nodeId: String,
        output: String,
        visited: Set<GraphOutputReference> = []
    ) -> Set<GraphFieldKind> {
        guard let graphNode = node(id: nodeId) else { return [] }
        let selected = Self.canonicalOutputName(output, for: graphNode.type)
        let reference = GraphOutputReference(node: nodeId, output: selected)
        guard !visited.contains(reference),
              let port = Self.outputPorts(for: graphNode.type)
                .first(where: { $0.name == selected }) else { return [] }
        guard let inheritedInput = port.inheritInput else {
            return [port.declaredKind]
        }
        guard let edge = connections.last(where: {
            $0.to == nodeId && $0.input == UInt32(inheritedInput)
        }) else {
            return Self.inputPorts(for: graphNode.type)
                .first(where: { $0.index == UInt32(inheritedInput) })?
                .acceptedKinds ?? []
        }
        var nextVisited = visited
        nextVisited.insert(reference)
        return possibleOutputKinds(nodeId: edge.from, output: edge.output,
                                   visited: nextVisited)
    }

    func resolvedOutputKind(nodeId: String, output: String,
                            visited: Set<GraphOutputReference> = []) -> GraphFieldKind? {
        guard let graphNode = node(id: nodeId) else { return nil }
        let selected = Self.canonicalOutputName(output, for: graphNode.type)
        let reference = GraphOutputReference(node: nodeId, output: selected)
        guard !visited.contains(reference),
              let port = Self.outputPorts(for: graphNode.type)
                .first(where: { $0.name == selected }) else { return nil }
        guard let inheritedInput = port.inheritInput else { return port.declaredKind }
        guard let edge = connections.last(where: {
            $0.to == nodeId && $0.input == UInt32(inheritedInput)
        }) else { return port.declaredKind }
        var nextVisited = visited
        nextVisited.insert(reference)
        return resolvedOutputKind(nodeId: edge.from, output: edge.output,
                                  visited: nextVisited)
    }

    func connectionCompatibility(
        from source: GraphOutputReference,
        to targetNodeId: String,
        input targetInput: UInt32
    ) -> GraphConnectionCompatibility {
        guard source.node != targetNodeId else {
            return .incompatible(message: "A node cannot connect to itself.")
        }
        guard let sourceNode = node(id: source.node) else {
            return .incompatible(message: "The source output is unavailable.")
        }
        let sourceOutput = Self.canonicalOutputName(source.output,
                                                    for: sourceNode.type)
        guard
              Self.outputPorts(for: sourceNode.type).contains(where: {
                  $0.name == sourceOutput
              }) else {
            return .incompatible(message: "The source output is unavailable.")
        }
        guard let targetNode = node(id: targetNodeId),
              let targetPort = Self.inputPorts(for: targetNode.type)
                .first(where: { $0.index == targetInput }) else {
            return .incompatible(message: "The target input is unavailable.")
        }

        let possibleKinds = possibleOutputKinds(nodeId: source.node,
                                                output: sourceOutput)
        guard !possibleKinds.isEmpty else {
            return .incompatible(message: "The source output type could not be resolved.")
        }
        let replaces = connections.contains {
            $0.to == targetNodeId && $0.input == targetInput
        }
        let kindLabel = possibleKinds.count == 1
            ? possibleKinds.first!.rawValue
            : "unresolved"

        guard possibleKinds.isSubset(of: targetPort.acceptedKinds) else {
            if possibleKinds.count > 1 {
                return .incompatible(
                    message: "\(sourceOutput) depends on an upstream type. Connect its upstream input before using \(targetNode.id).\(targetPort.name).")
            }
            return .incompatible(
                message: "\(sourceOutput) is \(kindLabel); \(targetNode.id).\(targetPort.name) accepts \(Self.kindList(targetPort.acceptedKinds)).")
        }

        if targetNode.type == "combine" || targetNode.type == "blend" {
            let siblingEdges = connections.filter {
                $0.to == targetNodeId && $0.input != targetInput
            }
            for sibling in siblingEdges {
                let siblingKinds = possibleOutputKinds(nodeId: sibling.from,
                                                       output: sibling.output)
                guard !siblingKinds.isEmpty else { continue }
                if possibleKinds.isDisjoint(with: siblingKinds) {
                    return .incompatible(
                        message: "\(targetNode.id) requires matching field types on both inputs.")
                }
                if possibleKinds.count > 1 || siblingKinds.count > 1 {
                    return .pending(
                        message: "\(targetNode.id) will require both inputs to resolve to the same type.",
                        replacesExisting: replaces)
                }
            }
        }

        if possibleKinds.count > 1 {
            return .pending(
                message: "\(sourceOutput) will inherit its type from the upstream connection.",
                replacesExisting: replaces)
        }
        return .compatible(replacesExisting: replaces)
    }

    func compatibleNodeTargets(
        from source: GraphOutputReference,
        availableTypes: [String]
    ) -> [GraphCompatibleNodeTarget] {
        let possibleKinds = possibleOutputKinds(nodeId: source.node,
                                                output: source.output)
        guard !possibleKinds.isEmpty else { return [] }
        let sourceType = node(id: source.node)?.type ?? ""
        return availableTypes.compactMap { type in
            let compatible = Self.inputPorts(for: type)
                .filter { possibleKinds.isSubset(of: $0.acceptedKinds) }
                .sorted {
                    if $0.acceptedKinds.count != $1.acceptedKinds.count {
                        return $0.acceptedKinds.count < $1.acceptedKinds.count
                    }
                    return $0.index < $1.index
                }
            guard let input = compatible.first else { return nil }
            let recommendation = Self.contextualRecommendation(
                sourceType: sourceType,
                output: source.output,
                kinds: possibleKinds,
                targetType: type,
                input: input)
            return GraphCompatibleNodeTarget(
                nodeType: type,
                input: input,
                priority: recommendation.priority,
                reason: recommendation.reason)
        }.sorted {
            if $0.priority != $1.priority {
                return $0.priority < $1.priority
            }
            return $0.nodeType.localizedCaseInsensitiveCompare($1.nodeType)
                == .orderedAscending
        }
    }

    private static func contextualRecommendation(
        sourceType: String,
        output: String,
        kinds: Set<GraphFieldKind>,
        targetType: String,
        input: GraphInputPort
    ) -> (priority: Int, reason: String) {
        let onlyKind = kinds.count == 1 ? kinds.first : nil
        var ranked: [(String, String)]

        if output == "flow" {
            ranked = [
                ("rivercarve", "Use flow as a carve mask"),
                ("remap", "Shape the flow range"),
                ("normalize", "Normalize the flow map"),
                ("clamp", "Limit the flow range"),
                ("blur", "Smooth the flow map"),
                ("invert", "Invert the flow map"),
                ("export", "Export the flow map")
            ]
        } else if output == "ridge" {
            ranked = [
                ("remap", "Shape the ridge range"),
                ("normalize", "Normalize the ridge map"),
                ("clamp", "Limit the ridge range"),
                ("blur", "Smooth the ridge map"),
                ("invert", "Invert the ridge map"),
                ("export", "Export the ridge map")
            ]
        } else if onlyKind == .mask || output == "mask" {
            ranked = [
                ("rivercarve", "Use mask to carve terrain"),
                ("invert", "Invert the mask"),
                ("remap", "Shape the mask range"),
                ("blur", "Soften the mask"),
                ("clamp", "Limit the mask range"),
                ("normalize", "Normalize the mask"),
                ("export", "Export the mask")
            ]
        } else if onlyKind == .terrain {
            ranked = [
                ("thermal", "Add thermal erosion"),
                ("fluvial", "Add fluvial erosion"),
                ("erosionfilter", "Extract terrain ridges"),
                ("terrace", "Create stepped terrain"),
                ("warp", "Distort terrain features"),
                ("river", "Derive a river mask"),
                ("slopemask", "Derive a slope mask"),
                ("rivercarve", "Use as carve terrain"),
                ("export", "Export the terrain")
            ]
        } else {
            ranked = [
                ("remap", "Shape the field range"),
                ("normalize", "Normalize the field"),
                ("clamp", "Limit the field range"),
                ("blur", "Smooth the field"),
                ("invert", "Invert the field"),
                ("export", "Export the field")
            ]
        }

        if let index = ranked.firstIndex(where: { $0.0 == targetType }) {
            let repeatedPenalty = targetType == sourceType ? 20 : 0
            return (index + repeatedPenalty, ranked[index].1)
        }
        if targetType == "combine" || targetType == "blend" {
            return (24, "Combine with another \(onlyKind?.rawValue ?? "field")")
        }
        let accepted = input.acceptsEveryKind
            ? "Continue processing this field"
            : "Connect to \(input.name)"
        return (40, accepted)
    }

    func terrainReference(for reference: GraphOutputReference,
                          visited: Set<String> = []) -> GraphOutputReference? {
        guard !visited.contains(reference.node),
              let graphNode = node(id: reference.node) else { return nil }
        for port in Self.outputPorts(for: graphNode.type) {
            if resolvedOutputKind(nodeId: reference.node, output: port.name) == .terrain {
                return GraphOutputReference(node: reference.node, output: port.name)
            }
        }
        var nextVisited = visited
        nextVisited.insert(reference.node)
        var effectiveInputs: [UInt32: GraphDocumentConnection] = [:]
        for edge in connections where edge.to == reference.node {
            effectiveInputs[edge.input] = edge
        }
        for edge in effectiveInputs.values.sorted(by: { $0.input < $1.input }) {
            let upstream = GraphOutputReference(node: edge.from, output: edge.output)
            if let terrain = terrainReference(for: upstream, visited: nextVisited) {
                return terrain
            }
        }
        return nil
    }

    func isOutputEvaluable(_ reference: GraphOutputReference) -> Bool {
        outputDependenciesAreComplete(reference, visiting: [])
    }

    private func outputDependenciesAreComplete(
        _ reference: GraphOutputReference,
        visiting: Set<String>
    ) -> Bool {
        guard let graphNode = node(id: reference.node) else { return false }
        let canonicalOutput = Self.canonicalOutputName(reference.output,
                                                       for: graphNode.type)
        guard
              Self.outputPorts(for: graphNode.type).contains(where: {
                  $0.name == canonicalOutput
              }),
              !visiting.contains(reference.node) else { return false }

        var nextVisiting = visiting
        nextVisiting.insert(reference.node)
        var inputKinds: [GraphFieldKind] = []
        for input in 0..<inputCount(for: graphNode.type) {
            guard let edge = connections.last(where: {
                $0.to == reference.node && $0.input == input
            }) else { return false }
            let upstream = GraphOutputReference(node: edge.from, output: edge.output)
            guard outputDependenciesAreComplete(upstream, visiting: nextVisiting),
                  let upstreamKind = resolvedOutputKind(nodeId: edge.from,
                                                        output: edge.output) else {
                return false
            }
            let accepted = Self.inputKinds(for: graphNode.type, input: input)
            guard accepted.isEmpty || accepted.contains(upstreamKind) else { return false }
            inputKinds.append(upstreamKind)
        }

        if (graphNode.type == "combine" || graphNode.type == "blend"),
           inputKinds.count == 2, inputKinds[0] != inputKinds[1] {
            return false
        }
        return true
    }

    mutating func setSink(nodeId: String, output: String = "") {
        sink = nodeId
        guard let type = node(id: nodeId)?.type else {
            sinkOutput = ""
            return
        }
        let names = Set(Self.outputPorts(for: type).map(\.name))
        let canonical = Self.canonicalOutputName(output, for: type)
        sinkOutput = names.contains(canonical)
            ? canonical : Self.defaultOutputName(for: type)
    }

    static func outputPorts(for type: String) -> [GraphOutputPort] {
        NodeTypeMetadataCache.shared.outputPorts(for: type) {
            uncachedOutputPorts(for: type)
        }
    }

    private static func uncachedOutputPorts(for type: String) -> [GraphOutputPort] {
        let count = theia.graph_node_type_output_count(type)
        return (0..<count).compactMap { index in
            let name = readCxxString {
                theia.graph_node_type_output_name(type, index, $0, $1)
            }
            let kindName = readCxxString {
                theia.graph_node_type_output_kind(type, index, $0, $1)
            }
            guard !name.isEmpty, let kind = GraphFieldKind(rawValue: kindName) else {
                return nil
            }
            let inherited = theia.graph_node_type_output_inherit_input(type, index)
            return GraphOutputPort(name: name,
                                   declaredKind: kind,
                                   inheritInput: inherited >= 0 ? Int(inherited) : nil,
                                   isDefault: theia.graph_node_type_output_is_default(type, index))
        }
    }

    static func inputPorts(for type: String) -> [GraphInputPort] {
        NodeTypeMetadataCache.shared.inputPorts(for: type) {
            uncachedInputPorts(for: type)
        }
    }

    private static func uncachedInputPorts(for type: String) -> [GraphInputPort] {
        let count = theia.graph_node_type_input_count(type)
        return (0..<count).map { index in
            let name = readCxxString {
                theia.graph_node_type_input_name(type, index, $0, $1)
            }
            let kinds = Set(readCxxString {
                theia.graph_node_type_input_kinds(type, index, $0, $1)
            }.split(separator: ",").compactMap {
                GraphFieldKind(rawValue: String($0))
            })
            return GraphInputPort(index: index,
                                  name: name.isEmpty ? "input\(index)" : name,
                                  acceptedKinds: kinds)
        }
    }

    private static func inputKinds(for type: String,
                                   input: UInt32) -> Set<GraphFieldKind> {
        inputPorts(for: type)
            .first(where: { $0.index == input })?.acceptedKinds ?? []
    }

    private static func kindList(_ kinds: Set<GraphFieldKind>) -> String {
        GraphFieldKind.allCases
            .filter(kinds.contains)
            .map(\.rawValue)
            .joined(separator: "/")
    }

    static func defaultOutputName(for type: String) -> String {
        let ports = outputPorts(for: type)
        return ports.first(where: \.isDefault)?.name ?? ports.first?.name ?? ""
    }

    static func canonicalOutputName(_ authoredName: String,
                                    for type: String) -> String {
        if authoredName.isEmpty { return defaultOutputName(for: type) }
        if authoredName == "height" {
            let ports = outputPorts(for: type)
            if !ports.contains(where: { $0.name == "height" }),
               ports.contains(where: {
                   $0.name == "terrain" && $0.declaredKind == .terrain
               }) {
                return "terrain"
            }
        }
        return authoredName
    }

    static func defaultParams(for type: String) -> [String: Double] {
        NodeTypeMetadataCache.shared.defaultParams(for: type) {
            uncachedDefaultParams(for: type)
        }
    }

    private static func uncachedDefaultParams(for type: String) -> [String: Double] {
        var result: [String: Double] = [:]
        let count = theia.graph_default_param_count(type)
        for i in 0..<count {
            let name = readCxxString { theia.graph_default_param_name(type, i, $0, $1) }
            result[name] = theia.graph_default_param_value(type, name, 0)
        }
        return result
    }

    private func uniqueNodeId(base: String) -> String {
        var id = base
        var suffix = 1
        while nodes.contains(where: { $0.id == id }) {
            id = "\(base)\(suffix)"
            suffix += 1
        }
        return id
    }
}
