import SwiftUI

/// Collapsed floating composer pill that sits above the safe area on the home
/// screen. Tapping anywhere expands the full composer. Rendered with iOS 26
/// Liquid Glass.
struct ComposerPill: View {
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(width: 34, height: 34)

                Text("Plan, ask, build…")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textSecondary)

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Theme.separator, lineWidth: 1)
        )
    }
}

#Preview {
    ZStack {
        Theme.background.ignoresSafeArea()
        VStack {
            Spacer()
            ComposerPill {}
                .padding(.horizontal, 16)
        }
    }
    .preferredColorScheme(.dark)
}
