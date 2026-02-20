import SwiftUI

struct PresetsSettingsView: View {
    @Bindable var appSettings: AppSettings
    @State private var showingWidthEditor = false
    @State private var showingRatioEditor = false
    @State private var editingPreset: WidthPreset?
    @State private var editingRatio: AspectRatio?

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            // Width Presets
            VStack(alignment: .leading) {
                Text("Width Presets")
                    .font(.headline)

                List {
                    ForEach(appSettings.widthPresets) { preset in
                        HStack {
                            Text(preset.label)
                            Spacer()
                            if preset.isBuiltIn {
                                Text("Built-in")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else if preset.label != "\(preset.width)px" {
                                Text("\(preset.width)px")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !preset.isBuiltIn {
                                editingPreset = preset
                                showingWidthEditor = true
                            }
                        }
                        .contextMenu {
                            if !preset.isBuiltIn {
                                Button("Edit") {
                                    editingPreset = preset
                                    showingWidthEditor = true
                                }
                                Button("Delete", role: .destructive) {
                                    appSettings.widthPresets.removeAll { $0.id == preset.id }
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 150)

                Button("Add Width Preset") {
                    editingPreset = nil
                    showingWidthEditor = true
                }
            }

            Divider()

            // Aspect Ratios
            VStack(alignment: .leading) {
                Text("Aspect Ratios")
                    .font(.headline)

                List {
                    ForEach(appSettings.aspectRatios) { ratio in
                        HStack {
                            Text(ratio.label)
                            Spacer()
                            if ratio.isBuiltIn {
                                Text("Built-in")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if !ratio.isBuiltIn {
                                editingRatio = ratio
                                showingRatioEditor = true
                            }
                        }
                        .contextMenu {
                            if !ratio.isBuiltIn {
                                Button("Edit") {
                                    editingRatio = ratio
                                    showingRatioEditor = true
                                }
                                Button("Delete", role: .destructive) {
                                    appSettings.aspectRatios.removeAll { $0.id == ratio.id }
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 150)

                Button("Add Aspect Ratio") {
                    editingRatio = nil
                    showingRatioEditor = true
                }
            }
        }
        .padding()
        .sheet(isPresented: $showingWidthEditor) {
            PresetEditorSheet(preset: editingPreset) { newPreset in
                if let existing = editingPreset {
                    if let idx = appSettings.widthPresets.firstIndex(where: { $0.id == existing.id }) {
                        appSettings.widthPresets[idx] = newPreset
                    }
                } else {
                    appSettings.widthPresets.append(newPreset)
                }
            }
        }
        .sheet(isPresented: $showingRatioEditor) {
            AspectRatioEditorSheet(ratio: editingRatio) { newRatio in
                if let existing = editingRatio {
                    if let idx = appSettings.aspectRatios.firstIndex(where: { $0.id == existing.id }) {
                        appSettings.aspectRatios[idx] = newRatio
                    }
                } else {
                    appSettings.aspectRatios.append(newRatio)
                }
            }
        }
    }
}
