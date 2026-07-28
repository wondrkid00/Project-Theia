import SwiftUI

/// The bottom pane of the workspace: a graph tab strip, the node canvas, and a
/// collapsible diagnostics tray along the bottom.
///
/// Gaea runs its graph across the bottom of the window with the tab strip above
/// the nodes. The Output panel used to cost a tab switch here, so it becomes a
/// tray that stays summarised in one line and expands in place.
struct GraphColumn: View {
    @ObservedObject var model: TerrainModel
    let viewport: TerrainMTKView

    var body: some View {
        VStack(spacing: 0) {
            graphTabStrip

            NodeEditorCanvas(model: model, viewport: viewport)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            GraphOutputTray(model: model, viewport: viewport)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    /// Workspace tabs are intentionally independent from the document filename.
    /// There is one root tab today; the model boundary leaves room for portals
    /// to expose additional graph scopes later without changing this strip.
    private var graphTabStrip: some View {
        HStack(spacing: 6) {
            ForEach(model.graphTabs) { tab in
                Button {
                    model.selectGraphTab(tab.id)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(tab.title)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(
                        model.selectedGraphTabId == tab.id
                            ? Color.white.opacity(0.08)
                            : Color.clear,
                        in: RoundedRectangle(cornerRadius: 5,
                                             style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Graph tab \(tab.title)")
                .accessibilityValue(
                    model.selectedGraphTabId == tab.id ? "Selected" : "Not selected")
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .frame(height: graphColumnHeaderHeight)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theiaChromeDivider)
                .frame(height: 1)
        }
    }

}

let graphColumnHeaderHeight: CGFloat = 34

/// Collapsible diagnostics tray. Collapsed it is a single summary row; it opens
/// on click, and opens itself when a new error appears so failures cannot sit
/// unnoticed behind a hidden tab.
struct GraphOutputTray: View {
    @ObservedObject var model: TerrainModel
    let viewport: TerrainMTKView

    @State private var expanded = false
    /// Set once the user collapses the tray by hand, so auto-expand does not
    /// keep reopening something they deliberately closed.
    @State private var userCollapsed = false
    @State private var lastErrorCount = 0

    private let trayHeight: CGFloat = 210
    private let barHeight: CGFloat = 30

    var body: some View {
        VStack(spacing: 0) {
            summaryBar

            if expanded {
                GraphOutputPanel(model: model, viewport: viewport)
                    .frame(height: trayHeight)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theiaChromeDivider)
                .frame(height: 1)
        }
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: expanded)
        .onAppear {
            let count = model.diagnostics.authoringErrorCount
            if Self.shouldAutoExpand(errorCount: count,
                                     previousErrorCount: lastErrorCount,
                                     userCollapsed: userCollapsed) {
                expanded = true
            }
            lastErrorCount = count
        }
        .onChange(of: model.diagnostics.authoringErrorCount) { _, count in
            // Only surface on a rising edge: a graph that is already failing
            // should not reopen the tray on every re-evaluation.
            if Self.shouldAutoExpand(errorCount: count,
                                     previousErrorCount: lastErrorCount,
                                     userCollapsed: userCollapsed) {
                expanded = true
            }
            lastErrorCount = count
        }
    }

    static func shouldAutoExpand(errorCount: Int,
                                 previousErrorCount: Int,
                                 userCollapsed: Bool) -> Bool {
        !userCollapsed && errorCount > 0 && errorCount > previousErrorCount
    }

    private var summaryBar: some View {
        Button {
            expanded.toggle()
            userCollapsed = !expanded
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))

                Text("Output")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .kerning(0.4)

                if !expanded {
                    Text(summaryText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 0)

                if expanded {
                    countChip(model.diagnostics.authoringErrorCount, color: .red)
                    countChip(model.diagnostics.authoringWarningCount, color: .orange)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: barHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Collapse output" : "Expand output")
    }

    @ViewBuilder
    private func countChip(_ count: Int, color: Color) -> some View {
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
                .padding(.horizontal, 5)
                .frame(height: 15)
                .background(color.opacity(0.15), in: Capsule(style: .continuous))
        }
    }

    private var summaryText: String {
        let errors = model.diagnostics.authoringErrorCount
        let warnings = model.diagnostics.authoringWarningCount
        if errors == 0 && warnings == 0 { return "Graph is healthy" }
        var parts: [String] = []
        if errors > 0 { parts.append("\(errors) error\(errors == 1 ? "" : "s")") }
        if warnings > 0 { parts.append("\(warnings) warning\(warnings == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }
}
