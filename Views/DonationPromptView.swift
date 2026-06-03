import SwiftUI

struct DonationPromptView: View {
    var onDismiss: () -> Void = {}
    var onDonate: () -> Void = {}

    @State private var neverAskAgain = false

    var body: some View {
        VStack(spacing: 0) {
            // Icon
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .padding(.top, 28)
                .padding(.bottom, 14)

            Text("Enjoying SimplShot?")
                .font(.title2)
                .fontWeight(.semibold)

            // Body
            VStack(spacing: 10) {
                Text("SimplShot is free to use, and I do my best to keep it that way. But running it isn't entirely free — the Apple Developer Program, a small hosting bill, and the occasional weekend of debugging all add up.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)

                Text("Even a tiny one-time tip goes a long way toward keeping this tool alive and improving. No subscription, no nag screens — just this one ask.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .font(.body)
            .padding(.horizontal, 28)
            .padding(.top, 14)
            .padding(.bottom, 20)

            // "Don't ask" checkbox
            Toggle(isOn: $neverAskAgain) {
                Text("Don't ask me again")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .toggleStyle(.checkbox)
            .padding(.bottom, 20)

            Divider()

            // Buttons
            HStack(spacing: 12) {
                Button("Maybe Later") {
                    if neverAskAgain {
                        DonationService.neverAsk = true
                    }
                    onDismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Button("Support SimplShot ♥") {
                    NSWorkspace.shared.open(DonationService.donationURL)
                    DonationService.neverAsk = true
                    onDonate()
                }
                .buttonStyle(.borderedProminent)
                .tint(.pink)
                .keyboardShortcut(.return, modifiers: [])
            }
            .controlSize(.large)
            .padding(.vertical, 18)
        }
        .frame(width: 400)
    }
}
