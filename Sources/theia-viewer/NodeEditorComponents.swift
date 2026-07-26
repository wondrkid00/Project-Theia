import AppKit
import SwiftUI

enum GraphPortPalette {
    static func color(_ kind: GraphFieldKind) -> Color {
        switch kind {
        case .terrain: return .blue
        case .mask: return .cyan
        case .data: return .orange
        }
    }

    static func inputColor(_ port: GraphInputPort) -> Color {
        if port.acceptedKinds.count == 1, let kind = port.acceptedKinds.first {
            return color(kind)
        }
        if port.acceptedKinds == [.mask, .data] {
            return .teal
        }
        return Color(nsColor: .tertiaryLabelColor)
    }

    static func kindDescription(_ kinds: Set<GraphFieldKind>) -> String {
        GraphFieldKind.allCases
            .filter(kinds.contains)
            .map(\.rawValue)
            .joined(separator: "/")
    }
}

enum NodePortLayout {
    static let width: CGFloat = 168
    static let minimumHeight: CGFloat = 96
    static let rowGap: CGFloat = 20
    static let firstRowY: CGFloat = 52

    static func size(inputCount: Int, outputCount: Int) -> CGSize {
        let rows = max(1, max(inputCount, outputCount))
        let height = max(minimumHeight,
                         firstRowY + CGFloat(rows - 1) * rowGap + 18)
        return CGSize(width: width, height: height)
    }

    static func inputY(_ index: Int) -> CGFloat {
        firstRowY + CGFloat(index) * rowGap
    }

    static func outputY(_ index: Int) -> CGFloat {
        firstRowY + CGFloat(index) * rowGap
    }
}

enum InputPortDragState: Equatable {
    case idle
    case compatible(replacesExisting: Bool)
    case pending(replacesExisting: Bool)
    case incompatible

    var isHighlighted: Bool {
        switch self {
        case .compatible, .pending: return true
        case .idle, .incompatible: return false
        }
    }

    var isReplacement: Bool {
        switch self {
        case .compatible(let replaces), .pending(let replaces): return replaces
        case .idle, .incompatible: return false
        }
    }
}

struct NodeCard: View {
    let node: GraphDocumentNode
    let position: CGPoint
    let selected: Bool
    let inputPorts: [GraphInputPort]
    let outputPorts: [GraphOutputPort]
    let connectedInputs: Set<UInt32>
    let missingInputs: Set<UInt32>
    let inputDragStates: [UInt32: InputPortDragState]
    let diagnosticSeverity: String?
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onDuplicate: () -> Void
    let onSelectUpstream: () -> Void
    let onSelectDownstream: () -> Void
    let onInputDisconnect: (UInt32) -> Void
    let onOutputPreview: (String) -> Void
    let onOutputDragChanged: (String, CGPoint) -> Void
    let onOutputDragEnded: (String, CGPoint) -> Void
    let zoom: Double

    private var cardSize: CGSize {
        NodePortLayout.size(inputCount: inputPorts.count,
                            outputCount: outputPorts.count)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(borderColor,
                                lineWidth: selected ? 2 : 1))
                .shadow(color: selected ? .accentColor.opacity(0.22) : .black.opacity(0.22),
                        radius: selected ? 7 : 4,
                        y: selected ? 0 : 2)

            HStack(spacing: 7) {
                Image(systemName: NodeTypeCatalog.icon(for: node.type))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(nodeTint)
                    .frame(width: 17, height: 17)
                    .background(nodeTint.opacity(0.12), in: Circle())
                Text(NodeTypeCatalog.nodeTitle(id: node.id, type: node.type))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 24)
            }
            .padding(10)
            .help("\(NodeTypeCatalog.title(for: node.type)) · id \(node.id)")

            if hasMaskOutput {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.caption2)
                    .foregroundStyle(Color.cyan.opacity(0.85))
                    .position(x: cardSize.width - 14, y: 14)
            }

            if node.type == "export" {
                badge(systemImage: "square.and.arrow.up",
                      color: .purple)
                    .position(x: cardSize.width - 14, y: 14)
            }

            if let diagnosticSeverity {
                badge(systemImage: diagnosticSeverity == "error"
                      ? "exclamationmark.triangle.fill"
                      : "exclamationmark.circle.fill",
                      color: diagnosticSeverity == "error" ? .red : .orange)
                    .position(x: cardSize.width - 14,
                              y: hasMaskOutput || node.type == "export" ? 32 : 14)
                    .transition(.scale.combined(with: .opacity))
            }

            ForEach(inputPorts) { input in
                let state = inputDragStates[input.index] ?? .idle
                Text(input.name)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(state == .incompatible
                                     ? Color.secondary.opacity(0.35)
                                     : Color.secondary)
                    .frame(width: 68, alignment: .leading)
                    .position(x: 39, y: NodePortLayout.inputY(Int(input.index)))
                    .allowsHitTesting(false)

                PortView(color: GraphPortPalette.inputColor(input),
                         warning: missingInputs.contains(input.index),
                         dragState: state)
                    .position(x: 0, y: NodePortLayout.inputY(Int(input.index)))
                    .help("\(input.name): accepts \(GraphPortPalette.kindDescription(input.acceptedKinds))")
                    .contextMenu {
                        if connectedInputs.contains(input.index) {
                            Button("Disconnect") {
                                onInputDisconnect(input.index)
                            }
                        }
                    }
            }

            ForEach(Array(outputPorts.enumerated()), id: \.element.name) { index, output in
                let rowY = NodePortLayout.outputY(index)
                HStack(spacing: 5) {
                    Text(output.name)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    PortView(color: GraphPortPalette.color(output.declaredKind))
                }
                .frame(width: 78, height: 20)
                .contentShape(Rectangle())
                .position(x: cardSize.width - 33, y: rowY)
                .help("\(output.name): \(output.declaredKind.rawValue) output")
                .highPriorityGesture(
                    TapGesture().onEnded {
                        onOutputPreview(output.name)
                    })
                    .gesture(DragGesture(coordinateSpace: .named("node-canvas"))
                        .onChanged { onOutputDragChanged(output.name, $0.location) }
                        .onEnded { onOutputDragEnded(output.name, $0.location) })
            }
        }
        .frame(width: cardSize.width, height: cardSize.height)
        .scaleEffect(zoom, anchor: .center)
        .position(x: position.x + cardSize.width * CGFloat(zoom) * 0.5,
                  y: position.y + cardSize.height * CGFloat(zoom) * 0.5)
        .onTapGesture(perform: onSelect)
        .animation(.easeOut(duration: 0.14), value: selected)
        .animation(.easeOut(duration: 0.14), value: diagnosticSeverity)
        .contextMenu {
            Button("Duplicate", action: onDuplicate)
            Divider()
            Button("Select Upstream", action: onSelectUpstream)
            Button("Select Downstream", action: onSelectDownstream)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private func badge(systemImage: String, color: Color) -> some View {
        Image(systemName: systemImage)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .frame(width: 16, height: 16)
            .background(Color.black.opacity(0.42), in: Circle())
    }

    private var hasMaskOutput: Bool {
        outputPorts.contains { $0.declaredKind == .mask }
    }

    private var nodeTint: Color {
        guard let output = outputPorts.first(where: \.isDefault)
                ?? outputPorts.first else { return .secondary }
        return GraphPortPalette.color(output.declaredKind)
    }

    private var borderColor: Color {
        if selected { return .accentColor }
        if diagnosticSeverity == "error" { return Color.red.opacity(0.75) }
        if hasMaskOutput { return Color.cyan.opacity(0.55) }
        return Color.secondary.opacity(0.35)
    }
}

struct PortView: View {
    let color: Color
    var warning = false
    var dragState: InputPortDragState = .idle

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: dragState.isHighlighted ? 15 : 11,
                   height: dragState.isHighlighted ? 15 : 11)
            .overlay(
                Circle().stroke(strokeColor,
                                lineWidth: dragState.isHighlighted ? 2 : 1))
            .overlay {
                if dragState.isReplacement {
                    Circle()
                        .fill(Color.black.opacity(0.75))
                        .frame(width: 4, height: 4)
                }
            }
            .shadow(color: dragState.isHighlighted ? color.opacity(0.9) : .clear,
                    radius: 5)
            .opacity(dragState == .incompatible ? 0.24 : 1)
            .animation(.easeOut(duration: 0.12), value: dragState)
    }

    private var strokeColor: Color {
        if warning && dragState == .idle { return .orange }
        switch dragState {
        case .pending: return .yellow
        default: return .white.opacity(0.75)
        }
    }
}

struct EdgeView: View {
    let edge: GraphDocumentConnection
    let start: CGPoint
    let end: CGPoint
    let color: Color
    let selected: Bool
    let zoom: Double

    var body: some View {
        ZStack {
            EdgeShape(start: start, end: end, minHandle: 50 * CGFloat(zoom))
                .stroke(Color.primary.opacity(0.001),
                        style: StrokeStyle(lineWidth: max(6, 16 * CGFloat(zoom)),
                                           lineCap: .round))
            EdgeShape(start: start, end: end, minHandle: 50 * CGFloat(zoom))
                .stroke(selected ? Color.accentColor.opacity(0.55) : .clear,
                        style: StrokeStyle(lineWidth: max(1, 5 * CGFloat(zoom)),
                                           lineCap: .round))
            EdgeShape(start: start, end: end, minHandle: 50 * CGFloat(zoom))
                .stroke(color.opacity(selected ? 1 : 0.78),
                        style: StrokeStyle(lineWidth: max(1, (selected ? 3 : 2) * CGFloat(zoom)),
                                           lineCap: .round))
        }
    }
}

struct EdgeShape: Shape {
    var start: CGPoint
    var end: CGPoint
    var minHandle: CGFloat = 50

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let dx = max(minHandle, abs(end.x - start.x) * 0.45)
        p.move(to: start)
        p.addCurve(to: end,
                   control1: CGPoint(x: start.x + dx, y: start.y),
                   control2: CGPoint(x: end.x - dx, y: end.y))
        return p
    }
}

struct CanvasGrid: View {
    let pan: CGSize
    let zoom: Double

    var body: some View {
        Canvas { context, size in
            let step = max(6, 24 * CGFloat(zoom))
            var minor = Path()
            var major = Path()

            var x = pan.width.truncatingRemainder(dividingBy: step)
            if x > 0 { x -= step }
            while x <= size.width {
                let index = Int(round((x - pan.width) / step))
                if index.isMultiple(of: 5) {
                    major.move(to: CGPoint(x: x, y: 0))
                    major.addLine(to: CGPoint(x: x, y: size.height))
                } else {
                    minor.move(to: CGPoint(x: x, y: 0))
                    minor.addLine(to: CGPoint(x: x, y: size.height))
                }
                x += step
            }

            var y = pan.height.truncatingRemainder(dividingBy: step)
            if y > 0 { y -= step }
            while y <= size.height {
                let index = Int(round((y - pan.height) / step))
                if index.isMultiple(of: 5) {
                    major.move(to: CGPoint(x: 0, y: y))
                    major.addLine(to: CGPoint(x: size.width, y: y))
                } else {
                    minor.move(to: CGPoint(x: 0, y: y))
                    minor.addLine(to: CGPoint(x: size.width, y: y))
                }
                y += step
            }

            context.stroke(minor, with: .color(.secondary.opacity(0.10)), lineWidth: 1)
            context.stroke(major, with: .color(.secondary.opacity(0.18)), lineWidth: 1)
        }
    }
}

struct CanvasMouseEventView: NSViewRepresentable {
    let onChanged: (CGSize) -> Void
    let onEnded: () -> Void
    let onZoom: (CGFloat, CGPoint) -> Void
    let onPanBy: (CGSize) -> Void
    let onRequestAddNode: (CGPoint) -> Void
    let isOverNode: (CGPoint) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = CanvasMouseEventNSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? CanvasMouseEventNSView else { return }
        apply(to: view)
    }

    private func apply(to view: CanvasMouseEventNSView) {
        view.onChanged = onChanged
        view.onEnded = onEnded
        view.onZoom = onZoom
        view.onPanBy = onPanBy
        view.onRequestAddNode = onRequestAddNode
        view.isOverNode = isOverNode
    }
}

// Canvas navigation, following node-editor conventions (Godot GraphEdit /
// Blender / Figma):
//   two-finger scroll        pan
//   pinch or cmd+scroll      zoom about the cursor
//   right-drag / MMB-drag    pan
//   right-click empty space  request the canvas node picker at the cursor
final class CanvasMouseEventNSView: NSView {
    var onChanged: ((CGSize) -> Void)?
    var onEnded: (() -> Void)?
    var onZoom: ((CGFloat, CGPoint) -> Void)?
    var onPanBy: ((CGSize) -> Void)?
    var onRequestAddNode: ((CGPoint) -> Void)?
    var isOverNode: ((CGPoint) -> Bool)?
    private var start: NSPoint?
    private var dragDistance: CGFloat = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = window?.currentEvent else { return nil }
        switch event.type {
        case .rightMouseDown, .rightMouseDragged, .rightMouseUp:
            let local = convert(point, from: superview)
            let flipped = CGPoint(x: local.x, y: bounds.height - local.y)
            if event.type == .rightMouseDown, isOverNode?(flipped) == true {
                return nil
            }
            return self
        case .otherMouseDown, .otherMouseDragged, .otherMouseUp,
             .scrollWheel, .magnify:
            return self
        default:
            return nil
        }
    }

    override func rightMouseDown(with event: NSEvent) { beginDrag(event) }
    override func rightMouseDragged(with event: NSEvent) { dragged(event) }
    override func rightMouseUp(with event: NSEvent) {
        let wasClick = dragDistance < 4
        endDrag()
        if wasClick { onRequestAddNode?(localPoint(event)) }
    }
    override func otherMouseDown(with event: NSEvent) { beginDrag(event) }
    override func otherMouseDragged(with event: NSEvent) { dragged(event) }
    override func otherMouseUp(with event: NSEvent) { endDrag() }

    private func beginDrag(_ event: NSEvent) {
        start = event.locationInWindow
        dragDistance = 0
    }

    private func dragged(_ event: NSEvent) {
        guard let start else { return }
        let p = event.locationInWindow
        dragDistance = max(dragDistance, abs(p.x - start.x) + abs(p.y - start.y))
        onChanged?(CGSize(width: p.x - start.x, height: p.y - start.y))
    }

    private func endDrag() {
        start = nil
        onEnded?()
    }

    override func scrollWheel(with event: NSEvent) {
        let point = localPoint(event)
        if event.modifierFlags.contains(.command) {
            onZoom?(event.scrollingDeltaY, point)
        } else {
            onPanBy?(CGSize(width: event.scrollingDeltaX,
                            height: event.scrollingDeltaY))
        }
    }

    override func magnify(with event: NSEvent) {
        onZoom?(event.magnification * 100, localPoint(event))
    }

    private func localPoint(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        return CGPoint(x: local.x, y: bounds.height - local.y)
    }

}
