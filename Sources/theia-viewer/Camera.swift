import simd

enum CameraPreset: String, CaseIterable, Identifiable {
    case iso
    case top
    case bottom
    case front
    case back
    case right
    case left

    var id: String { rawValue }
}

enum ViewportProjection: String, CaseIterable, Identifiable {
    case perspective
    case orthographic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .perspective:
            return "Perspective"
        case .orthographic:
            return "Orthographic"
        }
    }
}

// Right-handed perspective projection mapping depth to [0,1] (Metal convention),
// column-major (Metal-ready).
func perspectiveRH(fovy: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
    let y = 1 / tan(fovy * 0.5)
    let x = y / aspect
    let z = far / (near - far)
    return float4x4(
        SIMD4<Float>(x, 0, 0, 0),
        SIMD4<Float>(0, y, 0, 0),
        SIMD4<Float>(0, 0, z, -1),
        SIMD4<Float>(0, 0, z * near, 0))
}

func orthographicRH(left: Float, right: Float, bottom: Float, top: Float,
                    near: Float, far: Float) -> float4x4 {
    float4x4(
        SIMD4<Float>(2 / (right - left), 0, 0, 0),
        SIMD4<Float>(0, 2 / (top - bottom), 0, 0),
        SIMD4<Float>(0, 0, 1 / (near - far), 0),
        SIMD4<Float>(
            -(right + left) / (right - left),
            -(top + bottom) / (top - bottom),
            near / (near - far),
            1))
}

func lookAtRH(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
    let z = normalize(eye - center)
    let x = normalize(cross(up, z))
    let y = cross(z, x)
    return float4x4(
        SIMD4<Float>(x.x, y.x, z.x, 0),
        SIMD4<Float>(x.y, y.y, z.y, 0),
        SIMD4<Float>(x.z, y.z, z.z, 0),
        SIMD4<Float>(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1))
}

// Orbit camera: spherical position (azimuth/elevation/distance) around a target.
struct OrbitCamera {
    var target = SIMD3<Float>(0, 0.05, 0)
    var distance: Float = 2.8
    var azimuth: Float = .pi * 0.25
    var elevation: Float = .pi * 0.30
    var fovy: Float = 50 * .pi / 180

    static func framed(heightExaggeration: Float) -> OrbitCamera {
        var c = OrbitCamera()
        c.target = SIMD3<Float>(0, max(0.04, heightExaggeration * 0.35), 0)
        // Keep the full square visible while letting it occupy substantially
        // more of the viewport than the old, distant overview framing.
        c.distance = max(2.35, 2.05 + heightExaggeration * 0.8)
        c.azimuth = .pi * 0.25
        c.elevation = .pi * 0.28
        c.fovy = 50 * .pi / 180
        return c
    }

    mutating func reset(heightExaggeration: Float) {
        self = Self.framed(heightExaggeration: heightExaggeration)
    }

    func eye() -> SIMD3<Float> {
        let ce = cos(elevation), se = sin(elevation)
        let ca = cos(azimuth), sa = sin(azimuth)
        return target + distance * SIMD3<Float>(ce * sa, se, ce * ca)
    }

    func basis() -> (right: SIMD3<Float>, up: SIMD3<Float>, forward: SIMD3<Float>) {
        let forward = normalize(target - eye())
        let worldUp = SIMD3<Float>(0, 1, 0)
        let right = normalize(cross(forward, worldUp))
        let up = normalize(cross(right, forward))
        return (right, up, forward)
    }

    mutating func pan(deltaX: Float, deltaY: Float, viewportHeight: Float,
                      sensitivity: Float = 1.0) {
        let b = basis()
        let pixelsToWorld = 2.0 * distance * tan(fovy * 0.5) /
            max(1.0, viewportHeight) * sensitivity
        target += (-b.right * deltaX - b.up * deltaY) * pixelsToWorld
    }

    mutating func zoom(deltaY: Float) {
        distance = max(0.6, min(20, distance * (1 - deltaY * 0.01)))
    }

    mutating func applyPreset(_ preset: CameraPreset,
                              heightExaggeration: Float) {
        switch preset {
        case .iso:
            reset(heightExaggeration: heightExaggeration)
        case .top:
            target = SIMD3<Float>(0, max(0.04, heightExaggeration * 0.35), 0)
            distance = max(2.7, 2.3 + heightExaggeration * 1.1)
            azimuth = 0
            elevation = .pi / 2 - 0.035
        case .bottom:
            target = SIMD3<Float>(0, max(0.04, heightExaggeration * 0.35), 0)
            distance = max(2.7, 2.3 + heightExaggeration * 1.1)
            azimuth = 0
            elevation = -.pi / 2 + 0.035
        case .front:
            target = SIMD3<Float>(0, max(0.04, heightExaggeration * 0.35), 0)
            distance = max(3.0, 2.7 + heightExaggeration * 1.15)
            azimuth = 0
            elevation = 0.32
        case .back:
            target = SIMD3<Float>(0, max(0.04, heightExaggeration * 0.35), 0)
            distance = max(3.0, 2.7 + heightExaggeration * 1.15)
            azimuth = .pi
            elevation = 0.32
        case .right:
            target = SIMD3<Float>(0, max(0.04, heightExaggeration * 0.35), 0)
            distance = max(3.0, 2.7 + heightExaggeration * 1.15)
            azimuth = .pi / 2
            elevation = 0.32
        case .left:
            target = SIMD3<Float>(0, max(0.04, heightExaggeration * 0.35), 0)
            distance = max(3.0, 2.7 + heightExaggeration * 1.15)
            azimuth = -.pi / 2
            elevation = 0.32
        }
    }

    func viewProjection(aspect: Float,
                        projection: ViewportProjection = .perspective) -> float4x4 {
        let view = lookAtRH(eye: eye(), center: target, up: SIMD3<Float>(0, 1, 0))
        let safeAspect = max(0.01, aspect)
        let proj: float4x4
        switch projection {
        case .perspective:
            proj = perspectiveRH(fovy: fovy, aspect: safeAspect, near: 0.01, far: 100)
        case .orthographic:
            let halfHeight = max(0.3, distance * tan(fovy * 0.5))
            let halfWidth = halfHeight * safeAspect
            proj = orthographicRH(left: -halfWidth, right: halfWidth,
                                  bottom: -halfHeight, top: halfHeight,
                                  near: 0.01, far: 100)
        }
        return proj * view
    }
}
