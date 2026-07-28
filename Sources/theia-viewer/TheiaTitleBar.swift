import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Height of the unified title/toolbar strip. The window uses
/// `.fullSizeContentView` with a transparent titlebar, so this row sits *in* the
/// titlebar rather than below it — the same space reclamation GAEA describes for
/// its own main toolbar ("shared with the title bar to give you maximum
/// workspace area").
let theiaTitleBarHeight: CGFloat = 38

/// Left inset that keeps toolbar controls clear of the window's traffic lights.
private let trafficLightInset: CGFloat = 78

let theiaChromeDivider = Color.white.opacity(0.08)

struct TheiaTitleBar: View {
    @ObservedObject var model: TerrainModel
    let viewport: TerrainMTKView

    /// Help text of whatever the pointer is currently over. Shown in place of
    /// the document title so that icon-only buttons stay self-describing.
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: trafficLightInset)

            fileGroup
            groupDivider
            cameraGroup
            groupDivider
            displayGroup

            if model.canEditActiveMask {
                groupDivider
                maskGroup
            }

            Spacer(minLength: 12)

            documentLabel
                .padding(.trailing, 12)
        }
        .frame(height: theiaTitleBarHeight)
        .background(Color(red: 0.115, green: 0.12, blue: 0.13))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theiaChromeDivider)
                .frame(height: 1)
        }
    }

    // MARK: - Groups

    private var fileGroup: some View {
        HStack(spacing: 2) {
            barButton(systemImage: "folder",
                      help: "Load graph") {
                openDocument()
                redraw()
            }
            barButton(help: "Save graph (⌘S)",
                      action: {
                          saveDocument()
                          redraw()
                      }) {
                FloppyDiskGlyph()
            }
        }
    }

    private var cameraGroup: some View {
        HStack(spacing: 2) {
            barButton(systemImage: "viewfinder",
                      help: "Reset camera (F)") {
                model.resetCamera()
                redraw()
            }
            barButton(systemImage: "arrow.triangle.2.circlepath",
                      help: "Orbit tool (O): left drag orbits the camera.",
                      active: model.viewportTool == .orbit) {
                model.setViewportTool(.orbit)
                redraw()
            }
            barButton(systemImage: "hand.draw",
                      help: "Pan tool (H): left drag pans the camera.",
                      active: model.viewportTool == .pan) {
                model.setViewportTool(.pan)
                redraw()
            }
            barButton(systemImage: "magnifyingglass",
                      help: "Zoom tool (Z): left drag vertically zooms the camera.",
                      active: model.viewportTool == .zoom) {
                model.setViewportTool(.zoom)
                redraw()
            }
        }
    }

    private var displayGroup: some View {
        HStack(spacing: 2) {
            barButton(systemImage: "square.grid.3x3",
                      help: "Toggle grid",
                      active: model.gridVisible) {
                model.setGridVisible(!model.gridVisible)
                redraw()
            }
            barButton(systemImage: "arrow.up.and.down.and.arrow.left.and.right",
                      help: "Toggle axes",
                      active: model.axisVisible) {
                model.setAxisVisible(!model.axisVisible)
                redraw()
            }
            barButton(systemImage: "cube.transparent",
                      help: "Toggle wireframe",
                      active: model.wireframeEnabled) {
                model.wireframeEnabled.toggle()
                model.applyViewportSettings()
                redraw()
            }
        }
    }

    private var maskGroup: some View {
        barButton(systemImage: "eraser",
                  help: "Mask eraser (E): drag on terrain to remove unwanted mask paths.",
                  active: model.maskBrushEnabled) {
            model.setMaskBrushEnabled(!model.maskBrushEnabled)
            redraw()
        }
    }

    // MARK: - Document label

    private var documentLabel: some View {
        HStack(spacing: 7) {
            if let hint {
                Text(hint)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .transition(.opacity)
            } else {
                Text(documentName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Circle()
                    .fill(model.isDirty ? Color.orange : Color.green.opacity(0.8))
                    .frame(width: 6, height: 6)
                    .help(model.isDirty ? "Unsaved changes" : "Saved")
            }
        }
        .animation(.easeOut(duration: 0.12), value: hint)
    }

    private var documentName: String {
        guard let path = model.graphPath else { return "Untitled graph" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    // MARK: - Building blocks

    private var groupDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 18)
            .padding(.horizontal, 7)
    }

    private func barButton(systemImage: String, help: String,
                           active: Bool = false,
                           action: @escaping () -> Void) -> some View {
        barButton(help: help, active: active, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
        }
    }

    private func barButton<Icon: View>(help: String,
                                       active: Bool = false,
                                       action: @escaping () -> Void,
                                       @ViewBuilder icon: () -> Icon) -> some View {
        Button(action: action) {
            icon()
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
                .background(active ? Color.accentColor.opacity(0.32) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Color.accentColor : Color.white.opacity(0.84))
        .accessibilityLabel(Text(help))
        .help(help)
        .onHover { hovering in
            if hovering {
                hint = help
            } else if hint == help {
                hint = nil
            }
        }
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

struct FloppyDiskGlyph: View {
    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 15, height: 15)
        } else {
            Image(systemName: "externaldrive")
                .font(.system(size: 13, weight: .semibold))
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
