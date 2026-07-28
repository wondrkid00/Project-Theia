import SwiftUI

struct ViewportSettingsPopover: View {
    @ObservedObject var model: TerrainModel
    let viewport: TerrainMTKView

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Viewport")
                    .font(.subheadline.weight(.semibold))
                Text(model.activeDisplayModeLabel())
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.resetCamera()
                    redraw()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Reset camera")
            }

            SettingSlider(title: "mask opacity",
                          value: Binding(
                            get: { model.maskOpacity },
                            set: { value in
                                model.setMaskOpacity(value)
                                redraw()
                            }),
                          range: 0...1,
                          step: 0.01,
                          precision: 2)

            if model.canEditActiveMask {
                HStack {
                    Toggle(isOn: Binding(
                        get: { model.maskBrushEnabled },
                        set: { enabled in
                            model.setMaskBrushEnabled(enabled)
                            redraw()
                        })) {
                        Label("Erase", systemImage: "eraser")
                    }
                    .font(.caption)
                    Spacer()
                    Button {
                        model.clearActiveMaskErase()
                        redraw()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.activeMaskEraseCount == 0)
                }

                SettingSlider(title: "brush",
                              value: Binding(
                                get: { model.maskBrushRadius },
                                set: { model.maskBrushRadius = min(max($0, 0.005), 0.12) }),
                              range: 0.005...0.12,
                              step: 0.005,
                              precision: 3)
            }

            SettingSlider(title: "light azimuth",
                          value: setting(\.lightAzimuthDegrees),
                          range: -180...180,
                          step: 1,
                          precision: 0)

            SettingSlider(title: "light elevation",
                          value: setting(\.lightElevationDegrees),
                          range: 5...90,
                          step: 1,
                          precision: 0)

            Toggle("wireframe", isOn: Binding(
                get: { model.wireframeEnabled },
                set: { enabled in
                    model.wireframeEnabled = enabled
                    model.applyViewportSettings()
                    redraw()
                }))
                .font(.caption)
        }
    }

    private func setting(_ keyPath: ReferenceWritableKeyPath<TerrainModel, Double>)
        -> Binding<Double> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: { value in
                model[keyPath: keyPath] = value
                model.applyViewportSettings()
                redraw()
            })
    }

    private func redraw() {
        viewport.setNeedsDisplay(viewport.bounds)
    }
}


struct SettingSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let precision: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                Spacer()
                Text(String(format: "%.\(precision)f", value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}
