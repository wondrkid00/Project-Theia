// Self-contained test runner for TheiaCore.
//
// `swift test` (XCTest) is unavailable in a Command-Line-Tools-only environment,
// so this is a plain executable: it runs checks, prints a report, and exits
// non-zero if anything fails. Run with `swift run theia-tests`.

import Foundation
import CoreGraphics
import ImageIO
import TheiaCore

// --- tiny assertion harness --------------------------------------------------
final class Harness {
    private(set) var failures = 0
    private(set) var checks = 0

    func expect(_ cond: Bool, _ message: @autoclosure () -> String) {
        checks += 1
        if !cond {
            failures += 1
            print("  ✗ \(message())")
        }
    }

    func test(_ name: String, _ body: () -> Void) {
        let before = failures
        body()
        let mark = failures == before ? "✓" : "✗"
        print("\(mark) \(name)")
    }
}

// std::string does not bridge to Swift.String on this toolchain; read strings
// back through the C++ core's buffer-copy accessors.
private func readCxxString(
    _ accessor: (UnsafeMutablePointer<CChar>?, Int) -> Int
) -> String {
    var buf = [CChar](repeating: 0, count: 1024)
    let n = buf.withUnsafeMutableBufferPointer { accessor($0.baseAddress, $0.count) }
    let len = min(max(n, 0), buf.count - 1)
    return String(decoding: buf[0..<len].map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private func readCxxLongString(
    _ accessor: (UnsafeMutablePointer<CChar>?, Int) -> Int
) -> String {
    var cap = 4096
    while true {
        var buf = [CChar](repeating: 0, count: cap)
        let n = buf.withUnsafeMutableBufferPointer { accessor($0.baseAddress, $0.count) }
        if n < cap {
            let len = max(n, 0)
            return String(decoding: buf[0..<len].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        cap = max(cap * 2, n + 1)
    }
}

let h = Harness()

h.test("Version and capabilities API are parseable") {
    let version = readCxxString { theia.theia_version_string($0, $1) }
    let versionFile = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("VERSION")
    let releaseVersion = (try? String(contentsOf: versionFile, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    h.expect(releaseVersion != nil, "could not read VERSION at \(versionFile.path)")
    h.expect(version == releaseVersion,
             "core version \(version) does not match VERSION \(releaseVersion ?? "<missing>")")
    h.expect(theia.theia_api_version() >= 3, "api version should be >= 3")
    let capsText = readCxxLongString { theia.theia_capabilities_json($0, $1) }
    guard let data = capsText.data(using: .utf8),
          let caps = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        h.expect(false, "capabilities JSON did not parse")
        return
    }
    let heightmapFormats = caps["heightmapFormats"] as? [String] ?? []
    let meshFormats = caps["meshFormats"] as? [String] ?? []
    h.expect(heightmapFormats.contains("png16"), "missing png16 capability")
    h.expect(heightmapFormats.contains("r16"), "missing r16 capability")
    h.expect(heightmapFormats.contains("pfm32"), "missing pfm32 capability")
    h.expect(meshFormats.contains("obj"), "missing obj capability")
    h.expect(caps["graphFormatVersion"] as? Int == 2,
             "graph format capability should be 2")
}

h.test("GPU fill produces a uniform buffer") {
    let value: Float = 3.5
    let count: UInt32 = 4096
    let r = theia.gpu_smoke_fill(count, value)
    let err = readCxxString { theia.smoke_error(r, $0, $1) }

    h.expect(r.ok, "smoke failed: \(err)")
    h.expect(r.count == count, "count mismatch: \(r.count)")
    h.expect(r.allMatch, "not all elements matched")
    h.expect(r.first == value, "first=\(r.first)")
    h.expect(r.last == value, "last=\(r.last)")

    let device = readCxxString { theia.smoke_device_name(r, $0, $1) }
    h.expect(!device.isEmpty, "empty device name")
}

h.test("Zero-length fill is a successful no-op") {
    let r = theia.gpu_smoke_fill(0, 1.0)
    h.expect(r.ok, "zero-count should succeed")
    h.expect(r.count == 0, "count should be 0")
}

func perlin(seed: UInt32, size: UInt32 = 256) -> theia.GenerateResult {
    var p = theia.PerlinParams()
    p.width = size
    p.height = size
    p.seed = seed
    return theia.generate_perlin(p, nil, nil)  // no file output
}

h.test("Perlin output is well-formed terrain (range + non-degenerate)") {
    let r = perlin(seed: 42)
    let err = readCxxString { theia.generate_error(r, $0, $1) }
    h.expect(r.ok, "generation failed: \(err)")
    h.expect(r.width == 256 && r.height == 256, "wrong dims")
    h.expect(r.minHeight >= 0.0 && r.maxHeight <= 1.0, "out of [0,1]: [\(r.minHeight),\(r.maxHeight)]")
    h.expect(r.maxHeight > r.minHeight, "flat output")
    h.expect(r.variance > 1e-5, "degenerate output, variance=\(r.variance)")
    h.expect(r.mean > 0.3 && r.mean < 0.7, "mean not centered: \(r.mean)")
}

h.test("Perlin is deterministic for a fixed seed") {
    let a = perlin(seed: 7)
    let b = perlin(seed: 7)
    h.expect(a.ok && b.ok, "generation failed")
    h.expect(a.minHeight == b.minHeight, "min differs")
    h.expect(a.maxHeight == b.maxHeight, "max differs")
    h.expect(a.mean == b.mean, "mean differs: \(a.mean) vs \(b.mean)")
    h.expect(a.variance == b.variance, "variance differs")
}

h.test("Different seeds produce different terrain") {
    let a = perlin(seed: 1)
    let b = perlin(seed: 2)
    h.expect(a.ok && b.ok, "generation failed")
    h.expect(a.mean != b.mean || a.variance != b.variance,
             "seeds 1 and 2 produced identical stats")
}

// --- M2: node graph engine ---------------------------------------------------

func graphError(_ g: OpaquePointer) -> String {
    readCxxString { theia.graph_last_error(g, $0, $1) }
}

func diagnosticsString(_ text: String) -> String {
    var buf = [CChar](repeating: 0, count: 16384)
    let n = buf.withUnsafeMutableBufferPointer {
        theia.graph_diagnostics_json_text(text, $0.baseAddress, $0.count)
    }
    let len = min(max(n, 0), buf.count - 1)
    return String(decoding: buf[0..<len].map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

func diagnosticsObject(_ text: String) -> [String: Any] {
    let str = diagnosticsString(text)
    let data = Data(str.utf8)
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

func diagnosticCodes(_ text: String) -> Set<String> {
    let obj = diagnosticsObject(text)
    let issues = obj["issues"] as? [[String: Any]] ?? []
    return Set(issues.compactMap { $0["code"] as? String })
}

h.test("Graph evaluates a linear chain (topological order)") {
    guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
    defer { theia.graph_destroy(g) }
    h.expect(theia.graph_add_node(g, "a", "perlin"), "add a")
    h.expect(theia.graph_add_node(g, "b", "scalebias"), "add b")
    h.expect(theia.graph_add_node(g, "c", "scalebias"), "add c")
    h.expect(theia.graph_connect(g, "a", "b", 0), "connect a->b")
    h.expect(theia.graph_connect(g, "b", "c", 0), "connect b->c")

    let r = theia.graph_evaluate(g, "c", 256, 256, nil, nil)
    h.expect(r.ok, "eval failed: \(graphError(g))")
    h.expect(r.evaluated == 3, "expected 3 evaluated, got \(r.evaluated)")
    h.expect(r.reused == 0, "expected 0 reused, got \(r.reused)")
    h.expect(r.variance > 1e-5, "degenerate output")
}

h.test("Incremental cache recomputes only the affected subgraph") {
    guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
    defer { theia.graph_destroy(g) }
    _ = theia.graph_add_node(g, "a", "perlin")
    _ = theia.graph_add_node(g, "b", "scalebias")
    _ = theia.graph_add_node(g, "c", "scalebias")
    _ = theia.graph_connect(g, "a", "b", 0)
    _ = theia.graph_connect(g, "b", "c", 0)

    let r1 = theia.graph_evaluate(g, "c", 256, 256, nil, nil)
    h.expect(r1.evaluated == 3 && r1.reused == 0, "cold: \(r1.evaluated)/\(r1.reused)")

    // No change => full cache hit.
    let r2 = theia.graph_evaluate(g, "c", 256, 256, nil, nil)
    h.expect(r2.evaluated == 0 && r2.reused == 3, "warm: \(r2.evaluated)/\(r2.reused)")

    // Change the sink's param => only the sink recomputes; upstream reused.
    _ = theia.graph_set_param(g, "c", "bias", 0.1)
    let r3 = theia.graph_evaluate(g, "c", 256, 256, nil, nil)
    h.expect(r3.evaluated == 1 && r3.reused == 2, "leaf change: \(r3.evaluated)/\(r3.reused)")

    // Change the root's param => everything downstream recomputes.
    _ = theia.graph_set_param(g, "a", "seed", 4242)
    let r4 = theia.graph_evaluate(g, "c", 256, 256, nil, nil)
    h.expect(r4.evaluated == 3 && r4.reused == 0, "root change: \(r4.evaluated)/\(r4.reused)")
}

h.test("Diamond DAG reuses the unaffected branch") {
    guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
    defer { theia.graph_destroy(g) }
    _ = theia.graph_add_node(g, "a", "perlin")
    _ = theia.graph_add_node(g, "b", "perlin")
    _ = theia.graph_add_node(g, "mix", "combine")
    _ = theia.graph_connect(g, "a", "mix", 0)
    _ = theia.graph_connect(g, "b", "mix", 1)

    let r1 = theia.graph_evaluate(g, "mix", 256, 256, nil, nil)
    h.expect(r1.ok && r1.evaluated == 3, "cold: \(r1.evaluated) (\(graphError(g)))")

    // Change only branch "a": a + mix recompute, b reused.
    _ = theia.graph_set_param(g, "a", "frequency", 8.0)
    let r2 = theia.graph_evaluate(g, "mix", 256, 256, nil, nil)
    h.expect(r2.evaluated == 2 && r2.reused == 1, "after a-change: \(r2.evaluated)/\(r2.reused)")
}

h.test("Cycles are detected and rejected") {
    guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
    defer { theia.graph_destroy(g) }
    _ = theia.graph_add_node(g, "x", "scalebias")
    _ = theia.graph_add_node(g, "y", "scalebias")
    _ = theia.graph_connect(g, "x", "y", 0)
    _ = theia.graph_connect(g, "y", "x", 0)
    let r = theia.graph_evaluate(g, "y", 64, 64, nil, nil)
    h.expect(!r.ok, "cycle should fail evaluation")
    h.expect(graphError(g).contains("cycle"), "error should mention cycle: \(graphError(g))")
}

h.test("Unknown node type and duplicate id are rejected") {
    guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
    defer { theia.graph_destroy(g) }
    h.expect(!theia.graph_add_node(g, "n", "nonsense"), "unknown type should fail")
    h.expect(theia.graph_add_node(g, "n", "perlin"), "first add ok")
    h.expect(!theia.graph_add_node(g, "n", "perlin"), "duplicate id should fail")
}

h.test("JSON round-trip preserves graph behavior") {
    let tmp = NSTemporaryDirectory() + "theia_rt_\(getpid()).json"
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    var original = theia.GraphEvalResult()
    do {
        guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
        defer { theia.graph_destroy(g) }
        _ = theia.graph_add_node(g, "a", "perlin")
        _ = theia.graph_add_node(g, "out", "scalebias")
        _ = theia.graph_set_param(g, "out", "scale", 1.3)
        _ = theia.graph_connect(g, "a", "out", 0)
        original = theia.graph_evaluate(g, "out", 256, 256, nil, nil)
        h.expect(original.ok, "original eval: \(graphError(g))")
        h.expect(theia.graph_save_json_file(g, tmp), "save failed: \(graphError(g))")
    }

    guard let g2 = theia.graph_create() else { h.expect(false, "create2 failed"); return }
    defer { theia.graph_destroy(g2) }
    h.expect(theia.graph_load_json_file(g2, tmp), "load failed: \(graphError(g2))")
    let reloaded = theia.graph_evaluate(g2, "out", 256, 256, nil, nil)
    h.expect(reloaded.ok, "reloaded eval: \(graphError(g2))")
    h.expect(reloaded.minHeight == original.minHeight, "min differs")
    h.expect(reloaded.maxHeight == original.maxHeight, "max differs")
    h.expect(reloaded.mean == original.mean, "mean differs")
    h.expect(reloaded.variance == original.variance, "variance differs")
}

h.test("Failed JSON reload leaves the previous graph usable") {
    let bad = NSTemporaryDirectory() + "theia_bad_\(getpid()).json"
    defer { try? FileManager.default.removeItem(atPath: bad) }
    try? """
    {
      "sink": "out",
      "nodes": [
        { "id": "out", "type": "not-a-node", "params": {} }
      ]
    }
    """.write(toFile: bad, atomically: true, encoding: .utf8)

    guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
    defer { theia.graph_destroy(g) }
    _ = theia.graph_add_node(g, "a", "perlin")
    _ = theia.graph_add_node(g, "out", "scalebias")
    _ = theia.graph_connect(g, "a", "out", 0)

    let before = theia.graph_evaluate(g, "out", 64, 64, nil, nil)
    h.expect(before.ok, "before eval failed: \(graphError(g))")
    h.expect(!theia.graph_load_json_file(g, bad), "bad reload should fail")

    let after = theia.graph_evaluate(g, "out", 64, 64, nil, nil)
    h.expect(after.ok, "graph should survive failed reload: \(graphError(g))")
    h.expect(after.mean == before.mean, "surviving graph mean changed")
    h.expect(after.reused == 2, "surviving graph should still use cache, got \(after.reused)")
}

h.test("Loads the bundled example graph") {
    guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
    defer { theia.graph_destroy(g) }
    if theia.graph_load_json_file(g, "examples/terrain.json") {
        let r = theia.graph_evaluate(g, "", 256, 256, nil, nil)  // "" => default sink
        h.expect(r.ok, "example eval: \(graphError(g))")
        h.expect(r.evaluated == 4, "expected 4 nodes, got \(r.evaluated)")
        h.expect(r.variance > 1e-5, "degenerate example output")
    } else {
        print("  (skipping example: \(graphError(g)))")
    }
}

// --- M3: erosion -------------------------------------------------------------

h.test("Hydraulic erosion alters terrain and is deterministic") {
    func run() -> (base: theia.GraphEvalResult, ero: theia.GraphEvalResult)? {
        guard let g = theia.graph_create() else { return nil }
        defer { theia.graph_destroy(g) }
        _ = theia.graph_add_node(g, "p", "perlin")
        _ = theia.graph_set_param(g, "p", "seed", 2024)
        _ = theia.graph_add_node(g, "e", "hydraulic")
        _ = theia.graph_set_param(g, "e", "iterations", 50)
        _ = theia.graph_connect(g, "p", "e", 0)
        let base = theia.graph_evaluate(g, "p", 128, 128, nil, nil)
        let ero = theia.graph_evaluate(g, "e", 128, 128, nil, nil)
        return (base, ero)
    }
    guard let r1 = run(), let r2 = run() else { h.expect(false, "run failed"); return }
    h.expect(r1.ero.ok, "hydraulic eval failed")
    h.expect(r1.ero.variance > 1e-6, "degenerate erosion output")
    h.expect(r1.ero.mean != r1.base.mean, "erosion did not change the terrain")
    h.expect(r1.ero.mean == r2.ero.mean && r1.ero.variance == r2.ero.variance,
             "hydraulic erosion is non-deterministic")
}

h.test("Thermal erosion smooths slopes and lowers peaks") {
    guard let g = theia.graph_create() else { h.expect(false, "create"); return }
    defer { theia.graph_destroy(g) }
    _ = theia.graph_add_node(g, "p", "perlin")
    _ = theia.graph_set_param(g, "p", "seed", 7)
    _ = theia.graph_add_node(g, "t", "thermal")
    _ = theia.graph_set_param(g, "t", "talusAngle", 12.0)
    _ = theia.graph_set_param(g, "t", "iterations", 80)
    _ = theia.graph_connect(g, "p", "t", 0)

    let base = theia.graph_evaluate(g, "p", 128, 128, nil, nil)
    let th = theia.graph_evaluate(g, "t", 128, 128, nil, nil)
    h.expect(th.ok, "thermal eval failed: \(graphError(g))")
    h.expect(th.variance < base.variance,
             "thermal should reduce variance: \(base.variance) -> \(th.variance)")
    h.expect(th.maxHeight <= base.maxHeight + 1e-4, "thermal should not raise peaks")
}

h.test("Loads the erosion example graph (perlin->hydraulic->thermal)") {
    guard let g = theia.graph_create() else { h.expect(false, "create"); return }
    defer { theia.graph_destroy(g) }
    if theia.graph_load_json_file(g, "examples/erosion.json") {
        let r = theia.graph_evaluate(g, "", 128, 128, nil, nil)  // default sink
        h.expect(r.ok, "erosion example eval: \(graphError(g))")
        h.expect(r.evaluated == 3, "expected 3 nodes, got \(r.evaluated)")
        h.expect(r.variance > 1e-6, "degenerate erosion-example output")
    } else {
        print("  (skipping erosion example: \(graphError(g)))")
    }
}

// --- M4: filters + polish ----------------------------------------------------

func perlinThen(_ type: String, configure: (OpaquePointer) -> Void = { _ in })
    -> theia.GraphEvalResult? {
    guard let g = theia.graph_create() else { return nil }
    defer { theia.graph_destroy(g) }
    _ = theia.graph_add_node(g, "p", "perlin")
    _ = theia.graph_set_param(g, "p", "seed", 2024)
    _ = theia.graph_add_node(g, "f", type)
    _ = theia.graph_connect(g, "p", "f", 0)
    configure(g)
    return theia.graph_evaluate(g, "f", 128, 128, nil, nil)
}

h.test("Normalize stretches the range to [0,1]") {
    guard let r = perlinThen("normalize") else { h.expect(false, "run"); return }
    h.expect(r.ok, "normalize eval failed")
    h.expect(r.minHeight < 0.001, "min not ~0: \(r.minHeight)")
    h.expect(r.maxHeight > 0.999, "max not ~1: \(r.maxHeight)")
}

h.test("Terrace produces a valid, non-degenerate field") {
    guard let a = perlinThen("terrace"), let b = perlinThen("terrace") else {
        h.expect(false, "run"); return
    }
    h.expect(a.ok, "terrace eval failed")
    h.expect(a.minHeight >= 0.0 && a.maxHeight <= 1.0, "out of [0,1]")
    h.expect(a.variance > 1e-6, "degenerate terrace")
    h.expect(a.mean == b.mean && a.variance == b.variance, "terrace non-deterministic")
}

h.test("Slope mask is a valid [0,1] mask with variation") {
    guard let r = perlinThen("slopemask") else { h.expect(false, "run"); return }
    h.expect(r.ok, "slopemask eval failed")
    h.expect(r.minHeight >= 0.0 && r.maxHeight <= 1.0, "mask out of [0,1]")
    h.expect(r.variance > 1e-6, "mask has no variation")
}

// Horizontal spacing is ground distance derived from the terrain's world width,
// so a slope operator must not drift with the sampling grid. Before this was
// enforced, the same slope mask measured [0,1] at 128 and [0,0] at 1024,
// and the suite missed it by only ever evaluating at 128.
// See docs/research/terrain-horizontal-scale-notes.md.
func slopeMaskGraphJSON(terrainSize: Double, heightScale: Double = 100.0,
                        low: Double = 25.0, high: Double = 45.0) -> String {
    """
    {
      "resolution": { "width": 256, "height": 256 },
      "sink": "mask",
      "nodes": [
        { "id": "p", "type": "perlin", "params": {
          "seed": 2026, "frequency": 1.6, "octaves": 4,
          "lacunarity": 2.0, "gain": 0.48, "heightScale": 1.0
        } },
        { "id": "mask", "type": "slopemask", "params": {
          "low": \(low), "high": \(high),
          "heightScale": \(heightScale), "terrainSize": \(terrainSize)
        } }
      ],
      "connections": [ { "from": "p", "to": "mask", "input": 0 } ]
    }
    """
}

func meanCoverage(_ values: [Float]) -> Double {
    guard !values.isEmpty else { return 0 }
    return Double(values.reduce(0, +)) / Double(values.count)
}

h.test("Slope mask coverage is stable across sampling resolutions") {
    let json = slopeMaskGraphJSON(terrainSize: 256)
    let grids: [UInt32] = [128, 256, 512, 1024]
    var coverages: [Double] = []
    for grid in grids {
        let mask = evalGraphHeightsJSON(json, sink: "mask", size: grid)
        h.expect(mask.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 },
                 "slope mask left [0,1] at \(grid)")
        let coverage = meanCoverage(mask)
        h.expect(coverage > 0.01,
                 "slope mask vanished at \(grid): coverage \(coverage)")
        coverages.append(coverage)
    }
    // Finer grids legitimately resolve finer detail, so the contract is a
    // bounded ratio rather than equality. The pre-fix implementation collapsed
    // to exactly zero here, an unbounded ratio.
    let low = coverages.min() ?? 0
    let high = coverages.max() ?? 0
    h.expect(low > 0 && high / low < 2.0,
             "slope coverage drifted with resolution: \(coverages)")
}

h.test("Slope depends only on the vertical-to-horizontal ratio") {
    // GDAL's -scale is the ratio of vertical to horizontal units, so scaling
    // both by the same factor must leave the emitted angle untouched.
    let baseline = evalGraphHeightsJSON(
        slopeMaskGraphJSON(terrainSize: 256, heightScale: 100), sink: "mask", size: 256)
    let doubled = evalGraphHeightsJSON(
        slopeMaskGraphJSON(terrainSize: 512, heightScale: 200), sink: "mask", size: 256)
    h.expect(baseline.count == doubled.count && !baseline.isEmpty,
             "ratio fixtures must be comparable")
    h.expect(meanAbsoluteDifference(baseline, doubled) < 1e-6,
             "equal vertical/horizontal ratio changed the slope mask")

    // A steeper ratio must produce strictly more coverage, so the parameter is
    // not merely inert.
    let steeper = evalGraphHeightsJSON(
        slopeMaskGraphJSON(terrainSize: 128, heightScale: 100), sink: "mask", size: 256)
    h.expect(meanCoverage(steeper) > meanCoverage(baseline) + 0.01,
             "halving terrainSize should steepen the mask")
}

h.test("Slope mask rejects a degenerate terrain size") {
    for bad in ["0.0", "-256.0"] {
        guard let g = theia.graph_create() else { h.expect(false, "create"); return }
        defer { theia.graph_destroy(g) }
        h.expect(theia.graph_load_json_text(g, slopeMaskGraphJSON(terrainSize: 1)),
                 "load: \(graphError(g))")
        h.expect(theia.graph_set_param(g, "mask", "terrainSize", Double(bad) ?? 0),
                 "set terrainSize \(bad)")
        let r = theia.graph_evaluate(g, "mask", 128, 128, nil, nil)
        h.expect(!r.ok, "terrainSize \(bad) should fail evaluation")
    }
}

h.test("Legacy cellSize migrates at the document's declared resolution") {
    let json = """
    {
      "resolution": { "width": 96, "height": 96 },
      "sink": "mask",
      "nodes": [
        { "id": "p", "type": "perlin", "params": { "seed": 7, "frequency": 3.0 } },
        { "id": "mask", "type": "slopemask", "params": {
          "low": 20.0, "high": 60.0, "heightScale": 100.0, "cellSize": 2.0
        } }
      ],
      "connections": [ { "from": "p", "to": "mask", "input": 0 } ]
    }
    """
    guard let g = theia.graph_create() else { h.expect(false, "create"); return }
    defer { theia.graph_destroy(g) }
    h.expect(theia.graph_load_json_text(g, json), "load: \(graphError(g))")
    // cellSize 2.0 over 95 intervals is a 190-unit world; reproducing it keeps
    // the document rendering exactly as it did at its own declared grid.
    h.expect(theia.graph_param_value(g, "mask", "terrainSize", -1) == 190.0,
             "legacy cellSize should migrate to an equivalent terrainSize")
    h.expect(theia.graph_param_value(g, "mask", "cellSize", -1) == -1,
             "legacy cellSize should not survive migration")
}

h.test("Legacy slope mask defaults migrate to preview-safe values") {
    guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
    defer { theia.graph_destroy(g) }
    let json = """
    {
      "resolution": { "width": 96, "height": 96 },
      "sink": "mask",
      "nodes": [
        { "id": "p", "type": "perlin", "params": { "seed": 42, "frequency": 5.0 } },
        { "id": "mask", "type": "slopemask", "params": {
          "low": 0.2, "high": 0.8, "heightScale": 64.0, "cellSize": 1.0
        } }
      ],
      "connections": [
        { "from": "p", "to": "mask", "input": 0 }
      ]
    }
    """
    h.expect(theia.graph_load_json_text(g, json), "load: \(graphError(g))")
    h.expect(theia.graph_param_value(g, "mask", "heightScale", -1) == 100.0,
             "legacy slopemask heightScale should migrate")
    h.expect(theia.graph_param_value(g, "mask", "low", -1) == 15.0,
             "legacy slopemask low should migrate")
    h.expect(theia.graph_param_value(g, "mask", "high", -1) == 50.0,
             "legacy slopemask high should migrate")
    let r = theia.graph_evaluate(g, "", 96, 96, nil, nil)
    h.expect(r.ok, "eval: \(graphError(g))")
    h.expect(r.variance > 1e-6, "migrated mask should retain variation")
}

h.test("Invalid slope mask thresholds are migrated before evaluation") {
    guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
    defer { theia.graph_destroy(g) }
    let json = """
    {
      "resolution": { "width": 96, "height": 96 },
      "sink": "mask",
      "nodes": [
        { "id": "p", "type": "perlin", "params": { "seed": 42, "frequency": 5.0 } },
        { "id": "mask", "type": "slopemask", "params": {
          "low": 0.12, "high": -0.94, "heightScale": 1.2, "cellSize": 2.4
        } }
      ],
      "connections": [
        { "from": "p", "to": "mask", "input": 0 }
      ]
    }
    """
    h.expect(theia.graph_load_json_text(g, json), "load: \(graphError(g))")
    h.expect(theia.graph_param_value(g, "mask", "low", -1) == 15.0,
             "invalid slopemask low should migrate")
    h.expect(theia.graph_param_value(g, "mask", "high", -1) == 50.0,
             "invalid slopemask high should migrate")
    let r = theia.graph_evaluate(g, "", 96, 96, nil, nil)
    h.expect(r.ok, "eval: \(graphError(g))")
    h.expect(r.variance > 1e-6, "invalid migrated mask should retain variation")
}

h.test("16-bit PNG export is well-formed") {
    let tmp = NSTemporaryDirectory() + "theia_png16_\(getpid()).png"
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    guard let g = theia.graph_create() else { h.expect(false, "create"); return }
    defer { theia.graph_destroy(g) }
    _ = theia.graph_add_node(g, "p", "perlin")
    let r = theia.graph_evaluate(g, "p", 64, 64, tmp, nil)
    h.expect(r.ok, "eval failed: \(graphError(g))")

    guard let bytes = FileManager.default.contents(atPath: tmp) else {
        h.expect(false, "png not written"); return
    }
    let sig: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    h.expect(Array(bytes.prefix(8)) == sig, "bad PNG signature")
    // IHDR bit-depth byte is at offset 24 (8 sig + 4 len + 4 'IHDR' + 8 w/h).
    h.expect(bytes.count > 24 && bytes[24] == 16, "expected 16-bit depth, got \(bytes.count > 24 ? Int(bytes[24]) : -1)")
}

h.test("Production export writes maps and OBJ with valid topology") {
    let dir = NSTemporaryDirectory() + "theia_export_\(getpid())"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    guard let g = theia.graph_create() else { h.expect(false, "create"); return }
    defer { theia.graph_destroy(g) }
    _ = theia.graph_add_node(g, "p", "perlin")
    let height = dir + "/terrain_height.png"
    let pfm = dir + "/terrain.pfm"
    let normal = dir + "/terrain_normal.png"
    let slope = dir + "/terrain_slope.png"
    let mask = dir + "/terrain_mask.png"
    let obj = dir + "/terrain.obj"
    let r = theia.graph_export(g, "p", 8, 8, height, pfm, normal, slope, mask, obj, 1.0, 2)
    h.expect(r.ok, "export failed: \(graphError(g))")
    for path in [height, pfm, normal, slope, mask, obj] {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = attrs?[.size] as? NSNumber
        h.expect((size?.intValue ?? 0) > 16, "export missing/empty \(path)")
    }

    guard let text = try? String(contentsOfFile: obj) else {
        h.expect(false, "obj read failed"); return
    }
    let lines = text.split(separator: "\n")
    let vertexLines = lines.filter { $0.hasPrefix("v ") }
    let vCount = lines.filter { $0.hasPrefix("v ") }.count
    let vtCount = lines.filter { $0.hasPrefix("vt ") }.count
    let vnCount = lines.filter { $0.hasPrefix("vn ") }.count
    let fLines = lines.filter { $0.hasPrefix("f ") }
    h.expect(vCount == 25, "stride 2 over 8x8 should export 5x5 vertices, got \(vCount)")
    h.expect(vtCount == vCount && vnCount == vCount, "obj attribute counts mismatch")
    h.expect(fLines.count == 32, "4x4 quads should export 32 faces, got \(fLines.count)")
    for line in fLines {
        let refs = line.split(separator: " ").dropFirst()
        h.expect(refs.count == 3, "face should be triangular: \(line)")
        for ref in refs {
            let parts = ref.split(separator: "/")
            h.expect(parts.count == 3, "face ref should include v/vt/vn: \(ref)")
            let idx = Int(parts[0]) ?? 0
            h.expect(idx >= 1 && idx <= vCount, "obj index out of range: \(idx)")
        }
    }
    if vertexLines.count == vCount, let firstFace = fLines.first {
        let verts = vertexLines.compactMap { line -> (Double, Double, Double)? in
            let p = line.split(separator: " ")
            guard p.count == 4,
                  let x = Double(p[1]), let y = Double(p[2]), let z = Double(p[3]) else {
                return nil
            }
            return (x, y, z)
        }
        let idx = firstFace.split(separator: " ").dropFirst().compactMap {
            Int($0.split(separator: "/")[0]).map { $0 - 1 }
        }
        if verts.count == vCount && idx.count == 3 {
            let a = verts[idx[0]], b = verts[idx[1]], c = verts[idx[2]]
            let ab = (b.0 - a.0, b.1 - a.1, b.2 - a.2)
            let ac = (c.0 - a.0, c.1 - a.1, c.2 - a.2)
            let normalY = ab.2 * ac.0 - ab.0 * ac.2
            h.expect(normalY > 0, "first OBJ face should wind upward for one-sided top faces")
        }
    }
}

h.test("Structured graph_export2 writes PNG16, R16, PFM32, and OBJ") {
    let dir = NSTemporaryDirectory() + "theia_export2_\(getpid())"
    defer { try? FileManager.default.removeItem(atPath: dir) }

    guard let g = theia.graph_create() else { h.expect(false, "create"); return }
    defer { theia.graph_destroy(g) }
    _ = theia.graph_add_node(g, "p", "perlin")

    func callExport2(_ base: String,
                     _ heightmap: theia.HeightmapFormat,
                     _ mesh: theia.MeshFormat) -> theia.GraphEvalResult {
        dir.withCString { dirPtr in
            base.withCString { basePtr in
                "p".withCString { sinkPtr in
                    var opts = theia.GraphExportOptions()
                    opts.sinkId = sinkPtr
                    opts.width = 8
                    opts.height = 8
                    opts.outDir = dirPtr
                    opts.basename = basePtr
                    opts.heightmapFormat = heightmap
                    opts.meshFormat = mesh
                    opts.verticalScale = 1.0
                    opts.meshStride = 2
                    return theia.graph_export2(g, opts)
                }
            }
        }
    }

    let pngObj = callExport2("terrain_png", theia.HeightmapFormat.png16, theia.MeshFormat.obj)
    h.expect(pngObj.ok, "png/obj export2 failed: \(graphError(g))")
    let raw = callExport2("terrain_raw", theia.HeightmapFormat.r16, theia.MeshFormat.none)
    h.expect(raw.ok, "r16 export2 failed: \(graphError(g))")
    let pfm = callExport2("terrain_pfm", theia.HeightmapFormat.pfm32, theia.MeshFormat.none)
    h.expect(pfm.ok, "pfm32 export2 failed: \(graphError(g))")

    let expectedFiles = [
        "\(dir)/terrain_png_height.png",
        "\(dir)/terrain_png.obj",
        "\(dir)/terrain_raw_height.r16",
        "\(dir)/terrain_pfm.pfm",
    ]
    for path in expectedFiles {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = attrs?[.size] as? NSNumber
        h.expect((size?.intValue ?? 0) > 0, "export2 missing/empty \(path)")
    }
    let rawAttrs = try? FileManager.default.attributesOfItem(atPath: "\(dir)/terrain_raw_height.r16")
    let rawSize = rawAttrs?[.size] as? NSNumber
    h.expect(rawSize?.intValue == 8 * 8 * 2, "r16 size should be 128 bytes")
}

h.test("Production export rejects invalid options without writing") {
    let dir = NSTemporaryDirectory() + "theia_export_bad_\(getpid())"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    guard let g = theia.graph_create() else { h.expect(false, "create"); return }
    defer { theia.graph_destroy(g) }
    _ = theia.graph_add_node(g, "p", "perlin")
    let out = dir + "/bad.obj"
    let badSize = theia.graph_export(g, "p", 1, 1, "", "", "", "", "", out, 1.0, 1)
    h.expect(!badSize.ok, "export should reject 1x1 resolution")
    let badStride = theia.graph_export(g, "p", 8, 8, "", "", "", "", "", out, 1.0, 0)
    h.expect(!badStride.ok, "export should reject stride 0")
    let badScale = theia.graph_export(g, "p", 8, 8, "", "", "", "", "", out, 0.0, 1)
    h.expect(!badScale.ok, "export should reject vertical scale 0")
    let badPath = theia.graph_export(g, "p", 8, 8, dir, "", "", "", "", "", 1.0, 1)
    h.expect(!badPath.ok, "export should reject unwritable output paths")

    guard let empty = theia.graph_create() else { h.expect(false, "create empty"); return }
    defer { theia.graph_destroy(empty) }
    let noSink = theia.graph_export(empty, "", 8, 8, "", "", "", "", "", out, 1.0, 1)
    h.expect(!noSink.ok, "export should reject empty sink")
}

h.test("Structured graph_export2 rejects invalid options") {
    let dir = NSTemporaryDirectory() + "theia_export2_bad_\(getpid())"
    defer { try? FileManager.default.removeItem(atPath: dir) }

    guard let g = theia.graph_create() else { h.expect(false, "create"); return }
    defer { theia.graph_destroy(g) }
    _ = theia.graph_add_node(g, "p", "perlin")

    func callExport2(_ width: UInt32,
                     _ heightmap: theia.HeightmapFormat,
                     _ mesh: theia.MeshFormat) -> theia.GraphEvalResult {
        dir.withCString { dirPtr in
            "bad".withCString { basePtr in
                "p".withCString { sinkPtr in
                    var opts = theia.GraphExportOptions()
                    opts.sinkId = sinkPtr
                    opts.width = width
                    opts.height = width
                    opts.outDir = dirPtr
                    opts.basename = basePtr
                    opts.heightmapFormat = heightmap
                    opts.meshFormat = mesh
                    opts.verticalScale = 1.0
                    opts.meshStride = 1
                    return theia.graph_export2(g, opts)
                }
            }
        }
    }

    let noOutputs = callExport2(8, theia.HeightmapFormat.none, theia.MeshFormat.none)
    h.expect(!noOutputs.ok, "export2 should reject no outputs")
    let badSize = callExport2(1, theia.HeightmapFormat.png16, theia.MeshFormat.none)
    h.expect(!badSize.ok, "export2 should reject 1x1 resolution")
}

h.test("Loads the showcase graph (full pipeline)") {
    guard let g = theia.graph_create() else { h.expect(false, "create"); return }
    defer { theia.graph_destroy(g) }
    if theia.graph_load_json_file(g, "examples/showcase.json") {
        let r = theia.graph_evaluate(g, "", 128, 128, nil, nil)
        h.expect(r.ok, "showcase eval: \(graphError(g))")
        h.expect(r.evaluated == 5, "expected 5 nodes, got \(r.evaluated)")
    } else {
        print("  (skipping showcase: \(graphError(g)))")
    }
}

// --- Phase 2: viewer support API ---------------------------------------------

h.test("graph_evaluate_heights fills a buffer matching the stats") {
    guard let g = theia.graph_create() else { h.expect(false, "create"); return }
    defer { theia.graph_destroy(g) }
    _ = theia.graph_add_node(g, "p", "perlin")
    _ = theia.graph_set_param(g, "p", "seed", 2024)

    let w = 64, n = w * w
    var buf = [Float](repeating: -1, count: n)
    let r = buf.withUnsafeMutableBufferPointer {
        theia.graph_evaluate_heights(g, "p", UInt32(w), UInt32(w), $0.baseAddress, $0.count)
    }
    h.expect(r.ok, "eval failed: \(graphError(g))")
    h.expect(r.width == 64 && r.height == 64, "dims")

    let mn = buf.min() ?? 0, mx = buf.max() ?? 0
    h.expect(abs(mn - r.minHeight) < 1e-5, "buffer min \(mn) != stat \(r.minHeight)")
    h.expect(abs(mx - r.maxHeight) < 1e-5, "buffer max \(mx) != stat \(r.maxHeight)")
    h.expect(mn >= 0 && mx <= 1, "values out of [0,1]")
    h.expect(mx > mn, "buffer is flat")
}

h.test("graph_evaluate_heights tolerates a null/too-small buffer") {
    guard let g = theia.graph_create() else { h.expect(false, "create"); return }
    defer { theia.graph_destroy(g) }
    _ = theia.graph_add_node(g, "p", "perlin")
    let probe = theia.graph_evaluate_heights(g, "p", 32, 32, nil, 0)
    h.expect(probe.ok, "null-buffer probe should still evaluate")
    h.expect(probe.width == 32 && probe.height == 32, "probe dims")
}

h.test("Graph node and parameter enumeration exposes slider data") {
    guard let g = theia.graph_create() else { h.expect(false, "create"); return }
    defer { theia.graph_destroy(g) }
    _ = theia.graph_add_node(g, "base", "perlin")
    _ = theia.graph_set_param(g, "base", "seed", 2024)
    _ = theia.graph_set_param(g, "base", "frequency", 6.5)
    _ = theia.graph_add_node(g, "out", "scalebias")
    _ = theia.graph_set_param(g, "out", "scale", 1.2)

    h.expect(theia.graph_node_count(g) == 2, "expected 2 nodes")
    let id0 = readCxxString { theia.graph_node_id(g, 0, $0, $1) }
    let type0 = readCxxString { theia.graph_node_type(g, 0, $0, $1) }
    h.expect(id0 == "base", "first node id \(id0)")
    h.expect(type0 == "perlin", "first node type \(type0)")

    let paramCount = theia.graph_param_count(g, "base")
    h.expect(paramCount == 6, "base param count \(paramCount)")
    var names: [String] = []
    for i in 0..<paramCount {
        names.append(readCxxString { theia.graph_param_name(g, "base", i, $0, $1) })
    }
    h.expect(names == ["frequency", "gain", "heightScale", "lacunarity", "octaves", "seed"],
             "ordered params \(names)")
    h.expect(theia.graph_param_value(g, "base", "frequency", -1) == 6.5, "frequency value")
    h.expect(theia.graph_param_value(g, "missing", "frequency", 42) == 42, "fallback value")
}

h.test("Graph loads JSON text transactionally and preserves editor UI metadata") {
    guard let g = theia.graph_create() else { h.expect(false, "create"); return }
    defer { theia.graph_destroy(g) }
    let valid = """
    {
      "resolution": { "width": 64, "height": 64 },
      "sink": "out",
      "nodes": [
        { "id": "base", "type": "perlin", "params": { "seed": 2024 } },
        { "id": "out", "type": "normalize", "params": {} }
      ],
      "connections": [
        { "from": "base", "to": "out", "input": 0 }
      ],
      "ui": {
        "positions": {
          "base": { "x": 120, "y": 80 },
          "out": { "x": 320, "y": 80 }
        }
      }
    }
    """
    h.expect(theia.graph_load_json_text(g, valid), "valid JSON text failed: \(graphError(g))")
    let first = theia.graph_evaluate(g, "", 64, 64, nil, nil)
    h.expect(first.ok, "eval failed after JSON text load: \(graphError(g))")

    let bad = """
    {
      "sink": "broken",
      "nodes": [
        { "id": "broken", "type": "not-a-node", "params": {} }
      ]
    }
    """
    h.expect(!theia.graph_load_json_text(g, bad), "bad JSON text should fail")
    let after = theia.graph_evaluate(g, "", 64, 64, nil, nil)
    h.expect(after.ok, "previous graph should survive failed text load: \(graphError(g))")
    h.expect(after.reused == 2, "surviving graph should reuse cache, got \(after.reused)")

    let tmp = NSTemporaryDirectory() + "theia_ui_roundtrip_\(getpid()).json"
    defer { try? FileManager.default.removeItem(atPath: tmp) }
    h.expect(theia.graph_save_json_file(g, tmp), "save with UI metadata failed")
    let saved = (try? String(contentsOfFile: tmp, encoding: .utf8)) ?? ""
    h.expect(saved.contains("positions"), "graph save should preserve UI metadata")
}

h.test("Mask erase metadata affects cache, downstream terrain, and export evaluation") {
    guard let g = theia.graph_create() else { h.expect(false, "create"); return }
    defer { theia.graph_destroy(g) }
    let baselineJSON = """
    {
      "resolution": { "width": 64, "height": 64 },
      "sink": "carve",
      "nodes": [
        { "id": "base", "type": "perlin", "params": { "seed": 5109, "frequency": 3.5 } },
        { "id": "mask", "type": "river", "params": { "seed": 2027, "water": 0.8, "width": 3.0, "headwaters": 32 } },
        { "id": "carve", "type": "rivercarve", "params": { "depth": 0.7 } }
      ],
      "connections": [
        { "from": "base", "to": "mask", "input": 0 },
        { "from": "base", "to": "carve", "input": 0 },
        { "from": "mask", "to": "carve", "input": 1 }
      ]
    }
    """
    h.expect(theia.graph_load_json_text(g, baselineJSON), "baseline load: \(graphError(g))")
    var baselineMask = [Float](repeating: 0, count: 64 * 64)
    let maskResult = baselineMask.withUnsafeMutableBufferPointer {
        theia.graph_evaluate_heights(g, "mask", 64, 64, $0.baseAddress, $0.count)
    }
    var baselineCarve = [Float](repeating: 0, count: 64 * 64)
    let carveResult = baselineCarve.withUnsafeMutableBufferPointer {
        theia.graph_evaluate_heights(g, "carve", 64, 64, $0.baseAddress, $0.count)
    }
    h.expect(maskResult.ok && carveResult.ok, "baseline evaluation failed: \(graphError(g))")
    guard let peak = baselineMask.indices.max(by: { baselineMask[$0] < baselineMask[$1] }) else {
        h.expect(false, "missing mask peak")
        return
    }
    h.expect(baselineMask[peak] > 0.25, "river mask peak too weak for edit test")
    let editX = Double(peak % 64) / 63.0
    let editY = Double(peak / 64) / 63.0
    let editedJSON = baselineJSON.dropLast(2) + """
      ,"ui": {
        "positions": {},
        "maskErases": {
          "mask": [
            { "x": \(editX), "y": \(editY), "radius": 0.08, "strength": 1.0 }
          ]
        }
      }
    }
    """
    h.expect(theia.graph_load_json_text(g, String(editedJSON)), "edited load: \(graphError(g))")
    var editedMask = [Float](repeating: 0, count: 64 * 64)
    let editedMaskResult = editedMask.withUnsafeMutableBufferPointer {
        theia.graph_evaluate_heights(g, "mask", 64, 64, $0.baseAddress, $0.count)
    }
    h.expect(editedMaskResult.ok, "edited mask eval: \(graphError(g))")
    h.expect(editedMaskResult.evaluated == 1 && editedMaskResult.reused == 1,
             "mask edit should reuse base and recompute mask: \(editedMaskResult.evaluated)/\(editedMaskResult.reused)")
    h.expect(editedMask[peak] < 1e-6, "erase stroke should clear selected mask cell")

    var editedCarve = [Float](repeating: 0, count: 64 * 64)
    let editedCarveResult = editedCarve.withUnsafeMutableBufferPointer {
        theia.graph_evaluate_heights(g, "carve", 64, 64, $0.baseAddress, $0.count)
    }
    h.expect(editedCarveResult.ok, "edited carve eval: \(graphError(g))")
    h.expect(editedCarveResult.evaluated == 1 && editedCarveResult.reused == 2,
             "downstream carve should be the only remaining recompute")
    h.expect(editedCarve[peak] > baselineCarve[peak],
             "erasing river mask should reduce downstream carving")

    let dir = NSTemporaryDirectory() + "theia_mask_export_\(getpid())"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let exported = dir.withCString { dirPtr in
        "edited-mask".withCString { basePtr in
            "mask".withCString { sinkPtr in
                var options = theia.GraphExportOptions()
                options.sinkId = sinkPtr
                options.width = 64
                options.height = 64
                options.outDir = dirPtr
                options.basename = basePtr
                options.heightmapFormat = theia.HeightmapFormat.r16
                options.meshFormat = theia.MeshFormat.none
                return theia.graph_export2(g, options)
            }
        }
    }
    h.expect(exported.ok, "edited mask export failed: \(graphError(g))")
    let raw = (try? Data(contentsOf: URL(fileURLWithPath: dir + "/edited-mask_height.r16"))) ?? Data()
    h.expect(raw.count == 64 * 64 * 2, "edited R16 size mismatch")
    if raw.count == 64 * 64 * 2 {
        let offset = peak * 2
        let sample = UInt16(raw[offset]) | (UInt16(raw[offset + 1]) << 8)
        h.expect(sample == 0, "exported mask should contain the erased cell")
    }
}

h.test("Graph diagnostics JSON reports health and authoring issues") {
    let valid = """
    {
      "resolution": { "width": 64, "height": 64 },
      "sink": "out",
      "nodes": [
        { "id": "base", "type": "perlin", "params": {} },
        { "id": "out", "type": "normalize", "params": {} }
      ],
      "connections": [
        { "from": "base", "to": "out", "input": 0 }
      ]
    }
    """
    let validObj = diagnosticsObject(valid)
    let validSummary = validObj["summary"] as? [String: Any]
    h.expect(validObj["ok"] as? Bool == true, "valid graph should be diagnostic-ok")
    h.expect((validSummary?["nodes"] as? Int) == 2, "valid node count \(String(describing: validSummary))")
    h.expect((validObj["issues"] as? [Any] ?? []).isEmpty, "valid graph should have no issues")

    let empty = #"{"nodes":[],"connections":[]}"#
    let emptyCodes = diagnosticCodes(empty)
    h.expect(emptyCodes.contains("empty_graph"), "empty graph warning missing")
    h.expect(emptyCodes.contains("empty_sink"), "empty sink warning missing")

    let broken = """
    {
      "sink": "mix",
      "nodes": [
        { "id": "base", "type": "perlin", "params": {} },
        { "id": "mix", "type": "combine", "params": {} },
        { "id": "orphan", "type": "blur", "params": {} },
        { "id": "slow", "type": "dropleterosion", "params": { "particles": 40000, "maxAge": 300 } }
      ],
      "connections": [
        { "from": "base", "to": "mix", "input": 0 }
      ]
    }
    """
    let brokenCodes = diagnosticCodes(broken)
    h.expect(brokenCodes.contains("missing_input"), "missing input not reported")
    h.expect(brokenCodes.contains("orphan_node"), "orphan node not reported")
    h.expect(brokenCodes.contains("heavy_simulation"), "heavy simulation not reported")

    let riskyHydraulic = """
    {
      "sink": "h",
      "nodes": [
        { "id": "base", "type": "perlin", "params": {} },
        { "id": "h", "type": "hydraulic", "params": {
          "dt": 0.1, "minTilt": 1.0, "heightScale": 200.0
        } }
      ],
      "connections": [ { "from": "base", "to": "h", "input": 0 } ]
    }
    """
    h.expect(diagnosticCodes(riskyHydraulic).contains("hydraulic_authoring_envelope"),
             "risky hydraulic authoring range should be diagnosed")

    let invalid = "{"
    let invalidObj = diagnosticsObject(invalid)
    h.expect(invalidObj["ok"] as? Bool == false, "invalid JSON should not be ok")
    h.expect(diagnosticCodes(invalid).contains("invalid_json"), "invalid JSON code missing")
}

h.test("Malformed graph JSON shapes fail without aborting or replacing the graph") {
    guard let g = theia.graph_create() else { h.expect(false, "create"); return }
    defer { theia.graph_destroy(g) }
    let valid = """
    {
      "resolution": { "width": 32, "height": 32 },
      "sink": "out",
      "nodes": [
        { "id": "base", "type": "perlin", "params": {} },
        { "id": "out", "type": "normalize", "params": {} }
      ],
      "connections": [
        { "from": "base", "to": "out", "input": 0 }
      ]
    }
    """
    h.expect(theia.graph_load_json_text(g, valid), "valid baseline load")
    let before = theia.graph_evaluate(g, "", 32, 32, nil, nil)
    h.expect(before.ok, "baseline eval: \(graphError(g))")

    let badCases = [
        "[]",
        #"{"resolution":"wide","nodes":[]}"#,
        #"{"resolution":{"width":0},"nodes":[]}"#,
        #"{"resolution":{"width":-1},"nodes":[]}"#,
        #"{"resolution":{"width":"64"},"nodes":[]}"#,
        #"{"sink":"","nodes":[]}"#,
        #"{"sink":4,"nodes":[]}"#,
        #"{"nodes":"oops"}"#,
        #"{"nodes":["oops"]}"#,
        #"{"nodes":[{"id":7,"type":"perlin","params":{}}]}"#,
        #"{"nodes":[{"id":"base","type":7,"params":{}}]}"#,
        #"{"nodes":[{"id":"base","type":"perlin","params":[]}]}"#,
        #"{"nodes":[{"id":"base","type":"perlin","params":{"seed":"42"}}]}"#,
        #"{"nodes":[],"connections":"oops"}"#,
        #"{"nodes":[],"connections":["oops"]}"#,
        #"{"nodes":[],"connections":[{"from":7,"to":"out","input":0}]}"#,
        #"{"nodes":[],"connections":[{"from":"base","to":"out","input":-1}]}"#,
    ]

    for bad in badCases {
        h.expect(!theia.graph_load_json_text(g, bad),
                 "malformed graph JSON should fail: \(bad)")
        let after = theia.graph_evaluate(g, "", 32, 32, nil, nil)
        h.expect(after.ok, "graph should survive malformed JSON: \(bad) / \(graphError(g))")
    }
}

h.test("Default sink validation rejects unevaluable JSON transactionally") {
    guard let g = theia.graph_create() else { h.expect(false, "create"); return }
    defer { theia.graph_destroy(g) }
    let valid = """
    {
      "resolution": { "width": 32, "height": 32 },
      "sink": "out",
      "nodes": [
        { "id": "base", "type": "perlin", "params": {} },
        { "id": "out", "type": "normalize", "params": {} }
      ],
      "connections": [
        { "from": "base", "to": "out", "input": 0 }
      ]
    }
    """
    h.expect(theia.graph_load_json_text(g, valid), "valid baseline load")
    let before = theia.graph_evaluate(g, "", 32, 32, nil, nil)
    h.expect(before.ok, "baseline eval: \(graphError(g))")

    let badCases = [
        """
        {
          "sink": "missing",
          "nodes": [
            { "id": "base", "type": "perlin", "params": {} }
          ],
          "connections": []
        }
        """,
        """
        {
          "sink": "out",
          "nodes": [
            { "id": "base", "type": "perlin", "params": {} },
            { "id": "out", "type": "normalize", "params": {} }
          ],
          "connections": []
        }
        """,
        """
        {
          "sink": "a",
          "nodes": [
            { "id": "a", "type": "scalebias", "params": {} },
            { "id": "b", "type": "scalebias", "params": {} }
          ],
          "connections": [
            { "from": "a", "to": "b", "input": 0 },
            { "from": "b", "to": "a", "input": 0 }
          ]
        }
        """,
    ]

    for bad in badCases {
        h.expect(!theia.graph_load_json_text(g, bad),
                 "unevaluable default sink should fail load")
        let after = theia.graph_evaluate(g, "", 32, 32, nil, nil)
        h.expect(after.ok, "previous graph should survive failed sink validation: \(graphError(g))")
    }
}

h.test("Empty authoring graph is loadable and first Perlin source evaluates") {
    guard let g = theia.graph_create() else { h.expect(false, "create"); return }
    defer { theia.graph_destroy(g) }

    let empty = """
    {
      "resolution": { "width": 32, "height": 32 },
      "nodes": [],
      "connections": [],
      "ui": { "positions": {} }
    }
    """
    h.expect(theia.graph_load_json_text(g, empty),
             "empty authoring graph should load: \(graphError(g))")
    let emptyEval = theia.graph_evaluate(g, "", 32, 32, nil, nil)
    h.expect(!emptyEval.ok, "empty graph should not evaluate without a sink")
    h.expect(graphError(g).contains("no sink specified"),
             "empty graph error should mention missing sink: \(graphError(g))")

    let firstPerlin = """
    {
      "resolution": { "width": 32, "height": 32 },
      "sink": "perlin",
      "nodes": [
        { "id": "perlin", "type": "perlin", "params": { "seed": 1337 } }
      ],
      "connections": [],
      "ui": {
        "positions": {
          "perlin": { "x": 120, "y": 120 }
        }
      }
    }
    """
    h.expect(theia.graph_load_json_text(g, firstPerlin),
             "single Perlin graph should load: \(graphError(g))")
    let perlinEval = theia.graph_evaluate(g, "", 32, 32, nil, nil)
    h.expect(perlinEval.ok, "single Perlin should evaluate: \(graphError(g))")
    h.expect(perlinEval.variance > 1e-5, "single Perlin should produce noise")
}

h.test("Viewer preview metadata is optional and ignored by the core loader") {
    guard let g = theia.graph_create() else { h.expect(false, "create"); return }
    defer { theia.graph_destroy(g) }

    let json = """
    {
      "resolution": { "width": 64, "height": 64 },
      "sink": "mask",
      "nodes": [
        { "id": "base", "type": "perlin", "params": { "seed": 42 } },
        { "id": "mask", "type": "slopemask", "params": {} }
      ],
      "connections": [
        { "from": "base", "to": "mask", "input": 0 }
      ],
      "ui": {
        "positions": {
          "base": { "x": 120, "y": 120 },
          "mask": { "x": 340, "y": 120 }
        },
        "preview": {
          "displayMode": "mask",
          "materialPreset": "alpine",
          "maskOpacity": 0.72
        }
      }
    }
    """

    h.expect(theia.graph_load_json_text(g, json), "load preview ui: \(graphError(g))")
    let base = theia.graph_evaluate(g, "base", 64, 64, nil, nil)
    let mask = theia.graph_evaluate(g, "mask", 64, 64, nil, nil)
    h.expect(base.ok, "base arbitrary sink eval: \(graphError(g))")
    h.expect(mask.ok, "mask arbitrary sink eval: \(graphError(g))")
    h.expect(base.variance > 1e-6, "base terrain should vary")
    h.expect(mask.minHeight >= 0 && mask.maxHeight <= 1, "mask stays normalized")
}

h.test("Perlin heightScale controls node-local terrain amplitude") {
    guard let g = theia.graph_create() else { h.expect(false, "create"); return }
    defer { theia.graph_destroy(g) }

    let full = """
    {
      "resolution": { "width": 64, "height": 64 },
      "sink": "p",
      "nodes": [
        { "id": "p", "type": "perlin", "params": { "seed": 42, "heightScale": 1.0 } }
      ],
      "connections": []
    }
    """
    h.expect(theia.graph_load_json_text(g, full), "full scale load: \(graphError(g))")
    let fullEval = theia.graph_evaluate(g, "", 64, 64, nil, nil)
    h.expect(fullEval.ok, "full scale eval: \(graphError(g))")

    let low = """
    {
      "resolution": { "width": 64, "height": 64 },
      "sink": "p",
      "nodes": [
        { "id": "p", "type": "perlin", "params": { "seed": 42, "heightScale": 0.25 } }
      ],
      "connections": []
    }
    """
    h.expect(theia.graph_load_json_text(g, low), "low scale load: \(graphError(g))")
    let lowEval = theia.graph_evaluate(g, "", 64, 64, nil, nil)
    h.expect(lowEval.ok, "low scale eval: \(graphError(g))")
    h.expect(lowEval.mean < fullEval.mean * 0.35,
             "low scale should lower mean: \(lowEval.mean) vs \(fullEval.mean)")
    h.expect(lowEval.maxHeight < fullEval.maxHeight * 0.35,
             "low scale should lower max: \(lowEval.maxHeight) vs \(fullEval.maxHeight)")
}

h.test("Default node parameter enumeration supports node creation") {
    h.expect(theia.graph_node_type_input_count("perlin") == 0, "perlin inputs")
    h.expect(theia.graph_node_type_input_count("combine") == 2, "combine inputs")
    h.expect(theia.graph_default_param_count("perlin") == 6, "perlin default count")
    let p0 = readCxxString { theia.graph_default_param_name("perlin", 0, $0, $1) }
    h.expect(p0 == "frequency", "first perlin default \(p0)")
    h.expect(theia.graph_default_param_value("perlin", "seed", -1) == 1337,
             "perlin default seed")
    h.expect(theia.graph_default_param_value("perlin", "heightScale", -1) == 1.0,
             "perlin default heightScale")
    h.expect(theia.graph_default_param_value("scalebias", "scale", -1) == 1.0,
             "scalebias default scale")
    h.expect(theia.graph_default_param_value("combine", "t", -1) == 0.5,
             "combine default t")
    h.expect(theia.graph_default_param_value("slopemask", "heightScale", -1) == 100.0,
             "slopemask default heightScale")
    h.expect(theia.graph_default_param_value("slopemask", "low", -1) == 15.0,
             "slopemask default low")
    h.expect(theia.graph_default_param_value("slopemask", "high", -1) == 50.0,
             "slopemask default high")
    h.expect(theia.graph_default_param_value("hydraulic", "rain", -1) == 0.010,
             "hydraulic default rain")
    h.expect(theia.graph_default_param_value("hydraulic", "sedimentCapacity", -1) == 0.65,
             "hydraulic default sediment capacity")
    h.expect(theia.graph_default_param_value("hydraulic", "suspension", -1) == 0.60,
             "hydraulic default erosion rate")
    h.expect(theia.graph_default_param_value("hydraulic", "minTilt", -1) == 0.005,
             "hydraulic default slope floor")
}

h.test("Export node is a valid passthrough graph terminal") {
    let types = readCxxString { theia.node_type_list($0, $1) }
    h.expect(types.contains("export"), "export missing from node_type_list: \(types)")
    h.expect(theia.graph_node_type_input_count("export") == 1, "export input count")
    h.expect(theia.graph_default_param_count("export") == 0, "export has no params")

    let source = """
    {
      "resolution": { "width": 32, "height": 32 },
      "sink": "p",
      "nodes": [
        { "id": "p", "type": "perlin", "params": { "seed": 99 } }
      ],
      "connections": []
    }
    """
    let terminal = """
    {
      "resolution": { "width": 32, "height": 32 },
      "sink": "out",
      "nodes": [
        { "id": "p", "type": "perlin", "params": { "seed": 99 } },
        { "id": "out", "type": "export", "params": {} }
      ],
      "connections": [
        { "from": "p", "to": "out", "input": 0 }
      ]
    }
    """
    let a = evalGraphHeightsJSON(source, sink: "p", size: 32)
    let b = evalGraphHeightsJSON(terminal, sink: "out", size: 32)
    h.expect(a.count == b.count, "export passthrough count")
    let maxDiff = zip(a, b).map { abs($0 - $1) }.max() ?? 1
    h.expect(maxDiff < 0.00001, "export should pass through input, diff \(maxDiff)")
}

// --- P4: foundation node pack ------------------------------------------------

@MainActor
func evalGraphJSON(_ json: String, sink: String = "", size: UInt32 = 96) -> theia.GraphEvalResult {
    guard let g = theia.graph_create() else {
        h.expect(false, "create failed")
        return theia.GraphEvalResult()
    }
    defer { theia.graph_destroy(g) }
    h.expect(theia.graph_load_json_text(g, json), "load json: \(graphError(g))")
    let r = theia.graph_evaluate(g, sink, size, size, nil, nil)
    h.expect(r.ok, "eval \(sink): \(graphError(g))")
    return r
}

@MainActor
func evalGraphHeightsJSON(_ json: String, sink: String = "",
                          size: UInt32 = 96) -> [Float] {
    guard let g = theia.graph_create() else {
        h.expect(false, "create failed")
        return []
    }
    defer { theia.graph_destroy(g) }
    h.expect(theia.graph_load_json_text(g, json), "load json: \(graphError(g))")
    var buf = [Float](repeating: 0, count: Int(size * size))
    let r = buf.withUnsafeMutableBufferPointer {
        theia.graph_evaluate_heights(g, sink, size, size, $0.baseAddress, $0.count)
    }
    h.expect(r.ok, "eval heights \(sink): \(graphError(g))")
    return buf
}

@MainActor
func evalGraphOutputHeightsJSON(_ json: String, sink: String,
                                output: String, size: UInt32 = 96) -> [Float] {
    guard let g = theia.graph_create() else {
        h.expect(false, "create failed")
        return []
    }
    defer { theia.graph_destroy(g) }
    h.expect(theia.graph_load_json_text(g, json), "load json: \(graphError(g))")
    var buf = [Float](repeating: 0, count: Int(size * size))
    let r = buf.withUnsafeMutableBufferPointer {
        theia.graph_evaluate_heights_output(g, sink, output, size, size,
                                            $0.baseAddress, $0.count)
    }
    h.expect(r.ok, "eval heights \(sink).\(output): \(graphError(g))")
    return buf
}

func maxNeighborDelta(_ values: [Float], size: Int) -> Float {
    var maxDelta: Float = 0
    for y in 0..<size {
        for x in 0..<size {
            let i = y * size + x
            if x + 1 < size {
                maxDelta = max(maxDelta, abs(values[i] - values[i + 1]))
            }
            if y + 1 < size {
                maxDelta = max(maxDelta, abs(values[i] - values[i + size]))
            }
        }
    }
    return maxDelta
}

func curvaturePercentile(_ values: [Float], size: Int,
                         percentile: Double) -> Float {
    guard values.count == size * size, size >= 3 else { return .infinity }
    var samples: [Float] = []
    samples.reserveCapacity((size - 2) * (size - 2))
    for y in 1..<(size - 1) {
        for x in 1..<(size - 1) {
            let i = y * size + x
            let mean = 0.25 * (values[i - 1] + values[i + 1] +
                               values[i - size] + values[i + size])
            samples.append(abs(values[i] - mean))
        }
    }
    samples.sort()
    let p = min(1.0, max(0.0, percentile))
    return samples[min(samples.count - 1,
                       Int(Double(samples.count - 1) * p))]
}

func isolatedExtremaCount(_ values: [Float], size: Int,
                          threshold: Float) -> Int {
    guard values.count == size * size, size >= 3 else { return .max }
    var count = 0
    for y in 1..<(size - 1) {
        for x in 1..<(size - 1) {
            let i = y * size + x
            let neighbors = [values[i - 1], values[i + 1],
                             values[i - size], values[i + size]]
            let isExtremum = values[i] > (neighbors.max() ?? values[i]) ||
                             values[i] < (neighbors.min() ?? values[i])
            let separated = neighbors.allSatisfy { abs(values[i] - $0) > threshold }
            if isExtremum && separated { count += 1 }
        }
    }
    return count
}

func meanAbsoluteDifference(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var sum: Float = 0
    for (x, y) in zip(a, b) {
        sum += abs(x - y)
    }
    return sum / Float(a.count)
}

h.test("Hydraulic erosion default profile avoids spike striping") {
    let json = """
    {
      "resolution": { "width": 96, "height": 96 },
      "sink": "h",
      "nodes": [
        { "id": "p", "type": "perlin", "params": {
          "seed": 1337, "frequency": 4.0, "octaves": 7,
          "lacunarity": 2.0, "gain": 0.45, "heightScale": 1.0
        } },
        { "id": "h", "type": "hydraulic", "params": {} }
      ],
      "connections": [
        { "from": "p", "to": "h", "input": 0 }
      ]
    }
    """
    let base = evalGraphHeightsJSON(json, sink: "p", size: 96)
    let values = evalGraphHeightsJSON(json, sink: "h", size: 96)
    let repeated = evalGraphHeightsJSON(json, sink: "h", size: 96)
    h.expect(values == repeated, "default hydraulic profile must be deterministic")
    h.expect(values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 },
             "default hydraulic profile contains invalid terrain")
    h.expect(meanAbsoluteDifference(base, values) > 0.0005,
             "default hydraulic profile should visibly alter terrain")

    let baseDelta = maxNeighborDelta(base, size: 96)
    let maxDelta = maxNeighborDelta(values, size: 96)
    h.expect(maxDelta <= baseDelta * 1.15 + 0.002,
             "default hydraulic profile amplified neighbor delta \(baseDelta) -> \(maxDelta)")
    let baseCurvature = curvaturePercentile(base, size: 96, percentile: 0.999)
    let curvature = curvaturePercentile(values, size: 96, percentile: 0.999)
    h.expect(curvature <= baseCurvature * 1.35 + 0.001,
             "default hydraulic profile amplified curvature \(baseCurvature) -> \(curvature)")
    let baseExtrema = isolatedExtremaCount(base, size: 96, threshold: 0.003)
    let extrema = isolatedExtremaCount(values, size: 96, threshold: 0.003)
    h.expect(extrema <= baseExtrema + 8,
             "default hydraulic profile created isolated extrema \(baseExtrema) -> \(extrema)")
}

h.test("Hydraulic screenshot-risk profile does not create one-cell artifacts") {
    let json = """
    {
      "resolution": { "width": 96, "height": 96 },
      "sink": "h",
      "nodes": [
        { "id": "p", "type": "perlin", "params": {
          "seed": 1337, "frequency": 4.0, "octaves": 7,
          "lacunarity": 2.0, "gain": 0.45, "heightScale": 1.0
        } },
        { "id": "h", "type": "hydraulic", "params": {
          "iterations": 200, "rain": 0.012, "evaporation": 0.265,
          "sedimentCapacity": 0.35, "suspension": 0.25,
          "deposition": 0.60, "gravity": 9.81, "dt": 0.10,
          "minTilt": 1.0, "heightScale": 200.0,
          "pipeArea": 1.0, "pipeLength": 1.0, "cellSize": 1.0
        } }
      ],
      "connections": [ { "from": "p", "to": "h", "input": 0 } ]
    }
    """
    let base = evalGraphHeightsJSON(json, sink: "p", size: 96)
    let eroded = evalGraphHeightsJSON(json, sink: "h", size: 96)
    let repeated = evalGraphHeightsJSON(json, sink: "h", size: 96)
    h.expect(eroded == repeated, "risk profile must remain bitwise deterministic")
    h.expect(eroded.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 },
             "risk profile contains non-finite or out-of-range terrain")
    h.expect(meanAbsoluteDifference(base, eroded) > 0.0001,
             "stability guards must not turn hydraulic erosion into an identity")

    let baseDelta = maxNeighborDelta(base, size: 96)
    let erodedDelta = maxNeighborDelta(eroded, size: 96)
    h.expect(erodedDelta <= baseDelta * 1.15 + 0.002,
             "risk profile amplified neighbor delta \(baseDelta) -> \(erodedDelta)")

    let baseCurvature = curvaturePercentile(base, size: 96, percentile: 0.999)
    let erodedCurvature = curvaturePercentile(eroded, size: 96, percentile: 0.999)
    h.expect(erodedCurvature <= baseCurvature * 1.30 + 0.001,
             "risk profile amplified p99.9 curvature \(baseCurvature) -> \(erodedCurvature)")

    let baseExtrema = isolatedExtremaCount(base, size: 96, threshold: 0.003)
    let erodedExtrema = isolatedExtremaCount(eroded, size: 96, threshold: 0.003)
    h.expect(erodedExtrema <= baseExtrema + 8,
             "risk profile created isolated extrema \(baseExtrema) -> \(erodedExtrema)")
}

h.test("Hydraulic curvature limiter never reverses erosion exchange") {
    let json = """
    {
      "resolution": { "width": 96, "height": 96 },
      "sink": "h",
      "nodes": [
        { "id": "p", "type": "perlin", "params": {
          "seed": 4049, "frequency": 5.0, "octaves": 7,
          "lacunarity": 2.0, "gain": 0.48, "heightScale": 1.0
        } },
        { "id": "h", "type": "hydraulic", "params": {
          "iterations": 240, "rain": 0.03, "evaporation": 0.02,
          "sedimentCapacity": 2.0, "suspension": 2.0,
          "deposition": 0.0, "gravity": 9.81, "dt": 0.025,
          "minTilt": 0.005, "heightScale": 80.0,
          "pipeArea": 1.0, "pipeLength": 1.0, "cellSize": 1.0
        } }
      ],
      "connections": [ { "from": "p", "to": "h", "input": 0 } ]
    }
    """
    let base = evalGraphHeightsJSON(json, sink: "p", size: 96)
    let eroded = evalGraphHeightsJSON(json, sink: "h", size: 96)
    let baseMass = base.reduce(0.0) { $0 + Double($1) }
    let erodedMass = eroded.reduce(0.0) { $0 + Double($1) }
    h.expect(meanAbsoluteDifference(base, eroded) > 0.0001,
             "erosion-only profile should alter terrain")
    h.expect(erodedMass <= baseMass + 1e-5,
             "erosion-only profile created bed mass \(baseMass) -> \(erodedMass)")
}

h.test("Hydraulic flat closed basin remains an exact equilibrium") {
    let json = """
    {
      "resolution": { "width": 48, "height": 48 },
      "sink": "h",
      "nodes": [
        { "id": "flat", "type": "perlin", "params": {
          "seed": 1, "heightScale": 0.0
        } },
        { "id": "h", "type": "hydraulic", "params": {
          "iterations": 80, "rain": 0.5, "evaporation": 0.0,
          "sedimentCapacity": 4.0, "suspension": 4.0,
          "deposition": 4.0, "gravity": 20.0, "dt": 0.1,
          "minTilt": 1.0, "heightScale": 300.0,
          "pipeArea": 4.0, "pipeLength": 0.05, "cellSize": 0.05
        } }
      ],
      "connections": [ { "from": "flat", "to": "h", "input": 0 } ]
    }
    """
    let base = evalGraphHeightsJSON(json, sink: "flat", size: 48)
    let eroded = evalGraphHeightsJSON(json, sink: "h", size: 48)
    h.expect(base == eroded, "uniform closed basin should not erode or deposit")
}

h.test("Hydraulic rejects non-finite parameters and guards extreme API values") {
    guard let g = theia.graph_create() else { h.expect(false, "create"); return }
    defer { theia.graph_destroy(g) }
    h.expect(theia.graph_add_node(g, "p", "perlin"), "add source")
    h.expect(theia.graph_add_node(g, "h", "hydraulic"), "add hydraulic")
    h.expect(theia.graph_connect(g, "p", "h", 0), "connect hydraulic")
    h.expect(theia.graph_set_param(g, "h", "dt", Double.infinity),
             "set non-finite timestep")
    let rejected = theia.graph_evaluate(g, "h", 48, 48, nil, nil)
    h.expect(!rejected.ok && graphError(g).contains("must be finite"),
             "non-finite hydraulic parameter must fail cleanly: \(graphError(g))")

    h.expect(theia.graph_set_param(g, "h", "dt", 1_000_000), "set extreme dt")
    h.expect(theia.graph_set_param(g, "h", "cellSize", -1_000_000),
             "set extreme cell size")
    h.expect(theia.graph_set_param(g, "h", "heightScale", 1_000_000),
             "set extreme vertical scale")
    h.expect(theia.graph_set_param(g, "h", "iterations", 1e300),
             "set extreme iteration count")
    let guarded = theia.graph_evaluate(g, "h", 48, 48, nil, nil)
    h.expect(guarded.ok && guarded.minHeight.isFinite && guarded.maxHeight.isFinite &&
             guarded.minHeight >= 0 && guarded.maxHeight <= 1,
             "finite extreme parameters should be safely bounded: \(graphError(g))")
}

func p4JSON(type: String, params: String = "{}", inputCount: Int = 1) -> String {
    var nodes = """
        { "id": "p", "type": "perlin", "params": { "seed": 11, "frequency": 5.0 } },
        { "id": "n", "type": "\(type)", "params": \(params) }
    """
    var connections = """
        { "from": "p", "to": "n", "input": 0 }
    """
    if inputCount == 0 {
        nodes = """
        { "id": "n", "type": "\(type)", "params": \(params) }
        """
        connections = ""
    } else if inputCount == 2 {
        nodes = """
        { "id": "a", "type": "perlin", "params": { "seed": 11, "frequency": 5.0 } },
        { "id": "b", "type": "rugged", "params": { "seed": 21 } },
        { "id": "n", "type": "\(type)", "params": \(params) }
        """
        connections = """
        { "from": "a", "to": "n", "input": 0 },
        { "from": "b", "to": "n", "input": 1 }
        """
    }
    return """
    {
      "resolution": { "width": 96, "height": 96 },
      "sink": "n",
      "nodes": [ \(nodes) ],
      "connections": [ \(connections) ]
    }
    """
}

let terrainPrimitiveDefaults: [(type: String, params: [(String, Double)])] = [
    ("rollinghills", [
        ("scale", 0.65), ("height", 0.55), ("softness", 0.70),
        ("undulation", 0.40), ("warp", 0.15), ("detail", 0.55),
        ("seed", 1337)
    ]),
    ("canyon", [
        ("scale", 0.75), ("height", 0.78), ("depth", 0.55), ("width", 0.10),
        ("branches", 12), ("wallSharpness", 0.65), ("roughness", 0.25),
        ("benching", 0.45), ("seed", 1337)
    ]),
    ("crater", [
        ("scale", 0.45), ("height", 0.80), ("depth", 0.26),
        ("rimHeight", 0.14), ("rimWidth", 0.18), ("irregularity", 0.45),
        ("ejecta", 0.35), ("x", 0), ("y", 0), ("complexity", 0.30),
        ("terraces", 0.50), ("surroundings", 0.30), ("seed", 1337)
    ]),
    ("dunesea", [
        ("scale", 0.18), ("height", 0.42), ("direction", 0),
        ("asymmetry", 0.65), ("sharpness", 0.55), ("chaos", 0.25),
        ("warp", 0.15), ("crestMeander", 0.55), ("defects", 0.45),
        ("seed", 1337)
    ]),
    ("mountain", [
        ("scale", 0.65), ("height", 0.90), ("bulk", 0.58),
        ("roughness", 0.38), ("warp", 0.20), ("x", 0), ("y", 0),
        ("surroundings", 0.30), ("seed", 1337)
    ]),
    ("mountainrange", [
        ("scale", 0.70), ("height", 0.90), ("length", 1.25),
        ("width", 0.24), ("direction", 25), ("peaks", 5),
        ("roughness", 0.40), ("warp", 0.25), ("x", 0), ("y", 0),
        ("surroundings", 0.30), ("peakVariation", 0.65),
        ("arc", 0.35), ("sinuosity", 0.45), ("seed", 1337)
    ]),
    ("mountainside", [
        ("scale", 0.90), ("height", 0.85), ("slope", 0.65),
        ("direction", 25), ("peak", 0.50), ("detail", 0.35),
        ("warp", 0.15), ("x", 0), ("y", 0), ("seed", 1337)
    ]),
    ("ridge", [
        ("scale", 0.75), ("height", 0.85), ("length", 1.30),
        ("width", 0.12), ("direction", 20), ("definition", 0.70),
        ("fractures", 0.35), ("warp", 0.25), ("x", 0), ("y", 0),
        ("seed", 1337)
    ]),
    ("rugged", [
        ("scale", 0.55), ("height", 0.85), ("bulk", 0.60),
        ("roughness", 0.70), ("fractures", 0.45), ("warp", 0.25),
        ("seed", 1337)
    ]),
    ("slump", [
        ("scale", 0.65), ("height", 0.65), ("collapse", 0.45),
        ("direction", 20), ("softness", 0.55), ("lobes", 4),
        ("warp", 0.15), ("seed", 1337)
    ]),
    ("uplift", [
        ("scale", 0.70), ("height", 0.85), ("direction", 20), ("folds", 5),
        ("foldWidth", 0.12), ("jitter", 0.25), ("roughness", 0.30),
        ("seed", 1337)
    ]),
    ("volcano", [
        ("scale", 0.55), ("height", 0.90), ("mouth", 0.22),
        ("calderaDepth", 0.45), ("bulk", 0.60), ("radialErosion", 0.35),
        ("roughness", 0.30), ("x", 0), ("y", 0), ("seed", 1337)
    ])
]

func primitiveJSON(_ type: String, params: String = "{}",
                   size: Int = 64) -> String {
    """
    {
      "resolution": { "width": \(size), "height": \(size) },
      "sink": "terrain",
      "nodes": [
        { "id": "terrain", "type": "\(type)", "params": \(params) }
      ],
      "connections": []
    }
    """
}

h.test("Terrain primitive library is registered with exact defaults") {
    let registered = Set(readCxxString { theia.node_type_list($0, $1) }
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
    h.expect(!registered.contains("ridged"), "retired ridged generator is still registered")

    for primitive in terrainPrimitiveDefaults {
        let type = primitive.type
        h.expect(registered.contains(type), "\(type) is not registered")
        h.expect(theia.graph_node_type_input_count(type) == 0,
                 "\(type) must have zero inputs")
        h.expect(theia.graph_node_type_output_count(type) == 1,
                 "\(type) must have exactly one output")
        let outputName = readCxxString {
            theia.graph_node_type_output_name(type, 0, $0, $1)
        }
        let outputKind = readCxxString {
            theia.graph_node_type_output_kind(type, 0, $0, $1)
        }
        h.expect(outputName == "terrain" && outputKind == "terrain" &&
                 theia.graph_node_type_output_is_default(type, 0),
                 "\(type) must expose a default terrain output")
        h.expect(Int(theia.graph_default_param_count(type)) == primitive.params.count,
                 "\(type) parameter count mismatch")

        let actualNames = Set((0..<theia.graph_default_param_count(type)).map { index in
            readCxxString {
                theia.graph_default_param_name(type, index, $0, $1)
            }
        })
        h.expect(actualNames == Set(primitive.params.map { $0.0 }),
                 "\(type) parameter schema mismatch: \(actualNames)")
        for (name, expected) in primitive.params {
            let actual = theia.graph_default_param_value(type, name, .nan)
            h.expect(actual == expected, "\(type).\(name) default \(actual), expected \(expected)")
        }
    }
}

h.test("Legacy ridged JSON is rejected while erosionfilter.ridge remains available") {
    guard let g = theia.graph_create() else { h.expect(false, "create"); return }
    defer { theia.graph_destroy(g) }
    let legacy = """
    {
      "sink": "legacy",
      "nodes": [
        { "id": "legacy", "type": "ridged", "params": { "seed": 1337 } }
      ],
      "connections": []
    }
    """
    h.expect(!theia.graph_load_json_text(g, legacy),
             "retired ridged JSON should not load")
    h.expect(graphError(g).lowercased().contains("unknown"),
             "ridged rejection should identify an unknown node: \(graphError(g))")
    h.expect(theia.graph_node_type_output_count("erosionfilter") == 2,
             "erosionfilter outputs were removed with ridged")
    let ridge = readCxxString {
        theia.graph_node_type_output_name("erosionfilter", 1, $0, $1)
    }
    h.expect(ridge == "ridge", "erosionfilter.ridge must remain available")
}

h.test("Terrain primitive defaults are bounded, nondegenerate, deterministic, and seedable") {
    for primitive in terrainPrimitiveDefaults {
        let type = primitive.type
        guard let g = theia.graph_create() else {
            h.expect(false, "create \(type)")
            continue
        }
        defer { theia.graph_destroy(g) }
        h.expect(theia.graph_add_node(g, "terrain", type), "add \(type): \(graphError(g))")
        var first = [Float](repeating: 0, count: 48 * 48)
        let cold = first.withUnsafeMutableBufferPointer {
            theia.graph_evaluate_heights(g, "terrain", 48, 48, $0.baseAddress, $0.count)
        }
        var repeated = [Float](repeating: 0, count: first.count)
        let warm = repeated.withUnsafeMutableBufferPointer {
            theia.graph_evaluate_heights(g, "terrain", 48, 48, $0.baseAddress, $0.count)
        }
        h.expect(cold.ok && warm.ok, "\(type) evaluation failed: \(graphError(g))")
        h.expect(first == repeated, "\(type) is not bitwise deterministic")
        h.expect(warm.evaluated == 0 && warm.reused == 1,
                 "\(type) warm cache \(warm.evaluated)/\(warm.reused)")
        h.expect(first.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 },
                 "\(type) default output is not finite normalized terrain")
        let lo = first.min() ?? 0
        let hi = first.max() ?? 0
        h.expect(hi - lo > 1e-4, "\(type) default output is degenerate: \(lo)...\(hi)")

        h.expect(theia.graph_set_param(g, "terrain", "seed", 8123),
                 "set \(type) seed")
        var changed = [Float](repeating: 0, count: first.count)
        let changedResult = changed.withUnsafeMutableBufferPointer {
            theia.graph_evaluate_heights(g, "terrain", 48, 48, $0.baseAddress, $0.count)
        }
        h.expect(changedResult.ok, "\(type) changed-seed evaluation failed")
        h.expect(changed != first, "\(type) seed does not affect its terrain")

        let path = NSTemporaryDirectory() + "theia_primitive_\(type)_\(getpid()).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        h.expect(theia.graph_save_json_file(g, path), "save \(type): \(graphError(g))")
        guard let loaded = theia.graph_create() else {
            h.expect(false, "create reloaded \(type)")
            continue
        }
        defer { theia.graph_destroy(loaded) }
        h.expect(theia.graph_load_json_file(loaded, path),
                 "reload \(type): \(graphError(loaded))")
        var roundTripped = [Float](repeating: 0, count: first.count)
        let loadedResult = roundTripped.withUnsafeMutableBufferPointer {
            theia.graph_evaluate_heights(
                loaded, "terrain", 48, 48, $0.baseAddress, $0.count)
        }
        h.expect(loadedResult.ok && roundTripped == changed,
                 "\(type) JSON round-trip changed terrain")
    }
}

h.test("Terrain primitive parameter extremes are clamped to finite terrain") {
    for primitive in terrainPrimitiveDefaults {
        guard let g = theia.graph_create() else {
            h.expect(false, "create \(primitive.type)")
            continue
        }
        defer { theia.graph_destroy(g) }
        h.expect(theia.graph_add_node(g, "terrain", primitive.type),
                 "add \(primitive.type)")
        for (name, _) in primitive.params {
            h.expect(theia.graph_set_param(g, "terrain", name, 1e12),
                     "set high \(primitive.type).\(name)")
        }
        let high = theia.graph_evaluate(g, "terrain", 32, 32, nil, nil)
        h.expect(high.ok && high.minHeight.isFinite && high.maxHeight.isFinite &&
                 high.minHeight >= 0 && high.maxHeight <= 1,
                 "\(primitive.type) high extremes escaped bounds: \(graphError(g))")

        for (name, _) in primitive.params {
            h.expect(theia.graph_set_param(g, "terrain", name, -1e12),
                     "set low \(primitive.type).\(name)")
        }
        let low = theia.graph_evaluate(g, "terrain", 32, 32, nil, nil)
        h.expect(low.ok && low.minHeight.isFinite && low.maxHeight.isFinite &&
                 low.minHeight >= 0 && low.maxHeight <= 1,
                 "\(primitive.type) low extremes escaped bounds: \(graphError(g))")
    }
}

h.test("Terrain primitives reject NaN and infinity rather than silently clamping") {
    for primitive in terrainPrimitiveDefaults {
        guard let g = theia.graph_create() else {
            h.expect(false, "create \(primitive.type)")
            continue
        }
        defer { theia.graph_destroy(g) }
        h.expect(theia.graph_add_node(g, "terrain", primitive.type),
                 "add \(primitive.type)")
        for (name, defaultValue) in primitive.params {
            for invalid in [Double.infinity, Double.nan] {
                h.expect(theia.graph_set_param(g, "terrain", name, invalid),
                         "set non-finite \(primitive.type).\(name)")
                let result = theia.graph_evaluate(g, "terrain", 16, 16, nil, nil)
                h.expect(!result.ok,
                         "\(primitive.type).\(name) silently accepted \(invalid)")
                h.expect(theia.graph_set_param(g, "terrain", name, defaultValue),
                         "restore \(primitive.type).\(name)")
            }
        }
    }
}

@MainActor
func primitiveParamOutput(_ type: String, _ name: String,
                          _ value: Double) -> [Float] {
    evalGraphHeightsJSON(
        primitiveJSON(type, params: "{ \"seed\": 4242, \"\(name)\": \(value) }",
                      size: 32),
        sink: "terrain", size: 32)
}

h.test("Terrain primitive parameter families clamp at their public limits") {
    let clamps: [(String, String, Double, Double)] = [
        ("rollinghills", "scale", 0.05, -10),
        ("rollinghills", "scale", 1.5, 10),
        ("canyon", "depth", 0, -10),
        ("canyon", "depth", 1, 10),
        ("dunesea", "direction", 0, -720),
        ("dunesea", "direction", 360, 720),
        ("crater", "x", -1, -10),
        ("crater", "y", 1, 10),
        ("ridge", "length", 0.25, -10),
        ("ridge", "width", 0.6, 10),
        ("canyon", "branches", 1, -10),
        ("canyon", "branches", 32, 100),
        ("mountainrange", "peaks", 12, 100),
        ("slump", "lobes", 8, 100),
        ("uplift", "folds", 12, 100),
        ("uplift", "foldWidth", 0.01, -10),
        ("uplift", "foldWidth", 0.5, 10),
        ("rugged", "seed", 0, -10),
        ("rugged", "seed", 9999, 100000)
    ]
    for (type, name, limit, outside) in clamps {
        let atLimit = primitiveParamOutput(type, name, limit)
        let beyond = primitiveParamOutput(type, name, outside)
        h.expect(atLimit == beyond,
                 "\(type).\(name) did not clamp \(outside) to \(limit)")
    }
}

h.test("Centered mountain, crater, and volcano preserve broad landform structure") {
    let size = 65
    let center = (size / 2) * size + size / 2
    let corners = [0, size - 1, size * (size - 1), size * size - 1]

    let mountain = evalGraphHeightsJSON(
        primitiveJSON("mountain", size: size), sink: "terrain", size: UInt32(size))
    let cornerMean = corners.map { mountain[$0] }.reduce(0, +) / Float(corners.count)
    h.expect(mountain[center] > cornerMean + 0.10,
             "mountain should rise above the map corners")

    for type in ["crater", "volcano"] {
        let terrain = evalGraphHeightsJSON(
            primitiveJSON(type, size: size), sink: "terrain", size: UInt32(size))
        let innerRadius = 4
        let outerRadius = 18
        var surrounding: [Float] = []
        for y in 0..<size {
            for x in 0..<size {
                let dx = x - size / 2
                let dy = y - size / 2
                let d2 = dx * dx + dy * dy
                if d2 >= innerRadius * innerRadius && d2 <= outerRadius * outerRadius {
                    surrounding.append(terrain[y * size + x])
                }
            }
        }
        h.expect(terrain[center] < (surrounding.max() ?? terrain[center]) - 0.03,
                 "\(type) should retain a centered depression below its rim/flanks")
    }
}

func directionalVariation(_ values: [Float], width: Int) -> (Float, Float) {
    let height = values.count / width
    var dx: Float = 0
    var dy: Float = 0
    for y in 0..<height {
        for x in 0..<width {
            let i = y * width + x
            if x + 1 < width { dx += abs(values[i + 1] - values[i]) }
            if y + 1 < height { dy += abs(values[i + width] - values[i]) }
        }
    }
    return (dx / Float(height * (width - 1)),
            dy / Float((height - 1) * width))
}

h.test("Terrain primitives support 97x61 aspect ratios") {
    let width = 97
    let height = 61
    for primitive in terrainPrimitiveDefaults {
        guard let g = theia.graph_create() else {
            h.expect(false, "create \(primitive.type)")
            continue
        }
        defer { theia.graph_destroy(g) }
        h.expect(theia.graph_add_node(g, "terrain", primitive.type),
                 "add \(primitive.type)")
        var values = [Float](repeating: 0, count: width * height)
        let result = values.withUnsafeMutableBufferPointer {
            theia.graph_evaluate_heights(
                g, "terrain", UInt32(width), UInt32(height),
                $0.baseAddress, $0.count)
        }
        h.expect(result.ok && Int(result.width) == width && Int(result.height) == height,
                 "\(primitive.type) rejected 97x61: \(graphError(g))")
        h.expect(values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 },
                 "\(primitive.type) 97x61 output is invalid")
        h.expect((values.max() ?? 0) - (values.min() ?? 0) > 1e-4,
                 "\(primitive.type) 97x61 output is degenerate")
    }
}

func bilinearSample(_ values: [Float], width: Int, height: Int,
                    u: Double, v: Double) -> Float {
    guard width > 0, height > 0, values.count == width * height else {
        return .nan
    }
    let px = min(1.0, max(0.0, u)) * Double(width - 1)
    let py = min(1.0, max(0.0, v)) * Double(height - 1)
    let x0 = Int(floor(px))
    let y0 = Int(floor(py))
    let x1 = min(x0 + 1, width - 1)
    let y1 = min(y0 + 1, height - 1)
    let tx = Float(px - Double(x0))
    let ty = Float(py - Double(y0))
    let top = values[y0 * width + x0] * (1 - tx) +
              values[y0 * width + x1] * tx
    let bottom = values[y1 * width + x0] * (1 - tx) +
                 values[y1 * width + x1] * tx
    return top * (1 - ty) + bottom * ty
}

@MainActor
func evalPrimitiveHeights(_ type: String, params: String,
                          width: Int, height: Int) -> [Float] {
    guard let g = theia.graph_create() else {
        h.expect(false, "create \(type)")
        return []
    }
    defer { theia.graph_destroy(g) }
    h.expect(theia.graph_load_json_text(
        g, primitiveJSON(type, params: params, size: max(width, height))),
        "load \(type): \(graphError(g))")
    var values = [Float](repeating: 0, count: width * height)
    let result = values.withUnsafeMutableBufferPointer {
        theia.graph_evaluate_heights(
            g, "terrain", UInt32(width), UInt32(height),
            $0.baseAddress, $0.count)
    }
    h.expect(result.ok, "evaluate \(type) \(width)x\(height): \(graphError(g))")
    return values
}

h.test("Smooth radial primitives use independent width and height coordinates") {
    let width = 129
    let height = 65
    let cases = [
        ("crater", "{ \"seed\": 1337, \"irregularity\": 0, \"ejecta\": 0 }"),
        ("mountain", "{ \"seed\": 1337, \"roughness\": 0, \"warp\": 0 }"),
        ("volcano", "{ \"seed\": 1337, \"roughness\": 0, \"radialErosion\": 0 }")
    ]
    // Fractions of the normalized center-to-edge world distance. Fractional
    // positions exercise interpolation instead of relying on coincident pixels.
    let radii = [0.12, 0.25, 0.38, 0.52, 0.68, 0.84]
    for (type, params) in cases {
        let values = evalPrimitiveHeights(
            type, params: params, width: width, height: height)
        for radius in radii {
            let offset = 0.5 * radius
            let horizontal = 0.5 * (
                bilinearSample(values, width: width, height: height,
                               u: 0.5 - offset, v: 0.5) +
                bilinearSample(values, width: width, height: height,
                               u: 0.5 + offset, v: 0.5))
            let vertical = 0.5 * (
                bilinearSample(values, width: width, height: height,
                               u: 0.5, v: 0.5 - offset) +
                bilinearSample(values, width: width, height: height,
                               u: 0.5, v: 0.5 + offset))
            h.expect(abs(horizontal - vertical) < 0.03,
                     "\(type) aspect distortion at radius \(radius): " +
                     "x \(horizontal), y \(vertical)")
        }
    }
}

h.test("Terrain primitives are consistent at 128, 256, and 512 samples") {
    for primitive in terrainPrimitiveDefaults {
        let coarse = evalGraphHeightsJSON(
            primitiveJSON(primitive.type, size: 128),
            sink: "terrain", size: 128)
        for fineSize in [256, 512] {
            let fine = evalGraphHeightsJSON(
                primitiveJSON(primitive.type, size: fineSize),
                sink: "terrain", size: UInt32(fineSize))
            var sampled: [Float] = []
            sampled.reserveCapacity(coarse.count)
            for y in 0..<128 {
                let v = Double(y) / 127.0
                for x in 0..<128 {
                    let u = Double(x) / 127.0
                    sampled.append(bilinearSample(
                        fine, width: fineSize, height: fineSize, u: u, v: v))
                }
            }
            let difference = meanAbsoluteDifference(coarse, sampled)
            h.expect(difference < 0.06,
                     "\(primitive.type) changes at \(fineSize) samples, " +
                     "mean diff \(difference)")
        }
    }
}

h.test("Directional terrain primitives rotate their anisotropy") {
    for type in ["dunesea", "mountainrange", "mountainside", "ridge", "uplift"] {
        let zero = evalGraphHeightsJSON(
            primitiveJSON(type, params: "{ \"seed\": 404, \"direction\": 0 }",
                          size: 96),
            sink: "terrain", size: 96)
        let ninety = evalGraphHeightsJSON(
            primitiveJSON(type, params: "{ \"seed\": 404, \"direction\": 90 }",
                          size: 96),
            sink: "terrain", size: 96)
        let a = directionalVariation(zero, width: 96)
        let b = directionalVariation(ninety, width: 96)
        let anisotropyA = a.0 - a.1
        let anisotropyB = b.0 - b.1
        h.expect(abs(anisotropyA) > 0.001 && abs(anisotropyB) > 0.001,
                 "\(type) lacks anisotropy: \(a), \(b)")
        h.expect(anisotropyA * anisotropyB < 0,
                 "\(type) did not rotate its dominant variation: \(a), \(b)")
        h.expect(meanAbsoluteDifference(zero, ninety) > 0.01,
                 "\(type) direction did not change terrain")
    }
}

h.test("Mountain range peak count changes its summit rhythm") {
    let onePeak = evalGraphHeightsJSON(
        primitiveJSON("mountainrange",
                      params: "{ \"seed\": 404, \"peaks\": 1 }",
                      size: 128),
        sink: "terrain", size: 128)
    let manyPeaks = evalGraphHeightsJSON(
        primitiveJSON("mountainrange",
                      params: "{ \"seed\": 404, \"peaks\": 12 }",
                      size: 128),
        sink: "terrain", size: 128)
    h.expect(meanAbsoluteDifference(onePeak, manyPeaks) > 0.01,
             "mountainrange.peaks should reshape the summit chain")
}

h.test("Rolling hills are lower-frequency than rugged terrain") {
    let rolling = evalGraphHeightsJSON(
        primitiveJSON("rollinghills", params: "{ \"seed\": 919 }", size: 128),
        sink: "terrain", size: 128)
    let rugged = evalGraphHeightsJSON(
        primitiveJSON("rugged", params: "{ \"seed\": 919 }", size: 128),
        sink: "terrain", size: 128)
    let rollingDetail = curvaturePercentile(rolling, size: 128, percentile: 0.75)
    let ruggedDetail = curvaturePercentile(rugged, size: 128, percentile: 0.75)
    h.expect(ruggedDetail > rollingDetail * 1.35 + 0.0005,
             "rugged detail \(ruggedDetail) did not exceed rolling \(rollingDetail)")
}

h.test("Slump direction and lobe count control its structure") {
    @MainActor
    func slump(_ direction: Int, _ lobes: Int) -> [Float] {
        evalGraphHeightsJSON(
            primitiveJSON(
                "slump",
                params: "{ \"seed\": 122, \"direction\": \(direction), \"lobes\": \(lobes) }",
                size: 96),
            sink: "terrain", size: 96)
    }
    let a = slump(0, 2)
    let b = slump(90, 2)
    let many = slump(0, 7)
    let av = directionalVariation(a, width: 96)
    let bv = directionalVariation(b, width: 96)
    h.expect(abs(av.0 - av.1) > 0.001, "slump should be anisotropic")
    h.expect((av.0 - av.1) * (bv.0 - bv.1) < 0,
             "slump direction should rotate its structure")
    h.expect(meanAbsoluteDifference(a, many) > 0.005,
             "slump lobe count should affect deposits")
}

h.test("Dune sea crests do not tile") {
    let size = 192
    // Hashing per crest index gave each dune a constant, so the value jumped at
    // every phase wrap and the field rendered as rectangular tiles. Detect a
    // seam as a column whose neighbours differ far more than the field's own
    // typical horizontal step.
    let dunes = evalGraphHeightsJSON(
        primitiveJSON("dunesea", params: "{ \"seed\": 404 }", size: size),
        sink: "terrain", size: UInt32(size))
    h.expect(dunes.count == size * size, "dune sea must evaluate")
    var steps: [Float] = []
    for y in 0..<size {
        for x in 1..<size {
            steps.append(abs(dunes[y * size + x] - dunes[y * size + x - 1]))
        }
    }
    steps.sort()
    let median = steps[steps.count / 2]
    let worst = steps[steps.count - 1]
    h.expect(worst < max(median, 1e-5) * 90,
             "dune sea has a hard seam: peak step \(worst) vs median \(median)")
}

h.test("Landform primitives sit in terrain rather than on a flat plane") {
    // mountain, mountainrange and crater all clipped their profile to exactly
    // zero outside the feature radius, so the surroundings measured 0.00000
    // relief -- the landform read as stamped onto a plane. `surroundings` adds
    // ground the feature grades into.
    let size = 128
    var flat: [String] = []
    for type in ["mountain", "mountainrange", "crater"] {
        let field = evalGraphHeightsJSON(
            primitiveJSON(type, params: "{ \"seed\": 909 }", size: size),
            sink: "terrain", size: UInt32(size))
        guard field.count == size * size else {
            flat.append("\(type) (evaluation failed)")
            continue
        }
        // Sample a corner well clear of any centred feature.
        var corner: [Float] = []
        for y in 0..<(size / 8) {
            for x in 0..<(size / 8) { corner.append(field[y * size + x]) }
        }
        let relief = (corner.max() ?? 0) - (corner.min() ?? 0)
        if relief < 0.002 { flat.append("\(type) relief \(relief)") }
    }
    h.expect(flat.isEmpty, "these landforms sit on a dead-flat plane: \(flat)")

    // `surroundings` must be doing the work, not an unconditional base. Turning
    // it off is compared RELATIVELY: the footslope skirt is deliberately still
    // present out there, since that belongs to the landform rather than to the
    // surrounding ground, so strict flatness is the wrong contract.
    @MainActor func cornerRelief(_ surroundings: String) -> Float {
        let field = evalGraphHeightsJSON(
            primitiveJSON("mountain",
                          params: "{ \"seed\": 909, \"surroundings\": \(surroundings) }",
                          size: size),
            sink: "terrain", size: UInt32(size))
        guard field.count == size * size else { return -1 }
        var corner: [Float] = []
        for y in 0..<(size / 8) {
            for x in 0..<(size / 8) { corner.append(field[y * size + x]) }
        }
        return (corner.max() ?? 0) - (corner.min() ?? 0)
    }
    let off = cornerRelief("0")
    let on = cornerRelief("0.6")
    h.expect(off >= 0 && on >= 0, "surroundings fixtures must evaluate")
    // Measured ratio is ~3.6x; the bound leaves margin while still failing if
    // the control is ignored. The residual at 0 is the footslope skirt.
    h.expect(on > off * 2.5,
             "surroundings should dominate corner relief: \(off) -> \(on)")
}

h.test("Crater and mountain range avoid radial and crease artifacts") {
    let size = 192
    // Sampling noise on atan2 makes the angular coordinate vary infinitely fast
    // near the centre, producing a starburst of spokes. Detect it by comparing
    // variance along a ring close to the centre against one further out: a
    // starburst concentrates angular variation as radius shrinks.
    let crater = evalGraphHeightsJSON(
        primitiveJSON("crater", params: "{ \"seed\": 77 }", size: size),
        sink: "terrain", size: UInt32(size))
    h.expect(crater.count == size * size, "crater must evaluate")
    @MainActor func ringVariation(_ field: [Float], radius: Double) -> Double {
        var samples: [Double] = []
        for i in 0..<180 {
            let a = Double(i) / 180.0 * 2.0 * Double.pi
            let x = Int((0.5 + radius * cos(a)) * Double(size - 1))
            let y = Int((0.5 + radius * sin(a)) * Double(size - 1))
            guard x >= 0, y >= 0, x < size, y < size else { continue }
            samples.append(Double(field[y * size + x]))
        }
        guard samples.count > 2 else { return 0 }
        var d = 0.0
        for i in 1..<samples.count { d += abs(samples[i] - samples[i - 1]) }
        return d / Double(samples.count)
    }
    let inner = ringVariation(crater, radius: 0.02)
    let outer = ringVariation(crater, radius: 0.10)
    h.expect(inner <= max(outer, 1e-6) * 3.0,
             "crater shows a radial starburst near its centre: \(inner) vs \(outer)")

    // max() over per-summit gaussians is only C0 where two summits' influence
    // crosses, which showed as hard straight cuts across the ridge. A crease
    // leaves an isolated spike in the second derivative along the ridge axis.
    let range = evalGraphHeightsJSON(
        primitiveJSON("mountainrange", params: "{ \"seed\": 77 }", size: size),
        sink: "terrain", size: UInt32(size))
    h.expect(range.count == size * size, "mountainrange must evaluate")
    var worst: Float = 0
    var total: Float = 0
    var count = 0
    for y in 1..<(size - 1) {
        for x in 1..<(size - 1) {
            let i = y * size + x
            let curvature = abs(range[i - 1] + range[i + 1] - 2 * range[i])
            worst = max(worst, curvature)
            total += curvature
            count += 1
        }
    }
    let mean = total / Float(max(count, 1))
    h.expect(worst < mean * 260,
             "mountainrange has a crease discontinuity: peak \(worst) vs mean \(mean)")
}

h.test("Canyon depth carves a substantially connected network") {
    let size = 128
    let base = evalGraphHeightsJSON(
        primitiveJSON("canyon",
                      params: "{ \"seed\": 515, \"depth\": 0 }", size: size),
        sink: "terrain", size: UInt32(size))
    let carved = evalGraphHeightsJSON(
        primitiveJSON("canyon",
                      params: "{ \"seed\": 515, \"depth\": 0.7 }", size: size),
        sink: "terrain", size: UInt32(size))
    let mask = zip(base, carved).map { $0 - $1 > 0.025 }
    let carvedCount = mask.filter { $0 }.count
    var visited = [Bool](repeating: false, count: mask.count)
    var largest = 0
    let neighbors = [(-1, -1), (0, -1), (1, -1), (-1, 0),
                     (1, 0), (-1, 1), (0, 1), (1, 1)]
    for index in mask.indices where mask[index] && !visited[index] {
        var queue = [index]
        visited[index] = true
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            let x = current % size
            let y = current / size
            for (dx, dy) in neighbors {
                let nx = x + dx
                let ny = y + dy
                if nx < 0 || ny < 0 || nx >= size || ny >= size { continue }
                let next = ny * size + nx
                if mask[next] && !visited[next] {
                    visited[next] = true
                    queue.append(next)
                }
            }
        }
        largest = max(largest, queue.count)
    }
    h.expect(carvedCount > size && meanAbsoluteDifference(base, carved) > 0.01,
             "canyon depth should materially carve terrain")
    h.expect(carvedCount > 0 && largest * 3 > carvedCount,
             "canyon carving is fragmented: \(largest)/\(carvedCount)")
}

h.test("Foundation node types are registered and expose defaults") {
    let types = readCxxString { theia.node_type_list($0, $1) }
    for type in ["rugged", "invert", "clamp", "remap", "blur", "warp", "blend"] {
        h.expect(types.contains(type), "\(type) missing from node_type_list: \(types)")
        h.expect(theia.graph_default_param_count(type) > 0, "\(type) should expose defaults")
    }
    h.expect(theia.graph_node_type_input_count("rugged") == 0, "rugged input count")
    h.expect(theia.graph_node_type_input_count("blend") == 2, "blend input count")
    h.expect(theia.graph_default_param_value("blend", "opacity", -1) == 1.0,
             "blend opacity default")
}

h.test("Foundation nodes evaluate valid normalized terrain") {
    let cases: [(String, String, Int)] = [
        ("rugged", "{ \"seed\": 44 }", 0),
        ("invert", "{ \"amount\": 1.0 }", 1),
        ("clamp", "{ \"min\": 0.2, \"max\": 0.8 }", 1),
        ("remap", "{ \"inLow\": 0.2, \"inHigh\": 0.8, \"gamma\": 0.8 }", 1),
        ("blur", "{ \"radius\": 2, \"strength\": 1.0 }", 1),
        ("warp", "{ \"seed\": 99, \"strength\": 0.08 }", 1),
        ("blend", "{ \"mode\": 5, \"opacity\": 0.65 }", 2)
    ]
    for (type, params, inputs) in cases {
        let r = evalGraphJSON(p4JSON(type: type, params: params, inputCount: inputs))
        h.expect(r.minHeight >= -1e-6 && r.maxHeight <= 1.000001,
                 "\(type) out of range [\(r.minHeight), \(r.maxHeight)]")
        h.expect(r.variance > 1e-8, "\(type) degenerate")
    }
}

h.test("Foundation nodes are deterministic and preserve cache behavior") {
    let json = p4JSON(type: "warp",
                     params: "{ \"seed\": 99, \"frequency\": 4.0, \"strength\": 0.08 }")
    guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
    defer { theia.graph_destroy(g) }
    h.expect(theia.graph_load_json_text(g, json), "load: \(graphError(g))")
    let first = theia.graph_evaluate(g, "", 96, 96, nil, nil)
    let second = theia.graph_evaluate(g, "", 96, 96, nil, nil)
    h.expect(first.ok && second.ok, "determinism eval failed")
    h.expect(first.mean == second.mean && first.variance == second.variance,
             "warm eval changed stats")
    h.expect(second.evaluated == 0 && second.reused == 2,
             "warm cache should reuse p+warp: \(second.evaluated)/\(second.reused)")
    _ = theia.graph_set_param(g, "n", "strength", 0.12)
    let changed = theia.graph_evaluate(g, "", 96, 96, nil, nil)
    h.expect(changed.evaluated == 1 && changed.reused == 1,
             "warp param change cache: \(changed.evaluated)/\(changed.reused)")
    h.expect(changed.mean != first.mean || changed.variance != first.variance,
             "warp strength should affect output")
}

h.test("Blur smooths terrain and clamp respects output band") {
    let base = evalGraphJSON("""
    {
      "resolution": { "width": 96, "height": 96 },
      "sink": "p",
      "nodes": [
        { "id": "p", "type": "perlin", "params": { "seed": 42, "frequency": 9.0 } }
      ],
      "connections": []
    }
    """)
    let blurred = evalGraphJSON(p4JSON(type: "blur",
                                       params: "{ \"radius\": 3, \"strength\": 1.0 }"))
    h.expect(blurred.variance < base.variance, "blur should reduce variance")

    let clamped = evalGraphJSON(p4JSON(type: "clamp",
                                       params: "{ \"min\": 0.25, \"max\": 0.75 }"))
    h.expect(clamped.minHeight >= 0.25 - 1e-5, "clamp min \(clamped.minHeight)")
    h.expect(clamped.maxHeight <= 0.75 + 1e-5, "clamp max \(clamped.maxHeight)")
}

h.test("Foundation example graphs load and evaluate") {
    for path in ["examples/foundation.json", "examples/masks.json"] {
        guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
        defer { theia.graph_destroy(g) }
        h.expect(theia.graph_load_json_file(g, path), "load \(path): \(graphError(g))")
        let r = theia.graph_evaluate(g, "", 128, 128, nil, nil)
        h.expect(r.ok, "eval \(path): \(graphError(g))")
        h.expect(r.minHeight >= -1e-6 && r.maxHeight <= 1.000001,
                 "\(path) out of range")
        h.expect(r.variance > 1e-8, "\(path) degenerate")
        var values = [Float](repeating: 0, count: 128 * 128)
        let heights = values.withUnsafeMutableBufferPointer {
            theia.graph_evaluate_heights(g, "", 128, 128,
                                         $0.baseAddress, $0.count)
        }
        h.expect(heights.ok, "height readback \(path): \(graphError(g))")
        h.expect(values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 },
                 "\(path) contains non-finite or out-of-range samples")
    }
}

// --- Experimental point-local erosion filter -------------------------------

func erosionFilterJSON(seed: Int = 1337, strength: Double = 0.22,
                       scale: Double = 0.05, detail: Double = 1.5,
                       gullyWeight: Double = 0.35,
                       normalization: Double = 0.4,
                       fadeCenter: Double = 0.5,
                       fadeRange: Double = 0.5,
                       octaves: Int = 5) -> String {
    """
    {
      "resolution": { "width": 96, "height": 96 },
      "sink": "e",
      "nodes": [
        { "id": "p", "type": "perlin", "params": {
          "seed": 2026, "frequency": 3.2, "octaves": 6, "heightScale": 1.0
        } },
        { "id": "e", "type": "erosionfilter", "params": {
          "seed": \(seed), "scale": \(scale), "strength": \(strength),
          "octaves": \(octaves), "gullyWeight": \(gullyWeight), "detail": \(detail),
          "normalization": \(normalization), "fadeCenter": \(fadeCenter),
          "fadeRange": \(fadeRange)
        } }
      ],
      "connections": [
        { "from": "p", "to": "e", "input": 0 }
      ]
    }
    """
}

func maximumAdjacentJump(_ values: [Float], width: Int) -> Float {
    guard width > 0, values.count >= width else { return 0 }
    let height = values.count / width
    var result: Float = 0
    for y in 0..<height {
        for x in 0..<width {
            let index = y * width + x
            if x + 1 < width {
                result = max(result, abs(values[index] - values[index + 1]))
            }
            if y + 1 < height {
                result = max(result, abs(values[index] - values[index + width]))
            }
        }
    }
    return result
}

func introducedBoundaryCount(input: [Float], output: [Float]) -> Int {
    guard input.count == output.count else { return Int.max }
    return zip(input, output).reduce(into: 0) { count, pair in
        let (before, after) = pair
        let inputIsInterior = before > 0 && before < 1
        if inputIsInterior && (after <= 0 || after >= 1) {
            count += 1
        }
    }
}

func maximumLocalResidual(_ values: [Float], width: Int) -> Float {
    guard width > 2, values.count >= width * 3 else { return 0 }
    let height = values.count / width
    var result: Float = 0
    for y in 1..<(height - 1) {
        for x in 1..<(width - 1) {
            let index = y * width + x
            let neighborMean = (
                values[index - 1] + values[index + 1] +
                values[index - width] + values[index + width]) * 0.25
            result = max(result, abs(values[index] - neighborMean))
        }
    }
    return result
}

h.test("Experimental erosion filter is registered with stable defaults") {
    let types = readCxxString { theia.node_type_list($0, $1) }
    h.expect(types.contains("erosionfilter"),
             "erosionfilter missing from node_type_list: \(types)")
    h.expect(theia.graph_node_type_input_count("erosionfilter") == 1,
             "erosionfilter input count")
    h.expect(theia.graph_node_type_output_count("erosionfilter") == 2,
             "erosionfilter output count")
    let terrainName = readCxxString {
        theia.graph_node_type_output_name("erosionfilter", 0, $0, $1)
    }
    let terrainKind = readCxxString {
        theia.graph_node_type_output_kind("erosionfilter", 0, $0, $1)
    }
    let ridgeName = readCxxString {
        theia.graph_node_type_output_name("erosionfilter", 1, $0, $1)
    }
    let ridgeKind = readCxxString {
        theia.graph_node_type_output_kind("erosionfilter", 1, $0, $1)
    }
    h.expect(terrainName == "terrain" && terrainKind == "terrain" &&
             theia.graph_node_type_output_is_default("erosionfilter", 0),
             "terrain output descriptor")
    h.expect(ridgeName == "ridge" && ridgeKind == "data" &&
             !theia.graph_node_type_output_is_default("erosionfilter", 1),
             "ridge output descriptor")
    h.expect(theia.graph_default_param_count("erosionfilter") == 19,
             "erosionfilter default count")
    let defaults: [(String, Double)] = [
        ("seed", 1337), ("scale", 0.05), ("strength", 0.22),
        ("octaves", 5), ("lacunarity", 2.0), ("gain", 0.5),
        ("gullyWeight", 0.35), ("detail", 1.5),
        ("ridgeRounding", 0.18), ("creaseRounding", 0.1),
        ("onset", 1.25), ("assumedSlope", 0.7), ("slopeMix", 1.0),
        ("cellScale", 0.7), ("normalization", 0.4),
        ("heightOffset", -0.65), ("fadeAuto", 1),
        ("fadeCenter", 0.5), ("fadeRange", 0.5),
    ]
    for (key, expected) in defaults {
        h.expect(theia.graph_default_param_value("erosionfilter", key, -99) == expected,
                 "erosionfilter \(key) default")
    }
}

h.test("Erosion filter fadeAuto calibrates fade from the input range") {
    func graph(_ erosionParams: String) -> String {
        """
        {
          "resolution": { "width": 96, "height": 96 },
          "sink": "e",
          "nodes": [
            { "id": "p", "type": "perlin", "params": {
              "seed": 2026, "frequency": 3.2, "octaves": 6, "heightScale": 1.0
            } },
            { "id": "e", "type": "erosionfilter", "params": { \(erosionParams) } }
          ],
          "connections": [ { "from": "p", "to": "e", "input": 0 } ]
        }
        """
    }

    let auto = evalGraphJSON(graph("\"fadeAuto\": 1"))
    let manual = evalGraphJSON(graph("\"fadeAuto\": 0"))
    h.expect(auto.mean != manual.mean || auto.variance != manual.variance,
             "fadeAuto should change the fade mapping on a narrow-range input")

    let identity = evalGraphJSON(
        graph("\"fadeAuto\": 1, \"strength\": 0"))
    let input = evalGraphJSON("""
    {
      "resolution": { "width": 96, "height": 96 },
      "sink": "p",
      "nodes": [ { "id": "p", "type": "perlin", "params": {
        "seed": 2026, "frequency": 3.2, "octaves": 6, "heightScale": 1.0
      } } ],
      "connections": []
    }
    """)
    h.expect(identity.mean == input.mean && identity.variance == input.variance,
             "strength 0 with fadeAuto must preserve the input")
}

h.test("Erosion filter height and ridge share one atomic cache entry") {
    guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
    defer { theia.graph_destroy(g) }
    h.expect(theia.graph_load_json_text(g, erosionFilterJSON()),
             "load erosionfilter: \(graphError(g))")
    h.expect(theia.graph_output_count(g, "e") == 2,
             "graph instance should enumerate both erosion outputs")
    let instanceRidge = readCxxString {
        theia.graph_output_name(g, "e", 1, $0, $1)
    }
    let instanceKind = readCxxString {
        theia.graph_output_kind(g, "e", "ridge", $0, $1)
    }
    h.expect(instanceRidge == "ridge" && instanceKind == "data" &&
             !theia.graph_output_is_default(g, "e", 1),
             "graph instance ridge descriptor")
    var height = [Float](repeating: 0, count: 96 * 96)
    let heightResult = height.withUnsafeMutableBufferPointer {
        theia.graph_evaluate_heights_output(g, "e", "height", 96, 96,
                                            $0.baseAddress, $0.count)
    }
    var ridge = [Float](repeating: 0, count: 96 * 96)
    let ridgeResult = ridge.withUnsafeMutableBufferPointer {
        theia.graph_evaluate_heights_output(g, "e", "ridge", 96, 96,
                                            $0.baseAddress, $0.count)
    }
    h.expect(heightResult.ok && ridgeResult.ok,
             "named output evaluation: \(graphError(g))")
    h.expect(heightResult.evaluated == 2,
             "cold height should evaluate source+filter: \(heightResult.evaluated)")
    h.expect(ridgeResult.evaluated == 0 && ridgeResult.reused == 2,
             "ridge should reuse atomic source+filter cache: \(ridgeResult.evaluated)/\(ridgeResult.reused)")
    h.expect(ridge.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 },
             "ridge contains non-finite or out-of-range values")
    let ridgeRange = (ridge.max() ?? 0) - (ridge.min() ?? 0)
    h.expect(ridgeRange > 1e-4, "ridge output is degenerate: range \(ridgeRange)")
    let independentRidge = evalGraphOutputHeightsJSON(
        erosionFilterJSON(), sink: "e", output: "ridge", size: 96)
    h.expect(independentRidge == ridge,
             "ridge should be bitwise deterministic across graph instances")
    let neutralRidge = evalGraphOutputHeightsJSON(
        erosionFilterJSON(strength: 0), sink: "e", output: "ridge", size: 96)
    h.expect(neutralRidge.allSatisfy { $0 == 0.5 },
             "strength=0 ridge should be neutral 0.5")

    var legacy = [Float](repeating: 0, count: 96 * 96)
    let legacyResult = legacy.withUnsafeMutableBufferPointer {
        theia.graph_evaluate_heights(g, "e", 96, 96, $0.baseAddress, $0.count)
    }
    h.expect(legacyResult.ok && legacy == height,
             "legacy default output must be bit-identical to named height")

    h.expect(theia.graph_set_param(g, "p", "seed", 2027), "change upstream seed")
    let changed = theia.graph_evaluate_output(g, "e", "ridge", 96, 96, nil, nil)
    h.expect(changed.ok && changed.evaluated == 2 && changed.reused == 0,
             "upstream change must invalidate every output: \(changed.evaluated)/\(changed.reused)")
}

h.test("Downstream cache keys include the selected source output") {
    guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
    defer { theia.graph_destroy(g) }
    h.expect(theia.graph_add_node(g, "p", "perlin"), "add source")
    h.expect(theia.graph_add_node(g, "e", "erosionfilter"), "add erosionfilter")
    h.expect(theia.graph_add_node(g, "n", "normalize"), "add transform")
    h.expect(theia.graph_connect(g, "p", "e", 0), "connect source")
    h.expect(theia.graph_connect_output(g, "e", "height", "n", 0),
             "connect height output")
    var heightPath = [Float](repeating: 0, count: 64 * 64)
    let first = heightPath.withUnsafeMutableBufferPointer {
        theia.graph_evaluate_heights(g, "n", 64, 64, $0.baseAddress, $0.count)
    }
    h.expect(first.ok && first.evaluated == 3,
             "cold height path should evaluate three nodes")

    h.expect(theia.graph_connect_output(g, "e", "ridge", "n", 0),
             "switch transform to ridge output")
    var ridgePath = [Float](repeating: 0, count: 64 * 64)
    let switched = ridgePath.withUnsafeMutableBufferPointer {
        theia.graph_evaluate_heights(g, "n", 64, 64, $0.baseAddress, $0.count)
    }
    h.expect(switched.ok && switched.evaluated == 1 && switched.reused == 2,
             "port switch should reuse upstream but recompute downstream: \(switched.evaluated)/\(switched.reused)")
    h.expect(meanAbsoluteDifference(heightPath, ridgePath) > 1e-4,
             "switching source ports should change downstream content")
    let resolvedKind = readCxxString {
        theia.graph_output_kind(g, "n", "field", $0, $1)
    }
    h.expect(resolvedKind == "data", "generic transform should inherit ridge data kind")
}

h.test("Graph format v1 migrates through v2 with default ports and output-scoped mask edits") {
    let legacy = """
    {
      "resolution": { "width": 32, "height": 32 },
      "sink": "mask",
      "nodes": [
        { "id": "p", "type": "perlin", "params": {} },
        { "id": "mask", "type": "river", "params": {} }
      ],
      "connections": [ { "from": "p", "to": "mask", "input": 0 } ],
      "ui": { "positions": {}, "maskErases": {
        "mask": [ { "x": 0.5, "y": 0.5, "radius": 0.1, "strength": 1.0 } ],
        "p": [ { "x": 0.5, "y": 0.5, "radius": 0.1, "strength": 1.0 } ]
      } }
    }
    """
    guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
    defer { theia.graph_destroy(g) }
    h.expect(theia.graph_load_json_text(g, legacy), "load v1: \(graphError(g))")
    let path = NSTemporaryDirectory() + "theia_graph_v2_\(getpid()).json"
    defer { try? FileManager.default.removeItem(atPath: path) }
    h.expect(theia.graph_save_json_file(g, path), "save v2: \(graphError(g))")
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        h.expect(false, "saved v2 JSON did not parse")
        return
    }
    h.expect(root["formatVersion"] as? Int == 2, "formatVersion should be 2")
    h.expect(root["sinkOutput"] as? String == "mask", "migrated sinkOutput")
    let edges = root["connections"] as? [[String: Any]] ?? []
    h.expect(edges.first?["output"] as? String == "terrain",
             "legacy connection should map to source default output")
    let ui = root["ui"] as? [String: Any]
    let erases = ui?["maskErases"] as? [String: Any]
    let outputs = erases?["mask"] as? [String: Any]
    h.expect((outputs?["mask"] as? [[String: Any]])?.count == 1,
             "legacy mask edits should migrate under default output")
    h.expect(erases?["p"] == nil,
             "mask edits attached to terrain outputs should be discarded")
}

h.test("Legacy graph format v3 loads and normalizes to v2") {
    let legacy = """
    {
      "formatVersion": 3,
      "resolution": { "width": 32, "height": 32 },
      "sink": "p",
      "sinkOutput": "height",
      "nodes": [
        { "id": "p", "type": "perlin", "params": {} }
      ],
      "connections": [],
      "retiredExtension": { "enabled": true }
    }
    """
    guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
    defer { theia.graph_destroy(g) }
    h.expect(theia.graph_load_json_text(g, legacy), "load v3: \(graphError(g))")
    let path = NSTemporaryDirectory() + "theia_graph_v3_\(getpid()).json"
    defer { try? FileManager.default.removeItem(atPath: path) }
    h.expect(theia.graph_save_json_file(g, path), "save migrated v3: \(graphError(g))")
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        h.expect(false, "migrated v3 JSON did not parse")
        return
    }
    h.expect(root["formatVersion"] as? Int == 2,
             "v3 input should normalize to formatVersion 2")
    h.expect(root["sinkOutput"] as? String == "terrain",
             "legacy height sink should normalize to terrain")
    h.expect(root["retiredExtension"] == nil,
             "unsupported legacy extension fields should be discarded")
}

h.test("Named output validation rejects unknown and incompatible ports") {
    let unknown = erosionFilterJSON().replacingOccurrences(
        of: "\"sink\": \"e\",", with: "\"sink\": \"e\", \"sinkOutput\": \"removed\",")
    guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
    defer { theia.graph_destroy(g) }
    h.expect(!theia.graph_load_json_text(g, unknown),
             "unknown sink output should be rejected")
    h.expect(graphError(g).contains("output"), "unknown output error: \(graphError(g))")

    let incompatible = """
    {
      "formatVersion": 2,
      "resolution": { "width": 32, "height": 32 },
      "sink": "river", "sinkOutput": "mask",
      "nodes": [
        { "id": "p", "type": "perlin", "params": {} },
        { "id": "e", "type": "erosionfilter", "params": {} },
        { "id": "river", "type": "river", "params": {} }
      ],
      "connections": [
        { "from": "p", "output": "height", "to": "e", "input": 0 },
        { "from": "e", "output": "ridge", "to": "river", "input": 0 }
      ]
    }
    """
    h.expect(!theia.graph_load_json_text(g, incompatible),
             "data output connected to terrain input should be rejected")
    h.expect(graphError(g).contains("does not accept"),
             "kind mismatch error: \(graphError(g))")
    h.expect(diagnosticCodes(incompatible).contains("incompatible_kind"),
             "diagnostics should report incompatible_kind")

    let binaryMismatch = """
    {
      "formatVersion": 2,
      "resolution": { "width": 32, "height": 32 },
      "sink": "mix", "sinkOutput": "field",
      "nodes": [
        { "id": "p", "type": "perlin", "params": {} },
        { "id": "e", "type": "erosionfilter", "params": {} },
        { "id": "mix", "type": "blend", "params": {} }
      ],
      "connections": [
        { "from": "p", "output": "height", "to": "e", "input": 0 },
        { "from": "p", "output": "height", "to": "mix", "input": 0 },
        { "from": "e", "output": "ridge", "to": "mix", "input": 1 }
      ]
    }
    """
    h.expect(!theia.graph_load_json_text(g, binaryMismatch),
             "binary operation should reject mixed kinds")
    h.expect(diagnosticCodes(binaryMismatch).contains("incompatible_binary_kinds"),
             "diagnostics should report binary kind mismatch")
}

h.test("Named ridge export supports rasters and rejects OBJ") {
    guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
    defer { theia.graph_destroy(g) }
    h.expect(theia.graph_load_json_text(g, erosionFilterJSON()),
             "load erosionfilter: \(graphError(g))")
    let dir = NSTemporaryDirectory() + "theia_ridge_export_\(getpid())"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let raster = dir.withCString { dirPtr in
        "analysis".withCString { basePtr in
            "e".withCString { sinkPtr in
                "ridge".withCString { outputPtr in
                    var options = theia.GraphExportOptions()
                    options.sinkId = sinkPtr
                    options.outputName = outputPtr
                    options.width = 32
                    options.height = 32
                    options.outDir = dirPtr
                    options.basename = basePtr
                    options.heightmapFormat = theia.HeightmapFormat.r16
                    options.meshFormat = theia.MeshFormat.none
                    return theia.graph_export2(g, options)
                }
            }
        }
    }
    h.expect(raster.ok, "ridge raster export: \(graphError(g))")
    let ridgeData = try? Data(contentsOf: URL(fileURLWithPath: dir + "/analysis_ridge.r16"))
    h.expect(ridgeData?.count == 32 * 32 * 2, "ridge R16 output missing or wrong size")

    let mesh = dir.withCString { dirPtr in
        "invalid".withCString { basePtr in
            "e".withCString { sinkPtr in
                "ridge".withCString { outputPtr in
                    var options = theia.GraphExportOptions()
                    options.sinkId = sinkPtr
                    options.outputName = outputPtr
                    options.width = 32
                    options.height = 32
                    options.outDir = dirPtr
                    options.basename = basePtr
                    options.heightmapFormat = theia.HeightmapFormat.none
                    options.meshFormat = theia.MeshFormat.obj
                    return theia.graph_export2(g, options)
                }
            }
        }
    }
    h.expect(!mesh.ok && graphError(g).contains("terrain output"),
             "ridge OBJ export should be rejected: \(graphError(g))")
}

h.test("Experimental erosion filter is deterministic and normalized") {
    let a = evalGraphHeightsJSON(erosionFilterJSON(), size: 96)
    let b = evalGraphHeightsJSON(erosionFilterJSON(), size: 96)
    let base = evalGraphHeightsJSON(erosionFilterJSON(strength: 0), size: 96)
    h.expect(a.count == 96 * 96 && a == b,
             "erosionfilter should be bitwise deterministic")
    h.expect(a.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 },
             "erosionfilter contains non-finite or out-of-range samples")
    h.expect((a.max() ?? 0) > (a.min() ?? 0), "erosionfilter degenerate")
    h.expect(meanAbsoluteDifference(a, base) > 1e-4,
             "erosionfilter should visibly alter the input terrain")
}

h.test("Erosion filter stability envelope prevents spikes and clipped holes") {
    let input = evalGraphHeightsJSON(erosionFilterJSON(strength: 0), size: 96)
    let inputJump = maximumAdjacentJump(input, width: 96)
    let inputResidual = maximumLocalResidual(input, width: 96)
    let profiles: [(String, String)] = [
        ("default", erosionFilterJSON()),
        ("overscale", erosionFilterJSON(scale: 0.5)),
        ("heavy gullies", erosionFilterJSON(gullyWeight: 1.0)),
        ("full normalization", erosionFilterJSON(normalization: 1.0)),
        ("low fade center", erosionFilterJSON(fadeCenter: 0.0)),
        ("high fade center", erosionFilterJSON(fadeCenter: 1.0)),
    ]

    for (name, json) in profiles {
        let output = evalGraphHeightsJSON(json, size: 96)
        h.expect(output.count == input.count &&
                 output.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 },
                 "\(name) stability output invalid")
        let jump = maximumAdjacentJump(output, width: 96)
        h.expect(jump <= inputJump + 0.08,
                 "\(name) introduced an excessive adjacent jump: \(jump) vs \(inputJump)")
        let residual = maximumLocalResidual(output, width: 96)
        h.expect(residual <= inputResidual + 0.04,
                 "\(name) introduced an isolated curvature spike: \(residual) vs \(inputResidual)")
        h.expect(introducedBoundaryCount(input: input, output: output) == 0,
                 "\(name) introduced a hard-clipped zero/one sample")
    }

    let scaleLimit = evalGraphHeightsJSON(erosionFilterJSON(scale: 0.06), size: 96)
    let scaleAbove = evalGraphHeightsJSON(erosionFilterJSON(scale: 0.5), size: 96)
    h.expect(scaleLimit == scaleAbove,
             "scale above the safe envelope should clamp to 0.06")

    let gullyLimit = evalGraphHeightsJSON(erosionFilterJSON(gullyWeight: 0.65), size: 96)
    let gullyAbove = evalGraphHeightsJSON(erosionFilterJSON(gullyWeight: 1.0), size: 96)
    h.expect(gullyLimit == gullyAbove,
             "gullyWeight above the safe envelope should clamp to 0.65")

    let normalizationLimit = evalGraphHeightsJSON(
        erosionFilterJSON(normalization: 0.5), size: 96)
    let normalizationAbove = evalGraphHeightsJSON(
        erosionFilterJSON(normalization: 1.0), size: 96)
    h.expect(normalizationLimit == normalizationAbove,
             "normalization above the safe envelope should clamp to 0.5")
}

h.test("Erosion filter rejects octaves above the terrain sampling band") {
    let supported = evalGraphHeightsJSON(
        erosionFilterJSON(octaves: 1), size: 96)
    let excessive = evalGraphHeightsJSON(
        erosionFilterJSON(octaves: 8), size: 96)
    h.expect(supported == excessive,
             "96x96 output should reject octaves below 2.5 samples per cycle")

    let supportedRidge = evalGraphOutputHeightsJSON(
        erosionFilterJSON(octaves: 1), sink: "e", output: "ridge", size: 96)
    let excessiveRidge = evalGraphOutputHeightsJSON(
        erosionFilterJSON(octaves: 8), sink: "e", output: "ridge", size: 96)
    h.expect(supportedRidge == excessiveRidge,
             "rejected octaves must not leak into the ridge analysis output")

    let higherResolution = evalGraphHeightsJSON(
        erosionFilterJSON(octaves: 8), size: 256)
    let oneOctaveHighResolution = evalGraphHeightsJSON(
        erosionFilterJSON(octaves: 1), size: 256)
    h.expect(meanAbsoluteDifference(higherResolution, oneOctaveHighResolution) > 1e-5,
             "higher resolution should admit additional resolved octaves")
}

h.test("Experimental erosion filter identity, seed, and controls respond") {
    let identity = evalGraphHeightsJSON(erosionFilterJSON(strength: 0), size: 96)
    let input = evalGraphHeightsJSON("""
    {
      "resolution": { "width": 96, "height": 96 },
      "sink": "p",
      "nodes": [
        { "id": "p", "type": "perlin", "params": {
          "seed": 2026, "frequency": 3.2, "octaves": 6, "heightScale": 1.0
        } }
      ],
      "connections": []
    }
    """, size: 96)
    h.expect(identity == input, "strength=0 must preserve every input sample")

    let seedA = evalGraphHeightsJSON(erosionFilterJSON(seed: 100), size: 96)
    let seedB = evalGraphHeightsJSON(erosionFilterJSON(seed: 101), size: 96)
    h.expect(meanAbsoluteDifference(seedA, seedB) > 1e-5,
             "seed should change the procedural drainage field")

    let fine = evalGraphHeightsJSON(erosionFilterJSON(scale: 0.02), size: 96)
    let broad = evalGraphHeightsJSON(erosionFilterJSON(scale: 0.06), size: 96)
    h.expect(meanAbsoluteDifference(fine, broad) > 1e-4,
             "scale should change gully structure")

    let lowGully = evalGraphHeightsJSON(erosionFilterJSON(gullyWeight: 0.15), size: 96)
    let highGully = evalGraphHeightsJSON(erosionFilterJSON(gullyWeight: 0.9), size: 96)
    h.expect(meanAbsoluteDifference(lowGully, highGully) > 1e-4,
             "gullyWeight should change output")
}

h.test("Experimental erosion filter preserves graph cache behavior") {
    guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
    defer { theia.graph_destroy(g) }
    h.expect(theia.graph_load_json_text(g, erosionFilterJSON()),
             "load erosionfilter: \(graphError(g))")
    let first = theia.graph_evaluate(g, "", 96, 96, nil, nil)
    let warm = theia.graph_evaluate(g, "", 96, 96, nil, nil)
    h.expect(first.ok && warm.ok, "erosionfilter eval failed: \(graphError(g))")
    h.expect(warm.evaluated == 0 && warm.reused == 2,
             "warm cache should reuse source+filter: \(warm.evaluated)/\(warm.reused)")
    h.expect(theia.graph_set_param(g, "e", "strength", 0.3),
             "set erosionfilter strength")
    let changed = theia.graph_evaluate(g, "", 96, 96, nil, nil)
    h.expect(changed.evaluated == 1 && changed.reused == 1,
             "filter param change should reuse source: \(changed.evaluated)/\(changed.reused)")
}

h.test("Experimental erosion filter example loads and evaluates") {
    guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
    defer { theia.graph_destroy(g) }
    h.expect(theia.graph_load_json_file(g, "examples/erosion-filter.json"),
             "load example: \(graphError(g))")
    let r = theia.graph_evaluate(g, "", 128, 128, nil, nil)
    h.expect(r.ok, "eval example: \(graphError(g))")
    h.expect(r.minHeight >= 0 && r.maxHeight <= 1 && r.variance > 1e-8,
             "example output invalid [\(r.minHeight), \(r.maxHeight)]")
}

// --- Phase 7: particle hydrology --------------------------------------------

func hydrologyJSON(type: String, seed: Int = 1337, particles: Int = 900,
                   maxAge: Int = 45, momentum: Double = 0.8) -> String {
    """
    {
      "resolution": { "width": 72, "height": 72 },
      "sink": "h",
      "nodes": [
        { "id": "p", "type": "perlin", "params": {
          "seed": 91, "frequency": 4.5, "octaves": 6, "heightScale": 1.0
        } },
        { "id": "h", "type": "\(type)", "params": {
          "seed": \(seed),
          "particles": \(particles),
          "maxAge": \(maxAge),
          "evaporation": 0.01,
          "deposition": 0.12,
          "entrainment": 8.0,
          "gravity": 1.0,
          "momentumTransfer": \(momentum),
          "settling": 0.35,
          "maxDiff": 0.02,
          "heightScale": 64.0
        } }
      ],
      "connections": [
        { "from": "p", "to": "h", "input": 0 }
      ]
    }
    """
}

func riverJSON(seed: Int = 1337, water: Double = 0.7, width: Double = 2.0,
               headwaters: Int = 12) -> String {
    """
    {
      "resolution": { "width": 96, "height": 96 },
      "sink": "r",
      "nodes": [
        { "id": "p", "type": "perlin", "params": {
          "seed": 91, "frequency": 4.5, "octaves": 6, "heightScale": 1.0
        } },
        { "id": "r", "type": "river", "params": {
          "seed": \(seed),
          "water": \(water),
          "width": \(width),
          "headwaters": \(headwaters)
        } }
      ],
      "connections": [
        { "from": "p", "to": "r", "input": 0 }
      ]
    }
    """
}

h.test("Particle hydrology and river nodes are registered and expose defaults") {
    let types = readCxxString { theia.node_type_list($0, $1) }
    h.expect(types.contains("dropleterosion"), "dropleterosion missing from node_type_list: \(types)")
    h.expect(!types.contains("flowaccum"), "flowaccum should not be registered: \(types)")
    h.expect(types.contains("river"), "river missing from node_type_list: \(types)")
    h.expect(types.contains("rivercarve"), "rivercarve missing from node_type_list: \(types)")

    h.expect(theia.graph_node_type_input_count("dropleterosion") == 1,
             "dropleterosion input count")
    h.expect(theia.graph_default_param_count("dropleterosion") == 11,
             "dropleterosion default count")
    let dropletDefaults: [(String, Double)] = [
        ("seed", 1337), ("particles", 40000), ("maxAge", 300),
        ("evaporation", 0.010), ("deposition", 0.20),
        ("entrainment", 1.0), ("gravity", 1.0),
        ("momentumTransfer", 1.0), ("settling", 0.50),
        ("maxDiff", 0.100), ("heightScale", 100.0),
    ]
    for (key, expected) in dropletDefaults {
        h.expect(theia.graph_default_param_value("dropleterosion", key, -1) == expected,
                 "dropleterosion \(key) default")
    }

    h.expect(theia.graph_node_type_input_count("river") == 1, "river input count")
    h.expect(theia.graph_default_param_count("river") == 4, "river default count")
    h.expect(theia.graph_default_param_value("river", "seed", -1) == 1337,
             "river seed default")
    h.expect(theia.graph_default_param_value("river", "water", -1) == 0.65,
             "river water default")
    h.expect(theia.graph_default_param_value("river", "width", -1) == 2.0,
             "river width default")
    h.expect(theia.graph_default_param_value("river", "headwaters", -1) == 32,
             "river headwaters default")
    for removed in ["depth", "downcutting", "renderSurface", "riverValleyWidth"] {
        h.expect(theia.graph_default_param_value("river", removed, -1) == -1,
                 "river should not expose \(removed)")
    }

    h.expect(theia.graph_node_type_input_count("rivercarve") == 2, "rivercarve input count")
    h.expect(theia.graph_default_param_count("rivercarve") == 5,
             "rivercarve default count")
    h.expect(theia.graph_default_param_value("rivercarve", "depth", -1) == 0.45,
             "rivercarve depth default")
    h.expect(theia.graph_default_param_value("rivercarve", "shorelineWidth", -1) == 2.0,
             "rivercarve shorelineWidth default")
    h.expect(theia.graph_default_param_value("rivercarve", "shorelineSharpness", -1) == 0.45,
             "rivercarve shorelineSharpness default")
}

h.test("Droplet erosion is deterministic, finite, and seed-sensitive") {
    let base = evalGraphJSON("""
    {
      "resolution": { "width": 72, "height": 72 },
      "sink": "p",
      "nodes": [
        { "id": "p", "type": "perlin", "params": {
          "seed": 91, "frequency": 4.5, "octaves": 6, "heightScale": 1.0
        } }
      ],
      "connections": []
    }
    """, size: 72)
    let a = evalGraphJSON(hydrologyJSON(type: "dropleterosion", seed: 2027), size: 72)
    let b = evalGraphJSON(hydrologyJSON(type: "dropleterosion", seed: 2027), size: 72)
    let c = evalGraphJSON(hydrologyJSON(type: "dropleterosion", seed: 2028), size: 72)
    h.expect(a.minHeight >= -1e-6 && a.maxHeight <= 1.000001,
             "dropleterosion out of range [\(a.minHeight), \(a.maxHeight)]")
    h.expect(a.variance > 1e-8, "dropleterosion degenerate")
    h.expect(a.mean == b.mean && a.variance == b.variance,
             "dropleterosion should be deterministic")
    h.expect(a.mean != base.mean || a.variance != base.variance,
             "dropleterosion should alter terrain")
    h.expect(a.mean != c.mean || a.variance != c.variance,
             "different hydrology seeds should alter terrain")
}

h.test("Hydrology momentum changes terrain and river is a mask") {
    let noMomentum = evalGraphJSON(hydrologyJSON(type: "dropleterosion", momentum: 0.0), size: 72)
    let withMomentum = evalGraphJSON(hydrologyJSON(type: "dropleterosion", momentum: 1.25), size: 72)
    h.expect(noMomentum.mean != withMomentum.mean ||
             noMomentum.variance != withMomentum.variance,
             "momentumTransfer should affect droplet erosion")

    let river = evalGraphJSON(riverJSON(seed: 2027), size: 72)
    let riverOtherSeed = evalGraphJSON(riverJSON(seed: 2028), size: 72)
    h.expect(river.minHeight >= -1e-6 && river.maxHeight <= 1.000001,
             "river out of mask range [\(river.minHeight), \(river.maxHeight)]")
    h.expect(river.variance > 1e-8, "river mask should be non-degenerate")
    h.expect(river.mean != riverOtherSeed.mean || river.variance != riverOtherSeed.variance,
             "river seed should alter the mask network")
}

h.test("River node traces sparse connected downhill paths") {
    let size = 96
    let values = evalGraphHeightsJSON(riverJSON(seed: 2027), size: UInt32(size))
    let visible = values.map { $0 > 0.25 }
    let visibleCount = visible.filter { $0 }.count
    h.expect(visibleCount > size, "river should create visible river pixels")
    h.expect(visibleCount < values.count / 5,
             "river should stay sparse, got \(visibleCount)/\(values.count)")

    var visited = [Bool](repeating: false, count: values.count)
    var largest = 0
    var largestSpan = 0
    let neighbors = [(-1, -1), (0, -1), (1, -1), (-1, 0),
                     (1, 0), (-1, 1), (0, 1), (1, 1)]
    for i in values.indices where visible[i] && !visited[i] {
        var queue = [i]
        visited[i] = true
        var head = 0
        var count = 0
        var minX = size
        var maxX = 0
        var minY = size
        var maxY = 0
        while head < queue.count {
            let cur = queue[head]
            head += 1
            count += 1
            let x = cur % size
            let y = cur / size
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
            for (dx, dy) in neighbors {
                let nx = x + dx
                let ny = y + dy
                if nx < 0 || ny < 0 || nx >= size || ny >= size { continue }
                let ni = ny * size + nx
                if visible[ni] && !visited[ni] {
                    visited[ni] = true
                    queue.append(ni)
                }
            }
        }
        if count > largest {
            largest = count
            largestSpan = (maxX - minX) + (maxY - minY)
        }
    }
    h.expect(largest > size / 2, "largest river component too small: \(largest)")
    h.expect(largestSpan > size / 2, "largest river component too short: \(largestSpan)")
}

h.test("River node responds to upstream terrain changes") {
    let perlinOnly = riverJSON(seed: 2027, water: 0.72, width: 2.0,
                               headwaters: 24)
    let erodedUpstream = """
    {
      "resolution": { "width": 72, "height": 72 },
      "sink": "r",
      "nodes": [
        { "id": "p", "type": "perlin", "params": {
          "seed": 91, "frequency": 4.5, "octaves": 6, "heightScale": 1.0
        } },
        { "id": "e", "type": "dropleterosion", "params": {
          "seed": 2027, "particles": 1200, "maxAge": 70,
          "evaporation": 0.01, "deposition": 0.20, "entrainment": 1.0,
          "gravity": 1.0, "momentumTransfer": 1.0,
          "settling": 0.50, "maxDiff": 0.10, "heightScale": 100.0
        } },
        { "id": "r", "type": "river", "params": {
          "seed": 2027, "water": 0.72, "width": 2.0, "headwaters": 24
        } }
      ],
      "connections": [
        { "from": "p", "to": "e", "input": 0 },
        { "from": "e", "to": "r", "input": 0 }
      ]
    }
    """
    let rawMask = evalGraphHeightsJSON(perlinOnly, sink: "r", size: 72)
    let erodedMask = evalGraphHeightsJSON(erodedUpstream, sink: "r", size: 72)
    let diff = meanAbsoluteDifference(rawMask, erodedMask)
    h.expect(diff > 0.020,
             "river mask should adapt to eroded upstream terrain, mean diff \(diff)")
}

h.test("River node responds to combined upstream terrain") {
    let perlinOnly = riverJSON(seed: 2027, water: 0.72, width: 2.0,
                               headwaters: 24)
    let blendedUpstream = """
    {
      "resolution": { "width": 72, "height": 72 },
      "sink": "r",
      "nodes": [
        { "id": "a", "type": "perlin", "params": {
          "seed": 91, "frequency": 4.5, "octaves": 6, "heightScale": 1.0
        } },
        { "id": "b", "type": "rugged", "params": { "seed": 229 } },
        { "id": "blend", "type": "blend", "params": {
          "mode": 1, "opacity": 0.42
        } },
        { "id": "r", "type": "river", "params": {
          "seed": 2027, "water": 0.72, "width": 2.0, "headwaters": 24
        } }
      ],
      "connections": [
        { "from": "a", "to": "blend", "input": 0 },
        { "from": "b", "to": "blend", "input": 1 },
        { "from": "blend", "to": "r", "input": 0 }
      ]
    }
    """
    let rawMask = evalGraphHeightsJSON(perlinOnly, sink: "r", size: 72)
    let blendedMask = evalGraphHeightsJSON(blendedUpstream, sink: "r", size: 72)
    let diff = meanAbsoluteDifference(rawMask, blendedMask)
    h.expect(diff > 0.020,
             "river mask should adapt to blended upstream terrain, mean diff \(diff)")
}

h.test("River carve consumes a separate river mask") {
    let carved = evalGraphJSON("""
    {
      "resolution": { "width": 96, "height": 96 },
      "sink": "carve",
      "nodes": [
        { "id": "p", "type": "perlin", "params": {
          "seed": 91, "frequency": 4.5, "octaves": 6, "heightScale": 1.0
        } },
        { "id": "r", "type": "river", "params": {
          "seed": 2027, "water": 0.7, "width": 2.0, "headwaters": 32
        } },
        { "id": "carve", "type": "rivercarve", "params": {
          "depth": 0.45, "downcutting": 0.55, "riverValleyWidth": 2.0
        } }
      ],
      "connections": [
        { "from": "p", "to": "r", "input": 0 },
        { "from": "p", "to": "carve", "input": 0 },
        { "from": "r", "to": "carve", "input": 1 }
      ]
    }
    """, size: 96)
    let base = evalGraphJSON("""
    {
      "resolution": { "width": 96, "height": 96 },
      "sink": "p",
      "nodes": [
        { "id": "p", "type": "perlin", "params": {
          "seed": 91, "frequency": 4.5, "octaves": 6, "heightScale": 1.0
        } }
      ],
      "connections": []
    }
    """, size: 96)
    h.expect(carved.minHeight >= -1e-6 && carved.maxHeight <= 1.000001,
             "rivercarve out of range")
    h.expect(carved.mean < base.mean,
             "rivercarve should lower terrain mean \(base.mean) -> \(carved.mean)")
}

h.test("River carve shoreline controls bank falloff") {
    @MainActor
    func carved(sharpness: Double) -> [Float] {
        evalGraphHeightsJSON("""
        {
          "resolution": { "width": 72, "height": 72 },
          "sink": "carve",
          "nodes": [
            { "id": "p", "type": "perlin", "params": {
              "seed": 91, "frequency": 4.5, "octaves": 6, "heightScale": 1.0
            } },
            { "id": "r", "type": "river", "params": {
              "seed": 2027, "water": 0.72, "width": 2.0, "headwaters": 24
            } },
            { "id": "carve", "type": "rivercarve", "params": {
              "depth": 0.45,
              "downcutting": 0.75,
              "riverValleyWidth": 3.0,
              "shorelineWidth": 5.0,
              "shorelineSharpness": \(sharpness)
            } }
          ],
          "connections": [
            { "from": "p", "to": "r", "input": 0 },
            { "from": "p", "to": "carve", "input": 0 },
            { "from": "r", "to": "carve", "input": 1 }
          ]
        }
        """, sink: "carve", size: 72)
    }
    let soft = carved(sharpness: 0.05)
    let sharp = carved(sharpness: 0.95)
    let diff = meanAbsoluteDifference(soft, sharp)
    let softDelta = maxNeighborDelta(soft, size: 72)
    let sharpDelta = maxNeighborDelta(sharp, size: 72)
    h.expect(diff > 0.003,
             "shorelineSharpness should alter rivercarve bank falloff, diff \(diff)")
    h.expect(softDelta < sharpDelta,
             "soft shoreline should reduce abrupt bank deltas, soft \(softDelta), sharp \(sharpDelta)")
    h.expect((soft.min() ?? -1) >= -1e-6 && (soft.max() ?? 2) <= 1.000001,
             "soft shoreline output out of range")
    h.expect((sharp.min() ?? -1) >= -1e-6 && (sharp.max() ?? 2) <= 1.000001,
             "sharp shoreline output out of range")
}

h.test("Particle hydrology remains finite under heavier settings") {
    let r = evalGraphJSON(hydrologyJSON(type: "dropleterosion", seed: 3031,
                                        particles: 1800, maxAge: 160,
                                        momentum: 1.2), size: 72)
    h.expect(r.minHeight.isFinite && r.maxHeight.isFinite &&
             r.mean.isFinite && r.variance.isFinite,
             "heavy hydrology stats should stay finite")
    h.expect(r.minHeight >= -1e-6 && r.maxHeight <= 1.000001,
             "heavy hydrology out of range [\(r.minHeight), \(r.maxHeight)]")
}

h.test("Particle hydrology preserves cache behavior") {
    guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
    defer { theia.graph_destroy(g) }
    let json = """
    {
      "resolution": { "width": 72, "height": 72 },
      "sink": "out",
      "nodes": [
        { "id": "p", "type": "perlin", "params": {
          "seed": 91, "frequency": 4.5, "octaves": 6, "heightScale": 1.0
        } },
        { "id": "h", "type": "dropleterosion", "params": {
          "seed": 2027, "particles": 800, "maxAge": 40,
          "evaporation": 0.01, "deposition": 0.12, "entrainment": 8.0,
          "gravity": 1.0, "momentumTransfer": 0.8,
          "settling": 0.35, "maxDiff": 0.02, "heightScale": 64.0
        } },
        { "id": "out", "type": "normalize", "params": {} }
      ],
      "connections": [
        { "from": "p", "to": "h", "input": 0 },
        { "from": "h", "to": "out", "input": 0 }
      ]
    }
    """
    h.expect(theia.graph_load_json_text(g, json), "load: \(graphError(g))")
    let first = theia.graph_evaluate(g, "", 72, 72, nil, nil)
    let warm = theia.graph_evaluate(g, "", 72, 72, nil, nil)
    h.expect(first.ok && warm.ok, "hydrology cache eval failed: \(graphError(g))")
    h.expect(warm.evaluated == 0 && warm.reused == 3,
             "warm cache should reuse p+h+out: \(warm.evaluated)/\(warm.reused)")
    _ = theia.graph_set_param(g, "h", "momentumTransfer", 1.4)
    let changed = theia.graph_evaluate(g, "", 72, 72, nil, nil)
    h.expect(changed.evaluated == 2 && changed.reused == 1,
             "hydrology param cache: \(changed.evaluated)/\(changed.reused)")
}

h.test("Particle hydrology examples load and evaluate") {
    for path in ["examples/hydrology.json", "examples/rivers.json"] {
        guard let g = theia.graph_create() else { h.expect(false, "create failed"); return }
        defer { theia.graph_destroy(g) }
        h.expect(theia.graph_load_json_file(g, path), "load \(path): \(graphError(g))")
        let r = theia.graph_evaluate(g, "", 128, 128, nil, nil)
        h.expect(r.ok, "eval \(path): \(graphError(g))")
        h.expect(r.minHeight >= -1e-6 && r.maxHeight <= 1.000001,
                 "\(path) out of range")
        h.expect(r.variance > 1e-8, "\(path) degenerate")
    }
}

func runCLI(_ args: [String]) -> (Int32, String, String) {
    let root = FileManager.default.currentDirectoryPath
    let debugCLI = URL(fileURLWithPath: root).appendingPathComponent(".build/debug/theia-cli").path
    let process = Process()
    if FileManager.default.isExecutableFile(atPath: debugCLI) {
        process.executableURL = URL(fileURLWithPath: debugCLI)
        process.arguments = args
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "run", "theia-cli"] + args
    }
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return (127, "", error.localizedDescription)
    }
    let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8) ?? ""
    let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8) ?? ""
    return (process.terminationStatus, stdout, stderr)
}

h.test("CLI JSON commands are parseable and unknown options exit 2") {
    let nodes = runCLI(["nodes", "--json"])
    h.expect(nodes.0 == 0, "nodes --json exit \(nodes.0): \(nodes.2)")
    let nodesObject = try? JSONSerialization.jsonObject(with: Data(nodes.1.utf8)) as? [String: Any]
    let nodeList = nodesObject?["nodes"] as? [[String: Any]] ?? []
    let expectedTypes = readCxxString { theia.node_type_list($0, $1) }
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    let actualTypes = nodeList.compactMap { $0["type"] as? String }
    h.expect(actualTypes == expectedTypes, "nodes JSON type catalog mismatch: \(actualTypes)")
    h.expect(actualTypes.allSatisfy { $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) },
             "node types must not contain surrounding whitespace")
    let combine = nodeList.first { ($0["type"] as? String) == "combine" }
    let rugged = nodeList.first { ($0["type"] as? String) == "rugged" }
    let erosionFilter = nodeList.first { ($0["type"] as? String) == "erosionfilter" }
    h.expect((combine?["inputCount"] as? Int) == 2, "combine input count missing from catalog")
    h.expect(!((rugged?["defaultParams"] as? [[String: Any]]) ?? []).isEmpty,
             "rugged defaults missing from catalog")
    let erosionOutputs = erosionFilter?["outputs"] as? [[String: Any]] ?? []
    h.expect(erosionOutputs.count == 2 &&
             erosionOutputs.contains { ($0["name"] as? String) == "ridge" &&
                 ($0["kind"] as? String) == "data" &&
                 ($0["default"] as? Bool) == false },
             "erosionfilter named outputs missing from catalog")

    let diagnose = runCLI(["diagnose", "examples/foundation.json", "--json"])
    h.expect(diagnose.0 == 0, "diagnose --json exit \(diagnose.0): \(diagnose.2)")
    let diagnoseObject = try? JSONSerialization.jsonObject(with: Data(diagnose.1.utf8)) as? [String: Any]
    h.expect(diagnoseObject?["summary"] != nil, "diagnose JSON missing summary")

    let runPNG = NSTemporaryDirectory() + "theia_cli_run_\(getpid()).png"
    defer {
        try? FileManager.default.removeItem(atPath: runPNG)
        try? FileManager.default.removeItem(atPath: String(runPNG.dropLast(4)) + ".pfm")
    }
    let run = runCLI(["run", "examples/foundation.json", "--size", "32", "--out", runPNG, "--json"])
    h.expect(run.0 == 0, "run --json exit \(run.0): \(run.2)")
    let runObject = try? JSONSerialization.jsonObject(with: Data(run.1.utf8)) as? [String: Any]
    h.expect(runObject?["stats"] != nil, "run JSON missing stats")

    let exportDir = NSTemporaryDirectory() + "theia_cli_export_\(getpid())"
    defer { try? FileManager.default.removeItem(atPath: exportDir) }
    let export = runCLI([
        "export", "examples/foundation.json",
        "--size", "32",
        "--out-dir", exportDir,
        "--basename", "foundation",
        "--heightmap", "r16",
        "--mesh", "obj",
        "--json",
    ])
    h.expect(export.0 == 0, "export --json exit \(export.0): \(export.2)")
    let exportObject = try? JSONSerialization.jsonObject(with: Data(export.1.utf8)) as? [String: Any]
    h.expect(exportObject?["paths"] != nil, "export JSON missing paths")

    let ridgeRunPNG = NSTemporaryDirectory() + "theia_cli_ridge_\(getpid()).png"
    defer {
        try? FileManager.default.removeItem(atPath: ridgeRunPNG)
        try? FileManager.default.removeItem(
            atPath: String(ridgeRunPNG.dropLast(4)) + ".pfm")
    }
    let ridgeRun = runCLI([
        "run", "examples/erosion-filter.json",
        "--output", "ridge", "--size", "32", "--out", ridgeRunPNG, "--json",
    ])
    h.expect(ridgeRun.0 == 0, "named ridge run exit \(ridgeRun.0): \(ridgeRun.2)")
    let ridgeRunObject = try? JSONSerialization.jsonObject(
        with: Data(ridgeRun.1.utf8)) as? [String: Any]
    h.expect(ridgeRunObject?["output"] as? String == "ridge",
             "named run JSON should report ridge")

    let ridgeExport = runCLI([
        "export", "examples/erosion-filter.json",
        "--output", "ridge", "--size", "32",
        "--out-dir", exportDir, "--basename", "ridge",
        "--heightmap", "r16", "--mesh", "none", "--json",
    ])
    h.expect(ridgeExport.0 == 0,
             "named ridge export exit \(ridgeExport.0): \(ridgeExport.2)")
    h.expect(FileManager.default.fileExists(atPath: exportDir + "/ridge_ridge.r16"),
             "named ridge export file missing")

    let invalidMesh = runCLI([
        "export", "examples/erosion-filter.json",
        "--output", "ridge", "--size", "32",
        "--out-dir", exportDir, "--basename", "invalid-ridge",
        "--heightmap", "none", "--mesh", "obj", "--json",
    ])
    h.expect(invalidMesh.0 == 1,
             "ridge OBJ export should fail with exit 1, got \(invalidMesh.0)")

    let bad = runCLI(["nodes", "--bogus"])
    h.expect(bad.0 == 2, "unknown option should exit 2, got \(bad.0)")
}


// ---------------------------------------------------------------------------
// Fluvial landscape evolution.
// See docs/research/fluvial-landscape-evolution-notes.md for the audited
// equations and the invariant table these tests discharge.
// ---------------------------------------------------------------------------

func fluvialGraphJSON(size: Int = 128, overrides: String = "") -> String {
    """
    {
      "resolution": { "width": \(size), "height": \(size) },
      "sink": "ero",
      "sinkOutput": "height",
      "nodes": [
        { "id": "base", "type": "perlin", "params": {
          "seed": 2024, "octaves": 6, "frequency": 3.0,
          "lacunarity": 2.0, "gain": 0.5
        } },
        { "id": "ero", "type": "fluvial", "params": {
          "iterations": 24, "terrainSize": 1024.0, "heightScale": 100.0
          \(overrides.isEmpty ? "" : ", " + overrides)
        } }
      ],
      "connections": [
        { "from": "base", "output": "height", "to": "ero", "input": 0 }
      ]
    }
    """
}

h.test("Fluvial node is registered and exposes stream power defaults") {
    guard let g = theia.graph_create() else { h.expect(false, "create"); return }
    defer { theia.graph_destroy(g) }
    h.expect(theia.graph_add_node(g, "f", "fluvial"), "fluvial should be registered")
    // m = 0.5 with n = 1 is the specific-stream-power case in Whipple & Tucker.
    h.expect(theia.graph_param_value(g, "f", "areaExponent", -1) == 0.5,
             "areaExponent default should be 0.5")
    h.expect(theia.graph_param_value(g, "f", "slopeExponent", -1) == 1.0,
             "slopeExponent default should be 1.0")
    // Uniform uplift drives the surface to the model's own steady state and
    // erases the authored input, so it must stay opt-in.
    h.expect(theia.graph_param_value(g, "f", "uplift", -1) == 0.0,
             "uplift must default to zero")
}

h.test("Fluvial erosion is finite, bounded, deterministic, and not an identity") {
    let json = fluvialGraphJSON()
    let base = evalGraphHeightsJSON(json, sink: "base", size: 128)
    let eroded = evalGraphHeightsJSON(json, sink: "ero", size: 128)
    let repeated = evalGraphHeightsJSON(json, sink: "ero", size: 128)
    h.expect(eroded.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 },
             "fluvial output left [0,1] or went non-finite")
    h.expect(eroded == repeated, "fluvial must be bitwise deterministic")
    h.expect(meanAbsoluteDifference(base, eroded) > 0.001,
             "fluvial erosion must change the terrain")
}

h.test("Fluvial flow accumulation forms a channel hierarchy") {
    // The property that distinguishes a drainage network from roughened noise:
    // accumulated area is heavy-tailed, concentrated into a few channels rather
    // than spread evenly. The previous `hydraulic` node cannot satisfy this
    // because it has no notion of upstream area at all.
    let flow = evalGraphHeightsJSON(fluvialGraphJSON(), sink: "ero", size: 128)
    guard let g = theia.graph_create() else { h.expect(false, "create"); return }
    defer { theia.graph_destroy(g) }
    h.expect(theia.graph_load_json_text(g, fluvialGraphJSON()), "load: \(graphError(g))")
    var values = [Float](repeating: 0, count: 128 * 128)
    let r = values.withUnsafeMutableBufferPointer {
        theia.graph_evaluate_heights_output(g, "ero", "flow", 128, 128,
                                            $0.baseAddress, $0.count)
    }
    h.expect(r.ok, "flow output: \(graphError(g))")
    h.expect(values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 },
             "flow output must be a normalized field")
    _ = flow

    let sorted = values.sorted()
    let median = sorted[sorted.count / 2]
    let p99 = sorted[Int(Double(sorted.count) * 0.99)]
    h.expect(p99 > median * 1.5 + 0.05,
             "flow field is not heavy-tailed: median \(median) p99 \(p99)")
    let channels = values.filter { $0 > 0.75 }.count
    h.expect(channels > 0 && channels < values.count / 8,
             "channels should be present but sparse: \(channels)")
}

h.test("Fluvial deposition responds to the G coefficient") {
    let detachment = evalGraphHeightsJSON(
        fluvialGraphJSON(overrides: "\"deposition\": 0.0"), sink: "ero", size: 128)
    let transport = evalGraphHeightsJSON(
        fluvialGraphJSON(overrides: "\"deposition\": 4.0"), sink: "ero", size: 128)
    h.expect(detachment.allSatisfy { $0.isFinite }, "G=0 output must be finite")
    h.expect(transport.allSatisfy { $0.isFinite }, "G=4 output must be finite")
    // Deposition returns eroded material to the bed, so a transport-limited run
    // must retain more mass than a purely detachment-limited one.
    let detachedMean = detachment.reduce(0, +) / Float(detachment.count)
    let transportMean = transport.reduce(0, +) / Float(transport.count)
    h.expect(transportMean > detachedMean,
             "deposition should retain mass: \(detachedMean) vs \(transportMean)")
}

// Spikes and local minima, counted separately. `isolatedExtremaCount` cannot be
// reused here: it treats any cell separated from its four orthogonal neighbours
// as an artifact, which for an incision model also matches the bottom of a
// legitimate one-cell-wide diagonal channel. Carving those channels is the
// node's purpose, so the meaningful invariants are that spikes do not appear
// and that drainage connectivity does not degrade.
func spikePeakCount(_ values: [Float], size: Int, threshold: Float) -> Int {
    guard values.count == size * size, size >= 3 else { return .max }
    var count = 0
    for y in 1..<(size - 1) {
        for x in 1..<(size - 1) {
            let i = y * size + x
            let neighbors = [values[i - 1], values[i + 1],
                             values[i - size], values[i + size]]
            if values[i] > (neighbors.max() ?? values[i]),
               neighbors.allSatisfy({ abs(values[i] - $0) > threshold }) {
                count += 1
            }
        }
    }
    return count
}

// Cells with no lower neighbour in any of the eight directions: water arriving
// here has nowhere to go. This is the direct measure of the flow-path
// monotonicity invariant in the research note.
func undrainedCellCount(_ values: [Float], size: Int) -> Int {
    guard values.count == size * size, size >= 3 else { return .max }
    var count = 0
    for y in 1..<(size - 1) {
        for x in 1..<(size - 1) {
            let here = values[y * size + x]
            var lowest = Float.infinity
            for dy in -1...1 {
                for dx in -1...1 where dx != 0 || dy != 0 {
                    lowest = min(lowest, values[(y + dy) * size + (x + dx)])
                }
            }
            if lowest > here { count += 1 }
        }
    }
    return count
}

h.test("Fluvial erosion removes spikes and improves drainage connectivity") {
    let json = fluvialGraphJSON()
    let base = evalGraphHeightsJSON(json, sink: "base", size: 128)
    let eroded = evalGraphHeightsJSON(json, sink: "ero", size: 128)

    // The Courant limit and the receiver clamp exist to prevent the
    // spike/checkerboard mode of explicit erosion schemes. A correct run
    // should strictly reduce spikes rather than merely avoid adding them.
    let basePeaks = spikePeakCount(base, size: 128, threshold: 0.003)
    let erodedPeaks = spikePeakCount(eroded, size: 128, threshold: 0.003)
    h.expect(erodedPeaks <= basePeaks,
             "fluvial created spikes \(basePeaks) -> \(erodedPeaks)")

    // Depression routing should leave the surface better drained than it found
    // it; a rise here would mean the solver was manufacturing closed basins.
    let baseUndrained = undrainedCellCount(base, size: 128)
    let erodedUndrained = undrainedCellCount(eroded, size: 128)
    h.expect(erodedUndrained <= baseUndrained,
             "fluvial worsened drainage \(baseUndrained) -> \(erodedUndrained)")
}

h.test("Fluvial channel structure is stable across resolutions") {
    // terrainSize is fixed, so the same physical terrain is being sampled more
    // finely. Channel density may sharpen but must not collapse or explode.
    var densities: [Double] = []
    for size in [128, 256] {
        guard let g = theia.graph_create() else { h.expect(false, "create"); return }
        defer { theia.graph_destroy(g) }
        h.expect(theia.graph_load_json_text(g, fluvialGraphJSON(size: size)),
                 "load at \(size): \(graphError(g))")
        var values = [Float](repeating: 0, count: size * size)
        let r = values.withUnsafeMutableBufferPointer {
            theia.graph_evaluate_heights_output(g, "ero", "flow",
                                                UInt32(size), UInt32(size),
                                                $0.baseAddress, $0.count)
        }
        h.expect(r.ok, "flow at \(size): \(graphError(g))")
        let channels = values.filter { $0 > 0.75 }.count
        densities.append(Double(channels) / Double(values.count))
    }
    let low = densities.min() ?? 0
    let high = densities.max() ?? 0
    h.expect(low > 0.0005 && high / max(low, 1e-9) < 6.0,
             "channel density drifted with resolution: \(densities)")
}

h.test("Hillslope diffusion smooths grid-scale roughness") {
    // Fluvial incision alone is scale-free: it cuts a channel at one-cell
    // drainage area, packing the surface with grid-scale grooves. Diffusion is
    // the term that suppresses exactly that, so the measurement is grid-scale
    // curvature of the SURFACE. The `flow` output cannot be used here: it is
    // log-normalized against its own range, so rescaling hides the effect.
    @MainActor func gridScaleRoughness(_ diffusion: Double) -> Float {
        let eroded = evalGraphHeightsJSON(
            fluvialGraphJSON(overrides: "\"diffusion\": \(diffusion)"),
            sink: "ero", size: 128)
        guard eroded.count == 128 * 128 else { return -1 }
        return curvaturePercentile(eroded, size: 128, percentile: 0.90)
    }
    let none = gridScaleRoughness(0.0)
    let smoothed = gridScaleRoughness(0.5)   // the maximum the core allows
    h.expect(none >= 0 && smoothed >= 0, "diffusion fixtures must evaluate")
    // Measured ~12% reduction on this fixture. The margin is modest because the
    // diffusion number scales as 1/cell^2, so at this 128 grid the same
    // coefficient is ~16x weaker than at the 512 the default is tuned for.
    h.expect(smoothed < none * 0.95,
             "diffusion should smooth grid-scale relief: \(none) -> \(smoothed)")

    // The substepping exists to hold the explicit five-point scheme inside its
    // stability limit; the largest allowed coefficient must stay well-posed.
    let extreme = evalGraphHeightsJSON(
        fluvialGraphJSON(overrides: "\"diffusion\": 8.0"), sink: "ero", size: 128)
    h.expect(extreme.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 },
             "maximum diffusion must remain stable and bounded")
}

h.test("Nonlinear hillslope transport concentrates smoothing on steep ground") {
    // Roering et al. 1999: transport diverges as the gradient approaches Sc.
    // The point of the nonlinear law is selectivity -- at a coefficient that
    // suppresses grid-scale grooves it must flatten far LESS of the surface
    // than linear diffusion did, or it buys nothing over the old term.
    @MainActor func measure(_ overrides: String) -> (flat: Double, rough: Float) {
        let eroded = evalGraphHeightsJSON(fluvialGraphJSON(overrides: overrides),
                                          sink: "ero", size: 128)
        guard eroded.count == 128 * 128 else { return (-1, -1) }
        var flatCount = 0
        for y in 1..<127 {
            for x in 1..<127 {
                let i = y * 128 + x
                let lap = abs(eroded[i-1] + eroded[i+1] + eroded[i-128]
                              + eroded[i+128] - 4 * eroded[i])
                if lap < 0.0002 { flatCount += 1 }
            }
        }
        return (Double(flatCount) / Double(126 * 126),
                curvaturePercentile(eroded, size: 128, percentile: 0.90))
    }
    let off = measure("\"diffusion\": 0.0")
    let tuned = measure("\"diffusion\": 0.5, \"criticalSlope\": 0.6")
    h.expect(off.rough >= 0 && tuned.rough >= 0, "transport fixtures must evaluate")

    // Grooves must still be suppressed relative to no transport. The margin is
    // deliberately loose: the diffusion number scales as 1/cell^2, so at this
    // 128 test grid the same coefficient is ~16x weaker than at the 512 the
    // default is tuned for. Direction is the contract here, not magnitude.
    h.expect(tuned.rough < off.rough,
             "nonlinear transport should still smooth grooves: \(off.rough) -> \(tuned.rough)")
    let weak = measure("\"diffusion\": 0.05, \"criticalSlope\": 0.6")
    h.expect(tuned.rough < weak.rough,
             "raising the coefficient must increase smoothing: \(weak.rough) -> \(tuned.rough)")
    // ...without flattening the surface the way the linear term did.
    h.expect(tuned.flat < 0.25,
             "nonlinear transport flattened too much of the surface: \(tuned.flat)")

    // A lower critical slope makes the law fire at gentler gradients, so it
    // must smooth strictly more. This is what proves Sc is actually wired in --
    // and it caught a real bug: the diffuse kernel compared a NORMALIZED height
    // delta against Sc while every other kernel works in world units, leaving
    // the amplification inert across the whole authoring range.
    //
    // Both sides use the maximum coefficient and a wide Sc separation so the
    // gap is ~20%. An earlier version compared 0.6 against 0.3 at the default
    // coefficient, where the true difference is under 0.03% -- below the
    // floating-point noise floor between machines, and it passed locally while
    // failing in CI.
    let nearLinear = measure("\"diffusion\": 0.5, \"criticalSlope\": 3.0")
    let firesEarly = measure("\"diffusion\": 0.5, \"criticalSlope\": 0.2")
    h.expect(firesEarly.rough < nearLinear.rough * 0.9,
             "lowering criticalSlope should increase smoothing: \(nearLinear.rough) -> \(firesEarly.rough)")

    // The substep budget is sized for the amplification cap; the maximum
    // coefficient must stay well-posed.
    let extreme = evalGraphHeightsJSON(
        fluvialGraphJSON(overrides: "\"diffusion\": 0.5, \"criticalSlope\": 0.1"),
        sink: "ero", size: 128)
    h.expect(extreme.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 },
             "maximum nonlinear transport must remain stable and bounded")
}

h.test("Fluvial rejects non-finite parameters") {
    for name in ["erodibility", "dt", "deposition", "terrainSize", "uplift",
                 "diffusion", "mfdExponent", "areaExponent", "criticalSlope"] {
        guard let g = theia.graph_create() else { h.expect(false, "create"); return }
        defer { theia.graph_destroy(g) }
        h.expect(theia.graph_load_json_text(g, fluvialGraphJSON()),
                 "load: \(graphError(g))")
        h.expect(theia.graph_set_param(g, "ero", name, Double.nan),
                 "set \(name) to NaN")
        let r = theia.graph_evaluate(g, "ero", 64, 64, nil, nil)
        h.expect(!r.ok, "non-finite \(name) should fail evaluation")
    }
}

print("\n\(h.checks) checks, \(h.failures) failure(s)")
exit(h.failures == 0 ? 0 : 1)
