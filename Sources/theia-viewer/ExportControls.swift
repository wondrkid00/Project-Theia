import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ExportControls: View {
    @ObservedObject var model: TerrainModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            exportHeader
            destinationSection
            resolutionSection
            outputsSection

            if !model.exportStatus.isEmpty {
                Label(model.exportStatus,
                      systemImage: model.exportStatus.hasPrefix("export failed") ? "xmark.circle.fill" : "info.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.exportStatus.hasPrefix("export failed") ? .red : .secondary)
                    .lineLimit(2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            exportActionBar
        }
        .animation(.easeOut(duration: 0.14), value: model.exportStatus)
    }

    private var exportHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("Export")
                .font(.title3.weight(.bold))

            Spacer()

            Menu {
                Button("Reset Export Settings", action: resetSettings)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 30, height: 30)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
    }

    private var destinationSection: some View {
        ExportInspectorCard {
            VStack(alignment: .leading, spacing: 16) {
                ExportSectionHeader("DESTINATION")

                HStack(alignment: .center, spacing: 12) {
                    ExportFieldLabel("Folder")

                    Text(model.exportSettings.outDir)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        chooseFolder()
                    } label: {
                        Text("Choose...")
                            .font(.callout.weight(.semibold))
                            .frame(width: 104, height: 34)
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .background(inspectorControlFill,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(inspectorControlStroke())
                }

                HStack(alignment: .center, spacing: 12) {
                    ExportFieldLabel("Preset / Name")

                    HStack(spacing: 8) {
                        TextField("terrain", text: Binding(
                            get: { model.exportSettings.basename },
                            set: { model.exportSettings.basename = $0 }))
                            .textFieldStyle(.plain)
                            .font(.callout.weight(.semibold))

                        if !model.exportSettings.basename.isEmpty {
                            Button {
                                model.exportSettings.basename = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(inspectorControlFill,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(inspectorControlStroke())
                }
            }
        }
    }

    private var resolutionSection: some View {
        ExportInspectorCard {
            VStack(alignment: .leading, spacing: 16) {
                ExportSectionHeader("RESOLUTION & SCALE")

                ExportMetricRow(icon: "square.grid.3x3.fill",
                                title: "Size (Resolution)",
                                value: Binding(
                                    get: { Double(model.exportSettings.size) },
                                    set: { model.exportSettings.size = UInt32(max(2, $0.rounded())) }),
                                range: 64...4096,
                                step: 64,
                                precision: 0)

                ExportMetricRow(icon: "mountain.2.fill",
                                title: "Vertical Scale",
                                value: Binding(
                                    get: { model.exportSettings.verticalScale },
                                    set: { model.exportSettings.verticalScale = max(0.001, $0) }),
                                range: 0.05...8,
                                step: 0.05,
                                precision: 2)

                ExportMetricRow(icon: "square.grid.3x3",
                                title: "Mesh Stride",
                                value: Binding(
                                    get: { Double(model.exportSettings.meshStride) },
                                    set: { model.exportSettings.meshStride = UInt32(max(1, $0.rounded())) }),
                                range: 1...16,
                                step: 1,
                                precision: 0)
            }
        }
    }

    private var outputsSection: some View {
        ExportInspectorCard {
            VStack(alignment: .leading, spacing: 14) {
                ExportSectionHeader("EXPORT OUTPUTS")

                ExportFormatRow(icon: "mountain.2.fill",
                                title: "Heightmap",
                                enabled: Binding(
                                    get: { model.exportSettings.exportHeightmap },
                                    set: { model.exportSettings.exportHeightmap = $0 })) {
                    Menu {
                        ForEach(ExportSettings.HeightmapFormat.allCases) { format in
                            Button(format.label) {
                                model.exportSettings.heightmapFormat = format
                            }
                        }
                    } label: {
                        ExportFormatMenuLabel(model.exportSettings.heightmapFormat.label)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }

                ExportFormatRow(icon: "cube",
                                title: "Mesh",
                                enabled: Binding(
                                    get: {
                                        model.activeOutputSupportsMesh &&
                                            model.exportSettings.exportMesh
                                    },
                                    set: {
                                        model.exportSettings.exportMesh =
                                            model.activeOutputSupportsMesh && $0
                                    })) {
                    Menu {
                        ForEach(ExportSettings.MeshFormat.allCases) { format in
                            Button(format.isSupported ? format.label : "\(format.label) (later)") {
                                model.exportSettings.meshFormat = format
                            }
                            .disabled(!format.isSupported)
                        }
                    } label: {
                        ExportFormatMenuLabel(model.exportSettings.meshFormat.label)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                }
                .disabled(!model.activeOutputSupportsMesh)
                .opacity(model.activeOutputSupportsMesh ? 1 : 0.45)

                if !model.activeOutputSupportsMesh {
                    Label("Mask and data outputs export as raster fields only.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var exportActionBar: some View {
        HStack(spacing: 10) {
            Button(action: resetSettings) {
                Label("Reset", systemImage: "arrow.counterclockwise")
                    .font(.callout.weight(.semibold))
                    .frame(minWidth: 84, minHeight: 34)
            }
            .buttonStyle(.plain)
            .background(inspectorControlFill,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(inspectorControlStroke())

            Spacer()

            Button {
                model.runExport()
            } label: {
                Label(model.isExporting ? "Exporting" : "Export",
                      systemImage: "square.and.arrow.up")
                    .font(.callout.weight(.semibold))
                    .frame(minWidth: 92, minHeight: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(Color.accentColor,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .disabled(model.isExporting)
            .opacity(model.isExporting ? 0.65 : 1)
        }
        .padding(.top, 4)
    }

    private func resetSettings() {
        let outDir = model.exportSettings.outDir
        var defaults = ExportSettings()
        defaults.outDir = outDir
        model.exportSettings = defaults
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportSettings.outDir = url.path
    }
}

private struct ExportInspectorCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(colors: [
                    Color.white.opacity(0.035),
                    Color.white.opacity(0.015)
                ], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1))
    }
}

private struct ExportSectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.heavy))
            .tracking(1.6)
            .foregroundStyle(.secondary)
    }
}

private struct ExportFieldLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary.opacity(0.9))
            .frame(width: 112, alignment: .leading)
    }
}

private struct ExportMetricRow: View {
    let icon: String
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let precision: Int

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary.opacity(0.9))
                .frame(width: 118, alignment: .leading)

            ExportPlainSlider(value: $value, range: range, step: step)
                .frame(maxWidth: .infinity)
                .frame(height: 24)

            InspectorValueBox(text: formattedValue)
        }
    }

    private var formattedValue: String {
        if precision == 0 {
            return String(Int(round(value)))
        }
        return String(format: "%.\(precision)f", value)
    }
}

struct ExportPlainSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    var isContinuous: Bool = true
    /// Fires when a drag finishes, so callers can close an undo group rather
    /// than guessing from timing.
    var onEditingEnded: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value,
                              minValue: range.lowerBound,
                              maxValue: range.upperBound,
                              target: context.coordinator,
                              action: #selector(Coordinator.changed(_:)))
        slider.isContinuous = isContinuous
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        slider.controlSize = .small
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = value
        slider.isContinuous = isContinuous
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
    }

    final class Coordinator: NSObject {
        var parent: ExportPlainSlider

        init(_ parent: ExportPlainSlider) {
            self.parent = parent
        }

        @MainActor @objc func changed(_ sender: NSSlider) {
            let raw = sender.doubleValue
            let stepped: Double
            if parent.step > 0 {
                stepped = (raw / parent.step).rounded() * parent.step
            } else {
                stepped = raw
            }
            parent.value = min(parent.range.upperBound,
                               max(parent.range.lowerBound, stepped))
            // A continuous NSSlider reports the drag's final tick with a
            // leftMouseUp current event, which is the gesture boundary.
            if NSApp.currentEvent?.type == .leftMouseUp {
                parent.onEditingEnded?()
            }
        }
    }
}

private struct ExportFormatMenuLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Spacer(minLength: 0)

            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(width: 154, height: 34)
        .background(inspectorControlFill,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(inspectorControlStroke())
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct ExportFormatRow<Accessory: View>: View {
    let icon: String
    let title: String
    @Binding var enabled: Bool
    let accessory: Accessory

    init(icon: String,
         title: String,
         enabled: Binding<Bool>,
         @ViewBuilder accessory: () -> Accessory) {
        self.icon = icon
        self.title = title
        _enabled = enabled
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: $enabled)
                .labelsHidden()
                .toggleStyle(.checkbox)

            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text(title)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 8)

            accessory
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.45)
                .frame(width: 154)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(Color.white.opacity(0.018),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}
