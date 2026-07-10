import SwiftUI

/// Shared model chip used by composer rows.

/// Model chip: "Fable 5 ⌄" when interactive, or plain "Fable 5" when read-only.
struct ModelChip: View {
    let name: String
    var action: (() -> Void)?

    var body: some View {
        if let action {
            Button(action: action) {
                label(showsChevron: true)
            }
            .buttonStyle(.plain)
        } else {
            label(showsChevron: false)
        }
    }

    @ViewBuilder
    private func label(showsChevron: Bool) -> some View {
        HStack(spacing: 5) {
            Text(name)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        HStack(spacing: 16) {
            ModelChip(name: "Fable 5") {}
            ModelChip(name: "GPT-5.6 Sol")
        }
    }
    .padding()
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
