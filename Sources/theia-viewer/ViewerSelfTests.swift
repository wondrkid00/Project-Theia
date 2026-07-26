import Foundation
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

    var document = GraphDocument.emptyDocument(width: 64, height: 64)
    let source = document.addNode(type: "perlin", at: GraphNodePosition(x: 10, y: 20))
    let filter = document.addNode(type: "blur", after: source)
    document.connect(from: source, to: filter, input: 0)
    document.sink = filter
    expect(document.nodes.count == 2, "node creation count")
    expect(document.connections == [GraphDocumentConnection(from: source,
                                                             output: "height",
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
    multiOutput.connect(from: terrain, output: "height", to: erosion, input: 0)
    let erosionPorts = multiOutput.outputPorts(nodeId: erosion)
    expect(erosionPorts.map(\.name) == ["height", "ridge"],
           "erosionfilter should enumerate named outputs")
    expect(erosionPorts.map(\.declaredKind) == [.terrain, .data],
           "erosionfilter output kinds")
    multiOutput.setSink(nodeId: erosion, output: "ridge")
    expect(multiOutput.sinkOutput == "ridge", "named output should become sinkOutput")
    expect(multiOutput.resolvedOutputKind(nodeId: erosion, output: "ridge") == .data,
           "ridge should resolve as data")
    expect(multiOutput.terrainReference(
        for: GraphOutputReference(node: erosion, output: "ridge")) ==
        GraphOutputReference(node: erosion, output: "height"),
        "data preview should use sibling terrain geometry")
    do {
        let encoded = try multiOutput.encodedString()
        var decoded = try JSONDecoder().decode(GraphDocument.self,
                                               from: Data(encoded.utf8))
        decoded.ensureLayout()
        expect(decoded.formatVersion == 3 && decoded.sinkOutput == "ridge",
               "v3 round-trip should preserve selected output")
        expect(decoded.connections.first?.output == "height",
               "v2 round-trip should preserve edge source port")
    } catch {
        expect(false, "multi-output round-trip failed: \(error)")
    }
    print("✓ typed multi-output authoring and preview geometry")

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
        expect(migrated.formatVersion == 3 && migrated.sinkOutput == "mask",
               "v1 sink should migrate to its default named output")
        expect(migrated.connections.first?.output == "height",
               "v1 edge should migrate to source default output")
        expect(migrated.maskEraseStrokes(nodeId: "river", output: "mask").count == 1,
               "v1 mask edits should migrate under the mask output")
    } catch {
        expect(false, "v1 multi-output migration failed: \(error)")
    }
    print("✓ graph v1 to v3 named-output migration")

    do {
        var material = try GraphDocument.load(path: "examples/material-stack.json")
        expect(material.formatVersion == 3, "material example should load as graph v3")
        expect(material.materialStack?.layers.map(\.id) ==
               ["ground", "rock", "water", "ridge"],
               "material channel order should survive load")
        expect(material.materialStackValidationMessage() == nil,
               "material example should be semantically valid")
        expect(material.materialSourceCandidates().contains(
            GraphOutputReference(node: "gullies", output: "ridge")),
            "data outputs should appear in material source candidates")
        expect(material.materialSourceCandidates().contains(
            GraphOutputReference(node: "river", output: "mask")),
            "mask outputs should appear in material source candidates")
        expect(!material.materialSourceCandidates().contains(
            GraphOutputReference(node: "gullies", output: "height")),
            "terrain outputs must be filtered from material sources")

        var materialWithAvailableSource = material
        materialWithAvailableSource.removeMaterialLayer(index: 3)
        let stackBeforeCandidateLookup = materialWithAvailableSource.materialStack
        let unusedSources = materialWithAvailableSource.unusedMaterialSourceCandidates()
        expect(unusedSources == [
            GraphOutputReference(node: "gullies", output: "ridge"),
            GraphOutputReference(node: "ridgecoverage", output: "field")
        ], "unused material candidates should exclude sources already assigned")
        expect(materialWithAvailableSource
            .materialSourceCandidatesPrioritizingUnused().first == unusedSources.first,
            "unused material candidates should be offered before explicit duplicates")
        expect(materialWithAvailableSource.materialStack == stackBeforeCandidateLookup,
               "candidate lookup must not mutate the material stack")
        expect(material.unusedMaterialSourceCandidates(excludingLayerAt: 1).contains(
            GraphOutputReference(node: "steep", output: "mask")),
            "editing a layer should keep its current source available")

        var materialHistory = GraphDocumentHistory(limit: 4)
        materialHistory.record(material)
        material.setMaterialLayerColor(index: 0, color: [0.1, 0.2, 0.3])
        material.moveMaterialLayer(from: 3, offset: -1)
        expect(material.materialStack?.layers.map(\.id) ==
               ["ground", "rock", "ridge", "water"],
               "overlay reorder should change RGBA channel order")
        if let restored = materialHistory.undo(current: material) {
            expect(restored.materialStack?.layers.first?.previewColorSRGB ==
                   [0.22, 0.39, 0.18],
                   "material color change should participate in undo")
            expect(restored.materialStack?.layers.map(\.id) ==
                   ["ground", "rock", "water", "ridge"],
                   "material reorder should participate in undo")
        } else {
            expect(false, "material history snapshot missing")
        }

        let encoded = try material.encodedString()
        let decoded = try JSONDecoder().decode(GraphDocument.self,
                                                from: Data(encoded.utf8))
        expect(decoded.materialStack == material.materialStack,
               "material stack should round-trip colors, sources and order")

        if let encodedData = encoded.data(using: .utf8),
           var root = try JSONSerialization.jsonObject(with: encodedData) as? [String: Any],
           var stack = root["materialStack"] as? [String: Any],
           var layers = stack["layers"] as? [[String: Any]] {
            let originalLayers = layers
            layers[1]["source"] = ["node": "", "output": "mask"]
            stack["layers"] = layers
            root["materialStack"] = stack
            let emptyReference = try JSONSerialization.data(withJSONObject: root)
            expect((try? JSONDecoder().decode(GraphDocument.self,
                                               from: emptyReference)) == nil,
                   "Swift loader must reject empty material source references")

            layers = originalLayers
            if !layers.isEmpty {
                layers[0]["source"] = NSNull()
                stack["layers"] = layers
                root["materialStack"] = stack
                let nullBase = try JSONSerialization.data(withJSONObject: root)
                expect((try? JSONDecoder().decode(GraphDocument.self,
                                                   from: nullBase)) == nil,
                       "Swift loader must reject an explicit null base source")
            }
        } else {
            expect(false, "could not construct strict Swift material loader tests")
        }

        let channelOrderBeforeDeletion = material.materialStack?.layers.map(\.id)
        material.deleteNode(id: "river")
        expect(material.materialStack?.layers.map(\.id) == channelOrderBeforeDeletion,
               "deleting a source node must preserve layer identity and RGBA order")
        expect(material.materialStack?.layers.first(where: {
            $0.id == "water"
        })?.source == nil,
               "deleting a source node should clear only the affected layer source")
        expect(material.materialStackValidationMessage() != nil,
               "cleared material source should invalidate preview/export")
        expect(GraphDiagnostics.analyze(material).issues.contains(where: {
            $0.code == "missing_material_source"
        }), "cleared material source should be reported by core diagnostics")
        let repairableText = try material.encodedString()
        let repairableDecoded = try JSONDecoder().decode(
            GraphDocument.self, from: Data(repairableText.utf8))
        expect(repairableDecoded.materialStack?.layers.first(where: {
            $0.id == "water"
        })?.source == nil,
               "cleared layer source should round-trip through the Swift loader")
        if let graph = theia.graph_create() {
            expect(theia.graph_load_json_text(graph, repairableText),
                   "graph with an empty layer source must remain loadable for repair")
            theia.graph_destroy(graph)
        } else {
            expect(false, "graph creation failed for dangling material source test")
        }

        material.deleteNode(id: "gullies")
        expect(material.materialStack?.terrain.node == "gullies" &&
               material.materialStack?.layers.map(\.id) == channelOrderBeforeDeletion &&
               material.materialStackValidationMessage() != nil,
               "deleted terrain reference and layer channels should remain visible as invalid")

        var bulkDeletion = try GraphDocument.load(path: "examples/material-stack.json")
        let idsBeforeBulkDeletion = bulkDeletion.materialStack?.layers.map(\.id)
        bulkDeletion.deleteNodes(ids: ["river", "steep"])
        expect(bulkDeletion.materialStack?.layers.map(\.id) == idsBeforeBulkDeletion &&
               bulkDeletion.materialStack?.layers.first(where: {
                   $0.id == "rock"
               })?.source == nil &&
               bulkDeletion.materialStack?.layers.first(where: {
                   $0.id == "water"
               })?.source == nil,
               "bulk deletion must clear affected sources without reordering layers")
        print("✓ material stack persistence, filtering, history and deletion semantics")
    } catch {
        expect(false, "material stack viewer semantics failed: \(error)")
    }

    var incompleteCandidates = GraphDocument.emptyDocument(width: 32, height: 32)
    let completeTerrain = incompleteCandidates.addNode(type: "perlin")
    let incompleteFilter = incompleteCandidates.addNode(type: "erosionfilter")
    let incompleteRiver = incompleteCandidates.addNode(type: "river")
    let incompleteRemap = incompleteCandidates.addNode(type: "remap")
    expect(incompleteCandidates.materialTerrainCandidates() == [
        GraphOutputReference(node: completeTerrain, output: "height")
    ], "terrain candidates should exclude nodes with missing dependencies")
    expect(incompleteCandidates.materialSourceCandidates().isEmpty,
           "mask/data candidates should exclude nodes with missing dependencies")

    incompleteCandidates.connect(from: completeTerrain, to: incompleteFilter, input: 0)
    incompleteCandidates.connect(from: completeTerrain, to: incompleteRiver, input: 0)
    expect(incompleteCandidates.materialTerrainCandidates().contains(
        GraphOutputReference(node: incompleteFilter, output: "height")),
        "completed terrain dependency should become a material terrain candidate")
    expect(incompleteCandidates.materialSourceCandidates().contains(
        GraphOutputReference(node: incompleteFilter, output: "ridge")),
        "completed data dependency should become a material source candidate")
    expect(incompleteCandidates.materialSourceCandidates().contains(
        GraphOutputReference(node: incompleteRiver, output: "mask")),
        "completed mask dependency should become a material source candidate")
    expect(!incompleteCandidates.materialSourceCandidates().contains(
        GraphOutputReference(node: incompleteRemap, output: "field")),
        "unconnected inherited output must not be offered as a material source")
    incompleteCandidates.connect(from: incompleteRiver, output: "mask",
                                 to: incompleteRemap, input: 0)
    expect(incompleteCandidates.materialSourceCandidates().contains(
        GraphOutputReference(node: incompleteRemap, output: "field")),
        "completed inherited output should become a material source candidate")

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
           GraphOutputReference(node: duplicateTerrain, output: "height"),
           "terrain traversal must follow only each effective inbound connection")
    print("✓ material candidates require complete evaluable dependencies")

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
    maskDocument.connect(from: maskTerrain, output: "height",
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

    expect(abs(MaterialPreviewMath.srgbToLinear(0.04045) -
               (0.04045 / 12.92)) < 1e-12,
           "sRGB decode breakpoint should use the linear branch")
    expect(abs(MaterialPreviewMath.linearToSRGB(0.0031308) -
               (0.0031308 * 12.92)) < 1e-12,
           "sRGB encode breakpoint should use the linear branch")
    let decodedRGB = MaterialPreviewMath.srgbToLinear([0, 0.5, 1])
    expect(decodedRGB.count == 3 && decodedRGB[0] == 0 && decodedRGB[2] == 1 &&
           abs(decodedRGB[1] - 0.21404114048223255) < 1e-12,
           "material uniform colors should be decoded to linear light once on CPU")
    let midpoint = MaterialPreviewMath.blend(
        colorsSRGB: [[0, 0, 0], [1, 1, 1]], weights: [0.5, 0.5])
    expect(midpoint.allSatisfy { abs($0 - 0.735356983) < 1e-6 },
           "material colors must blend in linear light, not sRGB space")
    let fallbackWeights = Renderer.materialFallbackWeights(texelCount: 2)
    expect(fallbackWeights == [1, 0, 0, 0, 1, 0, 0, 0],
           "scalar preview fallback weights should select only the base channel")
    print("✓ audited sRGB transfer and linear-light material blend")

    if let device = MTLCreateSystemDefaultDevice(),
       let performanceRenderer = Renderer(device: device, colorFormat: .bgra8Unorm) {
        let dimension = 512
        let texels = dimension * dimension
        let flat = [Float](repeating: 0.5, count: texels)
        func packedWeights(_ rgba: [Float]) -> [Float] {
            var result = [Float](repeating: 0, count: texels * 4)
            for texel in 0..<texels {
                for channel in 0..<4 { result[texel * 4 + channel] = rgba[channel] }
            }
            return result
        }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? .infinity : sorted[sorted.count / 2]
        }
        performanceRenderer.applyViewportSettings(
            lightAzimuthDegrees: 35, lightElevationDegrees: 58,
            wireframeEnabled: false, displayMode: .material,
            materialPreset: .natural, maskOpacity: 0.65,
            gridVisible: false, axisVisible: false,
            projectionMode: .perspective)
        performanceRenderer.setPreview(
            heights: flat, data: flat,
            weightsRGBA: packedWeights([0.5, 0.5, 0, 0]),
            width: dimension, height: dimension, dataMatchesHeights: true)
        let uploadsAfterOneOverlay = performanceRenderer.previewUploadCount
        let twoChannelTime = median(performanceRenderer.benchmarkFrameTimes(
            width: 640, height: 400, measuredFrames: 12))
        performanceRenderer.setPreview(
            heights: flat, data: flat,
            weightsRGBA: packedWeights([0.25, 0.25, 0.25, 0.25]),
            width: dimension, height: dimension, dataMatchesHeights: true)
        let fourChannelTime = median(performanceRenderer.benchmarkFrameTimes(
            width: 640, height: 400, measuredFrames: 12))
        expect(twoChannelTime.isFinite && fourChannelTime.isFinite,
               "material frame benchmark should complete")
        expect(performanceRenderer.previewUploadCount == uploadsAfterOneOverlay + 1,
               "one- and three-overlay previews must use the same single packed upload path")
        // Timing remains diagnostic rather than pass/fail: GPU scheduling and
        // thermal contention make a wall-clock ratio unsuitable for a mandatory
        // functional self-test. Both cases execute the same float4 shader path.
        print(String(format:
            "✓ material steady-state render %.2fms (one overlay) / %.2fms (three overlays)",
            twoChannelTime, fourChannelTime))
    } else {
        expect(false, "Metal renderer unavailable for material performance test")
    }

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
       let engine = TerrainEngine(graphPath: "examples/material-stack.json") {
        let model = TerrainModel(engine: engine, renderer: renderer, size: 32)
        let deadline = Date().addingTimeInterval(15)
        while model.lastStats.hasPrefix("evaluating") && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        expect(model.lastStats.hasPrefix("nodes "),
               "material model preview should finish in background")
        var globalModelChanges = 0
        let modelChangeToken = model.objectWillChange.sink {
            globalModelChanges += 1
        }
        let cameraRevision = model.cameraSignal.revision
        let cameraActivity = model.previewWorkerActivity()
        let cameraUploads = renderer.previewUploadCount
        model.viewportCameraDidChange()
        modelChangeToken.cancel()
        expect(model.cameraSignal.revision == cameraRevision + 1 &&
               globalModelChanges == 0,
               "camera motion should invalidate only the axis gizmo signal")
        expect(model.previewWorkerActivity() == cameraActivity &&
               renderer.previewUploadCount == cameraUploads,
               "camera motion must not schedule graph work or rebuild preview buffers")
        let evaluationStatus = model.lastStats
        let activityBeforeColor = model.previewWorkerActivity()
        let uploadsBeforeColor = renderer.previewUploadCount
        let originalBaseColor = [0.22, 0.39, 0.18]
        model.setMaterialLayerColor(index: 0, color: [0.2, 0.3, 0.4])
        RunLoop.current.run(until: Date().addingTimeInterval(0.30))
        model.setMaterialLayerColor(index: 0, color: [0.24, 0.34, 0.44])
        RunLoop.current.run(until: Date().addingTimeInterval(0.30))
        model.setMaterialLayerColor(index: 0, color: [0.26, 0.36, 0.46])
        expect(model.lastStats == evaluationStatus,
               "color-only material edits must not evaluate the graph again")
        expect(model.previewWorkerActivity().submitted == activityBeforeColor.submitted,
               "color-only material edits must not submit preview work")
        expect(renderer.previewUploadCount == uploadsBeforeColor,
               "color-only material edits must not rebuild preview buffers")
        expect(model.previewWorkerActivity().submitted == activityBeforeColor.submitted &&
               renderer.previewUploadCount == uploadsBeforeColor,
               "a long continuous color gesture should remain uniform-only")
        model.undo()
        expect(model.document.materialStack?.layers[0].previewColorSRGB ==
               originalBaseColor,
               "a color gesture spanning the debounce window should undo in one step")
        expect(!model.isDirty,
               "undo back to the loaded document must restore clean dirty state")
        model.setDisplayMode(.terrain)
        let scalarDeadline = Date().addingTimeInterval(10)
        while model.lastStats.hasPrefix("evaluating") && Date() < scalarDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let activityBeforeCachedMode = model.previewWorkerActivity()
        model.setDisplayMode(.material)
        expect(model.previewWorkerActivity().submitted ==
               activityBeforeCachedMode.submitted &&
               model.lastStats.hasPrefix("material cached"),
               "returning to material mode should reuse the packed preview")
        let residentUploads = renderer.previewUploadCount
        let residentActivity = model.previewWorkerActivity()
        model.setDisplayMode(.material)
        expect(renderer.previewUploadCount == residentUploads &&
               model.previewWorkerActivity() == residentActivity,
               "selecting an already resident material mode must be a no-op")
        let persistedMode = model.document.ui?.preview.displayMode
        let dirtyBeforeInspect = model.isDirty
        model.inspectMaterialLayerSource(index: 2)
        expect(!model.canEditActiveMask,
               "mask eraser must wait for the inspected scalar preview to become resident")
        let inspectedMaskDeadline = Date().addingTimeInterval(10)
        while model.lastStats.hasPrefix("evaluating") &&
                Date() < inspectedMaskDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        expect(model.displayMode == .material && persistedMode == .material &&
               model.document.ui?.preview.displayMode == persistedMode &&
               model.activeDisplayModeLabel() == "mask" &&
               model.previewReference == GraphOutputReference(node: "river",
                                                               output: "mask"),
               "inspect-source should use an ephemeral scalar mode without changing the document")
        expect(model.isDirty == dirtyBeforeInspect,
               "inspect-source must not change document dirty state")
        expect(model.canEditActiveMask,
               "evaluated material mask source should expose the mask eraser")
        model.setMaskBrushEnabled(true)
        model.setDisplayMode(.material)
        expect(!model.canEditActiveMask && !model.maskBrushEnabled &&
               !model.beginMaskBrush(at: CGPoint(x: 0.5, y: 0.5)),
               "composite material preview must never accept mask brush strokes")

        model.inspectMaterialLayerSource(index: 2)
        let inspectedReference = model.previewReference
        model.setMaterialLayerColor(index: 0, color: [0.31, 0.32, 0.33])
        expect(model.isDirty, "semantic color edit should dirty the document")
        model.undo()
        expect(model.previewReference == inspectedReference &&
               model.activeDisplayModeLabel() == "mask",
               "undo while inspecting a source should preserve ephemeral preview state")
        expect(!model.isDirty,
               "undoing the semantic edit should return to the saved fingerprint")
        let stackBeforeRemoval = model.document.materialStack
        model.removeMaterialStack()
        expect(model.document.materialStack == nil,
               "material stack should be explicitly removable")
        model.undo()
        expect(model.document.materialStack == stackBeforeRemoval,
               "removing a material stack should participate in undo")
        print("✓ material color uniforms update without graph evaluation")
    } else {
        expect(false, "Metal renderer unavailable for material color test")
    }

    if let device = MTLCreateSystemDefaultDevice(),
       let renderer = Renderer(device: device, colorFormat: .bgra8Unorm),
       let engine = TerrainEngine(graphPath: "examples/material-stack.json") {
        let model = TerrainModel(engine: engine, renderer: renderer, size: 32)
        model.inspectMaterialLayerSource(index: 2)
        let editableDeadline = Date().addingTimeInterval(10)
        while model.lastStats.hasPrefix("evaluating") && Date() < editableDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        expect(model.canEditActiveMask,
               "resident source mask should be editable before topology changes")
        if let riverInput = model.document.connections.last(where: {
            $0.to == "river" && $0.input == 0
        }) {
            model.setMaskBrushEnabled(true)
            model.disconnect(riverInput)
            expect(!model.maskBrushEnabled && !model.canEditActiveMask,
                   "disconnecting a mask dependency must disable the eraser")
            model.undo()
            let restoredDeadline = Date().addingTimeInterval(10)
            while model.lastStats.hasPrefix("evaluating") && Date() < restoredDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            expect(!model.maskBrushEnabled && model.canEditActiveMask,
                   "undo may restore mask evaluability but must not re-enable the eraser")
        } else {
            expect(false, "material example river input missing")
        }
        model.setMaskBrushEnabled(true)
        expect(model.beginMaskBrush(at: CGPoint(x: 0.5, y: 0.5)),
               "resident source should begin a mask stroke")
        model.deleteSelection()
        expect(!model.maskBrushEnabled &&
               model.document.ui?.maskErases["river"] == nil,
               "deleting during a stroke must end it before removal and leave no orphan edit")
        expect(model.document.materialStack?.layers.first(where: {
            $0.id == "water"
        })?.source == nil,
               "viewer deletion should empty only the deleted overlay source")
        model.setDisplayMode(.material)
        expect(model.lastStats.hasPrefix("invalid material stack") &&
               model.materialStackIssue != nil,
               "invalid material stacks must fail composite preview instead of using legacy material")
        model.runMaterialExport()
        expect(model.exportStatus.hasPrefix("export failed"),
               "invalid material stack must block global bundle export")
        model.undo()
        expect(model.document.materialStackValidationMessage() == nil,
               "undo should restore a deleted material source and valid stack")
        print("✓ invalid material stacks remain repairable without legacy fallback")
    } else {
        expect(false, "Metal renderer unavailable for invalid material stack test")
    }

    if let device = MTLCreateSystemDefaultDevice(),
       let renderer = Renderer(device: device, colorFormat: .bgra8Unorm),
       let engine = TerrainEngine(graphPath: "examples/erosion-filter.json") {
        let model = TerrainModel(engine: engine, renderer: renderer, size: 32)
        let intendedTerrain = GraphOutputReference(node: model.document.sink,
                                                   output: model.document.sinkOutput)
        model.addNode(type: "combine")
        let incompleteTerrain = model.previewReference
        expect(!model.materialTerrainOptions.contains(incompleteTerrain),
               "incomplete inherited terrain must not be a material candidate")
        model.createMaterialStack()
        expect(model.document.materialStack?.terrain == intendedTerrain &&
               model.document.materialStack?.terrain != incompleteTerrain &&
               model.document.materialStackValidationMessage() == nil,
               "Create Material Stack must prefer the evaluable graph output terrain")
        print("✓ material stack creation ignores incomplete preview terrain")
    } else {
        expect(false, "Metal renderer unavailable for material creation test")
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
    let terrainOutput = GraphOutputReference(node: "terrain", output: "height")
    previewWorker.submit(jsonText: previewJSON(1), geometry: terrainOutput,
                         data: terrainOutput, size: 32) { _ in
        previewCompletions += 1
    }
    previewWorker.submit(jsonText: previewJSON(2), geometry: terrainOutput,
                         data: terrainOutput, size: 32) { outcome in
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

    do {
        let materialText = try String(contentsOfFile: "examples/material-stack.json",
                                      encoding: .utf8)
        let materialWorker = TerrainPreviewWorker()
        var materialFinished = false
        var materialCompletions = 0
        let testMaterialColors = [[0.2, 0.3, 0.1], [0.5, 0.5, 0.5],
                                  [0.1, 0.3, 0.7], [0.8, 0.4, 0.1]]
        materialWorker.submitMaterial(jsonText: materialText,
                                      colorsSRGB: testMaterialColors,
                                      size: 32) { _ in
            materialCompletions += 1
        }
        materialWorker.submitMaterial(jsonText: materialText,
                                      colorsSRGB: testMaterialColors,
                                      size: 32) { outcome in
            materialCompletions += 1
            if case .success(let preview) = outcome {
                expect(preview.geometry.count == 32 * 32,
                       "material worker terrain geometry count")
                expect(preview.weightsRGBA?.count == 32 * 32 * 4,
                       "material worker packed weight count")
                if let weights = preview.weightsRGBA {
                    var normalized = true
                    for texel in stride(from: 0, to: 32 * 32, by: 17) {
                        let start = texel * 4
                        let sum = weights[start..<(start + 4)].reduce(0, +)
                        normalized = normalized && abs(sum - 1) < 2e-6
                    }
                    expect(normalized, "material preview weights must sum to one")
                }
            } else {
                expect(false, "latest material preview snapshot failed")
            }
            materialFinished = true
        }
        let materialDeadline = Date().addingTimeInterval(15)
        while !materialFinished && Date() < materialDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        expect(materialFinished, "material preview worker timed out")
        expect(materialCompletions == 1,
               "stale material preview result should be discarded")
        let materialActivity = materialWorker.activitySnapshot()
        expect(materialActivity.submitted == 2 && materialActivity.started == 1 &&
               materialActivity.skippedBeforeStart >= 1 &&
               materialActivity.delivered == 1,
               "material worker should coalesce rapid layer edits")
        print("✓ asynchronous material preview and stale-result dropping")
    } catch {
        expect(false, "material worker fixture failed: \(error)")
    }

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

    // The viewer decodes documents itself, so it needs the same world-scale
    // migration the core performs -- otherwise a legacy file would render with
    // one scale in the viewer and another through the CLI.
    do {
        var legacy = try JSONDecoder().decode(GraphDocument.self, from: Data("""
        {
          "resolution": { "width": 128, "height": 128 },
          "sink": "mask",
          "nodes": [
            { "id": "base", "type": "perlin", "params": {} },
            { "id": "mask", "type": "slopemask",
              "params": { "low": 25.0, "high": 45.0,
                          "terrainSize": 512.0, "heightScale": 150.0 } },
            { "id": "t", "type": "thermal",
              "params": { "talusAngle": 33.0, "terrainSize": 2048.0 } }
          ],
          "connections": [ { "from": "base", "to": "mask", "input": 0 } ]
        }
        """.utf8))
        legacy.ensureNodeDefaults()
        expect(legacy.world.terrainSize == 512.0,
               "viewer should adopt the first physics node's terrainSize")
        expect(legacy.world.heightScale == 150.0,
               "viewer should adopt the first physics node's heightScale")
        expect(legacy.node(id: "mask")?.params["terrainSize"] == nil,
               "scale must not survive as a node param in the viewer")
        expect(legacy.node(id: "t")?.params["terrainSize"] == nil,
               "later nodes must drop their conflicting scale copy")

        // An authored world block is authoritative over per-node leftovers.
        var modern = try JSONDecoder().decode(GraphDocument.self, from: Data("""
        {
          "resolution": { "width": 128, "height": 128 },
          "world": { "terrainSize": 300.0, "heightScale": 90.0 },
          "sink": "mask",
          "nodes": [
            { "id": "base", "type": "perlin", "params": {} },
            { "id": "mask", "type": "slopemask",
              "params": { "low": 25.0, "high": 45.0, "terrainSize": 512.0 } }
          ],
          "connections": [ { "from": "base", "to": "mask", "input": 0 } ]
        }
        """.utf8))
        modern.ensureNodeDefaults()
        expect(modern.world.terrainSize == 300.0,
               "an authored world block must win over per-node leftovers")

        // Round-trip: world must survive encode/decode or saving would drop it.
        let data = try JSONEncoder().encode(modern)
        let reloaded = try JSONDecoder().decode(GraphDocument.self, from: data)
        expect(reloaded.world == modern.world, "world must survive a round trip")
        print("✓ graph-level world scale migrates and round-trips")
    } catch {
        expect(false, "world migration fixture failed: \(error)")
    }

    print("\n\(checks) viewer checks, \(failures) failure(s)")
    return failures == 0 ? 0 : 1
}
