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

enum GraphFieldKind: String, Codable {
    case terrain
    case mask
    case data
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

struct GraphMaterialLayer: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var previewColorSRGB: [Double]
    var source: GraphOutputReference?

    enum CodingKeys: String, CodingKey {
        case id, name, previewColorSRGB, source
    }

    init(id: String, name: String, previewColorSRGB: [Double],
         source: GraphOutputReference? = nil) {
        self.id = id
        self.name = name
        self.previewColorSRGB = previewColorSRGB
        self.source = source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        previewColorSRGB = try c.decode([Double].self, forKey: .previewColorSRGB)
        if c.contains(.source), try c.decodeNil(forKey: .source) {
            throw DecodingError.dataCorruptedError(forKey: .source, in: c,
                debugDescription: "material source must be an object when present")
        }
        source = try c.decodeIfPresent(GraphOutputReference.self, forKey: .source)
        guard !id.isEmpty, !name.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c,
                debugDescription: "material layer id/name must not be empty")
        }
        guard previewColorSRGB.count == 3,
              previewColorSRGB.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
            throw DecodingError.dataCorruptedError(forKey: .previewColorSRGB, in: c,
                debugDescription: "previewColorSRGB must contain three finite values in [0,1]")
        }
        if let source, source.node.isEmpty || source.output.isEmpty {
            throw DecodingError.dataCorruptedError(forKey: .source, in: c,
                debugDescription: "material source node/output must not be empty")
        }
    }
}

struct GraphMaterialStack: Codable, Equatable, Sendable {
    var terrain: GraphOutputReference
    var layers: [GraphMaterialLayer]

    enum CodingKeys: String, CodingKey { case terrain, layers }

    init(terrain: GraphOutputReference, layers: [GraphMaterialLayer]) {
        self.terrain = terrain
        self.layers = layers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        terrain = try c.decode(GraphOutputReference.self, forKey: .terrain)
        layers = try c.decode([GraphMaterialLayer].self, forKey: .layers)
        guard !terrain.node.isEmpty, !terrain.output.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .terrain, in: c,
                debugDescription: "material terrain reference must not be empty")
        }
        guard (1...4).contains(layers.count) else {
            throw DecodingError.dataCorruptedError(forKey: .layers, in: c,
                debugDescription: "material stack requires one to four layers")
        }
        guard layers[0].source == nil else {
            throw DecodingError.dataCorruptedError(forKey: .layers, in: c,
                debugDescription: "material base layer must not have a source")
        }
        // A missing overlay source is a repairable semantic state. Viewer node
        // deletion clears the reference without deleting/reordering the layer,
        // while material validation still blocks preview and export.
        guard Set(layers.map(\.id)).count == layers.count else {
            throw DecodingError.dataCorruptedError(forKey: .layers, in: c,
                debugDescription: "material layer ids must be unique")
        }
    }
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

struct GraphDocument: Codable {
    var formatVersion: Int
    var resolution: GraphResolution
    var sink: String
    var sinkOutput: String
    var nodes: [GraphDocumentNode]
    var connections: [GraphDocumentConnection]
    var materialStack: GraphMaterialStack?
    var ui: GraphDocumentUI?

    enum CodingKeys: String, CodingKey {
        case formatVersion, resolution, sink, sinkOutput, nodes, connections,
             materialStack, ui
    }

    init(formatVersion: Int = 3,
         resolution: GraphResolution,
         sink: String,
         sinkOutput: String = "",
         nodes: [GraphDocumentNode],
         connections: [GraphDocumentConnection],
         materialStack: GraphMaterialStack? = nil,
         ui: GraphDocumentUI?) {
        self.formatVersion = formatVersion
        self.resolution = resolution
        self.sink = sink
        self.sinkOutput = sinkOutput
        self.nodes = nodes
        self.connections = connections
        self.materialStack = materialStack
        self.ui = ui
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        resolution = try c.decodeIfPresent(GraphResolution.self, forKey: .resolution)
            ?? GraphResolution(width: 512, height: 512)
        sink = try c.decodeIfPresent(String.self, forKey: .sink) ?? ""
        sinkOutput = try c.decodeIfPresent(String.self, forKey: .sinkOutput) ?? ""
        nodes = try c.decodeIfPresent([GraphDocumentNode].self, forKey: .nodes) ?? []
        connections = try c.decodeIfPresent([GraphDocumentConnection].self, forKey: .connections) ?? []
        materialStack = try c.decodeIfPresent(GraphMaterialStack.self,
                                               forKey: .materialStack)
        guard (1...3).contains(formatVersion) else {
            throw DecodingError.dataCorruptedError(forKey: .formatVersion, in: c,
                debugDescription: "unsupported graph formatVersion \(formatVersion)")
        }
        if materialStack != nil && formatVersion < 3 {
            throw DecodingError.dataCorruptedError(forKey: .materialStack, in: c,
                debugDescription: "materialStack requires formatVersion 3")
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
        try c.encodeIfPresent(materialStack, forKey: .materialStack)
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

    static func emptyDocument(width: UInt32 = 512, height: UInt32 = 512) -> GraphDocument {
        GraphDocument(formatVersion: 3,
                      resolution: GraphResolution(width: width, height: height),
                      sink: "",
                      sinkOutput: "",
                      nodes: [],
                      connections: [],
                      ui: GraphDocumentUI())
    }

    mutating func ensureLayout() {
        formatVersion = 3
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
        for index in connections.indices where connections[index].output.isEmpty {
            guard let source = node(id: connections[index].from) else { continue }
            connections[index].output = Self.defaultOutputName(for: source.type)
        }
        if sink.isEmpty {
            sinkOutput = ""
        } else if let sinkNode = node(id: sink) {
            let names = Set(Self.outputPorts(for: sinkNode.type).map(\.name))
            if sinkOutput.isEmpty || !names.contains(sinkOutput) {
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
        if var stack = materialStack {
            for index in stack.layers.indices where
                stack.layers[index].source?.node == id {
                stack.layers[index].source = nil
            }
            materialStack = stack
        }
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
        if var stack = materialStack {
            for index in stack.layers.indices where
                stack.layers[index].source.map({ ids.contains($0.node) }) == true {
                stack.layers[index].source = nil
            }
            materialStack = stack
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
        let resolvedOutput = output.isEmpty
            ? node(id: from).map { Self.defaultOutputName(for: $0.type) } ?? ""
            : output
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

    func resolvedOutputKind(nodeId: String, output: String,
                            visited: Set<GraphOutputReference> = []) -> GraphFieldKind? {
        guard let graphNode = node(id: nodeId) else { return nil }
        let selected = output.isEmpty ? Self.defaultOutputName(for: graphNode.type) : output
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

    func materialTerrainCandidates() -> [GraphOutputReference] {
        nodes.flatMap { graphNode in
            Self.outputPorts(for: graphNode.type).compactMap { port in
                let reference = GraphOutputReference(node: graphNode.id,
                                                     output: port.name)
                return resolvedOutputKind(nodeId: graphNode.id,
                                          output: port.name) == .terrain &&
                    isOutputEvaluable(reference) ? reference : nil
            }
        }
    }

    func materialSourceCandidates() -> [GraphOutputReference] {
        nodes.flatMap { graphNode in
            Self.outputPorts(for: graphNode.type).compactMap { port in
                let reference = GraphOutputReference(node: graphNode.id,
                                                     output: port.name)
                guard let kind = resolvedOutputKind(nodeId: graphNode.id,
                                                    output: port.name),
                      kind == .mask || kind == .data,
                      isOutputEvaluable(reference) else { return nil }
                return reference
            }
        }
    }

    /// Material sources not already assigned to another overlay. When editing an
    /// existing layer, pass its index so its current source remains available.
    func unusedMaterialSourceCandidates(excludingLayerAt excludedIndex: Int? = nil)
        -> [GraphOutputReference] {
        let assigned: [GraphOutputReference] = materialStack?.layers.enumerated()
            .compactMap { index, layer in
            guard index > 0, index != excludedIndex else { return nil }
            return layer.source
        } ?? []
        let used = Set<GraphOutputReference>(assigned)
        return materialSourceCandidates().filter { !used.contains($0) }
    }

    /// Stable candidate order with unused outputs first. Used sources remain in
    /// the result because duplicate references are legal when explicitly chosen.
    func materialSourceCandidatesPrioritizingUnused(
        excludingLayerAt excludedIndex: Int? = nil
    ) -> [GraphOutputReference] {
        let all = materialSourceCandidates()
        let unused = Set(unusedMaterialSourceCandidates(
            excludingLayerAt: excludedIndex))
        return all.filter { unused.contains($0) } + all.filter { !unused.contains($0) }
    }

    /// Conservative authoring-time evaluability check. Node evaluation is atomic,
    /// so every required input dependency must be complete even when only one
    /// named output is being considered as a material source.
    func isOutputEvaluable(_ reference: GraphOutputReference) -> Bool {
        outputDependenciesAreComplete(reference, visiting: [])
    }

    private func outputDependenciesAreComplete(
        _ reference: GraphOutputReference,
        visiting: Set<String>
    ) -> Bool {
        guard let graphNode = node(id: reference.node),
              Self.outputPorts(for: graphNode.type).contains(where: {
                  $0.name == reference.output
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

    func materialStackValidationMessage() -> String? {
        guard let stack = materialStack else { return "No material stack configured" }
        guard resolvedOutputKind(nodeId: stack.terrain.node,
                                 output: stack.terrain.output) == .terrain,
              isOutputEvaluable(stack.terrain) else {
            return "Choose a valid terrain output"
        }
        guard (1...4).contains(stack.layers.count), stack.layers[0].source == nil else {
            return "Material stack structure is invalid"
        }
        for layer in stack.layers.dropFirst() {
            guard let source = layer.source,
                  let kind = resolvedOutputKind(nodeId: source.node,
                                                output: source.output),
                  (kind == .mask || kind == .data),
                  isOutputEvaluable(source) else {
                return "Layer \(layer.name) needs a mask or data source"
            }
        }
        return nil
    }

    mutating func createMaterialStack(terrain: GraphOutputReference) {
        materialStack = GraphMaterialStack(
            terrain: terrain,
            layers: [GraphMaterialLayer(id: "base", name: "Ground",
                                        previewColorSRGB: [0.42, 0.35, 0.26])])
    }

    mutating func setMaterialTerrain(_ reference: GraphOutputReference) {
        materialStack?.terrain = reference
    }

    mutating func setMaterialLayerName(index: Int, name: String) {
        guard materialStack?.layers.indices.contains(index) == true else { return }
        materialStack?.layers[index].name = name.isEmpty ? "Layer \(index + 1)" : name
    }

    mutating func setMaterialLayerColor(index: Int, color: [Double]) {
        guard materialStack?.layers.indices.contains(index) == true,
              color.count == 3,
              color.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else { return }
        materialStack?.layers[index].previewColorSRGB = color
    }

    mutating func setMaterialLayerSource(index: Int,
                                         source: GraphOutputReference) {
        guard index > 0, materialStack?.layers.indices.contains(index) == true else { return }
        materialStack?.layers[index].source = source
    }

    @discardableResult
    mutating func addMaterialLayer(source: GraphOutputReference) -> Bool {
        guard var stack = materialStack, stack.layers.count < 4 else { return false }
        let base = "layer"
        var suffix = stack.layers.count
        var id = "\(base)\(suffix)"
        let existing = Set(stack.layers.map(\.id))
        while existing.contains(id) {
            suffix += 1
            id = "\(base)\(suffix)"
        }
        let palette: [[Double]] = [
            [0.46, 0.45, 0.42], [0.18, 0.42, 0.62], [0.86, 0.88, 0.90]
        ]
        let overlayIndex = stack.layers.count - 1
        stack.layers.append(GraphMaterialLayer(
            id: id, name: "Layer \(stack.layers.count + 1)",
            previewColorSRGB: palette[min(overlayIndex, palette.count - 1)],
            source: source))
        materialStack = stack
        return true
    }

    mutating func removeMaterialLayer(index: Int) {
        guard index > 0, materialStack?.layers.indices.contains(index) == true else { return }
        materialStack?.layers.remove(at: index)
    }

    mutating func moveMaterialLayer(from index: Int, offset: Int) {
        guard index > 0, let count = materialStack?.layers.count else { return }
        let destination = index + offset
        guard destination > 0, destination < count else { return }
        guard let layer = materialStack?.layers.remove(at: index) else { return }
        materialStack?.layers.insert(layer, at: destination)
    }

    mutating func setSink(nodeId: String, output: String = "") {
        sink = nodeId
        guard let type = node(id: nodeId)?.type else {
            sinkOutput = ""
            return
        }
        let names = Set(Self.outputPorts(for: type).map(\.name))
        sinkOutput = !output.isEmpty && names.contains(output)
            ? output : Self.defaultOutputName(for: type)
    }

    static func outputPorts(for type: String) -> [GraphOutputPort] {
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

    private static func inputKinds(for type: String,
                                   input: UInt32) -> Set<GraphFieldKind> {
        Set(readCxxString {
            theia.graph_node_type_input_kinds(type, input, $0, $1)
        }.split(separator: ",").compactMap {
            GraphFieldKind(rawValue: String($0))
        })
    }

    static func defaultOutputName(for type: String) -> String {
        let ports = outputPorts(for: type)
        return ports.first(where: \.isDefault)?.name ?? ports.first?.name ?? ""
    }

    static func defaultParams(for type: String) -> [String: Double] {
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
