import CoreGraphics
import Foundation
import ImageIO
import Metal
import MetalKit
import UniformTypeIdentifiers
import simd

struct Uniforms {
    var mvp: float4x4
    var lightDirection: SIMD4<Float>
    var viewportParams: SIMD4<Float>
    var terrainParams: SIMD4<Float>
    var brushParams: SIMD4<Float>
    var gridParams: SIMD4<UInt32>
}

struct LineVertex {
    var position: SIMD3<Float>
    var color: SIMD4<Float>
}

// Renders a heightfield as a lit, displaced triangle grid. Shared by the live
// MTKView path and the offscreen --shot path.
final class Renderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let colorFormat: MTLPixelFormat
    let depthFormat: MTLPixelFormat = .depth32Float
    var displayInvalidationHandler: (() -> Void)?

    private var pipeline: MTLRenderPipelineState
    private var linePipeline: MTLRenderPipelineState
    private var depthState: MTLDepthStencilState
    private var lineDepthState: MTLDepthStencilState

    private var heightBuffer: MTLBuffer?
    private var dataBuffer: MTLBuffer?
    private var indexBuffer: MTLBuffer?
    private var gridLineBuffer: MTLBuffer?
    private var axisLineBuffer: MTLBuffer?
    private var indexCount = 0
    private var gridLineVertexCount = 0
    private var axisLineVertexCount = 0
    private(set) var gridW: UInt32 = 0
    private(set) var gridH: UInt32 = 0
    private let maxViewerGrid = 768

    var camera = OrbitCamera.framed(heightExaggeration: 0.5)
    var heightExaggeration: Float = 0.5
    private var lightAzimuthDegrees: Float = 35.0
    private var lightElevationDegrees: Float = 58.0
    private var displayMode: ViewportDisplayMode = .terrain
    private var materialPreset: MaterialPreset = .natural
    private(set) var previewUploadCount: UInt64 = 0
    private var maskOpacity: Float = 0.65
    private var terrainBaseHeight: Float = 0
    private var surfaceHeights: [Float] = []
    private var surfaceWidth = 0
    private var surfaceHeight = 0
    private var surfaceMaxHeight: Float = 0
    private var brushCenterUV = SIMD2<Float>(repeating: 0)
    private var brushRadius: Float = 0
    private var brushVisible = false
    private var projectionMode: ViewportProjection = .perspective
    var wireframeEnabled = false
    var gridVisible = true
    var axisVisible = true
    var clear = MTLClearColor(red: 0.09, green: 0.11, blue: 0.14, alpha: 1.0)

    init?(device: MTLDevice, colorFormat: MTLPixelFormat) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        self.colorFormat = colorFormat
        do {
            let lib = try device.makeLibrary(source: terrainShaderSource, options: nil)
            guard let vfn = lib.makeFunction(name: "terrain_vertex"),
                  let ffn = lib.makeFunction(name: "terrain_fragment"),
                  let lvn = lib.makeFunction(name: "line_vertex"),
                  let lfn = lib.makeFunction(name: "line_fragment") else { return nil }
            let pd = MTLRenderPipelineDescriptor()
            pd.vertexFunction = vfn
            pd.fragmentFunction = ffn
            pd.colorAttachments[0].pixelFormat = colorFormat
            pd.depthAttachmentPixelFormat = depthFormat
            pipeline = try device.makeRenderPipelineState(descriptor: pd)

            let lpd = MTLRenderPipelineDescriptor()
            lpd.vertexFunction = lvn
            lpd.fragmentFunction = lfn
            lpd.colorAttachments[0].pixelFormat = colorFormat
            lpd.depthAttachmentPixelFormat = depthFormat
            lpd.colorAttachments[0].isBlendingEnabled = true
            lpd.colorAttachments[0].rgbBlendOperation = .add
            lpd.colorAttachments[0].alphaBlendOperation = .add
            lpd.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            lpd.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            lpd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            lpd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            linePipeline = try device.makeRenderPipelineState(descriptor: lpd)
        } catch {
            FileHandle.standardError.write(Data("shader build failed: \(error)\n".utf8))
            return nil
        }
        let dd = MTLDepthStencilDescriptor()
        dd.depthCompareFunction = .less
        dd.isDepthWriteEnabled = true
        guard let ds = device.makeDepthStencilState(descriptor: dd) else { return nil }
        depthState = ds

        let ldd = MTLDepthStencilDescriptor()
        ldd.depthCompareFunction = .lessEqual
        ldd.isDepthWriteEnabled = false
        guard let lds = device.makeDepthStencilState(descriptor: ldd) else { return nil }
        lineDepthState = lds
        buildViewportGuides()
    }

    func setHeights(_ heights: [Float], width: Int, height: Int) {
        setPreview(heights: heights, data: heights, width: width, height: height,
                   dataMatchesHeights: true)
    }

    func setPreview(heights: [Float], data: [Float],
                    width: Int, height: Int, dataMatchesHeights: Bool = false) {
        guard width > 1, height > 1, heights.count >= width * height else { return }
        previewUploadCount &+= 1
        let sampledHeights = Self.viewerHeights(heights, width: width, height: height,
                                                maxGrid: maxViewerGrid)
        let sampledData: (values: [Float], width: Int, height: Int)
        if dataMatchesHeights {
            sampledData = sampledHeights
        } else {
            let sourceData = data.count >= width * height ? data : heights
            sampledData = Self.viewerHeights(sourceData, width: width, height: height,
                                             maxGrid: maxViewerGrid)
        }
        terrainBaseHeight = sampledHeights.values.min() ?? 0
        surfaceHeights = sampledHeights.values
        surfaceWidth = sampledHeights.width
        surfaceHeight = sampledHeights.height
        surfaceMaxHeight = sampledHeights.values.max() ?? terrainBaseHeight
        heightBuffer = device.makeBuffer(bytes: sampledHeights.values,
                                         length: sampledHeights.values.count *
                                            MemoryLayout<Float>.stride,
                                         options: .storageModeShared)
        if dataMatchesHeights {
            dataBuffer = heightBuffer
        } else {
            dataBuffer = device.makeBuffer(bytes: sampledData.values,
                                           length: sampledData.values.count *
                                                MemoryLayout<Float>.stride,
                                           options: .storageModeShared)
        }
        if gridW != UInt32(sampledHeights.width) || gridH != UInt32(sampledHeights.height) ||
            indexBuffer == nil {
            buildIndices(width: sampledHeights.width, height: sampledHeights.height)
            gridW = UInt32(sampledHeights.width)
            gridH = UInt32(sampledHeights.height)
        }
        invalidateDisplay()
    }

    private static func viewerHeights(_ heights: [Float], width: Int, height: Int,
                                      maxGrid: Int) -> (values: [Float], width: Int, height: Int) {
        guard max(width, height) > maxGrid else {
            return (heights, width, height)
        }

        let scale = Double(maxGrid) / Double(max(width, height))
        let outW = max(2, Int((Double(width) * scale).rounded()))
        let outH = max(2, Int((Double(height) * scale).rounded()))
        let xScale = Double(width - 1) / Double(outW - 1)
        let yScale = Double(height - 1) / Double(outH - 1)
        var out = [Float](repeating: 0, count: outW * outH)
        for y in 0..<outH {
            let sy = min(height - 1, Int((Double(y) * yScale).rounded()))
            for x in 0..<outW {
                let sx = min(width - 1, Int((Double(x) * xScale).rounded()))
                out[y * outW + x] = heights[sy * width + sx]
            }
        }
        return (out, outW, outH)
    }

    private func buildIndices(width: Int, height: Int) {
        var idx = [UInt32]()
        idx.reserveCapacity((width - 1) * (height - 1) * 6)
        for z in 0..<(height - 1) {
            for x in 0..<(width - 1) {
                let i = UInt32(z * width + x)
                let r = i + 1
                let d = UInt32((z + 1) * width + x)
                let dr = d + 1
                idx.append(contentsOf: [i, d, r, r, d, dr])
            }
        }
        indexBuffer = device.makeBuffer(bytes: idx,
                                        length: idx.count * MemoryLayout<UInt32>.stride,
                                        options: .storageModeShared)
        indexCount = idx.count
    }

    private func buildViewportGuides() {
        var grid = [LineVertex]()
        let extent: Float = 3.0
        let minorStep: Float = 0.1
        let majorEvery = 5
        let count = Int((extent * 2 / minorStep).rounded())
        for i in 0...count {
            let v = -extent + Float(i) * minorStep
            let major = i % majorEvery == 0
            let alpha: Float = major ? 0.34 : 0.18
            let c = SIMD4<Float>(0.58, 0.62, 0.66, alpha)
            let y: Float = 0.0
            grid.append(LineVertex(position: SIMD3<Float>(-extent, y, v), color: c))
            grid.append(LineVertex(position: SIMD3<Float>(extent, y, v), color: c))
            grid.append(LineVertex(position: SIMD3<Float>(v, y, -extent), color: c))
            grid.append(LineVertex(position: SIMD3<Float>(v, y, extent), color: c))
        }
        gridLineBuffer = device.makeBuffer(bytes: grid,
                                           length: grid.count * MemoryLayout<LineVertex>.stride,
                                           options: .storageModeShared)
        gridLineVertexCount = grid.count

        let axisExtent: Float = 3.25
        let groundY: Float = 0.0
        let red = SIMD4<Float>(1.0, 0.17, 0.30, 0.92)
        let green = SIMD4<Float>(0.47, 0.90, 0.12, 0.92)
        let blue = SIMD4<Float>(0.06, 0.52, 1.0, 0.92)
        let axis: [LineVertex] = [
            LineVertex(position: SIMD3<Float>(-axisExtent, groundY, 0), color: red),
            LineVertex(position: SIMD3<Float>(axisExtent, groundY, 0), color: red),
            LineVertex(position: SIMD3<Float>(0, groundY, -axisExtent), color: green),
            LineVertex(position: SIMD3<Float>(0, groundY, axisExtent), color: green),
            LineVertex(position: SIMD3<Float>(0, 0, 0), color: blue),
            LineVertex(position: SIMD3<Float>(0, 1.4, 0), color: blue)
        ]
        axisLineBuffer = device.makeBuffer(bytes: axis,
                                           length: axis.count * MemoryLayout<LineVertex>.stride,
                                           options: .storageModeShared)
        axisLineVertexCount = axis.count
    }

    func encode(commandBuffer: MTLCommandBuffer, passDescriptor: MTLRenderPassDescriptor,
                viewportSize: CGSize) {
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return
        }
        let aspect = Float(viewportSize.width / max(1, viewportSize.height))
        var u = Uniforms(mvp: camera.viewProjection(aspect: aspect,
                                                    projection: projectionMode),
                         lightDirection: lightDirection(),
                         viewportParams: SIMD4<Float>(
                            heightExaggeration,
                            min(max(maskOpacity, 0), 1),
                            Float(displayMode.rendererMode),
                            Float(materialPreset.rendererPreset)),
                         terrainParams: SIMD4<Float>(terrainBaseHeight, 0, 0, 0),
                         brushParams: SIMD4<Float>(brushCenterUV.x, brushCenterUV.y,
                                                   brushRadius, brushVisible ? 1 : 0),
                         gridParams: SIMD4<UInt32>(gridW, gridH, 0, 0))
        if let hb = heightBuffer, let db = dataBuffer, let ib = indexBuffer,
           indexCount > 0 {
            enc.setRenderPipelineState(pipeline)
            enc.setDepthStencilState(depthState)
            enc.setFrontFacing(.counterClockwise)
            enc.setCullMode(.back)
            enc.setTriangleFillMode(wireframeEnabled ? .lines : .fill)
            enc.setVertexBuffer(hb, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.setVertexBuffer(db, offset: 0, index: 2)
            enc.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: indexCount,
                                      indexType: .uint32, indexBuffer: ib,
                                      indexBufferOffset: 0)
        }
        drawViewportGuides(encoder: enc, uniforms: &u)
        enc.endEncoding()
    }

    private func drawViewportGuides(encoder enc: MTLRenderCommandEncoder,
                                    uniforms: inout Uniforms) {
        guard gridVisible || axisVisible else { return }
        enc.setRenderPipelineState(linePipeline)
        enc.setDepthStencilState(lineDepthState)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        if gridVisible, let gridLineBuffer, gridLineVertexCount > 0 {
            enc.setVertexBuffer(gridLineBuffer, offset: 0, index: 0)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: gridLineVertexCount)
        }
        if axisVisible, let axisLineBuffer, axisLineVertexCount > 0 {
            enc.setVertexBuffer(axisLineBuffer, offset: 0, index: 0)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: axisLineVertexCount)
        }
    }

    func applyViewportSettings(lightAzimuthDegrees: Double,
                               lightElevationDegrees: Double,
                               wireframeEnabled: Bool,
                               displayMode: ViewportDisplayMode,
                               materialPreset: MaterialPreset,
                               maskOpacity: Double,
                               gridVisible: Bool,
                               axisVisible: Bool,
                               projectionMode: ViewportProjection) {
        self.lightAzimuthDegrees = Float(lightAzimuthDegrees)
        self.lightElevationDegrees = Float(lightElevationDegrees)
        self.wireframeEnabled = wireframeEnabled
        self.displayMode = displayMode == .auto ? .terrain : displayMode
        self.materialPreset = materialPreset
        self.maskOpacity = Float(maskOpacity)
        self.gridVisible = gridVisible
        self.axisVisible = axisVisible
        self.projectionMode = projectionMode
        invalidateDisplay()
    }

    func resetCamera() {
        camera.reset(heightExaggeration: heightExaggeration)
        invalidateDisplay()
    }

    func setCameraPreset(_ preset: CameraPreset) {
        camera.applyPreset(preset, heightExaggeration: heightExaggeration)
        invalidateDisplay()
    }

    func orbitCamera(delta: CGSize) {
        camera.azimuth -= Float(delta.width) * 0.01
        let el = camera.elevation - Float(delta.height) * 0.01
        camera.elevation = max(0.05, min(.pi / 2 - 0.02, el))
        invalidateDisplay()
    }

    func panCamera(delta: CGSize, viewportSize: CGSize) {
        camera.pan(deltaX: Float(delta.width),
                   deltaY: Float(delta.height),
                   viewportHeight: Float(max(1, viewportSize.height)))
        invalidateDisplay()
    }

    func zoomCamera(deltaY: CGFloat) {
        camera.zoom(deltaY: Float(deltaY))
        invalidateDisplay()
    }

    func terrainUV(at point: CGPoint, in viewSize: CGSize) -> CGPoint? {
        guard viewSize.width > 1, viewSize.height > 1 else { return nil }
        let aspect = Float(viewSize.width / max(1, viewSize.height))
        let ndcX = Float((point.x / viewSize.width) * 2.0 - 1.0)
        let ndcY = Float((point.y / viewSize.height) * 2.0 - 1.0)
        let inv = camera.viewProjection(aspect: aspect,
                                        projection: projectionMode).inverse
        var near = inv * SIMD4<Float>(ndcX, ndcY, 0, 1)
        var far = inv * SIMD4<Float>(ndcX, ndcY, 1, 1)
        guard abs(near.w) > 1e-6, abs(far.w) > 1e-6 else { return nil }
        near /= near.w
        far /= far.w
        let origin = SIMD3<Float>(near.x, near.y, near.z)
        let end = SIMD3<Float>(far.x, far.y, far.z)
        let dir = normalize(end - origin)
        guard abs(dir.y) > 1e-5 else { return nil }
        return TerrainSurfacePicker.intersect(origin: origin, direction: dir,
                                              heights: surfaceHeights,
                                              width: surfaceWidth,
                                              height: surfaceHeight,
                                              baseHeight: terrainBaseHeight,
                                              maxHeight: surfaceMaxHeight,
                                              heightScale: heightExaggeration)
    }

    func setMaskBrushCursor(uv: CGPoint?, radius: Double) {
        guard let uv else {
            guard brushVisible else { return }
            brushVisible = false
            invalidateDisplay()
            return
        }
        brushCenterUV = SIMD2<Float>(Float(min(max(uv.x, 0), 1)),
                                     Float(min(max(uv.y, 0), 1)))
        brushRadius = Float(min(max(radius, 0.003), 0.20))
        brushVisible = true
        invalidateDisplay()
    }

    func applyMaskEraseStroke(_ stroke: GraphMaskEraseStroke) {
        applyMaskEraseStrokes([stroke])
    }

    func applyMaskEraseStrokes(_ strokes: [GraphMaskEraseStroke]) {
        guard !strokes.isEmpty else { return }
        guard let dataBuffer else { return }
        let width = Int(gridW)
        let height = Int(gridH)
        let count = min(width * height,
                        dataBuffer.length / MemoryLayout<Float>.stride)
        guard width > 0, height > 0, count >= width * height else { return }
        let pointer = dataBuffer.contents().bindMemory(to: Float.self, capacity: count)
        let values = UnsafeMutableBufferPointer(start: pointer, count: count)
        MaskBrushRasterizer.apply(strokes: strokes, to: values,
                                  width: width, height: height)
        invalidateDisplay()
    }

    private func invalidateDisplay() {
        displayInvalidationHandler?()
    }

    private func lightDirection() -> SIMD4<Float> {
        let az = lightAzimuthDegrees * .pi / 180
        let el = lightElevationDegrees * .pi / 180
        let ce = cos(el)
        return SIMD4<Float>(sin(az) * ce, sin(el), cos(az) * ce, 0)
    }

    // Deterministic offscreen timing hook used by the viewer performance test.
    func benchmarkFrameTimes(width: Int, height: Int,
                             warmupFrames: Int = 3,
                             measuredFrames: Int = 10) -> [Double] {
        guard heightBuffer != nil, dataBuffer != nil,
              indexBuffer != nil, indexCount > 0,
              width > 0, height > 0, measuredFrames > 0 else { return [] }
        let cd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: colorFormat, width: width, height: height, mipmapped: false)
        cd.usage = [.renderTarget]
        cd.storageMode = .private
        let dd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: depthFormat, width: width, height: height, mipmapped: false)
        dd.usage = [.renderTarget]
        dd.storageMode = .private
        guard let color = device.makeTexture(descriptor: cd),
              let depth = device.makeTexture(descriptor: dd) else { return [] }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = color
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = clear
        rpd.colorAttachments[0].storeAction = .dontCare
        rpd.depthAttachment.texture = depth
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1.0
        rpd.depthAttachment.storeAction = .dontCare

        var times: [Double] = []
        for frame in 0..<(max(0, warmupFrames) + measuredFrames) {
            guard let cb = queue.makeCommandBuffer() else { return [] }
            let start = CFAbsoluteTimeGetCurrent()
            encode(commandBuffer: cb, passDescriptor: rpd,
                   viewportSize: CGSize(width: width, height: height))
            cb.commit()
            cb.waitUntilCompleted()
            if frame >= warmupFrames {
                times.append((CFAbsoluteTimeGetCurrent() - start) * 1_000)
            }
        }
        return times
    }

    // Offscreen render of a single frame to a PNG. No window required.
    func renderToPNG(path: String, width: Int, height: Int) -> Bool {
        guard heightBuffer != nil, dataBuffer != nil,
              indexBuffer != nil, indexCount > 0 else { return false }
        let cd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: colorFormat, width: width, height: height, mipmapped: false)
        cd.usage = [.renderTarget]
        cd.storageMode = .shared
        let dd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: depthFormat, width: width, height: height, mipmapped: false)
        dd.usage = [.renderTarget]
        dd.storageMode = .private
        guard let color = device.makeTexture(descriptor: cd),
              let depth = device.makeTexture(descriptor: dd),
              let cb = queue.makeCommandBuffer() else { return false }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = color
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.depthAttachment.texture = depth
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.clearDepth = 1.0
        rpd.depthAttachment.storeAction = .dontCare

        encode(commandBuffer: cb, passDescriptor: rpd,
               viewportSize: CGSize(width: width, height: height))
        cb.commit()
        cb.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        color.getBytes(&bytes, bytesPerRow: width * 4,
                       from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return Self.writeBGRAtoPNG(bytes, width: width, height: height, path: path)
    }

    static func writeBGRAtoPNG(_ bytes: [UInt8], width: Int, height: Int,
                               path: String) -> Bool {
        let cs = CGColorSpaceCreateDeviceRGB()
        // bgra8 in memory == byteOrder32Little + alphaFirst-skipped == RGB
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let img = CGImage(width: width, height: height, bitsPerComponent: 8,
                                bitsPerPixel: 32, bytesPerRow: width * 4, space: cs,
                                bitmapInfo: info, provider: provider, decode: nil,
                                shouldInterpolate: false, intent: .defaultIntent)
        else { return false }
        let url = URL(fileURLWithPath: path) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(
            url, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest)
    }
}
