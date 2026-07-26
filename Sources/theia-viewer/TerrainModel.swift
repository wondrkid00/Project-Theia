import Foundation
import SwiftUI
import TheiaCore

struct GraphParameter: Identifiable {
    let nodeId: String
    let nodeType: String
    let name: String
    var value: Double

    var id: String { "\(nodeId).\(name)" }
}

struct GraphNodeInfo: Identifiable {
    let id: String
    let type: String
    var params: [GraphParameter]
}

private struct CachedMaterialPreview {
    let signature: String
    let geometry: [Float]
    let weightsRGBA: [Float]
    let width: Int
    let height: Int
    let evaluated: UInt32
    let reused: UInt32
}

/// Camera motion is high-frequency UI state. Keeping its revision in a small
/// observable prevents orbit/pan/zoom from invalidating the entire inspector
/// tree (including every material layer row) on every pointer event.
final class ViewportCameraSignal: ObservableObject {
    @Published private(set) var revision: UInt64 = 0

    func bump() {
        revision &+= 1
    }
}

enum ViewportTool: String, CaseIterable, Identifiable {
    case orbit
    case pan
    case zoom

    var id: String { rawValue }
}

@MainActor
final class TerrainModel: ObservableObject {
    @Published private(set) var nodes: [GraphNodeInfo] = []
    @Published private(set) var lastStats = ""
    @Published private(set) var document: GraphDocument
    @Published var selectedNodeId: String?
    @Published private(set) var selectedNodeIds: Set<String> = []
    @Published var selectedConnectionId: String?
    @Published private(set) var saveStatus = ""
    @Published private(set) var lastSavedAt: Date?
    @Published private(set) var isDirty = false
    @Published var lightAzimuthDegrees = 35.0
    @Published var lightElevationDegrees = 58.0
    @Published var wireframeEnabled = false
    @Published var displayMode: ViewportDisplayMode = .auto
    @Published var materialPreset: MaterialPreset = .natural
    @Published var maskOpacity = 0.65
    @Published var gridVisible = true
    @Published var axisVisible = true
    @Published var viewportTool: ViewportTool = .orbit
    @Published var viewportProjection: ViewportProjection = .perspective
    @Published var maskBrushEnabled = false
    @Published var maskBrushRadius = 0.035
    @Published var exportSettings = ExportSettings()
    @Published private(set) var exportStatus = ""
    @Published private(set) var isExporting = false
    @Published private(set) var diagnostics = GraphDiagnostics.empty
    @Published private(set) var materialTerrainOptions: [GraphOutputReference] = []
    @Published private(set) var materialSourceOptions: [GraphOutputReference] = []
    @Published private(set) var materialStackIssue: String?
    @Published private(set) var recentNodeTypes: [String] = []
    @Published private(set) var previewReference = GraphOutputReference(node: "", output: "")
    let cameraSignal = ViewportCameraSignal()

    let engine: TerrainEngine
    let renderer: Renderer
    let size: UInt32
    @Published private(set) var graphPath: String?
    let availableNodeTypes: [String]
    private var documentCanSave = true
    private var history = GraphDocumentHistory()
    private var isRestoringHistory = false
    private var isInteractiveMove = false
    private var isMaskBrushStrokeActive = false
    private var activeMaskBrushNodeId: String?
    private var activeMaskBrushOutput: String?
    private var lastMaskBrushUV: CGPoint?
    private var pendingMaskEraseStrokes: [GraphMaskEraseStroke] = []
    private var currentPreviewGeometry: [Float] = []
    private var currentPreviewData: [Float] = []
    private var currentScalarPreviewReference: GraphOutputReference?
    private var currentPreviewDataMatchesGeometry = false
    private var currentPreviewWeights: [Float]?
    private var currentPreviewWidth = 0
    private var currentPreviewHeight = 0
    private var cachedMaterialPreview: CachedMaterialPreview?
    private var residentMaterialSignature: String?
    private var transientDisplayMode: ViewportDisplayMode?
    private var materialColorGestureLayer: Int?
    private var materialColorGestureTask: Task<Void, Never>?
    private var cleanDocumentFingerprint: String?
    private let previewWorker = TerrainPreviewWorker()

    private var activeOutputReference: GraphOutputReference {
        previewReference
    }

    var activeOutputSupportsMesh: Bool {
        document.resolvedOutputKind(nodeId: document.sink,
                                    output: document.sinkOutput) == .terrain
    }

    init(engine: TerrainEngine, renderer: Renderer, size: UInt32) {
        self.engine = engine
        self.renderer = renderer
        self.size = size
        graphPath = engine.graphPath
        availableNodeTypes = readCxxString { theia.node_type_list($0, $1) }
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let path = engine.graphPath, let loaded = try? GraphDocument.load(path: path) {
            document = loaded
            exportSettings.basename = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        } else {
            document = GraphDocument.defaultDocument()
        }
        exportSettings.size = size == 0 ? document.resolution.width : size
        previewReference = GraphOutputReference(node: document.sink,
                                                output: document.sinkOutput)
        loadPreviewSettingsFromDocument()
        reloadInspector()
        syncPreviewWithDocument(markDirty: false)
        cleanDocumentFingerprint = try? document.encodedString()
        applyViewportSettings()
    }

    func record(_ result: theia.GraphEvalResult) {
        lastStats = "nodes \(result.evaluated), reused \(result.reused)"
    }

    func applyViewportSettings(displayMode override: ViewportDisplayMode? = nil) {
        renderer.applyViewportSettings(lightAzimuthDegrees: lightAzimuthDegrees,
                                       lightElevationDegrees: lightElevationDegrees,
                                       wireframeEnabled: wireframeEnabled,
                                       displayMode: override ?? effectiveDisplayMode(for: activeOutputReference),
                                       materialPreset: materialPreset,
                                       maskOpacity: maskOpacity,
                                       gridVisible: gridVisible,
                                       axisVisible: axisVisible,
                                       projectionMode: viewportProjection)
    }

    func resetCamera() {
        renderer.resetCamera()
        viewportCameraDidChange()
    }

    func setCameraPreset(_ preset: CameraPreset) {
        renderer.setCameraPreset(preset)
        viewportCameraDidChange()
    }

    func viewportCameraDidChange() {
        cameraSignal.bump()
    }

    func setDisplayMode(_ mode: ViewportDisplayMode) {
        let changed = displayMode != mode
        let wasTransient = transientDisplayMode != nil
        if !changed && !wasTransient {
            applyViewportSettings(displayMode: mode)
            return
        }
        transientDisplayMode = nil
        displayMode = mode
        if effectiveDisplayMode(for: activeOutputReference) != .mask {
            setMaskBrushEnabled(false)
        }
        if changed { persistPreviewSettings() }
        _ = refreshTerrain()
    }

    func setMaterialPreset(_ preset: MaterialPreset) {
        materialPreset = preset
        persistPreviewSettings()
        applyViewportSettings()
    }

    func setMaskOpacity(_ opacity: Double) {
        maskOpacity = min(max(opacity, 0), 1)
        persistPreviewSettings()
        applyViewportSettings()
    }

    func setGridVisible(_ visible: Bool) {
        gridVisible = visible
        applyViewportSettings()
    }

    func setAxisVisible(_ visible: Bool) {
        axisVisible = visible
        applyViewportSettings()
    }

    func setViewportTool(_ tool: ViewportTool) {
        viewportTool = tool
        setMaskBrushEnabled(false)
    }

    func setMaskBrushEnabled(_ enabled: Bool) {
        maskBrushEnabled = enabled && canEditActiveMask
        if !maskBrushEnabled {
            endMaskBrush()
        }
    }

    func setViewportProjection(_ projection: ViewportProjection) {
        viewportProjection = projection
        applyViewportSettings()
        viewportCameraDidChange()
    }

    func activeDisplayModeLabel() -> String {
        effectiveDisplayMode(for: activeOutputReference).label
    }

    var canEditActiveMask: Bool {
        effectiveDisplayMode(for: activeOutputReference) == .mask &&
            editableMaskReference() != nil
    }

    var activeMaskEraseCount: Int {
        guard canEditActiveMask,
              let reference = editableMaskReference() else { return 0 }
        return document.maskEraseStrokes(nodeId: reference.node,
                                         output: reference.output).count
    }

    func beginMaskBrush(at uv: CGPoint) -> Bool {
        guard maskBrushEnabled, canEditActiveMask,
              let reference = editableMaskReference() else { return false }
        previewWorker.cancelPending()
        pushUndo()
        isMaskBrushStrokeActive = true
        activeMaskBrushNodeId = reference.node
        activeMaskBrushOutput = reference.output
        lastMaskBrushUV = uv
        pendingMaskEraseStrokes.removeAll(keepingCapacity: true)
        queueMaskEraseStroke(at: uv)
        return true
    }

    func continueMaskBrush(at uv: CGPoint) -> Bool {
        guard maskBrushEnabled,
              isMaskBrushStrokeActive,
              activeMaskBrushNodeId != nil,
              let lastMaskBrushUV else { return false }
        let spacing = max(maskBrushRadius * 0.30, 0.0015)
        let points = MaskBrushRasterizer.interpolatedPoints(
            from: lastMaskBrushUV, to: uv, spacing: spacing)
        queueMaskEraseStrokes(at: points)
        if let last = points.last {
            self.lastMaskBrushUV = last
        }
        return true
    }

    func endMaskBrush() {
        guard isMaskBrushStrokeActive else { return }
        isMaskBrushStrokeActive = false
        lastMaskBrushUV = nil
        defer {
            activeMaskBrushNodeId = nil
            activeMaskBrushOutput = nil
            pendingMaskEraseStrokes.removeAll(keepingCapacity: true)
        }
        guard let nodeId = activeMaskBrushNodeId,
              let output = activeMaskBrushOutput,
              !pendingMaskEraseStrokes.isEmpty else { return }
        document.addMaskEraseStrokes(nodeId: nodeId,
                                     output: output,
                                     strokes: pendingMaskEraseStrokes)
        applyMaskEraseStrokesToCachedPreview(pendingMaskEraseStrokes)
        documentCanSave = true
        markDirty()
        lastStats = "mask edited (preview cached)"
    }

    func clearActiveMaskErase() {
        guard canEditActiveMask,
              let reference = editableMaskReference() else { return }
        pushUndo()
        document.clearMaskEraseStrokes(nodeId: reference.node,
                                       output: reference.output)
        documentCanSave = true
        markDirty()
        syncPreviewWithDocument(markDirty: false)
    }

    func runExport() {
        guard !isExporting else { return }
        guard !document.sink.isEmpty else {
            exportStatus = "choose a node to export"
            return
        }
        guard exportSettings.size >= 2 else {
            exportStatus = "size must be >= 2"
            return
        }
        guard exportSettings.meshStride > 0 else {
            exportStatus = "mesh stride must be > 0"
            return
        }
        guard exportSettings.verticalScale > 0 else {
            exportStatus = "vertical scale must be > 0"
            return
        }
        guard exportSettings.exportHeightmap || exportSettings.exportMesh else {
            exportStatus = "enable at least one output"
            return
        }
        guard !exportSettings.exportMesh || exportSettings.meshFormat.isSupported else {
            exportStatus = "FBX export is not available yet"
            return
        }
        if exportSettings.exportMesh,
           document.resolvedOutputKind(nodeId: document.sink,
                                       output: document.sinkOutput) != .terrain {
            exportStatus = "mesh export requires a terrain output"
            return
        }

        let settings = exportSettings
        let sink = document.sink
        let output = document.sinkOutput
        let text: String
        do {
            text = try document.encodedString()
        } catch {
            exportStatus = "export failed: \(error.localizedDescription)"
            return
        }
        isExporting = true
        exportStatus = "exporting..."

        DispatchQueue.global(qos: .userInitiated).async { [text, sink, output, settings] in
            let result = TerrainExporter.perform(text: text, sink: sink,
                                                 output: output, settings: settings)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isExporting = false
                self.exportStatus = result
            }
        }
    }

    func runMaterialExport() {
        guard !isExporting else { return }
        guard document.materialStack != nil else {
            exportStatus = "create a material stack first"
            return
        }
        if let issue = document.materialStackValidationMessage() {
            exportStatus = "export failed: \(issue)"
            return
        }
        guard exportSettings.size >= 2, exportSettings.meshStride > 0,
              exportSettings.verticalScale > 0 else {
            exportStatus = "export failed: invalid size or scale"
            return
        }
        guard !exportSettings.exportMesh || exportSettings.meshFormat.isSupported else {
            exportStatus = "export failed: FBX is not available yet"
            return
        }
        let text: String
        do { text = try document.encodedString() } catch {
            exportStatus = "export failed: \(error.localizedDescription)"
            return
        }
        let settings = exportSettings
        isExporting = true
        exportStatus = "exporting material bundle..."
        DispatchQueue.global(qos: .userInitiated).async { [text, settings] in
            let result = TerrainExporter.performMaterial(text: text, settings: settings)
            Task { @MainActor [weak self] in
                self?.isExporting = false
                self?.exportStatus = result
            }
        }
    }

    func createMaterialStack() {
        let candidates = materialTerrainOptions
        let sinkReference = GraphOutputReference(node: document.sink,
                                                 output: document.sinkOutput)
        let upstreamReference = document.terrainReference(for: previewReference)
        let selected = [previewReference, sinkReference, upstreamReference]
            .compactMap { $0 }
            .first(where: { candidates.contains($0) }) ?? candidates.first
        guard let terrain = selected else {
            exportStatus = "material stack needs a terrain output"
            return
        }
        pushUndo()
        document.createMaterialStack(terrain: terrain)
        transientDisplayMode = nil
        displayMode = .material
        document.setPreviewSettings(GraphPreviewSettings(
            displayMode: displayMode, materialPreset: materialPreset,
            maskOpacity: maskOpacity))
        syncPreviewWithDocument(markDirty: true)
    }

    func setMaterialTerrain(_ reference: GraphOutputReference) {
        guard document.resolvedOutputKind(nodeId: reference.node,
                                          output: reference.output) == .terrain,
              document.isOutputEvaluable(reference),
              document.materialStack?.terrain != reference else { return }
        pushUndo()
        document.setMaterialTerrain(reference)
        syncPreviewWithDocument(markDirty: true)
    }

    func setMaterialLayerName(index: Int, name: String) {
        guard let layers = document.materialStack?.layers,
              layers.indices.contains(index) else { return }
        let committed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !committed.isEmpty, layers[index].name != committed else { return }
        pushUndo()
        document.setMaterialLayerName(index: index, name: committed)
        documentCanSave = true
        markDirty()
        materialStackIssue = document.materialStackValidationMessage()
    }

    func setMaterialLayerColor(index: Int, color: [Double]) {
        guard let layers = document.materialStack?.layers,
              layers.indices.contains(index),
              color.count == 3,
              color.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
              layers[index].previewColorSRGB != color else { return }
        if materialColorGestureLayer != index {
            pushUndo()
            materialColorGestureLayer = index
        }
        scheduleMaterialColorGestureEnd(for: index)
        document.setMaterialLayerColor(index: index, color: color)
        documentCanSave = true
        markDirty()
        if let layers = document.materialStack?.layers {
            renderer.setMaterialColors(layers.map(\.previewColorSRGB))
        }
    }

    func setMaterialLayerSource(index: Int, source: GraphOutputReference) {
        guard let kind = document.resolvedOutputKind(nodeId: source.node,
                                                     output: source.output),
              kind == .mask || kind == .data,
              document.isOutputEvaluable(source),
              let layers = document.materialStack?.layers,
              layers.indices.contains(index), index > 0,
              layers[index].source != source else { return }
        pushUndo()
        document.setMaterialLayerSource(index: index, source: source)
        syncPreviewWithDocument(markDirty: true)
    }

    func addMaterialLayer(source: GraphOutputReference) {
        guard materialSourceOptions.contains(source),
              let count = document.materialStack?.layers.count,
              count < 4 else { return }
        pushUndo()
        guard document.addMaterialLayer(source: source) else { return }
        syncPreviewWithDocument(markDirty: true)
    }

    func removeMaterialLayer(index: Int) {
        guard let count = document.materialStack?.layers.count,
              index > 0, index < count else { return }
        pushUndo()
        document.removeMaterialLayer(index: index)
        syncPreviewWithDocument(markDirty: true)
    }

    func moveMaterialLayer(index: Int, offset: Int) {
        guard let count = document.materialStack?.layers.count,
              index > 0, index < count,
              index + offset > 0, index + offset < count else { return }
        pushUndo()
        document.moveMaterialLayer(from: index, offset: offset)
        syncPreviewWithDocument(markDirty: true)
    }

    func inspectMaterialLayerSource(index: Int) {
        guard let layers = document.materialStack?.layers,
              layers.indices.contains(index),
              let source = layers[index].source else { return }
        transientDisplayMode = .auto
        if activeOutputReference == source {
            setMaskBrushEnabled(false)
            _ = refreshTerrain()
        } else {
            selectOutput(nodeId: source.node, output: source.output)
        }
    }

    func removeMaterialStack() {
        guard document.materialStack != nil else { return }
        pushUndo()
        document.materialStack = nil
        cachedMaterialPreview = nil
        transientDisplayMode = nil
        if displayMode == .material {
            displayMode = .auto
            document.setPreviewSettings(GraphPreviewSettings(
                displayMode: displayMode, materialPreset: materialPreset,
                maskOpacity: maskOpacity))
        }
        syncPreviewWithDocument(markDirty: true)
    }

    func reloadInspector() {
        nodes = document.nodes.map { node in
            let params = node.params.keys.sorted().map {
                GraphParameter(nodeId: node.id, nodeType: node.type,
                               name: $0, value: node.params[$0] ?? 0)
            }
            return GraphNodeInfo(id: node.id, type: node.type, params: params)
        }
        refreshDiagnostics()
    }

    func refreshDiagnostics() {
        diagnostics = GraphDiagnostics.analyze(document)
        materialTerrainOptions = document.materialTerrainCandidates()
        materialSourceOptions = document.materialSourceCandidates()
        materialStackIssue = document.materialStack == nil
            ? nil : document.materialStackValidationMessage()
    }

    func apply(nodeId: String, param: String, value: Double) {
        pushUndo()
        document.setParam(nodeId: nodeId, key: param, value: value)
        markDirty()
        guard theia.graph_set_param(engine.handle, nodeId, param, value) else {
            lastStats = engine.lastError()
            return
        }
        _ = refreshTerrain()
        if param == "particles", value >= 20000 {
            lastStats += " - high particle count may preview slowly"
        }
        reloadInspector()
    }

    func resetParam(nodeId: String, param: String) {
        guard let node = document.node(id: nodeId),
              let value = GraphDocument.defaultParams(for: node.type)[param] else { return }
        apply(nodeId: nodeId, param: param, value: value)
    }

    func resetAllParams(nodeId: String) {
        guard document.node(id: nodeId) != nil else { return }
        pushUndo()
        guard document.resetNodeState(nodeId: nodeId) else { return }
        syncPreviewWithDocument(markDirty: true)
        reloadInspector()
    }

    @discardableResult
    func refreshTerrain() -> Bool {
        let dataReference = activeOutputReference
        let mode = effectiveDisplayMode(for: dataReference)
        if mode != .material {
            currentScalarPreviewReference = nil
        }
        if mode == .material, let stack = document.materialStack {
            if let issue = document.materialStackValidationMessage() {
                setFlatPreview(status: "invalid material stack · \(issue)")
                return true
            }
            let signature: String
            do {
                signature = try materialEvaluationSignature()
            } catch {
                lastStats = error.localizedDescription
                return false
            }
            if restoreCachedMaterialPreview(signature: signature,
                                            colors: stack.layers.map(\.previewColorSRGB)) {
                return true
            }
            let text: String
            do {
                text = try document.encodedString()
            } catch {
                lastStats = error.localizedDescription
                return false
            }
            lastStats = "evaluating material layers..."
            previewWorker.submitMaterial(
                jsonText: text,
                colorsSRGB: stack.layers.map(\.previewColorSRGB),
                size: size
            ) { [weak self] outcome in
                guard let self else { return }
                switch outcome {
                case .success(let preview):
                    guard (try? self.materialEvaluationSignature()) == signature,
                          let weights = preview.weightsRGBA else { return }
                    self.currentPreviewGeometry = preview.geometry
                    self.currentPreviewData = preview.data
                    self.currentScalarPreviewReference = nil
                    self.currentPreviewDataMatchesGeometry = preview.dataMatchesGeometry
                    self.currentPreviewWeights = weights
                    self.currentPreviewWidth = preview.width
                    self.currentPreviewHeight = preview.height
                    self.cachedMaterialPreview = CachedMaterialPreview(
                        signature: signature,
                        geometry: preview.geometry,
                        weightsRGBA: weights,
                        width: preview.width,
                        height: preview.height,
                        evaluated: preview.evaluated,
                        reused: preview.reused)
                    let colors = self.document.materialStack?.layers
                        .map(\.previewColorSRGB) ?? preview.materialColorsSRGB ?? []
                    self.renderer.setMaterialColors(colors)
                    self.renderCachedPreview()
                    self.residentMaterialSignature = signature
                    self.applyViewportSettings(displayMode: .material)
                    self.lastStats = "nodes \(preview.evaluated), reused \(preview.reused)"
                case .failure(let message):
                    self.lastStats = message
                    self.setFlatPreview(status: "invalid material stack")
                }
            }
            return true
        }
        guard !dataReference.node.isEmpty else {
            setFlatPreview(status: document.nodes.isEmpty ? "empty graph" : "no output")
            return true
        }

        let geometryReference = document.terrainReference(for: dataReference) ?? dataReference
        let text: String
        do {
            text = try document.encodedString()
        } catch {
            lastStats = error.localizedDescription
            return false
        }
        lastStats = "evaluating..."
        previewWorker.submit(jsonText: text,
                             geometry: geometryReference,
                             data: dataReference,
                             size: size) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success(let preview):
                self.residentMaterialSignature = nil
                self.currentPreviewGeometry = preview.geometry
                self.currentPreviewData = preview.data
                self.currentScalarPreviewReference = dataReference
                self.currentPreviewDataMatchesGeometry = preview.dataMatchesGeometry
                self.currentPreviewWeights = nil
                self.currentPreviewWidth = preview.width
                self.currentPreviewHeight = preview.height
                self.renderCachedPreview()
                self.applyViewportSettings(displayMode: mode)
                self.lastStats = "nodes \(preview.evaluated), reused \(preview.reused)"
            case .failure(let message):
                self.lastStats = message
                self.setFlatPreview(status: "invalid graph")
            }
        }
        return true
    }

    func refreshTerrainSynchronously() -> Bool {
        previewWorker.cancelPending()
        currentScalarPreviewReference = nil
        let dataReference = activeOutputReference
        let mode = effectiveDisplayMode(for: dataReference)
        if mode == .material, let stack = document.materialStack {
            if let issue = document.materialStackValidationMessage() {
                setFlatPreview(status: "invalid material stack · \(issue)")
                return true
            }
            guard let graph = theia.graph_create() else {
                lastStats = "material preview graph creation failed"
                return false
            }
            defer { theia.graph_destroy(graph) }
            guard let text = try? document.encodedString(),
                  theia.graph_load_json_text(graph, text) else {
                lastStats = readCxxString { theia.graph_last_error(graph, $0, $1) }
                return false
            }
            let dimension = Int(size)
            var terrain = [Float](repeating: 0, count: dimension * dimension)
            var weights = [Float](repeating: 0, count: dimension * dimension * 4)
            let result = terrain.withUnsafeMutableBufferPointer { terrainBuffer in
                weights.withUnsafeMutableBufferPointer { weightBuffer in
                    theia.graph_evaluate_material_stack(
                        graph, size, size,
                        terrainBuffer.baseAddress, terrainBuffer.count,
                        weightBuffer.baseAddress, weightBuffer.count)
                }
            }
            guard result.ok else {
                lastStats = readCxxString { theia.graph_last_error(graph, $0, $1) }
                return false
            }
            currentPreviewGeometry = terrain
            currentPreviewData = terrain
            currentScalarPreviewReference = nil
            currentPreviewDataMatchesGeometry = true
            currentPreviewWeights = weights
            currentPreviewWidth = Int(result.width)
            currentPreviewHeight = Int(result.height)
            renderer.setMaterialColors(stack.layers.map(\.previewColorSRGB))
            if let signature = try? materialEvaluationSignature() {
                cachedMaterialPreview = CachedMaterialPreview(
                    signature: signature, geometry: terrain,
                    weightsRGBA: weights, width: Int(result.width),
                    height: Int(result.height), evaluated: result.evaluated,
                    reused: result.reused)
            }
            renderCachedPreview()
            residentMaterialSignature = cachedMaterialPreview?.signature
            applyViewportSettings(displayMode: .material)
            lastStats = "nodes \(result.evaluated), reused \(result.reused)"
            return true
        }
        guard !dataReference.node.isEmpty else {
            setFlatPreview(status: document.nodes.isEmpty ? "empty graph" : "no output")
            return true
        }
        let geometryReference = document.terrainReference(for: dataReference) ?? dataReference
        guard let geometry = engine.evaluate(size: size,
                                             sink: geometryReference.node,
                                             output: geometryReference.output) else {
            lastStats = engine.lastError()
            return false
        }
        let data: (heights: [Float], result: theia.GraphEvalResult)
        if geometryReference == dataReference {
            data = geometry
        } else {
            guard let evaluatedData = engine.evaluate(size: size,
                                                      sink: dataReference.node,
                                                      output: dataReference.output) else {
                lastStats = engine.lastError()
                return false
            }
            data = evaluatedData
        }

        let w = Int(geometry.result.width)
        let h = Int(geometry.result.height)
        currentPreviewGeometry = geometry.heights
        currentPreviewData = data.heights
        currentScalarPreviewReference = dataReference
        residentMaterialSignature = nil
        currentPreviewDataMatchesGeometry = geometryReference == dataReference
        currentPreviewWeights = nil
        currentPreviewWidth = w
        currentPreviewHeight = h
        renderCachedPreview()
        applyViewportSettings(displayMode: mode)

        let evaluated = geometry.result.evaluated +
            (geometryReference == dataReference ? 0 : data.result.evaluated)
        let reused = geometry.result.reused +
            (geometryReference == dataReference ? 0 : data.result.reused)
        lastStats = "nodes \(evaluated), reused \(reused)"
        return true
    }

    func setFlatPreview(status: String = "flat preview") {
        previewWorker.cancelPending()
        residentMaterialSignature = nil
        let dim = max(2, Int(size == 0 ? document.resolution.width : size))
        let flat = [Float](repeating: 0, count: dim * dim)
        currentPreviewGeometry = flat
        currentPreviewData = flat
        currentScalarPreviewReference = nil
        currentPreviewDataMatchesGeometry = true
        currentPreviewWeights = nil
        currentPreviewWidth = dim
        currentPreviewHeight = dim
        renderer.setPreview(heights: flat, data: flat, weightsRGBA: nil,
                            width: dim, height: dim, dataMatchesHeights: true)
        applyViewportSettings(displayMode: .terrain)
        lastStats = status
    }

    func hotReloadIfChanged() -> Bool {
        guard let path = graphPath else { return false }
        guard engine.reloadIfChanged() else { return false }
        if let loaded = try? GraphDocument.load(path: path) {
            document = loaded
            previewReference = GraphOutputReference(node: document.sink,
                                                    output: document.sinkOutput)
            loadPreviewSettingsFromDocument()
            cleanDocumentFingerprint = try? document.encodedString()
            isDirty = false
            saveStatus = "reloaded"
        } else {
            saveStatus = "reloaded preview, document parse failed"
        }
        reloadInspector()
        syncPreviewWithDocument(markDirty: false)
        return true
    }

    func position(for nodeId: String) -> GraphNodePosition {
        document.ui?.positions[nodeId] ?? GraphNodePosition(x: 80, y: 80)
    }

    func outputPorts(for nodeId: String) -> [GraphOutputPort] {
        document.outputPorts(nodeId: nodeId).map { port in
            GraphOutputPort(
                name: port.name,
                declaredKind: document.resolvedOutputKind(nodeId: nodeId,
                                                          output: port.name)
                    ?? port.declaredKind,
                inheritInput: port.inheritInput,
                isDefault: port.isDefault)
        }
    }

    func isActiveOutput(nodeId: String, output: String) -> Bool {
        previewReference.node == nodeId && previewReference.output == output
    }

    func selectOutput(nodeId: String, output: String) {
        guard document.node(id: nodeId) != nil,
              outputPorts(for: nodeId).contains(where: { $0.name == output }),
              !isActiveOutput(nodeId: nodeId, output: output) else { return }
        previewReference = GraphOutputReference(node: nodeId, output: output)
        selectedNodeId = nodeId
        selectedNodeIds = [nodeId]
        selectedConnectionId = nil
        setMaskBrushEnabled(false)
        _ = refreshTerrain()
    }

    func selectNode(_ id: String?, extending: Bool = false) {
        selectedConnectionId = nil
        guard let id else {
            selectedNodeId = nil
            selectedNodeIds = []
            return
        }
        selectedNodeId = id
        if extending {
            selectedNodeIds.insert(id)
        } else {
            selectedNodeIds = [id]
        }
        guard let node = document.node(id: id) else { return }
        previewReference = GraphOutputReference(
            node: id, output: GraphDocument.defaultOutputName(for: node.type))
        setMaskBrushEnabled(false)
        _ = refreshTerrain()
    }

    func selectNodes(_ ids: Set<String>) {
        selectedConnectionId = nil
        selectedNodeIds = ids
        selectedNodeId = ids.sorted().last
        if let selectedNodeId, let node = document.node(id: selectedNodeId) {
            previewReference = GraphOutputReference(
                node: selectedNodeId,
                output: GraphDocument.defaultOutputName(for: node.type))
            setMaskBrushEnabled(false)
            _ = refreshTerrain()
        }
    }

    func previewSelectedNode() {
        guard let selectedNodeId, let node = document.node(id: selectedNodeId) else { return }
        previewReference = GraphOutputReference(
            node: selectedNodeId,
            output: GraphDocument.defaultOutputName(for: node.type))
        setMaskBrushEnabled(false)
        _ = refreshTerrain()
    }

    func selectNodesForMarquee(_ ids: Set<String>) {
        guard selectedConnectionId != nil || selectedNodeIds != ids else { return }
        if ids.isEmpty {
            clearSelectionToFlat(recordUndo: false)
            return
        }
        selectedConnectionId = nil
        selectedNodeIds = ids
        selectedNodeId = ids.sorted().last
    }

    func clearSelectionToFlat(recordUndo: Bool = true) {
        selectedConnectionId = nil
        selectedNodeId = nil
        selectedNodeIds = []
        _ = recordUndo
        previewReference = GraphOutputReference(node: "", output: "")
        setMaskBrushEnabled(false)
        setFlatPreview(status: document.nodes.isEmpty ? "empty graph" : "no selection")
    }

    func setPreviewAsGraphOutput() {
        guard !previewReference.node.isEmpty,
              document.node(id: previewReference.node) != nil else { return }
        if document.sink == previewReference.node &&
            document.sinkOutput == previewReference.output { return }
        pushUndo()
        document.setSink(nodeId: previewReference.node,
                         output: previewReference.output)
        if !activeOutputSupportsMesh { exportSettings.exportMesh = false }
        documentCanSave = true
        markDirty()
        refreshDiagnostics()
    }

    func selectConnection(_ id: String?) {
        selectedConnectionId = id
        selectedNodeId = nil
        selectedNodeIds = []
    }

    func moveNode(id: String, by delta: CGSize) {
        let p = position(for: id)
        document.setPosition(nodeId: id,
                             x: max(0, p.x + delta.width),
                             y: max(0, p.y + delta.height))
        markDirty()
    }

    func moveNode(id: String, to position: GraphNodePosition) {
        document.setPosition(nodeId: id,
                             x: max(0, position.x),
                             y: max(0, position.y))
        markDirty()
    }

    func moveNodes(to positions: [String: GraphNodePosition]) {
        if !isRestoringHistory && !isInteractiveMove { pushUndo() }
        for (id, position) in positions {
            document.setPosition(nodeId: id,
                                 x: max(0, position.x),
                                 y: max(0, position.y))
        }
        markDirty()
    }

    func dragSelection(for id: String) -> Set<String> {
        selectedNodeIds.contains(id) ? selectedNodeIds : [id]
    }

    func beginInteractiveMove() {
        guard !isInteractiveMove else { return }
        pushUndo()
        isInteractiveMove = true
    }

    func endInteractiveMove() {
        isInteractiveMove = false
    }

    func addNode(type: String, at position: GraphNodePosition? = nil) {
        pushUndo()
        recordRecentNodeType(type)
        let previous = selectedNodeId ?? (document.sink.isEmpty ? nil : document.sink)
        let id = document.addNode(type: type, after: previous, at: position)
        if type == "rivercarve",
           let previous,
           document.node(id: previous)?.type == "river",
           let terrain = document.upstreamNodeId(to: previous, input: 0) {
            document.connect(from: terrain, to: id, input: 0)
            document.connect(from: previous, to: id, input: 1)
        } else if let previous,
                  document.node(id: previous) != nil,
                  document.inputCount(for: type) > 0 {
            document.connect(from: previous, to: id, input: 0)
        }
        previewReference = GraphOutputReference(
            node: id, output: GraphDocument.defaultOutputName(for: type))
        selectedNodeId = id
        selectedNodeIds = [id]
        selectedConnectionId = nil
        syncPreviewWithDocument(markDirty: true)
        reloadInspector()
    }

    func addQuickStart(kind: String) {
        pushUndo()

        let selected: String
        let createdTypes: [String]
        switch kind {
        case "ridged":
            selected = document.addNode(type: "ridged",
                                        at: GraphNodePosition(x: 120, y: 120))
            createdTypes = ["ridged"]
        case "terrace":
            let perlin = document.addNode(type: "perlin",
                                          at: GraphNodePosition(x: 80, y: 120))
            let terrace = document.addNode(type: "terrace",
                                           at: GraphNodePosition(x: 300, y: 120))
            document.connect(from: perlin, to: terrace, input: 0)
            selected = terrace
            createdTypes = ["perlin", "terrace"]
        case "river":
            let perlin = document.addNode(type: "perlin",
                                          at: GraphNodePosition(x: 80, y: 120))
            let river = document.addNode(type: "river",
                                         at: GraphNodePosition(x: 300, y: 168))
            let carve = document.addNode(type: "rivercarve",
                                         at: GraphNodePosition(x: 520, y: 120))
            document.connect(from: perlin, to: river, input: 0)
            document.connect(from: perlin, to: carve, input: 0)
            document.connect(from: river, to: carve, input: 1)
            selected = carve
            createdTypes = ["perlin", "river", "rivercarve"]
        default:
            selected = document.addNode(type: "perlin",
                                        at: GraphNodePosition(x: 120, y: 120))
            createdTypes = ["perlin"]
        }

        createdTypes.forEach(recordRecentNodeType)
        document.setSink(nodeId: selected)
        selectedNodeId = selected
        selectedNodeIds = [selected]
        selectedConnectionId = nil
        syncPreviewWithDocument(markDirty: true)
        reloadInspector()
    }

    private func recordRecentNodeType(_ type: String) {
        recentNodeTypes.removeAll { $0 == type }
        recentNodeTypes.insert(type, at: 0)
        if recentNodeTypes.count > 6 {
            recentNodeTypes.removeLast(recentNodeTypes.count - 6)
        }
    }

    func deleteSelection() {
        if let edgeId = selectedConnectionId,
           let edge = document.connections.first(where: { $0.id == edgeId }) {
            setMaskBrushEnabled(false)
            pushUndo()
            document.disconnect(edge)
            selectedConnectionId = nil
            syncPreviewWithDocument(markDirty: true)
            return
        }
        let ids = selectedNodeIds.isEmpty
            ? (selectedNodeId.map { Set([$0]) } ?? [])
            : selectedNodeIds
        guard !ids.isEmpty else { return }
        let fallback = fallbackSelectionAfterDeleting(ids: ids)
        setMaskBrushEnabled(false)
        pushUndo()
        document.deleteNodes(ids: ids)
        selectedNodeId = fallback
        selectedNodeIds = selectedNodeId.map { Set([$0]) } ?? []
        if let selectedNodeId, let node = document.node(id: selectedNodeId) {
            previewReference = GraphOutputReference(
                node: selectedNodeId,
                output: GraphDocument.defaultOutputName(for: node.type))
        } else {
            previewReference = GraphOutputReference(node: document.sink,
                                                    output: document.sinkOutput)
        }
        syncPreviewWithDocument(markDirty: true)
        reloadInspector()
    }

    func duplicateSelection() {
        let ids = selectedNodeIds.isEmpty
            ? (selectedNodeId.map { Set([$0]) } ?? [])
            : selectedNodeIds
        guard !ids.isEmpty else { return }
        pushUndo()
        let duplicated = document.duplicateNodes(ids: ids)
        guard !duplicated.isEmpty else { return }
        selectedNodeId = duplicated.last
        selectedNodeIds = Set(duplicated)
        selectedConnectionId = nil
        if let selectedNodeId, let node = document.node(id: selectedNodeId) {
            previewReference = GraphOutputReference(
                node: selectedNodeId,
                output: GraphDocument.defaultOutputName(for: node.type))
        }
        syncPreviewWithDocument(markDirty: true)
        reloadInspector()
    }

    func selectUpstreamOfSelection() {
        guard let id = selectedNodeId,
              let edge = document.connections
                .filter({ $0.to == id })
                .sorted(by: { $0.input < $1.input })
                .first else { return }
        selectNode(edge.from)
    }

    func selectDownstreamOfSelection() {
        guard let id = selectedNodeId,
              let edge = document.connections
                .filter({ $0.from == id })
                .sorted(by: { $0.to < $1.to })
                .first else { return }
        selectNode(edge.to)
    }

    func selectDiagnosticIssue(_ issue: GraphDiagnosticIssue) {
        if let node = issue.node, document.node(id: node) != nil {
            selectNode(node)
        } else if let edgeId = issue.edge {
            selectConnection(edgeId)
        }
    }

    func diagnosticSeverity(for nodeId: String) -> String? {
        diagnostics.issueSeverity(for: nodeId)
    }

    func missingDiagnosticInputs(for nodeId: String) -> Set<UInt32> {
        diagnostics.missingInputs(for: nodeId)
    }

    private func fallbackSelectionAfterDeleting(ids: Set<String>) -> String? {
        let primary = selectedNodeId.flatMap { ids.contains($0) ? $0 : nil }
        if let primary,
           let upstream = document.connections
               .filter({ $0.to == primary && !ids.contains($0.from) })
               .sorted(by: { $0.input < $1.input })
               .first?.from,
           document.node(id: upstream) != nil {
            return upstream
        }

        if let upstream = document.connections
            .filter({ ids.contains($0.to) && !ids.contains($0.from) })
            .sorted(by: { $0.input < $1.input })
            .first?.from,
           document.node(id: upstream) != nil {
            return upstream
        }

        if let firstDeletedIndex = document.nodes.firstIndex(where: { ids.contains($0.id) }) {
            let before = document.nodes[..<firstDeletedIndex].last { !ids.contains($0.id) }
            if let before { return before.id }
        }

        return document.nodes.first { !ids.contains($0.id) }?.id
    }

    func connect(from: String, output: String, to: String, input: UInt32) {
        guard from != to, document.node(id: from) != nil,
              let target = document.node(id: to),
              input < document.inputCount(for: target.type) else { return }
        setMaskBrushEnabled(false)
        pushUndo()
        if target.type == "rivercarve",
           input == 0,
           document.node(id: from)?.type == "river",
           let terrain = document.upstreamNodeId(to: from, input: 0) {
            document.connect(from: terrain, to: to, input: 0)
            document.connect(from: from, output: output, to: to, input: 1)
        } else {
            document.connect(from: from, output: output, to: to, input: input)
            document.repairRiverCarveConnections()
        }
        previewReference = GraphOutputReference(
            node: to, output: GraphDocument.defaultOutputName(for: target.type))
        selectedNodeId = to
        selectedNodeIds = [to]
        selectedConnectionId = nil
        syncPreviewWithDocument(markDirty: true)
    }

    func disconnect(_ edge: GraphDocumentConnection) {
        setMaskBrushEnabled(false)
        pushUndo()
        document.disconnect(edge)
        selectedConnectionId = nil
        syncPreviewWithDocument(markDirty: true)
    }

    func setSink(_ id: String) {
        guard document.node(id: id) != nil else { return }
        pushUndo()
        document.setSink(nodeId: id)
        syncPreviewWithDocument(markDirty: true)
    }

    func resetLayout() {
        pushUndo()
        document.ui?.positions.removeAll()
        document.ensureLayout()
        markDirty()
    }

    @discardableResult
    func save(to path: String? = nil) -> Bool {
        if let path {
            graphPath = path
            engine.setGraphPath(path)
        }
        guard let graphPath else {
            saveStatus = "choose a file"
            return false
        }
        do {
            let text = try document.encodedString()
            if document.sink.isEmpty {
                guard engine.loadJSONText(text) else {
                    isDirty = true
                    saveStatus = "save blocked: \(engine.lastError())"
                    setFlatPreview(status: "no output")
                    return false
                }
                setFlatPreview(status: document.nodes.isEmpty ? "empty graph" : "no output")
                try text.write(toFile: graphPath, atomically: true, encoding: .utf8)
                cleanDocumentFingerprint = text
                isDirty = false
                saveStatus = "saved"
                lastSavedAt = Date()
                return true
            }
            guard engine.loadJSONText(text) else {
                isDirty = true
                saveStatus = "save blocked: \(engine.lastError())"
                setFlatPreview(status: "invalid graph")
                return false
            }
            guard refreshTerrainSynchronously() else {
                isDirty = true
                saveStatus = "save blocked: \(engine.lastError())"
                setFlatPreview(status: "invalid graph")
                return false
            }
            try text.write(toFile: graphPath, atomically: true, encoding: .utf8)
            cleanDocumentFingerprint = text
            isDirty = false
            saveStatus = "saved"
            lastSavedAt = Date()
            return true
        } catch {
            saveStatus = "save failed: \(error.localizedDescription)"
            return false
        }
    }

    func load(from path: String) {
        do {
            var loaded = try GraphDocument.load(path: path)
            loaded.ensureLayout()
            document = loaded
            history.clear()
            loadPreviewSettingsFromDocument()
            selectedNodeId = document.sink.isEmpty ? document.nodes.last?.id : document.sink
            selectedNodeIds = selectedNodeId.map { Set([$0]) } ?? []
            previewReference = GraphOutputReference(node: document.sink,
                                                    output: document.sinkOutput)
            selectedConnectionId = nil
            graphPath = path
            engine.setGraphPath(path)
            exportSettings.basename = URL(fileURLWithPath: path)
                .deletingPathExtension()
                .lastPathComponent
            cleanDocumentFingerprint = try? document.encodedString()
            isDirty = false
            saveStatus = "loaded"
            lastSavedAt = Self.fileModifiedDate(path: path)
            reloadInspector()
            syncPreviewWithDocument(markDirty: false)
        } catch {
            saveStatus = "load failed: \(error.localizedDescription)"
        }
    }

    func autosave() {
        guard isDirty, documentCanSave, let graphPath else { return }
        do {
            let text = try document.encodedString()
            try text.write(toFile: graphPath, atomically: true, encoding: .utf8)
            cleanDocumentFingerprint = text
            isDirty = false
            saveStatus = "autosaved"
            lastSavedAt = Date()
        } catch {
            saveStatus = "autosave failed: \(error.localizedDescription)"
        }
    }

    func undo() {
        endMaterialColorGesture()
        guard let previous = history.undo(current: document) else { return }
        restore(previous, status: "undo")
    }

    func redo() {
        endMaterialColorGesture()
        guard let next = history.redo(current: document) else { return }
        restore(next, status: "redo")
    }

    private func pushUndo() {
        guard !isRestoringHistory else { return }
        endMaterialColorGesture()
        history.record(document)
    }

    private func restore(_ snapshot: GraphDocument, status: String) {
        isRestoringHistory = true
        defer { isRestoringHistory = false }
        endMaterialColorGesture()
        let previousPreview = previewReference
        let previousSelectedNodeId = selectedNodeId
        let previousSelectedNodeIds = selectedNodeIds
        let previousTransientMode = transientDisplayMode
        document = snapshot
        document.ensureLayout()
        loadPreviewSettingsFromDocument()
        let previewSurvives = document.node(id: previousPreview.node) != nil &&
            document.outputPorts(nodeId: previousPreview.node).contains(where: {
                $0.name == previousPreview.output
            })
        if previewSurvives {
            previewReference = previousPreview
            transientDisplayMode = previousTransientMode
        } else {
            previewReference = GraphOutputReference(node: document.sink,
                                                    output: document.sinkOutput)
        }
        selectedNodeIds = Set(previousSelectedNodeIds.filter {
            document.node(id: $0) != nil
        })
        if let previousSelectedNodeId,
           document.node(id: previousSelectedNodeId) != nil {
            selectedNodeId = previousSelectedNodeId
            selectedNodeIds.insert(previousSelectedNodeId)
        } else {
            selectedNodeId = selectedNodeIds.sorted().last ??
                (document.sink.isEmpty ? document.nodes.last?.id : document.sink)
            if let selectedNodeId { selectedNodeIds.insert(selectedNodeId) }
        }
        selectedConnectionId = nil
        reloadInspector()
        syncPreviewWithDocument(markDirty: true)
        markDirty(forceReconcile: true)
        saveStatus = status
    }

    private func syncPreviewWithDocument(markDirty shouldMarkDirty: Bool) {
        refreshDiagnostics()
        do {
            let text = try document.encodedString()
            if document.sink.isEmpty {
                if engine.loadJSONText(text) {
                    documentCanSave = true
                    if shouldMarkDirty { markDirty() }
                    setFlatPreview(status: document.nodes.isEmpty ? "empty graph" : "no output")
                } else {
                    documentCanSave = false
                    if shouldMarkDirty {
                        isDirty = true
                        saveStatus = "preview flat: \(engine.lastError())"
                    }
                    setFlatPreview(status: "invalid graph")
                }
                return
            }
            if engine.loadJSONText(text) {
                documentCanSave = true
                if shouldMarkDirty { markDirty() }
                if !refreshTerrain() {
                    documentCanSave = false
                    if shouldMarkDirty {
                        saveStatus = "preview flat: \(engine.lastError())"
                    }
                    setFlatPreview(status: "invalid graph")
                }
            } else {
                documentCanSave = false
                if shouldMarkDirty {
                    isDirty = true
                    saveStatus = "preview flat: \(engine.lastError())"
                }
                setFlatPreview(status: "invalid graph")
            }
        } catch {
            documentCanSave = false
            if shouldMarkDirty {
                isDirty = true
                saveStatus = "preview flat: \(error.localizedDescription)"
            }
            setFlatPreview(status: "invalid graph")
        }
    }

    private func loadPreviewSettingsFromDocument() {
        let preview = document.ui?.preview ?? GraphPreviewSettings()
        transientDisplayMode = nil
        displayMode = preview.displayMode
        materialPreset = preview.materialPreset
        maskOpacity = preview.maskOpacity
    }

    private func persistPreviewSettings() {
        document.setPreviewSettings(GraphPreviewSettings(
            displayMode: displayMode,
            materialPreset: materialPreset,
            maskOpacity: maskOpacity))
        documentCanSave = true
        markDirty(forceReconcile: true)
    }

    private func effectiveDisplayMode(for reference: GraphOutputReference) -> ViewportDisplayMode {
        let requestedMode = transientDisplayMode ?? displayMode
        guard requestedMode == .auto else { return requestedMode }
        switch document.resolvedOutputKind(nodeId: reference.node,
                                           output: reference.output) {
        case .mask: return .mask
        case .data: return .data
        default: return .terrain
        }
    }

    private func editableMaskReference() -> GraphOutputReference? {
        let reference = activeOutputReference
        guard !reference.node.isEmpty,
              currentScalarPreviewReference == reference,
              document.resolvedOutputKind(nodeId: reference.node,
                                          output: reference.output) == .mask,
              document.isOutputEvaluable(reference) else {
            return nil
        }
        return reference
    }

    private func queueMaskEraseStroke(at uv: CGPoint) {
        queueMaskEraseStrokes(at: [uv])
    }

    private func queueMaskEraseStrokes(at points: [CGPoint]) {
        guard !points.isEmpty else { return }
        let strokes = points.map { uv in GraphMaskEraseStroke(
            x: min(max(Double(uv.x), 0), 1),
            y: min(max(Double(uv.y), 0), 1),
            radius: min(max(maskBrushRadius, 0.003), 0.20),
            strength: 1.0)
        }
        pendingMaskEraseStrokes.append(contentsOf: strokes)
        renderer.applyMaskEraseStrokes(strokes)
    }

    private func applyMaskEraseStrokesToCachedPreview(
        _ strokes: [GraphMaskEraseStroke]
    ) {
        guard !strokes.isEmpty,
              currentPreviewWidth > 0,
              currentPreviewHeight > 0,
              currentPreviewData.count >= currentPreviewWidth * currentPreviewHeight else {
            return
        }
        _ = currentPreviewData.withUnsafeMutableBufferPointer {
            MaskBrushRasterizer.apply(strokes: strokes, to: $0,
                                      width: currentPreviewWidth,
                                      height: currentPreviewHeight)
        }
    }

    private func renderCachedPreview() {
        guard currentPreviewWidth > 1,
              currentPreviewHeight > 1,
              !currentPreviewGeometry.isEmpty,
              !currentPreviewData.isEmpty else { return }
        renderer.setPreview(heights: currentPreviewGeometry, data: currentPreviewData,
                            weightsRGBA: currentPreviewWeights,
                            width: currentPreviewWidth, height: currentPreviewHeight,
                            dataMatchesHeights: currentPreviewDataMatchesGeometry)
    }

    private func restoreCachedMaterialPreview(signature: String,
                                              colors: [[Double]]) -> Bool {
        guard let cached = cachedMaterialPreview,
              cached.signature == signature else { return false }
        previewWorker.cancelPending()
        renderer.setMaterialColors(colors)
        if residentMaterialSignature == signature {
            applyViewportSettings(displayMode: .material)
            lastStats = "material resident · nodes \(cached.evaluated), reused \(cached.reused)"
            return true
        }
        currentPreviewGeometry = cached.geometry
        currentPreviewData = cached.geometry
        currentScalarPreviewReference = nil
        currentPreviewDataMatchesGeometry = true
        currentPreviewWeights = cached.weightsRGBA
        currentPreviewWidth = cached.width
        currentPreviewHeight = cached.height
        renderCachedPreview()
        residentMaterialSignature = signature
        applyViewportSettings(displayMode: .material)
        lastStats = "material cached · nodes \(cached.evaluated), reused \(cached.reused)"
        return true
    }

    /// Stable snapshot of only state that can affect terrain or material weights.
    /// Names, preview colors, sink selection, layout, and display settings are
    /// deliberately normalized so authoring-only edits never schedule graph work.
    private func materialEvaluationSignature() throws -> String {
        var snapshot = document
        snapshot.sink = ""
        snapshot.sinkOutput = ""
        if var stack = snapshot.materialStack {
            for index in stack.layers.indices {
                stack.layers[index].name = "Layer \(index + 1)"
                stack.layers[index].previewColorSRGB = [0, 0, 0]
            }
            snapshot.materialStack = stack
        }
        if var ui = snapshot.ui {
            ui.positions = [:]
            ui.preview = GraphPreviewSettings()
            snapshot.ui = ui
        }
        return "preview-size=\(size)\n" + (try snapshot.encodedString())
    }

    func previewWorkerActivity() -> TerrainPreviewWorkerActivity {
        previewWorker.activitySnapshot()
    }

    private func inputNodeId(to nodeId: String, input: UInt32) -> String? {
        document.connections.last { $0.to == nodeId && $0.input == input }?.from
    }

    private func scheduleMaterialColorGestureEnd(for layer: Int) {
        materialColorGestureTask?.cancel()
        materialColorGestureTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 450_000_000)
            } catch {
                return
            }
            guard let self, self.materialColorGestureLayer == layer else { return }
            self.materialColorGestureLayer = nil
            self.materialColorGestureTask = nil
        }
    }

    private func endMaterialColorGesture() {
        materialColorGestureTask?.cancel()
        materialColorGestureTask = nil
        materialColorGestureLayer = nil
    }

    private func markDirty(forceReconcile: Bool = false) {
        if isDirty && !forceReconcile {
            saveStatus = "unsaved"
            return
        }
        let fingerprint = try? document.encodedString()
        isDirty = fingerprint == nil || fingerprint != cleanDocumentFingerprint
        saveStatus = isDirty ? "unsaved" : "saved"
    }

    private static func fileModifiedDate(path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }
}
