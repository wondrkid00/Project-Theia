import AppKit
import SwiftUI

private struct NoNodeParametersCard: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("No parameters")
                .font(.callout.weight(.semibold))
            Text("This node has no editable parameters.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .background(inspectorControlFill,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(inspectorControlStroke())
    }
}

struct NodeParameterInspector: View {
    @ObservedObject var model: TerrainModel
    let viewport: TerrainMTKView
    @State private var advancedExpanded = false

    var visibleNodes: [GraphNodeInfo] {
        if let selected = model.selectedNodeId,
           let node = model.nodes.first(where: { $0.id == selected }) {
            return [node]
        }
        return []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Parameters")
                    .font(.headline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            if visibleNodes.isEmpty {
                Text(model.document.nodes.isEmpty ? "No nodes" : "No node selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }

            ForEach(visibleNodes) { node in
                VStack(alignment: .leading, spacing: 14) {
                    InspectorSectionHeader("SELECTED NODE")
                    NodeIdentityRow(node: node) {
                        model.resetAllParams(nodeId: node.id)
                        viewport.setNeedsDisplay(viewport.bounds)
                    }

                    let outputs = model.outputPorts(for: node.id)
                    if outputs.count > 1 {
                        VStack(alignment: .leading, spacing: 8) {
                            InspectorSectionHeader("PREVIEW OUTPUT")
                            HStack(spacing: 8) {
                                ForEach(outputs) { output in
                                    Button {
                                        model.selectOutput(nodeId: node.id,
                                                           output: output.name)
                                        viewport.setNeedsDisplay(viewport.bounds)
                                    } label: {
                                        HStack(spacing: 6) {
                                            Circle()
                                                .fill(outputColor(output.declaredKind))
                                                .frame(width: 8, height: 8)
                                            Text(output.name)
                                                .font(.caption.monospaced())
                                        }
                                        .padding(.horizontal, 10)
                                        .frame(height: 30)
                                        .background(
                                            model.isActiveOutput(nodeId: node.id,
                                                                 output: output.name)
                                                ? Color.accentColor.opacity(0.22)
                                                : inspectorControlFill,
                                            in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }

                    Button {
                        model.setPreviewAsGraphOutput()
                    } label: {
                        HStack {
                            Image(systemName: "target")
                            Text(model.document.sink == model.previewReference.node &&
                                 model.document.sinkOutput == model.previewReference.output
                                 ? "Graph Output" : "Set as Graph Output")
                            Spacer()
                            Text("\(model.previewReference.node).\(model.previewReference.output)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 32)
                    }
                    .buttonStyle(.plain)
                    .background(inspectorControlFill,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(inspectorControlStroke())
                    .disabled(model.previewReference.node != node.id ||
                              (model.document.sink == model.previewReference.node &&
                               model.document.sinkOutput == model.previewReference.output))
                    .help("Persist the previewed port as the CLI and export graph output")

                    if node.params.isEmpty {
                        NoNodeParametersCard()
                    } else {
                        Divider()
                            .padding(.vertical, 2)
                        InspectorSectionHeader("NODE SETTINGS")
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(basicParams(for: node)) { param in
                            ParameterSlider(param: param) { value in
                                model.apply(nodeId: param.nodeId,
                                            param: param.name,
                                            value: value)
                                viewport.setNeedsDisplay(viewport.bounds)
                            } onReset: {
                                model.resetParam(nodeId: param.nodeId,
                                                 param: param.name)
                                viewport.setNeedsDisplay(viewport.bounds)
                            }
                        }
                    }

                    let advanced = advancedParams(for: node)
                    if !advanced.isEmpty {
                        DisclosureGroup(isExpanded: $advancedExpanded) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(advanced) { param in
                                    ParameterSlider(param: param) { value in
                                        model.apply(nodeId: param.nodeId,
                                                    param: param.name,
                                                    value: value)
                                        viewport.setNeedsDisplay(viewport.bounds)
                                    } onReset: {
                                        model.resetParam(nodeId: param.nodeId,
                                                         param: param.name)
                                        viewport.setNeedsDisplay(viewport.bounds)
                                    }
                                }
                            }
                            .padding(.top, 8)
                        } label: {
                            HStack {
                                InspectorSectionHeader("ADVANCED")
                                Spacer()
                            }
                        }
                        .font(.caption.weight(.semibold))
                    }
                }
            }
        }
    }

    private func basicParams(for node: GraphNodeInfo) -> [GraphParameter] {
        node.params.filter { ParameterPresentation.for($0).group == .basic }
    }

    private func advancedParams(for node: GraphNodeInfo) -> [GraphParameter] {
        node.params.filter { ParameterPresentation.for($0).group == .advanced }
    }
}

private func outputColor(_ kind: GraphFieldKind) -> Color {
    switch kind {
    case .terrain: return .blue
    case .mask: return .cyan
    case .data: return .orange
    }
}

private struct InspectorSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.bold))
            .tracking(0.7)
            .foregroundStyle(.secondary)
    }
}

private struct NodeIdentityRow: View {
    let node: GraphNodeInfo
    let onResetAll: () -> Void
    private var presentation: NodePresentation {
        NodePresentation.for(node.type)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: presentation.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(presentation.tint)
                    .frame(width: 42, height: 42)
                    .background(presentation.tint.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(presentation.tint.opacity(0.26), lineWidth: 1))

                VStack(alignment: .leading, spacing: 3) {
                    Text(node.id)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    Text(presentation.subtitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button(action: onResetAll) {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .labelStyle(.iconOnly)
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .background(inspectorControlFill,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(inspectorControlStroke())
                .help("Reset node parameters and mask edits")
            }

            HStack(spacing: 8) {
                NodeIdentityChip(text: NodeTypeName.display(node.type),
                                 systemImage: "cube.transparent")
                NodeIdentityChip(text: node.type,
                                 systemImage: "number")
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.025),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 1))
    }
}

private struct NodeIdentityChip: View {
    let text: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(inspectorControlFill,
                    in: Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

private struct NodePresentation {
    let icon: String
    let tint: Color
    let subtitle: String

    static func `for`(_ type: String) -> NodePresentation {
        switch type {
        case "perlin":
            return NodePresentation(icon: "waveform.path.ecg",
                                    tint: .blue,
                                    subtitle: "Noise source")
        case "ridged":
            return NodePresentation(icon: "mountain.2",
                                    tint: .blue,
                                    subtitle: "Ridged noise source")
        case "scalebias":
            return NodePresentation(icon: "plus.forwardslash.minus",
                                    tint: .purple,
                                    subtitle: "Height remap")
        case "combine", "blend":
            return NodePresentation(icon: "square.stack.3d.up",
                                    tint: .indigo,
                                    subtitle: "Layer composition")
        case "invert", "clamp", "remap", "normalize":
            return NodePresentation(icon: "slider.horizontal.3",
                                    tint: .purple,
                                    subtitle: "Value shaping")
        case "blur", "warp":
            return NodePresentation(icon: "camera.filters",
                                    tint: .teal,
                                    subtitle: "Terrain filter")
        case "slopemask":
            return NodePresentation(icon: "circle.lefthalf.filled",
                                    tint: .green,
                                    subtitle: "Mask generator")
        case "hydraulic", "thermal", "dropleterosion":
            return NodePresentation(icon: "drop.triangle",
                                    tint: .orange,
                                    subtitle: "Erosion simulation")
        case "erosionfilter":
            return NodePresentation(icon: "water.waves",
                                    tint: .orange,
                                    subtitle: "Experimental gully filter")
        case "river":
            return NodePresentation(icon: "water.waves",
                                    tint: .cyan,
                                    subtitle: "River mask")
        case "rivercarve":
            return NodePresentation(icon: "water.waves.and.arrow.down",
                                    tint: .cyan,
                                    subtitle: "River terrain carve")
        case "terrace":
            return NodePresentation(icon: "stairs",
                                    tint: .brown,
                                    subtitle: "Stepped terrain")
        case "export":
            return NodePresentation(icon: "square.and.arrow.up",
                                    tint: .blue,
                                    subtitle: "Output terminal")
        default:
            return NodePresentation(icon: "circle.hexagongrid",
                                    tint: .secondary,
                                    subtitle: NodeTypeName.display(type))
        }
    }
}

struct ParameterSlider: View {
    let param: GraphParameter
    let onChange: (Double) -> Void
    let onReset: () -> Void

    @State private var value: Double
    private let config: SliderConfig
    private let presentation: ParameterPresentation

    init(param: GraphParameter,
         onChange: @escaping (Double) -> Void,
         onReset: @escaping () -> Void) {
        self.param = param
        self.onChange = onChange
        self.onReset = onReset
        _value = State(initialValue: param.value)
        config = SliderConfig.forParam(param)
        presentation = ParameterPresentation.for(param)
    }

    var body: some View {
        VStack(spacing: 0) {
            if param.nodeType == "blend", param.name == "mode" {
                row {
                    Menu {
                        ForEach(0..<blendModeNames.count, id: \.self) { mode in
                            Button(blendModeNames[mode]) {
                                value = Double(mode)
                                onChange(value)
                            }
                        }
                    } label: {
                        ParameterMenuLabel(title: blendModeName(Int(round(value))))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }
            } else {
                row {
                    ExportPlainSlider(value: Binding(
                        get: { value },
                        set: { newValue in
                            value = newValue
                            onChange(newValue)
                        }),
                                      range: config.range,
                                      step: config.step,
                                      isContinuous: true)
                        .frame(minWidth: 96)
                }
            }

            Divider()
                .opacity(0.45)
                .padding(.top, 12)
        }
        .padding(.vertical, 8)
        .onChange(of: param.value) { _, newValue in
            value = newValue
        }
    }

    private func row<Control: View>(@ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 10) {
            ParameterIconBox(systemName: presentation.icon)

            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.label)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                if let detail = presentation.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 132, alignment: .leading)

            control()
                .frame(maxWidth: .infinity)

            Button(action: onReset) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .background(inspectorControlFill,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(inspectorControlStroke())
            .help("Reset \(presentation.label)")

            InspectorValueField(value: value, config: config,
                                format: { presentation.format($0, config: config) }) { typed in
                value = typed
                onChange(typed)
            }
        }
        .frame(minHeight: 66)
    }

    private var blendModeNames: [String] {
        ["mix", "add", "multiply", "max", "min", "screen"]
    }

    private func blendModeName(_ mode: Int) -> String {
        guard blendModeNames.indices.contains(mode) else { return "mix" }
        return blendModeNames[mode]
    }
}

private struct ParameterMenuLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 34)
        .background(inspectorControlFill,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(inspectorControlStroke())
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ParameterIconBox: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 34, height: 34)
            .background(inspectorControlFill,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(inspectorControlStroke())
    }
}

private enum ParameterGroup {
    case basic
    case advanced
}

private struct ParameterPresentation {
    let label: String
    let detail: String?
    let unit: String?
    let icon: String
    let group: ParameterGroup

    func format(_ value: Double, config: SliderConfig) -> String {
        let base: String
        if unit == nil && config.precision == 0 {
            base = String(Int(round(value)))
        } else {
            base = config.format(value)
        }
        guard let unit else { return base }
        return "\(base)\(unit)"
    }

    static func `for`(_ param: GraphParameter) -> ParameterPresentation {
        ParameterPresentation(label: label(for: param),
                              detail: detail(for: param),
                              unit: unit(for: param),
                              icon: icon(for: param),
                              group: group(for: param))
    }

    private static func label(for param: GraphParameter) -> String {
        if param.nodeType == "hydraulic" {
            switch param.name {
            case "rain": return "Rainfall"
            case "suspension": return "Erosion Rate"
            case "sedimentCapacity": return "Sediment Capacity"
            case "minTilt": return "Slope Floor"
            case "heightScale": return "Vertical Scale"
            case "dt": return "Time Step"
            default: break
            }
        }
        let name = param.name
        switch name {
        case "dt": return "Delta Time"
        case "t": return "Mix"
        case "inLow": return "Input Low"
        case "inHigh": return "Input High"
        case "outLow": return "Output Low"
        case "outHigh": return "Output High"
        case "riverValleyWidth": return "Valley Width"
        case "shorelineWidth": return "Shoreline Width"
        case "shorelineSharpness": return "Shore Sharpness"
        case "heightScale": return "Height Scale"
        case "ridgeSharpness": return "Ridge Sharpness"
        case "maxAge": return "Max Age"
        case "maxDiff": return "Max Diff"
        case "momentumTransfer": return "Momentum"
        case "pipeArea": return "Pipe Area"
        case "pipeLength": return "Pipe Length"
        case "terrainSize": return "Terrain Size"
        case "erodibility": return "Erodibility"
        case "areaExponent": return "Area Exponent"
        case "slopeExponent": return "Slope Exponent"
        case "mfdExponent": return "Flow Convergence"
        case "uplift": return "Uplift"
        case "accuracy": return "Solver Accuracy"
        case "diffusion": return "Hillslope Diffusion"
        case "minSlope": return "Slope Floor"
        case "criticalSlope": return "Critical Slope"
        case "renderSurface": return "Render Surface"
        case "gullyWeight": return "Gully Weight"
        case "ridgeRounding": return "Ridge Rounding"
        case "creaseRounding": return "Crease Rounding"
        case "assumedSlope": return "Assumed Slope"
        case "slopeMix": return "Slope Override"
        case "cellScale": return "Cell Scale"
        case "heightOffset": return "Height Offset"
        case "fadeAuto": return "Fade Auto"
        case "fadeCenter": return "Fade Center"
        case "fadeRange": return "Fade Range"
        default:
            return ParameterName.display(name)
        }
    }

    private static func detail(for param: GraphParameter) -> String? {
        if param.nodeType == "hydraulic" {
            switch param.name {
            case "iterations":
                return "Controls simulation duration and erosion development."
            case "rain":
                return "Adds water uniformly during each simulation step."
            case "sedimentCapacity":
                return "Controls how much material moving water can carry."
            case "suspension":
                return "Controls how quickly flowing water picks up terrain."
            case "deposition":
                return "Controls how quickly excess sediment returns to the bed."
            case "dt":
                return "Numerical timestep, not effect strength. Keep it low."
            case "minTilt":
                return "Minimum slope used for capacity. High values erase slope selectivity."
            case "heightScale":
                return "Vertical scale inside the simulation; output height is unchanged."
            case "gravity":
                return "Pressure acceleration used by the virtual-pipe flow."
            case "pipeArea":
                return "Cross-section of each virtual flow pipe."
            case "pipeLength":
                return "Length of each virtual flow pipe."
            case "terrainSize":
                return "World width of the terrain. Cell spacing is derived from this and the grid, so results do not shift with resolution."
            case "evaporation":
                return "Removes water after flow and sediment transport."
            default: break
            }
        }
        switch param.name {
        case "frequency": return "Controls the overall scale."
        case "gain": return "Controls the amplitude."
        case "heightScale": return "Scales the output height."
        case "lacunarity": return "Gap between successive frequencies."
        case "octaves": return "Number of noise layers."
        case "particles": return "Simulation budget."
        case "iterations": return "Simulation pass count."
        case "maxAge": return "Particle lifetime."
        case "seed": return "Deterministic variation."
        case "mode" where param.nodeType == "blend": return "Blend formula."
        case "t": return "Mixes the first and second input."
        case "opacity": return "Controls blend contribution."
        case "scale": return "Multiplies incoming values."
        case "bias": return "Offsets incoming values."
        case "amount": return "Interpolates toward the effect."
        case "min": return "Lower clamp boundary."
        case "max": return "Upper clamp boundary."
        case "inLow": return "Input range start."
        case "inHigh": return "Input range end."
        case "outLow": return "Output range start."
        case "outHigh": return "Output range end."
        case "gamma": return "Shapes the remap curve."
        case "clamp": return "Limits values to the output range."
        case "radius": return "Filter sample radius."
        case "strength": return "Controls effect intensity."
        case "sharpness": return "Controls transition hardness."
        case "ridgeSharpness": return "Controls ridge contrast."
        case "steps": return "Number of terrace levels."
        case "low": return param.nodeType == "slopemask" ? "Minimum slope angle." : "Lower threshold."
        case "high": return param.nodeType == "slopemask" ? "Maximum slope angle." : "Upper threshold."
        case "depth": return "Controls carving depth."
        case "downcutting": return "Cuts channels into terrain."
        case "riverValleyWidth": return "Widens the carved valley."
        case "shorelineWidth": return "Softens riverbank width."
        case "shorelineSharpness": return "Controls bank edge hardness."
        case "headwaters": return "Number of river sources."
        case "water": return "Controls mask fill strength."
        case "deposition": return "Deposits carried sediment."
        case "entrainment": return "Picks up terrain sediment."
        case "evaporation": return "Reduces water over time."
        case "gravity": return "Controls downhill force."
        case "momentumTransfer": return "Carries flow direction forward."
        case "settling": return "Smooths unstable slopes."
        case "maxDiff": return "Limits local height changes."
        case "dt": return "Simulation timestep."
        case "minTilt": return "Minimum flow slope."
        case "rain": return "Adds water each iteration."
        case "sedimentCapacity": return "Maximum carried sediment."
        case "suspension": return "Keeps sediment in flow."
        case "pipeArea": return "Virtual pipe cross-section."
        case "pipeLength": return "Virtual pipe length."
        case "terrainSize": return "Terrain world width."
        case "erodibility": return "How fast channels cut (K)."
        case "areaExponent": return "Discharge influence on incision (m)."
        case "slopeExponent": return "Slope influence on incision (n)."
        case "mfdExponent": return "Higher values concentrate flow into sharper channels."
        case "uplift": return "Sustains relief against erosion. Zero preserves your input."
        case "accuracy": return "Flow solver iterations. Raise if channels look unresolved."
        case "diffusion": return "Smooths hillslopes and sets valley spacing. Too low grooves every cell."
        case "minSlope": return "Lets flat basins keep incising so they drain instead of filling in."
        case "criticalSlope": return "Gradient where hillslope transport runs away. Lower targets smoothing at steep grooves."
        case "talusAngle": return "Slope stability threshold."
        case "renderSurface": return "Switches preview surface mode."
        case "gullyWeight": return "Balances carved gullies against broad altitude shaping."
        case "detail" where param.nodeType == "erosionfilter": return "Sharpens branching detail across octaves."
        case "ridgeRounding": return "Rounds positive ridge transitions."
        case "creaseRounding": return "Rounds negative crease transitions."
        case "onset" where param.nodeType == "erosionfilter": return "Controls where slope-driven gullies begin."
        case "assumedSlope": return "Target slope used by directional gully tracing."
        case "slopeMix": return "Mixes measured terrain slope with the target slope."
        case "cellScale": return "Sets the procedural drainage-cell size."
        case "normalization" where param.nodeType == "erosionfilter": return "Controls phase blending between adjacent cells."
        case "heightOffset": return "Offsets each erosion octave vertically."
        case "fadeAuto": return "Fits the fade to the input's measured height range."
        case "fadeCenter": return "Altitude around which broad erosion changes direction."
        case "fadeRange": return "Width of the altitude-driven erosion transition."
        default: return nil
        }
    }

    private static func icon(for param: GraphParameter) -> String {
        switch param.name {
        case "frequency": return "waveform.path.ecg"
        case "gain": return "chart.line.uptrend.xyaxis"
        case "heightScale": return "mountain.2.fill"
        case "lacunarity": return "circle.dotted"
        case "octaves": return "square.3.layers.3d.down.right"
        case "seed": return "number"
        case "strength": return "dial.medium"
        case "radius": return "circle"
        case "width", "riverValleyWidth", "shorelineWidth": return "arrow.left.and.right"
        case "depth", "downcutting": return "arrow.down"
        case "water": return "drop.fill"
        case "particles", "iterations", "maxAge": return "timer"
        case "evaporation": return "cloud"
        case "deposition", "settling": return "tray.and.arrow.down"
        case "entrainment": return "wind"
        case "gravity": return "arrow.down.to.line"
        case "momentumTransfer": return "forward.frame"
        case "gullyWeight": return "water.waves"
        case "ridgeRounding", "creaseRounding": return "circle.dashed"
        case "assumedSlope", "slopeMix": return "angle"
        case "cellScale": return "square.grid.3x3"
        case "heightOffset": return "arrow.up.and.down"
        case "fadeAuto", "fadeCenter", "fadeRange": return "circle.lefthalf.filled"
        case "mode": return "square.stack.3d.up"
        default: return "slider.horizontal.3"
        }
    }

    private static func unit(for param: GraphParameter) -> String? {
        switch param.name {
        case "low" where param.nodeType == "slopemask",
             "high" where param.nodeType == "slopemask":
            return "°"
        default:
            return nil
        }
    }

    private static func group(for param: GraphParameter) -> ParameterGroup {
        if param.nodeType == "hydraulic" {
            switch param.name {
            case "iterations", "rain", "sedimentCapacity", "suspension", "deposition":
                return .basic
            default:
                return .advanced
            }
        }
        let advancedNames: Set<String> = [
            "particles", "maxAge", "iterations", "dt", "pipeArea",
            "pipeLength", "rain", "sedimentCapacity", "suspension",
            "terrainSize", "evaporation", "deposition", "entrainment",
            "areaExponent", "slopeExponent", "mfdExponent", "accuracy", "minSlope",
            "criticalSlope",
            "gravity", "momentumTransfer", "settling", "maxDiff"
        ]
        if advancedNames.contains(param.name) {
            return .advanced
        }
        if param.nodeType == "dropleterosion" {
            switch param.name {
            case "heightScale", "depth", "downcutting", "riverValleyWidth":
                return .basic
            default:
                return advancedNames.contains(param.name) ? .advanced : .basic
            }
        }
        if param.nodeType == "erosionfilter" {
            switch param.name {
            case "seed", "scale", "strength", "octaves", "gullyWeight", "detail":
                return .basic
            default:
                return .advanced
            }
        }
        return .basic
    }
}

let inspectorControlFill = Color.black.opacity(0.18)

func inspectorControlStroke() -> some View {
    RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.white.opacity(0.10), lineWidth: 1)
}

struct InspectorValueBox: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout.monospacedDigit().weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: 76, height: 34)
            .background(inspectorControlFill,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(inspectorControlStroke())
    }
}

/// Editable numeric readout. Typing is the only way to reach a precise value
/// when a slider's step is coarse, so the field commits the same clamped,
/// step-snapped value the slider would produce — a typed entry can never put a
/// parameter somewhere dragging could not.
struct InspectorValueField: View {
    let value: Double
    let config: SliderConfig
    let format: (Double) -> String
    let onCommit: (Double) -> Void

    @State private var draft: String
    @FocusState private var focused: Bool

    init(value: Double, config: SliderConfig,
         format: @escaping (Double) -> String,
         onCommit: @escaping (Double) -> Void) {
        self.value = value
        self.config = config
        self.format = format
        self.onCommit = onCommit
        _draft = State(initialValue: format(value))
    }

    /// Clamp first, then snap, then clamp again: snapping can push a value one
    /// step outside a range whose span is not a whole multiple of the step.
    static func sanitize(_ raw: Double, config: SliderConfig) -> Double? {
        guard raw.isFinite else { return nil }
        let lo = config.range.lowerBound
        let hi = config.range.upperBound
        var result = min(max(raw, lo), hi)
        if config.step > 0 {
            result = lo + ((result - lo) / config.step).rounded() * config.step
        }
        return min(max(result, lo), hi)
    }

    var body: some View {
        TextField("", text: $draft)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.center)
            .font(.callout.monospacedDigit().weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .focused($focused)
            .frame(width: 76, height: 34)
            .background(inspectorControlFill,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(inspectorControlStroke())
            .onSubmit(commit)
            .onChange(of: focused) { wasFocused, isFocused in
                if wasFocused && !isFocused { commit() }
            }
            .onChange(of: value) { _, newValue in
                // The slider, undo, and reset are all authoritative over an
                // in-progress draft; keeping the stale text would write it back
                // on the next blur and silently undo them.
                draft = format(newValue)
            }
            .help("Type a value between \(format(config.range.lowerBound)) "
                  + "and \(format(config.range.upperBound))")
    }

    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard let parsed = Double(text),
              let sanitized = Self.sanitize(parsed, config: config) else {
            draft = format(value)   // unparseable: restore, never guess
            return
        }
        draft = format(sanitized)
        if sanitized != value { onCommit(sanitized) }
    }
}

private enum NodeTypeName {
    static func display(_ type: String) -> String {
        switch type {
        case "scalebias": return "Scale Bias"
        case "dropleterosion": return "Droplet Erosion"
        case "erosionfilter": return "Erosion Filter"
        case "rivercarve": return "River Carve"
        case "slopemask": return "Slope Mask"
        default:
            return splitCamel(type.prefix(1).uppercased() + type.dropFirst())
        }
    }
}

private enum ParameterName {
    static func display(_ name: String) -> String {
        switch name {
        case "dt": return "Delta Time"
        case "t": return "Mix"
        default:
            return splitCamel(name.prefix(1).uppercased() + name.dropFirst())
        }
    }
}

private func splitCamel<S: StringProtocol>(_ value: S) -> String {
    var output = ""
    for scalar in String(value).unicodeScalars {
        let char = Character(scalar)
        if CharacterSet.uppercaseLetters.contains(scalar),
           !output.isEmpty,
           !output.hasSuffix(" ") {
            output.append(" ")
        }
        output.append(char)
    }
    return output
}

struct SliderConfig {
    let range: ClosedRange<Double>
    let step: Double
    let precision: Int

    func format(_ value: Double) -> String {
        String(format: "%.\(precision)f", value)
    }

    static func forParam(_ param: GraphParameter) -> SliderConfig {
        let name = param.name
        let value = param.value
        switch name {
        case "seed":
            return SliderConfig(range: 0...9999, step: 1, precision: 0)
        case "octaves":
            if param.nodeType == "erosionfilter" {
                return SliderConfig(range: 1...8, step: 1, precision: 0)
            }
            return SliderConfig(range: 1...12, step: 1, precision: 0)
        case "iterations":
            if param.nodeType == "fluvial" {
                return SliderConfig(range: 1...400, step: 1, precision: 0)
            }
            return SliderConfig(range: 1...300, step: 1, precision: 0)
        case "particles":
            return SliderConfig(range: 100...50000, step: 100, precision: 0)
        case "maxAge":
            return SliderConfig(range: 1...300, step: 1, precision: 0)
        case "frequency":
            return SliderConfig(range: 0.1...32, step: 0.1, precision: 1)
        case "lacunarity":
            return SliderConfig(range: 1...4, step: 0.05, precision: 2)
        case "gain", "t", "opacity", "amount",
             "water", "depth", "downcutting":
            return SliderConfig(range: 0...1, step: 0.01, precision: 2)
        case "rain":
            if param.nodeType == "hydraulic" {
                return SliderConfig(range: 0...0.05, step: 0.001, precision: 3)
            }
            if param.nodeType == "fluvial" {
                return SliderConfig(range: 0...8, step: 0.1, precision: 1)
            }
            return SliderConfig(range: 0...1, step: 0.01, precision: 2)
        case "sedimentCapacity", "suspension":
            return SliderConfig(range: 0...1, step: 0.01, precision: 2)
        case "minTilt":
            if param.nodeType == "hydraulic" {
                return SliderConfig(range: 0...0.15, step: 0.005, precision: 3)
            }
            return SliderConfig(range: 0...1, step: 0.01, precision: 2)
        case "deposition":
            if param.nodeType == "fluvial" {
                // G in the Yuan et al. deposition term, not a 0-1 rate.
                return SliderConfig(range: 0...4, step: 0.05, precision: 2)
            }
            return SliderConfig(range: 0...0.6, step: 0.01, precision: 2)
        case "evaporation":
            if param.nodeType == "hydraulic" {
                return SliderConfig(range: 0...0.1, step: 0.005, precision: 3)
            }
            return SliderConfig(range: 0...0.4, step: 0.005, precision: 3)
        case "width":
            if param.nodeType == "river" {
                return SliderConfig(range: 0.25...16, step: 0.25, precision: 2)
            }
            return SliderConfig(range: 0...16, step: 0.25, precision: 2)
        case "strength":
            if param.nodeType == "warp" {
                return SliderConfig(range: 0...0.35, step: 0.005, precision: 3)
            }
            return SliderConfig(range: 0...1, step: 0.01, precision: 2)
        case "mode":
            return SliderConfig(range: 0...5, step: 1, precision: 0)
        case "renderSurface":
            return SliderConfig(range: 0...1, step: 1, precision: 0)
        case "low", "high":
            if param.nodeType == "slopemask" {
                return SliderConfig(range: 0...90, step: 1, precision: 0)
            }
            return SliderConfig(range: 0...1, step: 0.01, precision: 2)
        case "min", "max", "inLow", "inHigh", "outLow", "outHigh", "clamp":
            return SliderConfig(range: 0...1, step: 0.01, precision: 2)
        case "gamma":
            return SliderConfig(range: 0.1...4, step: 0.05, precision: 2)
        case "entrainment":
            return SliderConfig(range: 0...24, step: 0.1, precision: 1)
        case "momentumTransfer":
            return SliderConfig(range: 0...4, step: 0.05, precision: 2)
        case "settling":
            return SliderConfig(range: 0...1, step: 0.01, precision: 2)
        case "maxDiff":
            return SliderConfig(range: 0.001...0.2, step: 0.001, precision: 3)
        case "scale":
            if param.nodeType == "erosionfilter" {
                return SliderConfig(range: 0.005...0.06, step: 0.005, precision: 3)
            }
            return SliderConfig(range: -4...4, step: 0.01, precision: 2)
        case "gullyWeight":
            return SliderConfig(range: 0...0.65, step: 0.01, precision: 2)
        case "normalization":
            return SliderConfig(range: 0...0.5, step: 0.01, precision: 2)
        case "slopeMix", "ridgeRounding", "creaseRounding":
            return SliderConfig(range: 0...1, step: 0.01, precision: 2)
        case "detail":
            return SliderConfig(range: 0.1...4, step: 0.05, precision: 2)
        case "onset":
            return SliderConfig(range: 0.1...4, step: 0.05, precision: 2)
        case "assumedSlope":
            return SliderConfig(range: 0.05...3, step: 0.05, precision: 2)
        case "cellScale":
            return SliderConfig(range: 0.1...2, step: 0.05, precision: 2)
        case "heightOffset":
            return SliderConfig(range: -1...1, step: 0.01, precision: 2)
        case "fadeAuto":
            return SliderConfig(range: 0...1, step: 1, precision: 0)
        case "fadeCenter":
            return SliderConfig(range: 0...1, step: 0.01, precision: 2)
        case "fadeRange":
            return SliderConfig(range: 0.01...1, step: 0.01, precision: 2)
        case "riverValleyWidth":
            return SliderConfig(range: 0...12, step: 0.1, precision: 1)
        case "shorelineWidth":
            return SliderConfig(range: 0...12, step: 0.1, precision: 1)
        case "shorelineSharpness":
            return SliderConfig(range: 0...1, step: 0.01, precision: 2)
        case "bias":
            return SliderConfig(range: -1...1, step: 0.01, precision: 2)
        case "radius":
            return SliderConfig(range: 0...16, step: 1, precision: 0)
        case "headwaters":
            return SliderConfig(range: 1...64, step: 1, precision: 0)
        case "steps":
            return SliderConfig(range: 2...32, step: 1, precision: 0)
        case "sharpness", "ridgeSharpness":
            return SliderConfig(range: 0.1...10, step: 0.1, precision: 1)
        case "talusAngle":
            return SliderConfig(range: 1...60, step: 0.5, precision: 1)
        case "heightScale":
            if param.nodeType == "fluvial" {
                return SliderConfig(range: 1...4096, step: 1, precision: 0)
            }
            if param.nodeType == "perlin" || param.nodeType == "ridged" {
                return SliderConfig(range: 0...2, step: 0.05, precision: 2)
            }
            if param.nodeType == "slopemask" {
                return SliderConfig(range: 1...300, step: 1, precision: 0)
            }
            if param.nodeType == "hydraulic" {
                return SliderConfig(range: 10...150, step: 1, precision: 0)
            }
            return SliderConfig(range: 1...200, step: 1, precision: 0)
        case "dt":
            if param.nodeType == "hydraulic" {
                return SliderConfig(range: 0.001...0.025, step: 0.001, precision: 3)
            }
            if param.nodeType == "fluvial" {
                // Landscape-evolution time, not storm seconds: the useful step
                // is ~1, three orders of magnitude above the hydraulic range.
                return SliderConfig(range: 0.01...2, step: 0.01, precision: 2)
            }
            return SliderConfig(range: 0.001...0.1, step: 0.001, precision: 3)
        case "gravity":
            if param.nodeType == "hydraulic" {
                return SliderConfig(range: 0...20, step: 0.1, precision: 1)
            }
            return SliderConfig(range: 0...6, step: 0.1, precision: 1)
        case "pipeArea", "pipeLength":
            return SliderConfig(range: 0.1...4, step: 0.1, precision: 1)
        case "terrainSize":
            return SliderConfig(range: 32...4096, step: 32, precision: 0)

        // Fluvial (stream power) controls. Each range is identical to the
        // clamp the core applies, so a value set here is never silently
        // rewritten on evaluation.
        case "erodibility":
            return SliderConfig(range: 0...2, step: 0.01, precision: 2)
        case "areaExponent":
            return SliderConfig(range: 0...1, step: 0.01, precision: 2)
        case "slopeExponent":
            return SliderConfig(range: 0.1...4, step: 0.05, precision: 2)
        case "uplift":
            return SliderConfig(range: 0...1, step: 0.01, precision: 2)
        case "mfdExponent":
            return SliderConfig(range: 0.5...6, step: 0.1, precision: 1)
        case "diffusion":
            return SliderConfig(range: 0...0.5, step: 0.005, precision: 3)
        case "criticalSlope":
            return SliderConfig(range: 0.1...4, step: 0.05, precision: 2)
        case "accuracy":
            return SliderConfig(range: 0.25...4, step: 0.25, precision: 2)
        case "minSlope":
            return SliderConfig(range: 0...0.1, step: 0.001, precision: 3)

        default:
            // Anchor the fallback on the node's DEFAULT value, not the live
            // one. A range derived from the live value slides outward as the
            // user drags, so the control never reaches an end stop and behaves
            // as if unbounded. Anchoring makes it stable and finite, and the
            // hard cap keeps a pathological default from reintroducing that.
            let anchor = GraphDocument.defaultParams(for: param.nodeType)[param.name]
                ?? value
            let base = anchor.isFinite ? anchor : 0
            let span = max(1, abs(base) * 4)
            let lower = max(-1_000_000, base - span)
            let upper = min(1_000_000, base + span)
            return SliderConfig(range: lower...max(upper, lower + 1e-6),
                                step: span / 100,
                                precision: 2)
        }
    }
}
