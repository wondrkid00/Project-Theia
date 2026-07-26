import MetalKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import simd

private let topToolbarHeight: CGFloat = 68
private let topToolbarDividerColor = Color.white.opacity(0.08)

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
        ZStack(alignment: .bottomTrailing) {
            HSplitView {
                VSplitView {
                    ViewportSurface(model: model, viewport: viewport)
                        .frame(minWidth: 560, minHeight: 360, idealHeight: 720)
                        .layoutPriority(3)

                    AuthoringDock(model: model, viewport: viewport)
                        .frame(minWidth: 560, minHeight: 378, idealHeight: 420)
                        .layoutPriority(1)
                }
                .frame(minWidth: 560, minHeight: 680)

                InspectorPanel(model: model, viewport: viewport)
                    .frame(minWidth: 340, idealWidth: 400, maxWidth: 460)
            }

            StatusBadge(model: model)
                .padding(.trailing, 14)
                .padding(.bottom, 12)
        }
    }
}

private enum AuthoringDockTab: String, CaseIterable {
    case graph
    case output

    var title: String {
        switch self {
        case .graph: return "Graph"
        case .output: return "Output"
        }
    }

    var systemImage: String {
        switch self {
        case .graph: return "rectangle.connected.to.line.below"
        case .output: return "text.bubble"
        }
    }
}

struct AuthoringDock: View {
    @ObservedObject var model: TerrainModel
    let viewport: TerrainMTKView
    @State private var selectedTab: AuthoringDockTab = .graph
    private let uiSpring = Animation.spring(response: 0.24, dampingFraction: 0.86)

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch selectedTab {
                case .graph:
                    NodeEditorCanvas(model: model, viewport: viewport)
                        .transition(.opacity.combined(with: .scale(scale: 0.995, anchor: .bottom)))
                case .output:
                    GraphOutputPanel(model: model, viewport: viewport)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(uiSpring, value: selectedTab)

            dockTabBar
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var dockTabBar: some View {
        HStack(spacing: 6) {
            ForEach(AuthoringDockTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(uiSpring) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 12, weight: .semibold))
                        Text(tab.title)
                            .font(.system(size: 12, weight: .semibold))
                        if tab == .output {
                            outputBadge
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                    .background(selectedTab == tab
                                ? Color.white.opacity(0.10)
                                : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .contentShape(Rectangle())
                    .scaleEffect(selectedTab == tab ? 1.0 : 0.98)
                    .animation(.easeOut(duration: 0.14), value: selectedTab)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var outputBadge: some View {
        let errors = model.diagnostics.authoringErrorCount
        let warnings = model.diagnostics.authoringWarningCount
        if errors > 0 || warnings > 0 {
            Text("\(errors + warnings)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(errors > 0 ? .red : .orange)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background((errors > 0 ? Color.red : Color.orange).opacity(0.14),
                            in: Capsule(style: .continuous))
                .transition(.scale.combined(with: .opacity))
                .animation(.spring(response: 0.22, dampingFraction: 0.78),
                           value: errors + warnings)
        }
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

            VStack(spacing: 0) {
                viewportToolbar
                Spacer()
            }

            floatingViewportMenus
                .padding(.top, topToolbarHeight + 10)
                .padding(.leading, 12)

            AxisGizmo(model: model, cameraSignal: model.cameraSignal,
                      viewport: viewport)
                .frame(width: 76, height: 76)
                .padding(.top, topToolbarHeight + 8)
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

    private var viewportToolbar: some View {
        HStack(alignment: .top, spacing: 8) {
            toolbarGroup("File") {
                viewportButton(systemImage: "folder",
                               title: "Load",
                               help: "Load graph") {
                    openDocument()
                    redraw()
                }
                viewportButton(title: "Save",
                               help: "Save graph",
                               action: {
                    saveDocument()
                    redraw()
                }) {
                    FloppyDiskIcon()
                }
            }

            toolbarDivider

            toolbarGroup("Camera") {
                viewportButton(systemImage: "viewfinder",
                               title: "Reset",
                               help: "Reset camera (F)") {
                    model.resetCamera()
                    redraw()
                }
                viewportButton(systemImage: "arrow.triangle.2.circlepath",
                               title: "Orbit",
                               help: "Orbit tool (O): left drag orbits the camera.",
                               active: model.viewportTool == .orbit) {
                    model.setViewportTool(.orbit)
                    redraw()
                }
                viewportButton(systemImage: "hand.draw",
                               title: "Pan",
                               help: "Pan tool (H): left drag pans the camera.",
                               active: model.viewportTool == .pan) {
                    model.setViewportTool(.pan)
                    redraw()
                }
                viewportButton(systemImage: "magnifyingglass",
                               title: "Zoom",
                               help: "Zoom tool (Z): left drag vertically zooms the camera.",
                               active: model.viewportTool == .zoom) {
                    model.setViewportTool(.zoom)
                    redraw()
                }
            }

            toolbarDivider

            if model.canEditActiveMask {
                toolbarGroup("Mask") {
                    viewportButton(systemImage: "eraser",
                                   title: "Erase",
                                   help: "Mask eraser (E): drag on terrain to remove unwanted mask paths.",
                                   active: model.maskBrushEnabled) {
                        model.setMaskBrushEnabled(!model.maskBrushEnabled)
                        redraw()
                    }
                }

                toolbarDivider
            }

            toolbarGroup("Display") {
                viewportButton(systemImage: "square.grid.3x3",
                               title: "Grid",
                               help: "Toggle grid",
                               active: model.gridVisible) {
                    model.setGridVisible(!model.gridVisible)
                    redraw()
                }
                viewportButton(systemImage: "arrow.up.and.down.and.arrow.left.and.right",
                               title: "Axes",
                               help: "Toggle axes",
                               active: model.axisVisible) {
                    model.setAxisVisible(!model.axisVisible)
                    redraw()
                }
                viewportButton(systemImage: "cube.transparent",
                               title: "Wire",
                               help: "Toggle wireframe",
                               active: model.wireframeEnabled) {
                    model.wireframeEnabled.toggle()
                    model.applyViewportSettings()
                    redraw()
                }
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .frame(height: topToolbarHeight)
        .background(Color(red: 0.115, green: 0.12, blue: 0.13).opacity(0.96))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(topToolbarDividerColor)
                .frame(height: 1)
        }
    }

    private func toolbarGroup<Content: View>(_ title: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                content()
            }
            Text(title)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.38))
                .textCase(.uppercase)
                .lineLimit(1)
        }
    }

    private func viewportButton(systemImage: String, title: String, help: String,
                                active: Bool = false,
                                action: @escaping () -> Void) -> some View {
        viewportButton(title: title, help: help, active: active, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
        }
    }

    private func viewportButton<Icon: View>(title: String, help: String,
                                            active: Bool = false,
                                            action: @escaping () -> Void,
                                            @ViewBuilder icon: () -> Icon) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                icon()
                    .frame(height: 18)
                Text(title)
                    .font(.system(size: 8, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 43, height: 42)
            .contentShape(Rectangle())
            .background(active ? Color.accentColor.opacity(0.35) : Color.white.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Color.accentColor : Color.white.opacity(0.86))
        .accessibilityLabel(Text(help))
        .onHover { setToolbarHint(help, hovering: $0) }
        .help(help)
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

    private var toolbarDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 48)
            .padding(.horizontal, 4)
            .padding(.top, 1)
    }

    private func redraw() {
        viewport.setNeedsDisplay(viewport.bounds)
    }

    private func saveDocument() {
        if model.graphPath != nil {
            _ = model.save()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "terrain-graph.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = model.save(to: url.path)
    }

    private func openDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.load(from: url.path)
    }
}

private struct FloppyDiskIcon: View {
    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 25, height: 25)
        } else {
            Image(systemName: "externaldrive")
                .font(.system(size: 15, weight: .semibold))
        }
    }

    private static let image: NSImage? = {
        guard let url = Bundle.module.url(forResource: "save_icon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.isTemplate = true
        return image
    }()
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
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: topToolbarHeight)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(topToolbarDividerColor)
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

struct GraphActions: View {
    @ObservedObject var model: TerrainModel
    let viewport: TerrainMTKView

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Graph")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    openDocument()
                    viewport.setNeedsDisplay(viewport.bounds)
                } label: {
                    Label("Load", systemImage: "folder")
                }
                .buttonStyle(.borderless)
                Button {
                    saveDocument()
                    viewport.setNeedsDisplay(viewport.bounds)
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
            }

            HStack {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(model.isDirty ? .orange : .secondary)
                Spacer()
            }

            if let nodeId = model.selectedNodeId,
               let node = model.document.node(id: nodeId) {
                HStack {
                    Text("selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(node.id) / \(node.type)")
                        .font(.caption.monospaced())
                        .lineLimit(1)
                    Spacer()
                }
            } else if model.selectedConnectionId != nil {
                HStack {
                    Text("edge selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.deleteSelection()
                        viewport.setNeedsDisplay(viewport.bounds)
                    } label: {
                        Label("Disconnect", systemImage: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var statusText: String {
        let state = model.isDirty ? "unsaved changes" :
            (model.saveStatus.isEmpty ? "saved in memory" : model.saveStatus)
        guard let path = model.graphPath else { return state }
        return "\(state) - \(URL(fileURLWithPath: path).lastPathComponent)"
    }

    private func saveDocument() {
        if let _ = model.graphPath {
            _ = model.save()
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "terrain-graph.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = model.save(to: url.path)
    }

    private func openDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.load(from: url.path)
    }
}
