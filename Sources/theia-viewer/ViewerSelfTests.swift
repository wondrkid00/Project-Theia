import Foundation
import AppKit
import Combine
import Metal
import simd
import TheiaCore

@MainActor
private func availableNodeTypesForSelfTest() -> [String] {
    readCxxString { theia.node_type_list($0, $1) }
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

@MainActor
func runViewerSelfTests() -> Int32 {
    var checks = 0
    var failures = 0
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() {
            failures += 1
            print("  ✗ \(message)")
        }
    }

    do {
        var legacy = try JSONDecoder().decode(GraphDocument.self, from: Data("""
        {
          "resolution": { "width": 64, "height": 64 },
          "sink": "mask",
          "nodes": [
            { "id": "base", "type": "perlin", "params": {} },
            { "id": "mask", "type": "slopemask",
              "params": { "low": 0.2, "high": 0.8, "heightScale": 64.0 } }
          ],
          "connections": [ { "from": "base", "to": "mask", "input": 0 } ]
        }
        """.utf8))
        legacy.ensureNodeDefaults()
        let mask = legacy.node(id: "mask")
        expect(mask?.params["low"] == 15.0, "viewer migration should use core low default")
        expect(mask?.params["high"] == 50.0, "viewer migration should use core high default")
        expect(mask?.params["heightScale"] == 100.0,
               "viewer migration should use core heightScale default")
        print("✓ legacy slope-mask migration")
    } catch {
        expect(false, "legacy document decode failed: \(error)")
    }

    let hydraulicDT = SliderConfig.forParam(
        GraphParameter(nodeId: "h", nodeType: "hydraulic", name: "dt", value: 0.015))
    let hydraulicTilt = SliderConfig.forParam(
        GraphParameter(nodeId: "h", nodeType: "hydraulic", name: "minTilt", value: 0.03))
    let hydraulicGravity = SliderConfig.forParam(
        GraphParameter(nodeId: "h", nodeType: "hydraulic", name: "gravity", value: 9.81))
    let hydraulicRain = SliderConfig.forParam(
        GraphParameter(nodeId: "h", nodeType: "hydraulic", name: "rain", value: 0.012))
    expect(hydraulicDT.range == 0.001...0.025,
           "hydraulic timestep authoring range must stay conservative")
    expect(hydraulicTilt.range == 0...0.15,
           "hydraulic slope floor must not encourage full-slope erosion")
    expect(hydraulicGravity.range.contains(9.81),
           "hydraulic gravity range must contain its physical default")
    expect(hydraulicRain.range == 0...0.05,
           "hydraulic rainfall needs a useful fine-grained range")
    print("✓ hydraulic authoring stability envelope")

    expect(NodeTypeCatalog.nodeTitle(id: "perlin", type: "perlin") == "Perlin",
           "canvas should collapse duplicate node id/type labels")
    expect(NodeTypeCatalog.nodeTitle(id: "fluvial1", type: "fluvial") ==
           "Fluvial Erosion 2",
           "automatic duplicate ids should become readable instance titles")
    expect(NodeTypeCatalog.nodeTitle(id: "riverCarveFinal",
                                     type: "rivercarve") == "River Carve Final",
           "custom node ids should become readable canvas titles")

    let pickerSourceRect = CGRect(x: 220, y: 180, width: 168, height: 96)
    let pickerPosition = NodePickerGeometry.position(
        anchor: CGPoint(x: 400, y: 230),
        canvasSize: CGSize(width: 1_000, height: 720),
        obstructionRects: [pickerSourceRect],
        sourceRect: pickerSourceRect)
    let pickerRect = CGRect(
        x: pickerPosition.x - NodePickerGeometry.size.width / 2,
        y: pickerPosition.y - NodePickerGeometry.size.height / 2,
        width: NodePickerGeometry.size.width,
        height: NodePickerGeometry.size.height)
    expect(!pickerRect.intersects(pickerSourceRect),
           "connection picker should avoid covering its source node")
    expect(pickerRect.minX >= 8 && pickerRect.maxX <= 992 &&
           pickerRect.minY >= 8 && pickerRect.maxY <= 712,
           "connection picker should remain inside the usable canvas")
    let upperPickerPosition = NodePickerGeometry.position(
        anchor: CGPoint(x: 700, y: 150),
        canvasSize: CGSize(width: 1_000, height: 720),
        obstructionRects: [],
        sourceRect: nil)
    let lowerPickerPosition = NodePickerGeometry.position(
        anchor: CGPoint(x: 700, y: 500),
        canvasSize: CGSize(width: 1_000, height: 720),
        obstructionRects: [],
        sourceRect: nil)
    expect(abs(upperPickerPosition.y - lowerPickerPosition.y) > 100,
           "right-click picker should follow the pointer vertically")
    let mouseEventView = CanvasMouseEventNSView(
        frame: CGRect(x: 0, y: 0, width: 1_000, height: 720))
    var requestedPickerPoint: CGPoint?
    mouseEventView.onRequestAddNode = { requestedPickerPoint = $0 }
    if let mouseDown = NSEvent.mouseEvent(
        with: .rightMouseDown,
        location: CGPoint(x: 400, y: 230),
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 1,
        clickCount: 1,
        pressure: 1),
       let mouseUp = NSEvent.mouseEvent(
        with: .rightMouseUp,
        location: CGPoint(x: 400, y: 230),
        modifierFlags: [],
        timestamp: 0.1,
        windowNumber: 0,
        context: nil,
        eventNumber: 2,
        clickCount: 1,
        pressure: 0) {
        mouseEventView.rightMouseDown(with: mouseDown)
        mouseEventView.rightMouseUp(with: mouseUp)
    }
    expect(requestedPickerPoint != nil,
           "right-click should request the shared canvas node picker")
    let commandA = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [.command],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "a",
        charactersIgnoringModifiers: "a",
        isARepeat: false,
        keyCode: 0)
    expect(commandA.map(NodePickerSearchField.isSelectAllShortcut) == true,
           "node picker search should recognize Command-A")
    print("✓ graph picker geometry and readable node titles")

    var document = GraphDocument.emptyDocument(width: 64, height: 64)
    let source = document.addNode(type: "perlin", at: GraphNodePosition(x: 10, y: 20))
    let filter = document.addNode(type: "blur", after: source)
    document.connect(from: source, to: filter, input: 0)
    document.sink = filter
    expect(document.nodes.count == 2, "node creation count")
    expect(document.connections == [GraphDocumentConnection(from: source,
                                                             output: "terrain",
                                                             to: filter,
                                                             input: 0)],
           "node connection should be recorded")
    let copies = document.duplicateNodes(ids: [source, filter])
    expect(copies.count == 2, "multi-node duplication count")
    expect(document.connections.count == 2, "internal duplicated edge should be preserved")
    document.deleteNodes(ids: Set(copies))
    expect(document.nodes.count == 2 && document.connections.count == 1,
           "delete should remove duplicated nodes and edges")
    print("✓ graph authoring operations")

    var multiOutput = GraphDocument.emptyDocument(width: 64, height: 64)
    let terrain = multiOutput.addNode(type: "perlin")
    let erosion = multiOutput.addNode(type: "erosionfilter", after: terrain)
    multiOutput.connect(from: terrain, output: "terrain", to: erosion, input: 0)
    let erosionPorts = multiOutput.outputPorts(nodeId: erosion)
    expect(erosionPorts.map(\.name) == ["terrain", "ridge"],
           "erosionfilter should enumerate named outputs")
    expect(erosionPorts.map(\.declaredKind) == [.terrain, .data],
           "erosionfilter output kinds")
    multiOutput.setSink(nodeId: erosion, output: "ridge")
    expect(multiOutput.sinkOutput == "ridge", "named output should become sinkOutput")
    expect(multiOutput.resolvedOutputKind(nodeId: erosion, output: "ridge") == .data,
           "ridge should resolve as data")
    expect(multiOutput.terrainReference(
        for: GraphOutputReference(node: erosion, output: "ridge")) ==
        GraphOutputReference(node: erosion, output: "terrain"),
        "data preview should use sibling terrain geometry")
    do {
        let encoded = try multiOutput.encodedString()
        var decoded = try JSONDecoder().decode(GraphDocument.self,
                                               from: Data(encoded.utf8))
        decoded.ensureLayout()
        expect(decoded.formatVersion == 2 && decoded.sinkOutput == "ridge",
               "v2 round-trip should preserve selected output")
        expect(decoded.connections.first?.output == "terrain",
               "v2 round-trip should preserve edge source port")
    } catch {
        expect(false, "multi-output round-trip failed: \(error)")
    }
    print("✓ typed multi-output authoring and preview geometry")

    var portWorkflow = GraphDocument.emptyDocument(width: 64, height: 64)
    let portBase = portWorkflow.addNode(type: "perlin")
    let portFluvial = portWorkflow.addNode(type: "fluvial", after: portBase)
    let portThermal = portWorkflow.addNode(type: "thermal", after: portFluvial)
    let portCarve = portWorkflow.addNode(type: "rivercarve", after: portThermal)
    let portRemap = portWorkflow.addNode(type: "remap", after: portCarve)
    let portCombine = portWorkflow.addNode(type: "combine", after: portRemap)
    portWorkflow.connect(from: portBase, output: "terrain",
                         to: portFluvial, input: 0)
    portWorkflow.connect(from: portBase, output: "terrain",
                         to: portCombine, input: 0)
    let terrainOutput = GraphOutputReference(node: portFluvial, output: "terrain")
    let flowOutput = GraphOutputReference(node: portFluvial, output: "flow")

    expect(portWorkflow.outputPorts(nodeId: portBase).map(\.name) == ["terrain"] &&
           portWorkflow.inputPorts(nodeId: portFluvial).map(\.name) == ["terrain"] &&
           portWorkflow.outputPorts(nodeId: portFluvial).map(\.name) ==
               ["terrain", "flow"],
           "terrain producers and consumers should share the terrain port name")
    expect(portWorkflow.inputPorts(nodeId: portCarve).map(\.name) ==
           ["terrain", "mask"],
           "viewer should enumerate named input ports")
    expect(portWorkflow.inputPorts(nodeId: portRemap).map(\.name) == ["field"] &&
           portWorkflow.outputPorts(nodeId: portRemap).map(\.name) == ["field"] &&
           portWorkflow.inputPorts(nodeId: portCombine).map(\.name) ==
               ["base", "source"],
           "generic and binary inputs should use meaningful canonical names")
    expect(portWorkflow.connectionCompatibility(
        from: terrainOutput, to: portThermal, input: 0).isAllowed,
        "fluvial.terrain should connect to thermal.terrain")
    let rejectedTerrain = portWorkflow.connectionCompatibility(
        from: flowOutput, to: portThermal, input: 0)
    expect(!rejectedTerrain.isAllowed &&
           (rejectedTerrain.message?.contains("accepts terrain") ?? false),
           "fluvial.flow should explain why thermal.terrain rejects data")
    expect(portWorkflow.connectionCompatibility(
        from: flowOutput, to: portCarve, input: 1).isAllowed,
        "fluvial.flow should connect to rivercarve.mask")
    expect(portWorkflow.connectionCompatibility(
        from: flowOutput, to: portRemap, input: 0).isAllowed,
        "fluvial.flow should connect to generic data transforms")
    expect(!portWorkflow.connectionCompatibility(
        from: flowOutput, to: portCombine, input: 1).isAllowed,
        "combine should reject mixed terrain and data inputs")

    let availableTargets = portWorkflow.compatibleNodeTargets(
        from: flowOutput,
        availableTypes: ["thermal", "rivercarve", "remap", "normalize",
                         "export", "blend"])
    let targetTypes = Set(availableTargets.map(\.nodeType))
    expect(!targetTypes.contains("thermal") &&
           targetTypes.isSuperset(of: ["rivercarve", "remap", "normalize",
                                       "export", "blend"]),
           "context picker should include only compatible data consumers")
    expect(availableTargets.first(where: { $0.nodeType == "rivercarve" })?
        .input.name == "mask",
        "context picker should prefer River Carve's typed mask input")
    expect(availableTargets.first?.nodeType == "rivercarve" &&
           availableTargets.first?.reason.contains("flow") == true,
           "flow recommendations should lead with River Carve and explain why")
    let terrainTargets = portWorkflow.compatibleNodeTargets(
        from: terrainOutput,
        availableTypes: ["thermal", "rivercarve", "remap", "normalize",
                         "export", "fluvial"])
    expect(terrainTargets.first?.nodeType == "thermal" &&
           terrainTargets.first?.reason.contains("thermal") == true,
           "terrain recommendations should lead with terrain operations")
    expect(terrainTargets.map(\.nodeType) != availableTargets.map(\.nodeType),
           "terrain and flow should not present the same contextual ordering")

    let unresolved = portWorkflow.addNode(type: "normalize", after: portCombine)
    let unresolvedOutput = GraphOutputReference(node: unresolved, output: "field")
    expect(!portWorkflow.connectionCompatibility(
        from: unresolvedOutput, to: portThermal, input: 0).isAllowed,
        "unresolved inherited output should not connect to terrain-only input")
    let unresolvedExport = portWorkflow.addNode(type: "export", after: unresolved)
    let pendingUniversal = portWorkflow.connectionCompatibility(
        from: unresolvedOutput, to: unresolvedExport, input: 0)
    if case .pending = pendingUniversal {
        expect(true, "unresolved output should remain pending on universal input")
    } else {
        expect(false, "unresolved output should be pending on universal input")
    }
    print("✓ typed connection compatibility and contextual targets")

    do {
        var migrated = try JSONDecoder().decode(GraphDocument.self, from: Data("""
        {
          "resolution": { "width": 32, "height": 32 },
          "sink": "river",
          "nodes": [
            { "id": "base", "type": "perlin", "params": {} },
            { "id": "river", "type": "river", "params": {} }
          ],
          "connections": [ { "from": "base", "to": "river", "input": 0 } ],
          "ui": { "maskErases": { "river": [
            { "x": 0.5, "y": 0.5, "radius": 0.1, "strength": 1.0 }
          ] } }
        }
        """.utf8))
        migrated.ensureLayout()
        expect(migrated.formatVersion == 2 && migrated.sinkOutput == "mask",
               "v1 sink should migrate to its default named output")
        expect(migrated.connections.first?.output == "terrain",
               "v1 edge should migrate to source default output")
        expect(migrated.maskEraseStrokes(nodeId: "river", output: "mask").count == 1,
               "v1 mask edits should migrate under the mask output")
    } catch {
        expect(false, "v1 multi-output migration failed: \(error)")
    }
    print("✓ graph v1 to v2 named-output migration")

    do {
        var migrated = try JSONDecoder().decode(GraphDocument.self, from: Data("""
        {
          "formatVersion": 3,
          "resolution": { "width": 32, "height": 32 },
          "sink": "base",
          "sinkOutput": "height",
          "nodes": [
            { "id": "base", "type": "perlin", "params": {} },
            { "id": "filter", "type": "blur", "params": {} }
          ],
          "connections": [
            { "from": "base", "output": "height", "to": "filter", "input": 0 }
          ],
          "retiredExtension": { "enabled": true }
        }
        """.utf8))
        migrated.ensureLayout()
        let encoded = try migrated.encodedString()
        let root = try JSONSerialization.jsonObject(
            with: Data(encoded.utf8)) as? [String: Any]
        expect(root?["formatVersion"] as? Int == 2,
               "v3 input should normalize to formatVersion 2")
        expect(root?["sinkOutput"] as? String == "terrain",
               "legacy height sink should normalize to terrain")
        let connections = root?["connections"] as? [[String: Any]]
        expect(connections?.first?["output"] as? String == "terrain",
               "legacy height edge should normalize to terrain")
        expect(root?["retiredExtension"] == nil,
               "unsupported legacy extension fields should be discarded")
    } catch {
        expect(false, "v3 compatibility migration failed: \(error)")
    }
    print("✓ graph v3 compatibility migration")

    var duplicateInputs = GraphDocument.emptyDocument(width: 32, height: 32)
    let duplicateTerrain = duplicateInputs.addNode(type: "perlin")
    let duplicateMask = duplicateInputs.addNode(type: "river")
    let duplicateData = duplicateInputs.addNode(type: "erosionfilter")
    let duplicateRemap = duplicateInputs.addNode(type: "remap")
    duplicateInputs.connect(from: duplicateTerrain, to: duplicateMask, input: 0)
    duplicateInputs.connect(from: duplicateTerrain, to: duplicateData, input: 0)
    duplicateInputs.connections.append(GraphDocumentConnection(
        from: duplicateData, output: "ridge", to: duplicateRemap, input: 0))
    duplicateInputs.connections.append(GraphDocumentConnection(
        from: duplicateMask, output: "mask", to: duplicateRemap, input: 0))
    let duplicateOutput = GraphOutputReference(
        node: duplicateRemap,
        output: GraphDocument.defaultOutputName(for: "remap"))
    expect(duplicateInputs.resolvedOutputKind(
        nodeId: duplicateOutput.node, output: duplicateOutput.output) == .mask &&
        duplicateInputs.isOutputEvaluable(duplicateOutput),
        "viewer must use the core's last-connection-wins policy for kind validation")
    expect(duplicateInputs.terrainReference(for: duplicateOutput) ==
           GraphOutputReference(node: duplicateTerrain, output: "terrain"),
           "terrain traversal must follow only each effective inbound connection")
    print("✓ effective connections drive output evaluability")

    var history = GraphDocumentHistory(limit: 4)
    history.record(document)
    let originalFrequency = document.node(id: source)?.params["frequency"]
    document.setParam(nodeId: source, key: "frequency", value: 9.0)
    if let restored = history.undo(current: document) {
        expect(restored.node(id: source)?.params["frequency"] == originalFrequency,
               "undo should restore prior document")
        if let redone = history.redo(current: restored) {
            expect(redone.node(id: source)?.params["frequency"] == 9.0,
                   "redo should restore changed document")
        } else {
            expect(false, "redo snapshot missing")
        }
    } else {
        expect(false, "undo snapshot missing")
    }
    print("✓ undo/redo history")

    var maskDocument = GraphDocument.emptyDocument(width: 64, height: 64)
    let maskTerrain = maskDocument.addNode(type: "perlin")
    let maskNode = maskDocument.addNode(type: "river", after: maskTerrain)
    maskDocument.connect(from: maskTerrain, output: "terrain",
                         to: maskNode, input: 0)
    maskDocument.setSink(nodeId: maskNode, output: "mask")
    maskDocument.addMaskEraseStroke(
        nodeId: maskNode, output: "mask",
        stroke: GraphMaskEraseStroke(x: 0.4, y: 0.6, radius: 0.05, strength: 1.0))
    do {
        let text = try maskDocument.encodedString()
        let decoded = try JSONDecoder().decode(GraphDocument.self, from: Data(text.utf8))
        expect(decoded.maskEraseStrokes(nodeId: maskNode, output: "mask").count == 1,
               "mask edit should survive Codable round-trip")
        let path = NSTemporaryDirectory() + "theia_viewer_selftest_\(getpid()).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        let loaded = try GraphDocument.load(path: path)
        expect(loaded.nodes.count == maskDocument.nodes.count,
               "document load should preserve nodes")
        expect(loaded.maskEraseStrokes(nodeId: maskNode, output: "mask").count == 1,
               "document load should preserve mask edits")
        print("✓ document persistence and mask edits")
    } catch {
        expect(false, "document persistence failed: \(error)")
    }

    document.setParam(nodeId: filter, key: "radius", value: 9)
    expect(document.resetNodeState(nodeId: filter),
           "node reset should accept an existing node")
    expect(document.node(id: filter)?.params == GraphDocument.defaultParams(for: "blur"),
           "node reset should restore all default parameters")
    maskDocument.setParam(nodeId: maskNode, key: "water", value: 0.2)
    expect(maskDocument.resetNodeState(nodeId: maskNode),
           "mask node reset should accept an existing node")
    expect(maskDocument.node(id: maskNode)?.params == GraphDocument.defaultParams(for: "river"),
           "mask node reset should restore all default parameters")
    expect(maskDocument.maskEraseStrokes(nodeId: maskNode, output: "mask").isEmpty,
           "node reset should clear persisted mask erase strokes")
    expect(!document.resetNodeState(nodeId: "missing"),
           "node reset should reject a missing node")
    print("✓ node reset restores parameters and mask edits")

    let heights = [Float](repeating: 1.0, count: 16)
    let direction = simd_normalize(SIMD3<Float>(0.5, -1.0, 0.0))
    let hit = TerrainSurfacePicker.intersect(
        origin: SIMD3<Float>(0, 2, 0), direction: direction,
        heights: heights, width: 4, height: 4,
        baseHeight: 0, maxHeight: 1, heightScale: 1)
    expect(hit != nil, "surface picker should hit raised terrain")
    if let hit {
        expect(abs(hit.x - 0.75) < 0.01,
               "surface-aware hit should differ from the y=0 plane projection: \(hit.x)")
        expect(abs(hit.y - 0.5) < 0.01, "surface picker v coordinate")
    }
    let miss = TerrainSurfacePicker.intersect(
        origin: SIMD3<Float>(0, 2, 0), direction: SIMD3<Float>(0, 1, 0),
        heights: heights, width: 4, height: 4,
        baseHeight: 0, maxHeight: 1, heightScale: 1)
    expect(miss == nil, "upward ray should miss terrain")
    print("✓ surface-aware brush picking")

    var maskValues = [Float](repeating: 1, count: 65 * 65)
    let rasterStroke = GraphMaskEraseStroke(x: 0.5, y: 0.5,
                                            radius: 0.08, strength: 1)
    let touched = maskValues.withUnsafeMutableBufferPointer {
        MaskBrushRasterizer.apply(stroke: rasterStroke, to: $0,
                                  width: 65, height: 65)
    }
    expect(touched > 0 && touched < 200,
           "brush rasterizer should update only its bounded region")
    expect(maskValues[32 * 65 + 32] == 0,
           "brush rasterizer should erase the stroke center immediately")
    expect(maskValues[0] == 1,
           "brush rasterizer should leave pixels outside the radius untouched")
    let sampledPath = MaskBrushRasterizer.interpolatedPoints(
        from: CGPoint(x: 0.1, y: 0.2),
        to: CGPoint(x: 0.7, y: 0.2),
        spacing: 0.05)
    expect(sampledPath.count == 12,
           "brush sampler should use radius-based spacing")
    expect(abs((sampledPath.last?.x ?? 0) - 0.7) < 0.0001,
           "brush sampler should cover the end of a fast drag")
    let tinyMove = MaskBrushRasterizer.interpolatedPoints(
        from: CGPoint(x: 0.1, y: 0.2),
        to: CGPoint(x: 0.11, y: 0.2),
        spacing: 0.05)
    expect(tinyMove.isEmpty,
           "brush sampler should discard redundant high-frequency events")
    print("✓ realtime bounded mask brush rasterization")

    if let device = MTLCreateSystemDefaultDevice(),
       let renderer = Renderer(device: device, colorFormat: .bgra8Unorm),
       let engine = TerrainEngine(graphPath: "examples/erosion-filter.json") {
        let model = TerrainModel(engine: engine, renderer: renderer, size: 32)
        let originalSink = GraphOutputReference(node: model.document.sink,
                                                output: model.document.sinkOutput)
        expect(!model.isDirty, "loading a graph should begin clean")
        model.selectOutput(nodeId: "gullies", output: "ridge")
        expect(model.previewReference == GraphOutputReference(node: "gullies",
                                                              output: "ridge"),
               "port selection should change only previewReference")
        expect(GraphOutputReference(node: model.document.sink,
                                    output: model.document.sinkOutput) == originalSink,
               "preview selection must not mutate graph output")
        expect(!model.isDirty, "preview selection must not dirty the document")
        model.setPreviewAsGraphOutput()
        expect(model.document.sink == "gullies" && model.document.sinkOutput == "ridge",
               "explicit Set as Graph Output should persist the preview port")
        expect(model.isDirty, "explicit graph output change should dirty the document")
        print("✓ ephemeral preview and explicit graph-output authoring")
    } else {
        expect(false, "Metal renderer unavailable for preview/output separation test")
    }

    if let device = MTLCreateSystemDefaultDevice(),
       let renderer = Renderer(device: device, colorFormat: .bgra8Unorm),
       let engine = TerrainEngine(graphPath: "examples/fluvial.json") {
        let model = TerrainModel(engine: engine, renderer: renderer, size: 32)
        let originalNodeCount = model.document.nodes.count
        let originalConnections = model.document.connections
        let invalid = model.connect(from: "carve", output: "flow",
                                    to: "scree", input: 0)
        expect(!invalid.isAllowed &&
               model.document.connections == originalConnections &&
               !model.isDirty,
               "invalid typed connection must not mutate or dirty the document")

        let created = model.addNode(
            type: "remap",
            at: GraphNodePosition(x: 720, y: 160),
            connecting: GraphOutputReference(node: "carve", output: "flow"),
            to: 0)
        let remap = model.document.nodes.first {
            $0.type == "remap" && $0.id != "carve"
        }
        expect(created && model.document.nodes.count == originalNodeCount + 1 &&
               remap != nil &&
               model.document.connections.contains(where: {
                   $0.from == "carve" && $0.output == "flow" &&
                   $0.to == remap?.id && $0.input == 0
               }),
               "context creation should atomically create and connect the node")
        expect(remap.flatMap { model.document.ui?.positions[$0.id] } ==
               GraphNodePosition(x: 720, y: 160),
               "context-created node should use the connection drop position")
        model.undo()
        expect(model.document.nodes.count == originalNodeCount &&
               model.document.connections == originalConnections &&
               !model.isDirty,
               "one undo should remove the contextual node and its connection")
        print("✓ guarded connection and atomic contextual creation")
    } else {
        expect(false, "Metal renderer unavailable for typed connection model test")
    }

    let previewWorker = TerrainPreviewWorker()
    let previewJSON: (Int) -> String = { seed in
        """
        {
          "resolution": { "width": 32, "height": 32 },
          "sink": "terrain",
          "nodes": [
            { "id": "terrain", "type": "perlin", "params": { "seed": \(seed) } }
          ],
          "connections": []
        }
        """
    }
    var previewFinished = false
    var previewCompletions = 0
    let submitStarted = Date()
    let previewTerrainOutput = GraphOutputReference(node: "terrain",
                                                    output: "terrain")
    previewWorker.submit(jsonText: previewJSON(1), geometry: previewTerrainOutput,
                         data: previewTerrainOutput, size: 32) { _ in
        previewCompletions += 1
    }
    previewWorker.submit(jsonText: previewJSON(2), geometry: previewTerrainOutput,
                         data: previewTerrainOutput, size: 32) { outcome in
        previewCompletions += 1
        if case .success(let preview) = outcome {
            expect(preview.width == 32 && preview.height == 32,
                   "preview worker dimensions")
            expect(preview.geometry.count == 32 * 32, "preview worker height count")
        } else {
            expect(false, "latest preview worker snapshot failed")
        }
        previewFinished = true
    }
    expect(Date().timeIntervalSince(submitStarted) < 0.1,
           "preview submission should not block the main actor")
    let deadline = Date().addingTimeInterval(10)
    while !previewFinished && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    expect(previewFinished, "preview worker timed out")
    expect(previewCompletions == 1, "stale preview result should be discarded")
    let previewActivity = previewWorker.activitySnapshot()
    expect(previewActivity.submitted == 2 && previewActivity.started == 1 &&
           previewActivity.skippedBeforeStart >= 1 && previewActivity.delivered == 1,
           "preview worker should coalesce rapid submissions before evaluation")
    print("✓ asynchronous latest-snapshot preview worker")

    // Every editable parameter must present a finite, stable slider range.
    // A range derived from the parameter's live value slides outward as the
    // user drags and never reaches an end stop, which reads as an unbounded
    // control. Checking the range is identical at three very different values
    // is what pins that down; checking finiteness alone would not catch it.
    do {
        var unbounded: [String] = []
        var unstable: [String] = []
        var excluded: [String] = []
        for type in availableNodeTypesForSelfTest() {
            for (name, defaultValue) in GraphDocument.defaultParams(for: type) {
                let label = "\(type).\(name)"
                func config(_ value: Double) -> SliderConfig {
                    SliderConfig.forParam(GraphParameter(nodeId: "n", nodeType: type,
                                                         name: name, value: value))
                }
                let base = config(defaultValue)
                guard base.range.lowerBound.isFinite,
                      base.range.upperBound.isFinite,
                      base.range.lowerBound < base.range.upperBound,
                      base.step.isFinite, base.step > 0 else {
                    unbounded.append(label)
                    continue
                }
                if !base.range.contains(defaultValue) {
                    excluded.append("\(label) default \(defaultValue) not in \(base.range)")
                }
                // Probe well outside the declared range: a value-anchored
                // fallback would follow the probe instead of holding still.
                for probe in [defaultValue - 1000, defaultValue + 1000, 0] {
                    let moved = config(probe)
                    if moved.range != base.range {
                        unstable.append("\(label) @\(probe)")
                        break
                    }
                }
            }
        }
        expect(unbounded.isEmpty, "non-finite slider ranges: \(unbounded)")
        expect(unstable.isEmpty, "slider ranges that follow the value: \(unstable)")
        // A range that excludes its own default pins the control at an end
        // stop, so dragging snaps the value instead of editing it. This is how
        // fluvial's dt (default 0.6) ended up on a 0.001...0.1 slider inherited
        // from the hydraulic node, which read as a broken control.
        expect(excluded.isEmpty, "slider ranges excluding their default: \(excluded)")
        print("✓ every node parameter has a bounded, value-independent slider range")
    }

    // Typed entry must land exactly where dragging could, for every parameter.
    // A field that bypassed the slider's clamp would be the one way to push a
    // value outside the core's envelope and have it silently clamped later.
    do {
        var escaped: [String] = []
        for type in availableNodeTypesForSelfTest() {
            for (name, defaultValue) in GraphDocument.defaultParams(for: type) {
                let cfg = SliderConfig.forParam(
                    GraphParameter(nodeId: "n", nodeType: type, name: name,
                                   value: defaultValue))
                let lo = cfg.range.lowerBound, hi = cfg.range.upperBound
                for probe in [lo - 1e6, hi + 1e6, lo, hi, defaultValue,
                              (lo + hi) / 2] {
                    guard let out = InspectorValueField.sanitize(probe, config: cfg)
                    else {
                        escaped.append("\(type).\(name) rejected \(probe)")
                        continue
                    }
                    if !(out >= lo - 1e-9 && out <= hi + 1e-9) || !out.isFinite {
                        escaped.append("\(type).\(name): \(probe) -> \(out)")
                    }
                }
                // Garbage must leave the value alone rather than resolve to 0.
                for junk in [Double.nan, Double.infinity, -Double.infinity] {
                    if InspectorValueField.sanitize(junk, config: cfg) != nil {
                        escaped.append("\(type).\(name) accepted \(junk)")
                    }
                }
            }
        }
        expect(escaped.isEmpty, "typed values escaping their range: \(escaped)")
        print("✓ typed parameter entry is clamped and snapped like the slider")
    }

    print("\n\(checks) viewer checks, \(failures) failure(s)")
    return failures == 0 ? 0 : 1
}
