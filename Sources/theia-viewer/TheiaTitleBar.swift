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

func titleBarDocumentName(path: String?) -> String {
    guard let path else { return "Untitled graph" }
    return URL(fileURLWithPath: path).lastPathComponent
}

/// The window disables AppKit's implicit titlebar dragging so SwiftUI controls
/// cannot accidentally move it. This view restores dragging only where it is
/// deliberately placed behind empty titlebar space.
struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragRegionView {
        WindowDragRegionView()
    }

    func updateNSView(_ nsView: WindowDragRegionView, context: Context) {}
}

final class WindowDragRegionView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

struct TheiaTitleBar: View {
    @ObservedObject var model: TerrainModel
    let viewport: TerrainMTKView

    /// Help text of whatever the pointer is currently over. The document name
    /// stays anchored in its own control group while hints use spare space.
    @State private var hint: String?
    @State private var isRenamingDocument = false
    @State private var documentNameDraft = ""
    @FocusState private var documentNameFieldFocused: Bool

    var body: some View {
        ZStack {
            WindowDragRegion()

            HStack(spacing: 0) {
                Color.clear
                    .frame(width: trafficLightInset)
                    .allowsHitTesting(false)

                interactiveControls

                Spacer(minLength: 12)

                if let hint {
                    toolbarHint(hint)
                        .padding(.trailing, 12)
                }
            }
        }
        .frame(height: theiaTitleBarHeight)
        .background(Color(red: 0.115, green: 0.12, blue: 0.13))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theiaChromeDivider)
                .frame(height: 1)
        }
    }

    private var interactiveControls: some View {
        HStack(spacing: 0) {
            documentGroup
            groupDivider
            cameraGroup
            groupDivider
            displayGroup

            if model.canEditActiveMask {
                groupDivider
                maskGroup
            }
        }
        // A practically transparent hit surface catches gaps between controls.
        // Buttons remain in front and keep their normal click behavior.
        .background(Color.black.opacity(0.001))
    }

    // MARK: - Groups

    private var documentGroup: some View {
        HStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.48))

                documentNameControl

                Circle()
                    .fill(model.isDirty ? Color.orange : Color.green.opacity(0.82))
                    .frame(width: 6, height: 6)
                    .help(model.isDirty ? "Unsaved changes" : "Saved")
            }
            .padding(.leading, 10)
            .padding(.trailing, 9)
            .frame(minWidth: 128, idealWidth: 172, maxWidth: 210,
                   alignment: .leading)

            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 1, height: 18)
                .padding(.horizontal, 3)

            barButton(systemImage: "folder",
                      help: "Load graph") {
                openDocument()
                redraw()
            }
            barButton(systemImage: "square.and.arrow.down",
                      help: "Save graph (⌘S)") {
                saveDocument()
                redraw()
            }
        }
        .padding(.horizontal, 2)
        .frame(height: 30)
        .background(Color.white.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.075), lineWidth: 1))
    }

    @ViewBuilder
    private var documentNameControl: some View {
        if isRenamingDocument {
            TextField("Filename", text: $documentNameDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .focused($documentNameFieldFocused)
                .onSubmit {
                    commitDocumentRename()
                }
                .onExitCommand {
                    cancelDocumentRename()
                }
                .onChange(of: documentNameFieldFocused) { wasFocused, isFocused in
                    if wasFocused && !isFocused && isRenamingDocument {
                        commitDocumentRename()
                    }
                }
                .onAppear {
                    DispatchQueue.main.async {
                        documentNameFieldFocused = true
                        DispatchQueue.main.async {
                            NSApp.sendAction(#selector(NSText.selectAll(_:)),
                                             to: nil, from: nil)
                        }
                    }
                }
                .accessibilityLabel("Document filename")
        } else {
            Button {
                beginDocumentRename()
            } label: {
                Text(titleBarDocumentName(path: model.graphPath))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Rename document")
            .accessibilityLabel("Rename document filename")
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

    private func toolbarHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.66))
            .lineLimit(1)
            .truncationMode(.tail)
            .transition(.opacity)
            .animation(.easeOut(duration: 0.12), value: hint)
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

    private func beginDocumentRename() {
        documentNameDraft = titleBarDocumentName(path: model.graphPath)
        isRenamingDocument = true
    }

    private func cancelDocumentRename() {
        documentNameFieldFocused = false
        isRenamingDocument = false
        documentNameDraft = ""
    }

    private func commitDocumentRename() {
        guard isRenamingDocument else { return }
        let proposedName = documentNameDraft
        documentNameFieldFocused = false
        isRenamingDocument = false

        if model.graphPath != nil {
            _ = model.renameDocumentFile(to: proposedName)
        } else {
            guard let filename = normalizedGraphFilename(proposedName) else {
                documentNameDraft = ""
                return
            }
            saveDocumentAs(filename: filename)
        }
        documentNameDraft = ""
        redraw()
    }

    private func saveDocumentAs(filename: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = filename
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
