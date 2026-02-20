import SwiftUI

struct AspectRatioEditorSheet: View {
    let ratio: AspectRatio?
    let onSave: (AspectRatio) -> Void

    @State private var widthText: String = ""
    @State private var heightText: String = ""
    @Environment(\.dismiss) private var dismiss

    private var isValid: Bool {
        guard let w = Int(widthText), let h = Int(heightText) else { return false }
        return w > 0 && h > 0
    }

    private var previewText: String {
        guard let w = Int(widthText), let h = Int(heightText), w > 0, h > 0 else { return "" }
        return "\(w):\(h)"
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(ratio == nil ? "Add Aspect Ratio" : "Edit Aspect Ratio")
                .font(.headline)

            Form {
                HStack {
                    TextField("Width:", text: $widthText)
                        .frame(width: 80)
                    Text(":")
                    TextField("Height:", text: $heightText)
                        .frame(width: 80)
                    if !previewText.isEmpty {
                        Text("(\(previewText))")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding()
        .frame(width: 300)
        .onAppear {
            if let ratio {
                widthText = "\(ratio.widthComponent)"
                heightText = "\(ratio.heightComponent)"
            }
        }
    }

    private func save() {
        guard let w = Int(widthText), let h = Int(heightText), w > 0, h > 0 else { return }
        let newRatio = AspectRatio(widthComponent: w, heightComponent: h)
        onSave(newRatio)
        dismiss()
    }
}
