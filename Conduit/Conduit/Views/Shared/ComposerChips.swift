import SwiftUI

/// Shared composer chips used by both the expanded new-session composer and
/// the session follow-up bar: model chip, thinking-effort chip, and the
/// signal-bars indicator.

/// Model chip: "Fable 5 ⌄" — tap opens the model picker sheet.
struct ModelChip: View {
    let name: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// Desktop-parity reasoning-effort chip: signal bars + level name, tap for a
/// Low / Medium / High / Extra High menu.
struct ThinkingChip: View {
    let level: ThinkingLevel
    var onSelect: (ThinkingLevel) -> Void

    var body: some View {
        Menu {
            Picker("Thinking", selection: binding) {
                ForEach(ThinkingLevel.allCases, id: \.self) { level in
                    Text(level.displayName).tag(level)
                }
            }
        } label: {
            HStack(spacing: 5) {
                ThinkingBars(barCount: level.barCount)
                Text(level.displayName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        .buttonStyle(.plain)
    }

    private var binding: Binding<ThinkingLevel> {
        Binding(get: { level }, set: { onSelect($0) })
    }
}

/// Four tiny capsules where the first `barCount` are highlighted — mirrors the
/// signal-bars reasoning-effort indicator in the Conductor desktop composer.
struct ThinkingBars: View {
    let barCount: Int
    private let total = 4

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(i < barCount ? Theme.textPrimary : Theme.textTertiary)
                    .frame(width: 2.5, height: 4 + CGFloat(i) * 3)
            }
        }
        .frame(height: 14, alignment: .bottom)
    }
}

/// Plain "+" circular button used inside glass composers (no filled circle —
/// glass-on-glass looks wrong, so it stays a plain glyph with a hit area).
struct PlusCircleButton: View {
    var size: CGFloat = 34
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    VStack(spacing: 20) {
        HStack(spacing: 16) {
            PlusCircleButton {}
            ModelChip(name: "Fable 5") {}
            ThinkingChip(level: .high) { _ in }
        }
    }
    .padding()
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
