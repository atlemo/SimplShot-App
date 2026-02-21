import SwiftUI

struct PresetEditorSheet: View {
    let preset: WidthPreset?
    let onSave: (WidthPreset) -> Void

    @State private var widthText: String = ""
    @State private var labelText: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text(preset == nil ? "Add Width Preset" : "Edit Width Preset")
                .font(.headline)

            Form {
                TextField("Width (pixels):", text: $widthText)
                TextField("Label (optional):", text: $labelText)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(Int(widthText) == nil || Int(widthText)! <= 0)
            }
        }
        .padding()
        .frame(width: 300)
        .onAppear {
            if let preset {
                widthText = "\(preset.width)"
                labelText = preset.label
            }
        }
    }

    private func save() {
        guard let width = Int(widthText), width > 0 else { return }
        let label = labelText.isEmpty ? "\(width)px" : labelText
        let newPreset = WidthPreset(width: width, label: label)
        onSave(newPreset)
        dismiss()
    }
}
