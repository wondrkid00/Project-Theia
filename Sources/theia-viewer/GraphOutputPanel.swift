import SwiftUI

private enum GraphOutputSeverity: String, CaseIterable {
    case all
    case error
    case warning
    case info

    var label: String {
        switch self {
        case .all: return "All"
        case .error: return "Errors"
        case .warning: return "Warnings"
        case .info: return "Info"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "line.3.horizontal.decrease.circle"
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .info: return "info.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .all: return .secondary
        case .error: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }
}
private struct GraphOutputItem: Identifiable {
    let severity: GraphOutputSeverity
    let message: String
    let detail: String?
    let issue: GraphDiagnosticIssue?

    var id: String {
        if let issue { return issue.id }
        return [severity.rawValue, message, detail ?? ""].joined(separator: "|")
    }
}

struct GraphOutputPanel: View {
    @ObservedObject var model: TerrainModel
    let viewport: TerrainMTKView
    @State private var filter: GraphOutputSeverity = .all
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            outputHeader

            Divider()

            if filteredItems.isEmpty {
                emptyOutput
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredItems) { item in
                            Button {
                                if let issue = item.issue {
                                    model.selectDiagnosticIssue(issue)
                                    viewport.setNeedsDisplay(viewport.bounds)
                                }
                            } label: {
                                GraphOutputRow(item: item)
                            }
                            .buttonStyle(.plain)
                            .disabled(item.issue == nil)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var outputHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(GraphOutputSeverity.allCases, id: \.self) { severity in
                    Button {
                        withAnimation(.easeOut(duration: 0.14)) {
                            filter = severity
                        }
                    } label: {
                        outputFilterSegment(severity)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("Filter messages", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                if !searchText.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.12)) {
                            searchText = ""
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(Color.black.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .animation(.easeOut(duration: 0.12), value: searchText.isEmpty)
    }

    private func outputFilterSegment(_ severity: GraphOutputSeverity) -> some View {
        HStack(spacing: 6) {
            Image(systemName: severity.systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(severity == .all ? .secondary : severity.color)
                .frame(width: 14)
            Text(severity.label)
                .font(.system(size: 12, weight: .semibold))
            if severity != .all {
                Text("\(count(for: severity))")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 10, alignment: .leading)
            }
        }
        // Sized to fit the graph column, which is far narrower than the
        // full-width dock this panel used to live in.
        .frame(minWidth: severity == .all ? 46 : 74, minHeight: 26)
        .padding(.horizontal, 4)
        .background(filter == severity
                    ? Color.white.opacity(0.12)
                    : Color.white.opacity(0.001),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .scaleEffect(filter == severity ? 1.0 : 0.98)
        .animation(.easeOut(duration: 0.14), value: filter)
    }

    private var emptyOutput: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.green)
            Text("No messages")
                .font(.headline)
            Text("Graph diagnostics will appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var outputItems: [GraphOutputItem] {
        var items: [GraphOutputItem] = model.diagnostics.authoringIssues.map { issue in
            GraphOutputItem(severity: issue.isError ? .error : .warning,
                            message: issue.message,
                            detail: issue.node ?? issue.edge ?? issue.code,
                            issue: issue)
        }

        let authoringIds = Set(model.diagnostics.authoringIssues.map(\.id))
        let advisory = model.diagnostics.issues.filter { !authoringIds.contains($0.id) }
        items.append(contentsOf: advisory.map { issue in
            GraphOutputItem(severity: .info,
                            message: issue.message,
                            detail: issue.node ?? issue.edge ?? issue.code,
                            issue: issue)
        })

        if items.isEmpty {
            items.append(GraphOutputItem(
                severity: .info,
                message: "Graph is healthy",
                detail: "\(model.document.nodes.count) node\(model.document.nodes.count == 1 ? "" : "s"), \(model.document.connections.count) connection\(model.document.connections.count == 1 ? "" : "s")",
                issue: nil))
        }

        return items
    }

    private var filteredItems: [GraphOutputItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return outputItems.filter { item in
            let matchesFilter = filter == .all || item.severity == filter
            guard matchesFilter else { return false }
            guard !query.isEmpty else { return true }
            return item.message.lowercased().contains(query) ||
                (item.detail?.lowercased().contains(query) ?? false)
        }
    }

    private func count(for severity: GraphOutputSeverity) -> Int {
        outputItems.filter { $0.severity == severity }.count
    }
}

private struct GraphOutputRow: View {
    let item: GraphOutputItem

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(item.severity.color)
                .frame(width: 16, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.message)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = item.detail {
                    Text(detail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.0001))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 1)
                .padding(.leading, 36)
        }
    }

    private var icon: String {
        switch item.severity {
        case .all:
            return "circle.fill"
        case .error:
            return "xmark.octagon.fill"
        case .warning:
            return "exclamationmark.circle.fill"
        case .info:
            return "info.circle.fill"
        }
    }
}
