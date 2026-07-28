import MetalKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import simd

/// Header height for the side panels (inspector, graph column). Matches the
/// unified title bar so the three columns line up along a single rule.
private let panelHeaderHeight: CGFloat = 34

struct TerrainViewport: NSViewRepresentable {
    let view: TerrainMTKView

    func makeNSView(context: Context) -> TerrainMTKView { view }
    func updateNSView(_ nsView: TerrainMTKView, context: Context) {
        nsView.syncBrushCursorState()
    }
}

struct ContentView: View {
    @ObservedObject var model: TerrainModel
    let viewport: TerrainMTKView

    var body: some View {
        VStack(spacing: 0) {
            TheiaTitleBar(model: model, viewport: viewport)

            // Gaea's arrangement: properties run the full height of the right
            // edge, the viewport takes the top of the remaining area, and the
            // graph spans the bottom beneath it.
            HSplitView {
                VSplitView {
                    ZStack(alignment: .bottomTrailing) {
                        ViewportSurface(model: model, viewport: viewport)

                        if let evaluation = model.previewEvaluation {
                            PreviewEvaluationBadge(evaluation: evaluation)
                                .padding(.leading, 14)
                                .padding(.bottom, 12)
                                .frame(maxWidth: .infinity, maxHeight: .infinity,
                                       alignment: .bottomLeading)
                        }

                        StatusBadge(model: model)
                            .padding(.trailing, 14)
                            .padding(.bottom, 12)
                    }
                    .frame(minHeight: 260, idealHeight: 640)
                    // The viewport absorbs spare height, so the graph settles at
                    // its minimum and the split opens near Gaea's ~60/40. The
                    // user can still drag the divider to grow the graph.
                    .layoutPriority(1)

                    GraphColumn(model: model, viewport: viewport)
                        .frame(minHeight: 400, idealHeight: 440)
                }
                .frame(minWidth: 620)

                InspectorPanel(model: model, viewport: viewport)
                    .frame(minWidth: 300, idealWidth: 380, maxWidth: 460)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}

struct PreviewEvaluationBadge: View {
    let evaluation: PreviewEvaluationState

    private var previewTitle: String {
        let title = NodeTypeCatalog.title(for: evaluation.nodeType)
        let nodeTitle = title.isEmpty ? "terrain" : title
        let defaultOutput = GraphDocument.defaultOutputName(for: evaluation.nodeType)
        guard !evaluation.output.isEmpty,
              evaluation.output != defaultOutput else { return nodeTitle }
        return "\(nodeTitle) · \(evaluation.output.capitalized)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Updating \(previewTitle) preview…")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)

            ProgressView()
                .progressViewStyle(.linear)
                .tint(NodeTypeCatalog.categoryColor(for: evaluation.nodeType))
                .frame(width: 210)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Color.black.opacity(0.68),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 1))
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview status")
        .accessibilityValue("Updating \(previewTitle) preview")
    }
}

struct ViewportSurface: View {
    @ObservedObject var model: TerrainModel
    let viewport: TerrainMTKView
    @State private var toolbarHint: String?
    @State private var showingViewportSettings = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            TerrainViewport(view: viewport)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            floatingViewportMenus
                .padding(.top, 10)
                .padding(.leading, 12)

            AxisGizmo(model: model, cameraSignal: model.cameraSignal,
                      viewport: viewport)
                .frame(width: 76, height: 76)
                .padding(.top, 8)
                .padding(.trailing, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .topTrailing)

            toolbarHintOverlay
        }
    }

    @ViewBuilder
    private var toolbarHintOverlay: some View {
        if let toolbarHint {
            Text(toolbarHint)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(Color.black.opacity(0.48),
                            in: Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1))
                .padding(.trailing, 12)
                .padding(.bottom, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .bottomTrailing)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private var floatingViewportMenus: some View {
        HStack(spacing: 8) {
            viewProjectionMenu
            displayModeMenu
            materialPresetMenu
            viewportSettingsButton
        }
    }

    private var viewProjectionMenu: some View {
        Menu {
            menuCheckButton("Perspective",
                            selected: model.viewportProjection == .perspective,
                            action: {
                                model.setViewportProjection(.perspective)
                                redraw()
                            })
            menuCheckButton("Orthographic",
                            selected: model.viewportProjection == .orthographic,
                            action: {
                                model.setViewportProjection(.orthographic)
                                redraw()
                            })

            Divider()

            Button("Reset Camera") {
                model.resetCamera()
                redraw()
            }
            Button("Top") {
                model.setCameraPreset(.top)
                redraw()
            }
        } label: {
            HStack(spacing: 6) {
                Text(model.viewportProjection.label)
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(0.72)
            }
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.42),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .help("Projection and camera options")
        }
        .buttonStyle(.plain)
        .onHover { setToolbarHint("Projection and camera options", hovering: $0) }
    }

    private var displayModeMenu: some View {
        Menu {
            ForEach(ViewportDisplayMode.allCases, id: \.self) { mode in
                menuCheckButton(mode.label,
                                selected: model.displayMode == mode,
                                action: {
                                    model.setDisplayMode(mode)
                                    redraw()
                                })
            }
        } label: {
            Image(systemName: "circle.lefthalf.filled")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 30, height: 30)
                .background(Color.black.opacity(0.42),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help("Display mode")
        }
        .buttonStyle(.plain)
        .onHover { setToolbarHint("Display mode: \(model.displayMode.label)", hovering: $0) }
    }

    private var materialPresetMenu: some View {
        Menu {
            ForEach(MaterialPreset.allCases, id: \.self) { preset in
                menuCheckButton(preset.label,
                                selected: model.materialPreset == preset,
                                action: {
                                    model.setMaterialPreset(preset)
                                    redraw()
                                })
            }
        } label: {
            Circle()
                .fill(materialSwatch(model.materialPreset))
                .overlay(Circle().stroke(Color.white.opacity(0.28), lineWidth: 1))
                .frame(width: 15, height: 15)
                .frame(width: 30, height: 30)
                .background(Color.black.opacity(0.42),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help("Material preset")
        }
        .buttonStyle(.plain)
        .onHover { setToolbarHint("Material: \(model.materialPreset.label)", hovering: $0) }
    }

    private var viewportSettingsButton: some View {
        Button {
            showingViewportSettings.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 30, height: 30)
                .background(Color.black.opacity(0.42),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .help("Viewport settings")
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingViewportSettings, arrowEdge: .top) {
            ViewportSettingsPopover(model: model, viewport: viewport)
                .frame(width: 270)
                .padding(14)
        }
        .onHover { setToolbarHint("Viewport settings", hovering: $0) }
    }

    private func menuCheckButton(_ title: String, selected: Bool,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                if selected {
                    Image(systemName: "checkmark")
                }
                Text(title)
            }
        }
    }

    private func materialSwatch(_ preset: MaterialPreset) -> Color {
        switch preset {
        case .natural:
            return Color(red: 0.36, green: 0.62, blue: 0.36)
        case .alpine:
            return Color(red: 0.78, green: 0.86, blue: 0.92)
        case .arid:
            return Color(red: 0.78, green: 0.58, blue: 0.34)
        case .analysis:
            return Color(red: 0.26, green: 0.55, blue: 0.95)
        }
    }

    private func setToolbarHint(_ hint: String, hovering: Bool) {
        if hovering {
            toolbarHint = hint
        } else if toolbarHint == hint {
            toolbarHint = nil
        }
    }

    private func redraw() {
        viewport.setNeedsDisplay(viewport.bounds)
    }
}

struct AxisGizmo: View {
    let model: TerrainModel
    @ObservedObject var cameraSignal: ViewportCameraSignal
    let viewport: TerrainMTKView
    private let center = CGPoint(x: 38, y: 40)

    var body: some View {
        let revision = cameraSignal.revision
        let xAxis = axisLayout(axis: SIMD3<Float>(1, 0, 0), revision: revision)
        let yAxis = axisLayout(axis: SIMD3<Float>(0, 0, 1), revision: revision)
        let zAxis = axisLayout(axis: SIMD3<Float>(0, 1, 0), revision: revision)
        ZStack {
            gizmoLine(from: center, to: xAxis.negative.point, color: .red.opacity(0.28))
            gizmoLine(from: center, to: yAxis.negative.point, color: .green.opacity(0.28))
            gizmoLine(from: center, to: zAxis.negative.point, color: .blue.opacity(0.28))
            gizmoLine(from: center, to: xAxis.positive.point, color: .red.opacity(0.9))
            gizmoLine(from: center, to: yAxis.positive.point, color: .green.opacity(0.9))
            gizmoLine(from: center, to: zAxis.positive.point, color: .blue.opacity(0.9))
            gizmoHub()
            gizmoDot(xAxis.negative.point, color: dotColor(.red, depth: xAxis.negative.depth), label: "",
                     help: "View from -X", preset: .left)
            gizmoDot(yAxis.negative.point, color: dotColor(.green, depth: yAxis.negative.depth), label: "",
                     help: "View from -Y", preset: .back)
            gizmoDot(zAxis.negative.point, color: dotColor(.blue, depth: zAxis.negative.depth), label: "",
                     help: "Bottom view from -Z", preset: .bottom)
            gizmoDot(xAxis.positive.point, color: dotColor(.red, depth: xAxis.positive.depth), label: "X",
                     help: "View from +X", preset: .right)
            gizmoDot(yAxis.positive.point, color: dotColor(.green, depth: yAxis.positive.depth), label: "Y",
                     help: "View from +Y", preset: .front)
            gizmoDot(zAxis.positive.point, color: dotColor(.blue, depth: zAxis.positive.depth), label: "Z",
                     help: "Top view from +Z", preset: .top)
        }
    }

    private func gizmoLine(from: CGPoint, to: CGPoint, color: Color) -> some View {
        Path { p in
            p.move(to: from)
            p.addLine(to: to)
        }
        .stroke(color, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
    }

    private func gizmoHub() -> some View {
        Button {
            model.resetCamera()
            redraw()
        } label: {
            Circle()
                .fill(Color.white.opacity(0.22))
                .overlay(Circle().stroke(Color.white.opacity(0.36), lineWidth: 1))
                .frame(width: 13, height: 13)
        }
        .buttonStyle(.plain)
        .help("Reset camera")
        .position(center)
    }

    private func gizmoDot(_ point: CGPoint, color: Color, label: String,
                          help: String, preset: CameraPreset) -> some View {
        Button {
            model.setCameraPreset(preset)
            redraw()
        } label: {
            Circle()
                .fill(color)
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                .frame(width: 18, height: 18)
                .overlay {
                    if !label.isEmpty {
                        Text(label)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.black.opacity(0.78))
                    }
                }
        }
        .buttonStyle(.plain)
        .help(help)
        .position(point)
    }

    private typealias AxisEndpoint = (point: CGPoint, depth: CGFloat)

    private func axisLayout(axis: SIMD3<Float>,
                            revision: UInt64) -> (positive: AxisEndpoint,
                                                   negative: AxisEndpoint) {
        _ = revision
        return (axisEndpoint(axis), axisEndpoint(-axis))
    }

    private func axisEndpoint(_ axis: SIMD3<Float>) -> AxisEndpoint {
        let b = model.renderer.camera.basis()
        let x = CGFloat(dot(axis, b.right))
        let y = CGFloat(-dot(axis, b.up))
        let depth = CGFloat(dot(axis, b.forward))
        let radius: CGFloat = 29
        let point = CGPoint(x: center.x + x * radius,
                            y: center.y + y * radius)
        return (point, depth)
    }

    private func dotColor(_ color: Color, depth: CGFloat) -> Color {
        color.opacity(depth >= 0 ? 0.98 : 0.48)
    }

    private func redraw() {
        viewport.setNeedsDisplay(viewport.bounds)
    }
}

struct StatusBadge: View {
    @ObservedObject var model: TerrainModel
    @State private var expanded = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    expanded.toggle()
                }
            } label: {
                Group {
                    if expanded {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(model.isDirty ? "Unsaved" : "Saved")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(model.isDirty ? .orange : .green)

                            Text(model.isDirty
                                 ? "Last saved \(savedTimestamp(relativeTo: timeline.date))"
                                 : savedTimestamp(relativeTo: timeline.date))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .bottomTrailing)))
                    } else {
                        Image(systemName: model.isDirty ? "clock.fill" : "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(model.isDirty ? .orange : .green)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                            .transition(.opacity.combined(with: .scale(scale: 0.86)))
                    }
                }
                .padding(.horizontal, expanded ? 10 : 4)
                .padding(.vertical, expanded ? 8 : 4)
                .background(Color.black.opacity(0.58),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(model.isDirty ? "Unsaved changes" : "Saved")
            .animation(.spring(response: 0.22, dampingFraction: 0.82),
                       value: expanded)
            .animation(.easeOut(duration: 0.18), value: model.isDirty)
        }
    }

    private func savedTimestamp(relativeTo now: Date) -> String {
        guard let savedAt = model.lastSavedAt else { return "Not saved yet" }
        let calendar = Calendar.current
        let seconds = max(0, Int(now.timeIntervalSince(savedAt)))
        if seconds < 60 { return "Just now" }
        let minutes = seconds / 60
        if calendar.isDateInToday(savedAt), minutes <= 15 {
            return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
        }
        let time = savedAt.formatted(.dateTime.hour().minute())
        if calendar.isDateInToday(savedAt) {
            return "Today at \(time)"
        }
        if calendar.isDateInYesterday(savedAt) {
            return "Yesterday at \(time)"
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: now),
           savedAt >= weekAgo {
            let weekday = savedAt.formatted(.dateTime.weekday(.wide))
            return "\(weekday) at \(time)"
        }
        let day = savedAt.formatted(.dateTime.month(.abbreviated).day())
        return "\(day) at \(time)"
    }
}

struct InspectorPanel: View {
    @ObservedObject var model: TerrainModel
    let viewport: TerrainMTKView

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Inspector")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.5)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: panelHeaderHeight)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(theiaChromeDivider)
                    .frame(height: 1)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if selectedNodeType == "export" {
                        ExportControls(model: model)
                            .padding(.horizontal, 14)

                        Divider()
                            .padding(.horizontal, 14)
                    }

                    NodeParameterInspector(model: model, viewport: viewport)
                        .padding(.horizontal, 14)
                }
                .padding(.vertical, 14)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var selectedNodeType: String? {
        guard let id = model.selectedNodeId else { return nil }
        return model.document.node(id: id)?.type
    }

}
