import SwiftUI

/// Shown in the inspector when no node is selected.
///
/// The per-node view has nothing to say with an empty selection, but the
/// document does: which port the graph resolves to, and what grid it is authored
/// at. The working resolution in particular had no UI at all — it could only be
/// changed with `--size` or by hand-editing the JSON — even though it is the
/// value that cell spacing and the river width migration are measured against.
struct GraphInspector: View {
    @ObservedObject var model: TerrainModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            documentSection

            if !model.document.nodes.isEmpty {
                Divider().opacity(0.5)
                outputSection
                Divider().opacity(0.5)
                resolutionSection
            } else {
                Text("Add a node to start building a terrain.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Document

    private var documentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(titleBarDocumentName(path: model.graphPath))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 6) {
                Text(countSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Circle()
                    .fill(model.isDirty ? Color.orange : Color.green.opacity(0.8))
                    .frame(width: 5, height: 5)

                Text(model.isDirty ? "Unsaved" : "Saved")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var countSummary: String {
        let nodes = model.document.nodes.count
        let links = model.document.connections.count
        return "\(nodes) node\(nodes == 1 ? "" : "s") · "
            + "\(links) link\(links == 1 ? "" : "s")"
    }

    // MARK: - Output

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            InspectorSectionLabel("OUTPUT")

            Menu {
                ForEach(model.selectableGraphOutputs, id: \.self) { reference in
                    Button {
                        model.setGraphOutput(reference)
                    } label: {
                        if isCurrentOutput(reference) {
                            Label("\(reference.node).\(reference.output)",
                                  systemImage: "checkmark")
                        } else {
                            Text("\(reference.node).\(reference.output)")
                        }
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "target")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(currentOutputColor)
                    Text(currentOutputLabel)
                        .font(.system(size: 12, weight: .medium).monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(inspectorControlFill,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(inspectorControlStroke())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(model.selectableGraphOutputs.isEmpty)
            .help("The port the graph resolves to for preview, CLI, and export")

            if model.document.sink.isEmpty {
                Text("No output set — the preview stays flat until one is chosen.")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func isCurrentOutput(_ reference: GraphOutputReference) -> Bool {
        model.document.sink == reference.node &&
            model.document.sinkOutput == reference.output
    }

    private var currentOutputLabel: String {
        let sink = model.document.sink
        guard !sink.isEmpty else { return "none" }
        let output = model.document.sinkOutput
        return output.isEmpty ? sink : "\(sink).\(output)"
    }

    private var currentOutputColor: Color {
        guard let kind = model.document.resolvedOutputKind(
            nodeId: model.document.sink,
            output: model.document.sinkOutput) else { return .secondary }
        return GraphPortPalette.color(kind)
    }

    // MARK: - Resolution

    private var resolutionSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            InspectorSectionLabel("RESOLUTION")

            HStack(spacing: 8) {
                Text("Working")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 60, alignment: .leading)

                Menu {
                    ForEach(TerrainModel.workingResolutionChoices, id: \.self) { choice in
                        Button {
                            model.setWorkingResolution(choice)
                        } label: {
                            if choice == model.previewSize {
                                Label("\(choice) × \(choice)", systemImage: "checkmark")
                            } else {
                                Text("\(choice) × \(choice)")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("\(model.previewSize)")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        Spacer(minLength: 2)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(inspectorControlFill,
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(inspectorControlStroke())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .help("Grid the graph is authored and previewed at. Changing it "
                      + "re-evaluates the graph.")
            }

            Text(cellSummary)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)

            if model.previewSizeOverridesDocument {
                Text("Previewing at \(model.previewSize) via --size; "
                     + "the document stores \(model.documentResolution).")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Spells out the derived spacing, which is what every world-scaled node
    /// actually consumes.
    private var cellSummary: String {
        let intervals = Double(max(1, model.previewSize - 1))
        let cell = 1024.0 / intervals
        return String(format: "cell = %.3f world units at terrainSize 1024",
                      cell)
    }
}

struct InspectorSectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(.secondary)
    }
}
