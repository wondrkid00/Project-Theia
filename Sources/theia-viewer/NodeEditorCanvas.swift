import AppKit
import SwiftUI

private let minCanvasZoom = 0.35
private let maxCanvasZoom = 2.5

private struct CanvasNodePickerState {
    let source: GraphOutputReference?
    let screenPoint: CGPoint
    let documentPoint: GraphNodePosition
    let targets: [GraphCompatibleNodeTarget]
    let availableTypes: [String]
}

private enum NodePickerSelection {
    case compatible(GraphCompatibleNodeTarget)
    case nodeType(String)
}

enum NodePickerGeometry {
    static let size = CGSize(width: 296, height: 310)
    private static let gap: CGFloat = 12
    private static let margin: CGFloat = 8

    static func position(anchor: CGPoint,
                         canvasSize: CGSize,
                         obstructionRects: [CGRect],
                         sourceRect: CGRect?) -> CGPoint {
        let safeRect = CGRect(
            x: margin,
            y: margin,
            width: max(0, canvasSize.width - margin * 2),
            height: max(0, canvasSize.height - margin * 2))
        let toolbarRect = CGRect(x: 0, y: 0,
                                 width: canvasSize.width, height: 58)

        let rawOrigins = [
            (CGPoint(x: anchor.x + gap, y: anchor.y - 30), CGFloat.zero),
            (CGPoint(x: anchor.x + gap, y: anchor.y + gap), CGFloat(1_200)),
            (CGPoint(x: anchor.x + gap,
                     y: anchor.y - size.height - gap), CGFloat(1_200)),
            (CGPoint(x: anchor.x - size.width - gap,
                     y: anchor.y - 30), CGFloat.zero),
            (CGPoint(x: anchor.x - size.width - gap,
                     y: anchor.y + gap), CGFloat(1_200)),
            (CGPoint(x: anchor.x - size.width - gap,
                     y: anchor.y - size.height - gap), CGFloat(1_200)),
        ]

        let candidates = rawOrigins.map { raw, alignmentPenalty -> (CGRect, CGFloat) in
            let maxX = max(safeRect.minX, safeRect.maxX - size.width)
            let maxY = max(safeRect.minY, safeRect.maxY - size.height)
            let origin = CGPoint(
                x: min(max(raw.x, safeRect.minX), maxX),
                y: min(max(raw.y, safeRect.minY), maxY))
            let rect = CGRect(origin: origin, size: size)
            let clampDistance = abs(origin.x - raw.x) + abs(origin.y - raw.y)
            let overlap = obstructionRects.reduce(CGFloat.zero) { total, item in
                let intersection = rect.intersection(item)
                guard !intersection.isNull else { return total }
                return total + intersection.width * intersection.height
            }
            let sourceOverlap: CGFloat
            if let sourceRect {
                let intersection = rect.intersection(sourceRect)
                sourceOverlap = intersection.isNull
                    ? 0 : intersection.width * intersection.height
            } else {
                sourceOverlap = 0
            }
            let toolbarIntersection = rect.intersection(toolbarRect)
            let toolbarOverlap = toolbarIntersection.isNull
                ? 0 : toolbarIntersection.width * toolbarIntersection.height
            return (rect, overlap * 4 + sourceOverlap * 12 +
                    toolbarOverlap * 10 + clampDistance * 8 +
                    alignmentPenalty)
        }

        let best = candidates.enumerated().min {
            if $0.element.1 != $1.element.1 {
                return $0.element.1 < $1.element.1
            }
            return $0.offset < $1.offset
        }?.element.0 ?? CGRect(origin: CGPoint(x: margin,
                                               y: margin),
                               size: size)
        return CGPoint(x: best.midX, y: best.midY)
    }
}

struct NodeTypeGroup: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let types: [String]
}

enum NodeTypeCatalog {
    static let terrainTypes = [
        "rollinghills", "mountain", "mountainrange", "canyon",
        "crater", "craterfield", "dunesea", "mountainside",
        "plates", "ridge", "rugged", "slump", "uplift", "volcano",
    ]
    static let quickStartTypes = [
        "rollinghills", "mountain", "mountainrange", "canyon",
    ]

    private static let hiddenTypes: Set<String> = ["ridged"]

    private static let groups: [NodeTypeGroup] = [
        NodeTypeGroup(id: "terrain", title: "Terrain", systemImage: "mountain.2",
                      types: terrainTypes),
        NodeTypeGroup(id: "noise", title: "Noise", systemImage: "waveform.path.ecg",
                      types: ["perlin"]),
        NodeTypeGroup(id: "shape", title: "Shape", systemImage: "slider.horizontal.3",
                      types: ["scalebias", "normalize", "terrace"]),
        NodeTypeGroup(id: "combine", title: "Combine", systemImage: "square.stack.3d.up",
                      types: ["combine", "blend"]),
        NodeTypeGroup(id: "filter", title: "Filter", systemImage: "camera.filters",
                      types: ["blur", "warp"]),
        NodeTypeGroup(id: "mask", title: "Mask", systemImage: "circle.lefthalf.filled",
                      types: ["slopemask", "invert", "clamp", "remap"]),
        // `fluvial` leads: it is the only erosion node driven by upstream
        // drainage area, so it is the one that produces branching valley
        // networks. The storm-scale and particle models follow as legacy.
        NodeTypeGroup(id: "erosion", title: "Erosion", systemImage: "drop.triangle",
                      types: ["fluvial", "thermal", "erosionfilter"]),
        NodeTypeGroup(id: "erosionLegacy", title: "Erosion (Legacy)",
                      systemImage: "clock.arrow.circlepath",
                      types: ["hydraulic", "dropleterosion"]),
        NodeTypeGroup(id: "river", title: "River", systemImage: "water.waves",
                      types: ["river", "rivercarve"]),
        NodeTypeGroup(id: "output", title: "Output", systemImage: "square.and.arrow.up",
                      types: ["export"]),
    ]

    static func grouped(_ availableTypes: [String]) -> [NodeTypeGroup] {
        let available = Set(availableTypes.filter(isPresented))
        var used = Set<String>()
        var result: [NodeTypeGroup] = []
        for group in groups {
            let types = group.types.filter { available.contains($0) }
            if types.isEmpty { continue }
            used.formUnion(types)
            result.append(NodeTypeGroup(id: group.id,
                                        title: group.title,
                                        systemImage: group.systemImage,
                                        types: types))
        }
        let uncategorized = availableTypes.filter {
            isPresented($0) && !used.contains($0)
        }
        if !uncategorized.isEmpty {
            result.append(NodeTypeGroup(id: "other",
                                        title: "Other",
                                        systemImage: "ellipsis.circle",
                                        types: uncategorized))
        }
        return result
    }

    static func filteredGroups(_ groups: [NodeTypeGroup],
                               query rawQuery: String) -> [NodeTypeGroup] {
        let query = rawQuery.trimmingCharacters(
            in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            let matchesGroup = group.title.lowercased().contains(query)
            let types = group.types.filter { type in
                matchesGroup ||
                    type.lowercased().contains(query) ||
                    title(for: type).lowercased().contains(query)
            }
            guard !types.isEmpty else { return nil }
            return NodeTypeGroup(id: group.id,
                                 title: group.title,
                                 systemImage: group.systemImage,
                                 types: types)
        }
    }

    static func title(for type: String) -> String {
        switch type {
        case "rollinghills": return "Rolling Hills"
        case "mountainrange": return "Mountain Range"
        case "craterfield": return "Crater Field"
        case "dunesea": return "Dune Sea"
        case "mountainside": return "Mountain Side"
        case "scalebias": return "Scale Bias"
        case "dropleterosion": return "Droplet Erosion"
        case "erosionfilter": return "Erosion Filter"
        case "rivercarve": return "River Carve"
        case "slopemask": return "Slope Mask"
        case "fluvial": return "Fluvial Erosion"
        case "hydraulic": return "Hydraulic (Legacy)"
        default:
            return type.prefix(1).uppercased() + type.dropFirst()
        }
    }

    static func icon(for type: String) -> String {
        switch type {
        case "rollinghills": return "waveform.path"
        case "mountain": return "mountain.2.fill"
        case "mountainrange": return "mountain.2"
        case "canyon": return "arrow.down.to.line.compact"
        case "crater": return "circle.circle"
        case "craterfield": return "circle.grid.2x2"
        case "dunesea": return "water.waves"
        case "mountainside": return "triangle.lefthalf.filled"
        case "plates": return "square.grid.3x3.fill"
        case "ridge": return "waveform.path.ecg"
        case "rugged": return "bolt.horizontal.circle"
        case "slump": return "arrow.down.right.circle"
        case "uplift": return "arrow.up.circle"
        case "volcano": return "triangle.fill"
        case "perlin": return "waveform.path.ecg"
        default:
            return groups.first(where: { $0.types.contains(type) })?.systemImage
                ?? "square.dashed"
        }
    }

    static func subtitle(for type: String) -> String {
        switch type {
        case "rollinghills": return "Soft rolling landforms"
        case "mountain": return "Single mountain mass"
        case "mountainrange": return "Connected mountain chain"
        case "canyon": return "Incised canyon network"
        case "crater": return "Single impact basin"
        case "craterfield": return "Scattered impact basins"
        case "dunesea": return "Wind-shaped dune field"
        case "mountainside": return "Directional mountain slope"
        case "plates": return "Tectonic plate relief"
        case "ridge": return "Linear ridge crest"
        case "rugged": return "Broken rocky terrain"
        case "slump": return "Downslope mass movement"
        case "uplift": return "Broad tectonic rise"
        case "volcano": return "Volcanic cone and crater"
        default: return title(for: type)
        }
    }

    static func isPresented(_ type: String) -> Bool {
        !hiddenTypes.contains(type)
    }

    static func nodeTitle(id: String, type: String) -> String {
        let typeTitle = title(for: type)
        if id == type { return typeTitle }
        if id.hasPrefix(type) {
            let suffix = String(id.dropFirst(type.count))
            if let index = Int(suffix), !suffix.isEmpty {
                return "\(typeTitle) \(index + 1)"
            }
        }
        return humanized(id)
    }

    private static func humanized(_ value: String) -> String {
        var result = ""
        for scalar in value.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ").unicodeScalars {
            if CharacterSet.uppercaseLetters.contains(scalar),
               !result.isEmpty, !result.hasSuffix(" ") {
                result.append(" ")
            }
            result.unicodeScalars.append(scalar)
        }
        guard let first = result.first else { return value }
        return first.uppercased() + result.dropFirst()
    }
}

struct NodeEditorCanvas: View {
    @ObservedObject var model: TerrainModel
    let viewport: TerrainMTKView

    @State private var pan = CGSize(width: 24, height: 24)
    @State private var panDragStart: CGSize?
    @State private var zoom = 1.0
    @State private var nodeDragStarts: [String: GraphNodePosition] = [:]
    @State private var nodeDragId: String?
    @State private var marqueeStart: CGPoint?
    @State private var marqueeEnd: CGPoint?
    @State private var pendingSource: GraphOutputReference?
    @State private var pendingPoint: CGPoint?
    @State private var nodePicker: CanvasNodePickerState?
    @State private var connectionFeedback: String?
    @State private var feedbackGeneration = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color(nsColor: .underPageBackgroundColor)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        nodePicker = nil
                        pendingSource = nil
                        pendingPoint = nil
                        model.clearSelectionToFlat()
                        viewport.setNeedsDisplay(viewport.bounds)
                    }

                CanvasGrid(pan: pan, zoom: zoom)
                    .allowsHitTesting(false)

                ForEach(model.document.connections) { edge in
                    EdgeView(edge: edge,
                             start: screen(outputPort(edge.from, output: edge.output)),
                             end: screen(inputPort(edge.to, input: edge.input)),
                             color: edgeColor(edge),
                             selected: model.selectedConnectionId == edge.id,
                             zoom: zoom)
                        .onTapGesture {
                            model.selectConnection(edge.id)
                        }
                        .contextMenu {
                            Button("Disconnect") {
                                model.disconnect(edge)
                            }
                        }
                }

                if let source = pendingSource, let point = pendingPoint {
                    EdgeShape(start: screen(outputPort(source.node,
                                                       output: source.output)),
                              end: point,
                              minHandle: 50 * CGFloat(zoom))
                        .stroke(sourceColor(source),
                                style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }

                if let rect = marqueeRect {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.16))
                        .overlay(Rectangle()
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }

                if model.document.nodes.isEmpty {
                    EmptyGraphQuickAdd(availableTypes: model.availableNodeTypes) { kind in
                        model.addQuickStart(kind: kind)
                        viewport.setNeedsDisplay(viewport.bounds)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                ForEach(model.document.nodes) { node in
                    let inputs = model.inputPorts(for: node.id)
                    NodeCard(node: node,
                             position: screen(nodePosition(node.id)),
                             selected: model.selectedNodeIds.contains(node.id),
                             inputPorts: inputs,
                             outputPorts: model.outputPorts(for: node.id),
                             connectedInputs: connectedInputs(for: node.id),
                             missingInputs: model.missingDiagnosticInputs(for: node.id),
                             inputDragStates: dragStates(for: node.id,
                                                        inputs: inputs),
                             diagnosticSeverity: model.diagnosticSeverity(for: node.id),
                             onSelect: {
                                 if model.selectedNodeId != node.id {
                                     selectNode(node.id)
                                 }
                             },
                             onDelete: { model.selectNode(node.id); model.deleteSelection() },
                             onDuplicate: { model.selectNode(node.id); model.duplicateSelection() },
                             onSelectUpstream: { model.selectNode(node.id); model.selectUpstreamOfSelection() },
                             onSelectDownstream: { model.selectNode(node.id); model.selectDownstreamOfSelection() },
                             onInputDisconnect: { input in
                                 if let edge = model.document.connections.first(where: {
                                     $0.to == node.id && $0.input == input
                                 }) {
                                     model.disconnect(edge)
                                     viewport.setNeedsDisplay(viewport.bounds)
                                 }
                             },
                             onOutputPreview: { output in
                                 model.selectOutput(nodeId: node.id, output: output)
                                 viewport.setNeedsDisplay(viewport.bounds)
                             },
                             onOutputDragChanged: { output, point in
                                 nodePicker = nil
                                 connectionFeedback = nil
                                 pendingSource = GraphOutputReference(node: node.id,
                                                                      output: output)
                                 pendingPoint = point
                             },
                             onOutputDragEnded: { output, point in
                                 finishConnectionDrop(
                                    from: GraphOutputReference(node: node.id,
                                                               output: output),
                                    point: point)
                             },
                             zoom: zoom)
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            if nodeDragId != node.id {
                                nodeDragId = node.id
                                if !model.selectedNodeIds.contains(node.id) {
                                    model.selectNode(node.id)
                                }
                                model.beginInteractiveMove()
                                nodeDragStarts = Dictionary(uniqueKeysWithValues:
                                    model.dragSelection(for: node.id).map {
                                        ($0, model.position(for: $0))
                                    })
                            }
                            let moved = nodeDragStarts.mapValues {
                                GraphNodePosition(
                                    x: $0.x + value.translation.width / zoom,
                                    y: $0.y + value.translation.height / zoom)
                            }
                            model.moveNodes(to: moved)
                        }
                        .onEnded { _ in
                            nodeDragId = nil
                            nodeDragStarts = [:]
                            model.endInteractiveMove()
                        })
                }

            }
            .coordinateSpace(name: "node-canvas")
            .clipped()
            .overlay(
                CanvasMouseEventView(
                    onChanged: { delta in
                        if panDragStart == nil { panDragStart = pan }
                        guard let start = panDragStart else { return }
                        pan = CGSize(width: start.width + delta.width,
                                     height: start.height - delta.height)
                    },
                    onEnded: {
                        panDragStart = nil
                    },
                    onZoom: { delta, point in
                        zoomCanvas(delta: delta, anchor: point)
                    },
                    onPanBy: { delta in
                        pan = CGSize(width: pan.width + delta.width,
                                     height: pan.height + delta.height)
                    },
                    onRequestAddNode: { point in
                        let doc = documentPoint(point)
                        pendingSource = nil
                        pendingPoint = nil
                        nodePicker = CanvasNodePickerState(
                            source: nil,
                            screenPoint: point,
                            documentPoint: GraphNodePosition(x: doc.x, y: doc.y),
                            targets: [],
                            availableTypes: model.availableNodeTypes)
                    },
                    isOverNode: { point in
                        model.document.nodes.contains { node in
                            let origin = screen(nodePosition(node.id))
                            let size = nodeCardSize(node)
                            return CGRect(x: origin.x, y: origin.y,
                                          width: size.width * zoom,
                                          height: size.height * zoom)
                                .contains(point)
                        }
                    })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("node-canvas"))
                .onChanged { value in
                    if marqueeStart == nil {
                        marqueeStart = value.startLocation
                    }
                    marqueeEnd = value.location
                    updateMarqueeSelection()
                }
                .onEnded { _ in
                    updateMarqueeSelection()
                    marqueeStart = nil
                    marqueeEnd = nil
                })
            .onChange(of: geo.size) { _, _ in }
            .overlay(alignment: .topLeading) {
                CanvasToolbar(model: model, zoom: $zoom, viewport: viewport)
                    .padding(.top, 10)
                    .padding(.leading, 8)
            }
            .overlay(alignment: .bottomLeading) {
                CanvasGraphStatus(model: model,
                                  source: pendingSource,
                                  feedback: connectionFeedback)
                    .padding(.leading, 12)
                    .padding(.bottom, 12)
            }
            // This must be the final overlay. A zIndex inside the graph ZStack
            // cannot rise above sibling toolbar overlays.
            .overlay {
                if let picker = nodePicker {
                    NodeSelectionWindow(
                        source: picker.source,
                        targets: picker.targets,
                        availableTypes: picker.availableTypes,
                        onSelect: { selection in
                            switch selection {
                            case .compatible(let target):
                                guard let source = picker.source else { break }
                                if model.addNode(type: target.nodeType,
                                                 at: picker.documentPoint,
                                                 connecting: source,
                                                 to: target.input.index) {
                                    showConnectionFeedback(
                                        "Connected \(source.output) to \(NodeTypeCatalog.title(for: target.nodeType)).\(target.input.name).")
                                }
                            case .nodeType(let type):
                                model.addNode(type: type,
                                              at: picker.documentPoint)
                            }
                            nodePicker = nil
                            pendingSource = nil
                            pendingPoint = nil
                            viewport.setNeedsDisplay(viewport.bounds)
                        },
                        onCancel: {
                            nodePicker = nil
                            pendingSource = nil
                            pendingPoint = nil
                        })
                        .position(NodePickerGeometry.position(
                            anchor: picker.screenPoint,
                            canvasSize: geo.size,
                            obstructionRects: nodeScreenRects(),
                            sourceRect: picker.source.flatMap(sourceNodeScreenRect)))
                        .zIndex(100)
                }
            }
        }
        .frame(minHeight: 340)
    }

    private func nodePosition(_ id: String) -> CGPoint {
        let p = model.position(for: id)
        return CGPoint(x: p.x, y: p.y)
    }

    private var marqueeRect: CGRect? {
        guard let start = marqueeStart, let end = marqueeEnd else { return nil }
        return CGRect(x: min(start.x, end.x),
                      y: min(start.y, end.y),
                      width: abs(end.x - start.x),
                      height: abs(end.y - start.y))
    }

    private func updateMarqueeSelection() {
        guard let rect = marqueeRect else { return }
        let selected = Set(model.document.nodes.compactMap { node -> String? in
            let p = screen(nodePosition(node.id))
            let size = nodeCardSize(node)
            let nodeRect = CGRect(x: p.x, y: p.y,
                                  width: size.width * zoom,
                                  height: size.height * zoom)
            return rect.intersects(nodeRect) ? node.id : nil
        })
        model.selectNodesForMarquee(selected)
    }

    private func selectNode(_ id: String) {
        let flags = NSEvent.modifierFlags
        model.selectNode(id, extending: flags.contains(.shift) || flags.contains(.command))
    }

    private func screen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * zoom + pan.width, y: point.y * zoom + pan.height)
    }

    private func zoomCanvas(delta: CGFloat, anchor: CGPoint) {
        guard delta != 0 else { return }
        let previousZoom = zoom
        let multiplier = exp(delta * 0.01)
        let nextZoom = min(max(previousZoom * multiplier,
                               minCanvasZoom),
                           maxCanvasZoom)
        guard nextZoom != previousZoom else { return }

        let documentAnchor = documentPoint(anchor)
        zoom = nextZoom
        pan = CGSize(width: anchor.x - documentAnchor.x * nextZoom,
                     height: anchor.y - documentAnchor.y * nextZoom)
    }

    private func documentPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - pan.width) / zoom, y: (point.y - pan.height) / zoom)
    }

    private func nodeCardSize(_ node: GraphDocumentNode) -> CGSize {
        NodePortLayout.size(
            inputCount: model.inputPorts(for: node.id).count,
            outputCount: model.outputPorts(for: node.id).count)
    }

    private func outputPort(_ id: String, output: String) -> CGPoint {
        let p = nodePosition(id)
        let outputs = model.outputPorts(for: id)
        let index = outputs.firstIndex(where: { $0.name == output }) ?? 0
        let inputCount = model.inputPorts(for: id).count
        let size = NodePortLayout.size(inputCount: inputCount,
                                       outputCount: outputs.count)
        return CGPoint(x: p.x + size.width,
                       y: p.y + NodePortLayout.outputY(index))
    }

    private func inputPort(_ id: String, input: UInt32) -> CGPoint {
        let p = nodePosition(id)
        let inputs = model.inputPorts(for: id)
        let index = inputs.firstIndex(where: { $0.index == input }) ?? Int(input)
        return CGPoint(x: p.x, y: p.y + NodePortLayout.inputY(index))
    }

    private func connectedInputs(for nodeId: String) -> Set<UInt32> {
        Set(model.document.connections.compactMap { $0.to == nodeId ? $0.input : nil })
    }

    private func finishConnection(from: GraphOutputReference,
                                  to: String, input: UInt32) {
        pendingSource = nil
        pendingPoint = nil
        let result = model.connect(from: from.node, output: from.output,
                                   to: to, input: input)
        switch result {
        case .compatible(let replaces):
            showConnectionFeedback(replaces
                ? "Replaced the connection with \(from.output)."
                : "Connected \(from.output).")
        case .pending(let message, _):
            showConnectionFeedback(message)
        case .incompatible(let message):
            showConnectionFeedback(message)
        }
        viewport.setNeedsDisplay(viewport.bounds)
    }

    private func finishConnectionDrop(from: GraphOutputReference, point: CGPoint) {
        let docPoint = documentPoint(point)
        let hitRadius = 22 / max(zoom, 0.01)
        var best: (node: String, input: UInt32, distance: CGFloat)?
        for node in model.document.nodes {
            let count = model.document.inputCount(for: node.type)
            for input in 0..<count {
                let port = inputPort(node.id, input: input)
                let dx = port.x - docPoint.x
                let dy = port.y - docPoint.y
                let dist = sqrt(dx * dx + dy * dy)
                if dist < hitRadius && (best == nil || dist < best!.distance) {
                    best = (node.id, input, dist)
                }
            }
        }
        if let best {
            finishConnection(from: from, to: best.node, input: best.input)
        } else {
            if nodeAtDocumentPoint(docPoint) != nil {
                pendingSource = nil
                pendingPoint = nil
                showConnectionFeedback("Drop the connection on a compatible input port.")
                return
            }
            let targets = model.document.compatibleNodeTargets(
                from: from, availableTypes: model.availableNodeTypes)
            guard !targets.isEmpty else {
                pendingSource = nil
                pendingPoint = nil
                showConnectionFeedback("No compatible node inputs are available.")
                return
            }
            pendingSource = from
            pendingPoint = point
            nodePicker = CanvasNodePickerState(
                source: from,
                screenPoint: point,
                documentPoint: GraphNodePosition(x: docPoint.x, y: docPoint.y),
                targets: targets,
                availableTypes: [])
        }
    }

    private func dragStates(for nodeId: String,
                            inputs: [GraphInputPort]) -> [UInt32: InputPortDragState] {
        guard nodePicker == nil, let source = pendingSource else { return [:] }
        return Dictionary(uniqueKeysWithValues: inputs.map { input in
            let compatibility = model.document.connectionCompatibility(
                from: source, to: nodeId, input: input.index)
            let state: InputPortDragState
            switch compatibility {
            case .compatible(let replaces):
                state = .compatible(replacesExisting: replaces)
            case .pending(_, let replaces):
                state = .pending(replacesExisting: replaces)
            case .incompatible:
                state = .incompatible
            }
            return (input.index, state)
        })
    }

    private func edgeColor(_ edge: GraphDocumentConnection) -> Color {
        sourceColor(GraphOutputReference(node: edge.from, output: edge.output))
    }

    private func sourceColor(_ source: GraphOutputReference) -> Color {
        let kind = model.document.resolvedOutputKind(nodeId: source.node,
                                                     output: source.output)
            ?? model.outputPorts(for: source.node)
                .first(where: { $0.name == source.output })?.declaredKind
            ?? .data
        return GraphPortPalette.color(kind)
    }

    private func nodeAtDocumentPoint(_ point: CGPoint) -> GraphDocumentNode? {
        model.document.nodes.first { node in
            let origin = nodePosition(node.id)
            let size = nodeCardSize(node)
            return CGRect(origin: origin, size: size).contains(point)
        }
    }

    private func nodeScreenRects() -> [CGRect] {
        model.document.nodes.map { node in
            let origin = screen(nodePosition(node.id))
            let size = nodeCardSize(node)
            return CGRect(x: origin.x, y: origin.y,
                          width: size.width * zoom,
                          height: size.height * zoom)
        }
    }

    private func sourceNodeScreenRect(_ source: GraphOutputReference) -> CGRect? {
        guard let node = model.document.node(id: source.node) else { return nil }
        let origin = screen(nodePosition(node.id))
        let size = nodeCardSize(node)
        return CGRect(x: origin.x, y: origin.y,
                      width: size.width * zoom,
                      height: size.height * zoom)
    }

    private func showConnectionFeedback(_ message: String) {
        feedbackGeneration += 1
        let generation = feedbackGeneration
        connectionFeedback = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.4))
            guard generation == feedbackGeneration else { return }
            connectionFeedback = nil
        }
    }
}

private struct EmptyGraphQuickAdd: View {
    let availableTypes: [String]
    let onAdd: (String) -> Void

    private var available: Set<String> { Set(availableTypes) }

    private var starters: [QuickAddStarter] {
        NodeTypeCatalog.quickStartTypes.map { type in
            QuickAddStarter(kind: type,
                            title: NodeTypeCatalog.title(for: type),
                            systemImage: NodeTypeCatalog.icon(for: type),
                            requiredTypes: [type])
        }.filter { starter in
            starter.requiredTypes.allSatisfy { available.contains($0) }
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                Image(systemName: "rectangle.connected.to.line.below")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("No nodes in this graph")
                    .font(.headline)
                Text("Right-click the canvas or use Add to create your first node.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !starters.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Quick Add")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        ForEach(starters) { starter in
                            QuickAddStarterButton(starter: starter) {
                                onAdd(starter.kind)
                            }
                        }
                    }
                }
                .padding(12)
                .background(Color.black.opacity(0.22),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }
}

private struct QuickAddStarter: Identifiable {
    let kind: String
    let title: String
    let systemImage: String
    let requiredTypes: [String]

    var id: String { kind }
}

private struct QuickAddStarterButton: View {
    let starter: QuickAddStarter
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: starter.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18)
                Text(starter.title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 11)
            .frame(height: 32)
            .frame(minWidth: 86)
            .contentShape(Rectangle())
            .background(hovered ? Color.white.opacity(0.12) : Color.white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.white.opacity(hovered ? 0.20 : 0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct NodeSelectionWindow: View {
    let source: GraphOutputReference?
    let targets: [GraphCompatibleNodeTarget]
    let availableTypes: [String]
    let onSelect: (NodePickerSelection) -> Void
    let onCancel: () -> Void
    @State private var searchText = ""
    @State private var hoveredTargetId: String?

    private var isCompatiblePicker: Bool { source != nil }

    private var visibleTargets: [GraphCompatibleNodeTarget] {
        let query = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines).lowercased()
        let presented = targets.filter {
            NodeTypeCatalog.isPresented($0.nodeType)
        }
        guard !query.isEmpty else { return presented }
        return presented.filter { target in
            target.nodeType.lowercased().contains(query) ||
                NodeTypeCatalog.title(for: target.nodeType)
                    .lowercased().contains(query) ||
                target.input.name.lowercased().contains(query)
        }
    }

    private var recommendedTargets: [GraphCompatibleNodeTarget] {
        visibleTargets.filter(\.isRecommended)
    }

    private var otherTargets: [GraphCompatibleNodeTarget] {
        visibleTargets.filter { !$0.isRecommended }
    }

    private var visibleGroups: [NodeTypeGroup] {
        let groups = NodeTypeCatalog.grouped(availableTypes)
        return NodeTypeCatalog.filteredGroups(groups, query: searchText)
    }

    private var hasVisibleItems: Bool {
        isCompatiblePicker ? !visibleTargets.isEmpty : !visibleGroups.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isCompatiblePicker ? "Add Compatible Node" : "Add Node")
                        .font(.system(size: 13, weight: .semibold))
                    if let source {
                        Text("\(source.node).\(source.output)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Choose a node for this workflow")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                NodeSearchField(text: $searchText,
                                placeholder: isCompatiblePicker
                                    ? "Search compatible nodes"
                                    : "Search nodes")
                    .frame(height: 22)
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(Color.black.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 7,
                                             style: .continuous))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    if isCompatiblePicker {
                        if !recommendedTargets.isEmpty {
                            compatibleSection("Recommended",
                                              targets: recommendedTargets)
                        }
                        if !otherTargets.isEmpty {
                            compatibleSection(recommendedTargets.isEmpty
                                ? "Compatible" : "All Compatible",
                                              targets: otherTargets)
                        }
                    } else {
                        ForEach(visibleGroups) { group in
                            catalogSection(group)
                        }
                    }
                }
            }

            if !hasVisibleItems {
                Text(isCompatiblePicker
                     ? "No matching compatible nodes"
                     : "No matching nodes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .padding(12)
        .frame(width: NodePickerGeometry.size.width,
               height: NodePickerGeometry.size.height)
        .background(.regularMaterial,
                    in: RoundedRectangle(cornerRadius: 10,
                                         style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.42), radius: 18, y: 8)
        .onExitCommand(perform: onCancel)
    }

    @ViewBuilder
    private func compatibleSection(
        _ title: String,
        targets: [GraphCompatibleNodeTarget]
    ) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 9)
            .padding(.top, 3)

        ForEach(targets) { target in
            Button {
                onSelect(.compatible(target))
            } label: {
                HStack(alignment: .top, spacing: 9) {
                    Circle()
                        .fill(GraphPortPalette.inputColor(target.input))
                        .frame(width: 9, height: 9)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(NodeTypeCatalog.title(for: target.nodeType))
                            .font(.system(size: 12, weight: .semibold))
                        Text(target.reason)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(target.input.name)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .background(
                    hoveredTargetId == target.id
                        ? Color.white.opacity(0.10)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6,
                                         style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                hoveredTargetId = hovering ? target.id : nil
            }
        }
    }

    @ViewBuilder
    private func catalogSection(_ group: NodeTypeGroup) -> some View {
        Label(group.title.uppercased(), systemImage: group.systemImage)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 9)
            .padding(.top, 5)

        ForEach(group.types, id: \.self) { type in
            Button {
                onSelect(.nodeType(type))
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: NodeTypeCatalog.icon(for: type))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(NodeTypeCatalog.title(for: type))
                        .font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 9)
                .frame(height: 32)
                .contentShape(Rectangle())
                .background(
                    hoveredTargetId == "type.\(type)"
                        ? Color.white.opacity(0.10)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6,
                                         style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                hoveredTargetId = hovering ? "type.\(type)" : nil
            }
        }
    }
}

struct CanvasGraphStatus: View {
    @ObservedObject var model: TerrainModel
    let source: GraphOutputReference?
    let feedback: String?

    var body: some View {
        Label(primaryText, systemImage: primaryIcon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(statusColor)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.34),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .allowsHitTesting(false)
    }

    private var primaryIcon: String {
        if feedback != nil { return "info.circle.fill" }
        if source != nil { return "arrow.right.circle.fill" }
        if model.diagnostics.authoringErrorCount > 0 { return "exclamationmark.triangle.fill" }
        if model.diagnostics.authoringWarningCount > 0 { return "exclamationmark.circle.fill" }
        return model.document.nodes.isEmpty ? "rectangle.connected.to.line.below" : "point.3.connected.trianglepath.dotted"
    }

    private var primaryText: String {
        if let feedback { return feedback }
        if let source {
            let kind = model.document.resolvedOutputKind(
                nodeId: source.node, output: source.output)?.rawValue ?? "unresolved"
            return "\(source.output) · \(kind) — choose a compatible input"
        }
        let count = model.document.nodes.count
        return "\(count) node\(count == 1 ? "" : "s")"
    }

    private var statusColor: Color {
        if feedback != nil { return .primary }
        if let source,
           let kind = model.document.resolvedOutputKind(nodeId: source.node,
                                                        output: source.output) {
            return GraphPortPalette.color(kind)
        }
        if model.diagnostics.authoringErrorCount > 0 { return .red }
        if model.diagnostics.authoringWarningCount > 0 { return .orange }
        return .secondary
    }
}

struct CanvasToolbar: View {
    @ObservedObject var model: TerrainModel
    @Binding var zoom: Double
    let viewport: TerrainMTKView
    @State private var addPopoverPresented = false
    @State private var selectedAddGroupId: String?

    var body: some View {
        HStack(spacing: 10) {
            Button {
                addPopoverPresented.toggle()
            } label: {
                toolbarLabel("Add", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .popover(isPresented: $addPopoverPresented, arrowEdge: .bottom) {
                AddNodePalette(groups: NodeTypeCatalog.grouped(model.availableNodeTypes),
                               recentTypes: model.recentNodeTypes,
                               selectedGroupId: $selectedAddGroupId) { type in
                    model.addNode(type: type)
                    viewport.setNeedsDisplay(viewport.bounds)
                    addPopoverPresented = false
                }
            }

            Button {
                model.deleteSelection()
                viewport.setNeedsDisplay(viewport.bounds)
            } label: {
                toolbarLabel("Delete", systemImage: "trash")
            }
            .buttonStyle(.plain)
            .disabled(model.selectedNodeId == nil && model.selectedConnectionId == nil)

            Button {
                model.duplicateSelection()
                viewport.setNeedsDisplay(viewport.bounds)
            } label: {
                toolbarLabel("Duplicate", systemImage: "plus.square.on.square")
            }
            .buttonStyle(.plain)
            .disabled(model.selectedNodeId == nil && model.selectedNodeIds.isEmpty)

            Button {
                model.resetLayout()
            } label: {
                toolbarLabel("Layout", systemImage: "rectangle.connected.to.line.below")
            }
            .buttonStyle(.plain)

            Button {
                model.undo()
                viewport.setNeedsDisplay(viewport.bounds)
            } label: {
                toolbarLabel("Undo", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(.plain)

            Button {
                model.redo()
                viewport.setNeedsDisplay(viewport.bounds)
            } label: {
                toolbarLabel("Redo", systemImage: "arrow.uturn.forward")
            }
            .buttonStyle(.plain)

            Slider(value: $zoom, in: minCanvasZoom...maxCanvasZoom, step: 0.1)
                .padding(.horizontal, 10)
                .frame(width: 124, height: 30)
                .background(toolbarFill,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    private var toolbarFill: Color {
        Color(red: 0.22, green: 0.22, blue: 0.24)
    }

    private func toolbarLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.9))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(toolbarFill,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

private struct AddNodePalette: View {
    let groups: [NodeTypeGroup]
    let recentTypes: [String]
    @Binding var selectedGroupId: String?
    let onSelect: (String) -> Void
    @State private var searchText = ""
    @State private var hoveredType: String?

    private var selectedGroup: NodeTypeGroup? {
        visibleGroups.first { $0.id == selectedGroupId } ?? visibleGroups.first
    }

    private var selectedTypes: [String] {
        selectedGroup?.types ?? []
    }

    private var visibleGroups: [NodeTypeGroup] {
        var sourceGroups = groups
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let available = Set(groups.flatMap(\.types))
            let recent = recentTypes.filter { available.contains($0) }
            if !recent.isEmpty {
                sourceGroups.insert(NodeTypeGroup(id: "recent",
                                                  title: "Recent",
                                                  systemImage: "clock",
                                                  types: recent),
                                    at: 0)
            }
        }
        return NodeTypeCatalog.filteredGroups(sourceGroups, query: searchText)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                NodeSearchField(text: $searchText,
                                placeholder: "Search nodes")
                    .frame(height: 22)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color.black.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1))

            HStack(spacing: 14) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(visibleGroups) { group in
                            Button {
                                withAnimation(.easeOut(duration: 0.14)) {
                                    selectedGroupId = group.id
                                }
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: group.systemImage)
                                        .frame(width: 17)
                                    Text(group.title)
                                        .fontWeight(.semibold)
                                    Spacer(minLength: 10)
                                }
                                .frame(width: 154, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                                .foregroundStyle(selectedGroup?.id == group.id ? .white : .primary)
                                .background(selectedGroup?.id == group.id ? Color.accentColor : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .scaleEffect(selectedGroup?.id == group.id ? 1.0 : 0.985)
                                .animation(.easeOut(duration: 0.14), value: selectedGroup?.id)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(width: 174, height: 340, alignment: .topLeading)

                Divider()
                    .frame(height: 340)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        if let selectedGroup {
                            ForEach(selectedGroup.types, id: \.self) { type in
                                Button {
                                    onSelect(type)
                                } label: {
                                    HStack(spacing: 9) {
                                        Image(systemName: NodeTypeCatalog.icon(for: type))
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 16)
                                        Text(NodeTypeCatalog.title(for: type))
                                            .fontWeight(.semibold)
                                        Spacer(minLength: 10)
                                    }
                                    .frame(width: 168, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .contentShape(Rectangle())
                                    .background(hoveredType == type
                                                ? Color.white.opacity(0.08)
                                                : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    .scaleEffect(hoveredType == type ? 1.015 : 1.0)
                                    .animation(.easeOut(duration: 0.10), value: hoveredType)
                                }
                                .buttonStyle(.plain)
                                .help(NodeTypeCatalog.subtitle(for: type))
                                .onHover { hovering in
                                    withAnimation(.easeOut(duration: 0.10)) {
                                        hoveredType = hovering ? type : nil
                                    }
                                }
                            }
                        } else {
                            Text("No matches")
                                .font(.callout.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 168, alignment: .leading)
                                .padding(.top, 7)
                        }
                    }
                }
                .frame(width: 188, height: 340, alignment: .topLeading)
            }
        }
        .padding(12)
        .frame(minWidth: 430, minHeight: 398)
        .onAppear {
            if selectedGroupId == nil || !visibleGroups.contains(where: { $0.id == selectedGroupId }) {
                selectedGroupId = visibleGroups.first?.id
            }
        }
        .onChange(of: searchText) { _, _ in
            if selectedGroupId == nil || !visibleGroups.contains(where: { $0.id == selectedGroupId }) {
                selectedGroupId = visibleGroups.first?.id
            }
        }
        .onDeleteCommand {
            guard !searchText.isEmpty else { return }
            searchText.removeLast()
        }
    }
}

final class NodePickerSearchField: NSSearchField {
    static func isSelectAllShortcut(_ event: NSEvent) -> Bool {
        event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.command) &&
        event.charactersIgnoringModifiers?.lowercased() == "a"
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard Self.isSelectAllShortcut(event) else {
            return super.performKeyEquivalent(with: event)
        }
        window?.makeFirstResponder(self)
        selectText(nil)
        return true
    }
}

private struct NodeSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NodePickerSearchField(frame: .zero)
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.stringValue = text
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        field.textColor = .labelColor
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        if let cell = field.cell as? NSSearchFieldCell {
            cell.searchButtonCell = nil
            cell.cancelButtonCell = nil
        }
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        @Binding var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text = field.stringValue
        }
    }
}
