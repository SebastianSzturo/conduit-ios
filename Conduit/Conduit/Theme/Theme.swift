import SwiftUI
import UIKit

/// Conduit design tokens — adaptive light/dark, matching the Cursor iOS
/// aesthetic (pure black in dark mode, soft off-white in light mode).
enum Theme {
    private static func adaptive(dark: UIColor, light: UIColor) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }

    // Backgrounds
    static let background = adaptive(
        dark: .black,
        light: .white
    )
    static let card = adaptive(
        dark: UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1),   // ~#1C1C1E
        light: UIColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1)   // ~#F2F2F4
    )
    static let cardElevated = adaptive(
        dark: UIColor(red: 0.15, green: 0.15, blue: 0.16, alpha: 1),
        light: UIColor(red: 0.92, green: 0.92, blue: 0.93, alpha: 1)
    )
    static let inputField = adaptive(
        dark: UIColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1),
        light: UIColor(red: 0.94, green: 0.94, blue: 0.95, alpha: 1)
    )

    // Text
    static let textPrimary = adaptive(dark: .white, light: UIColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1))
    static let textSecondary = adaptive(
        dark: UIColor(red: 0.56, green: 0.56, blue: 0.58, alpha: 1),   // ~#8E8E93
        light: UIColor(red: 0.45, green: 0.45, blue: 0.47, alpha: 1)
    )
    static let textTertiary = adaptive(
        dark: UIColor(red: 0.39, green: 0.39, blue: 0.40, alpha: 1),
        light: UIColor(red: 0.62, green: 0.62, blue: 0.64, alpha: 1)
    )

    // Accents
    static let additions = adaptive(
        dark: UIColor(red: 0.30, green: 0.85, blue: 0.39, alpha: 1),
        light: UIColor(red: 0.13, green: 0.60, blue: 0.24, alpha: 1)
    )
    static let deletions = adaptive(
        dark: UIColor(red: 1.00, green: 0.42, blue: 0.42, alpha: 1),
        light: UIColor(red: 0.80, green: 0.20, blue: 0.20, alpha: 1)
    )
    static let working = Color(red: 0.35, green: 0.55, blue: 1.00)       // active spinner tint
    /// Unread / attention accent (blue dot).
    static let accent = adaptive(
        dark: UIColor(red: 0.25, green: 0.52, blue: 1.00, alpha: 1),
        light: UIColor(red: 0.00, green: 0.40, blue: 0.95, alpha: 1)
    )
    static let error = adaptive(
        dark: UIColor(red: 1.00, green: 0.35, blue: 0.35, alpha: 1),
        light: UIColor(red: 0.85, green: 0.15, blue: 0.15, alpha: 1)
    )

    // Separators
    static let separator = adaptive(
        dark: UIColor(white: 1, alpha: 0.08),
        light: UIColor(white: 0, alpha: 0.08)
    )

    // Radii
    static let cornerLarge: CGFloat = 24
    static let cornerMedium: CGFloat = 16
    static let cornerSmall: CGFloat = 10
}

extension View {
    /// Standard dark card background used for transcript cards, rows and sheets.
    func themedCard(radius: CGFloat = Theme.cornerMedium) -> some View {
        background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Circular dark toolbar button (back chevron, search, filter, close).
struct CircleIconButton: View {
    let systemName: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 38, height: 38)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Animated multicolor dot shown next to actively working sessions.
struct WorkingIndicator: View {
    @State private var animating = false

    var body: some View {
        Image(systemName: "asterisk")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(
                AngularGradient(
                    colors: [.blue, .purple, .pink, .orange, .blue],
                    center: .center
                )
            )
            .rotationEffect(.degrees(animating ? 360 : 0))
            .animation(.linear(duration: 2.4).repeatForever(autoreverses: false), value: animating)
            .onAppear { animating = true }
    }
}

/// Relative "2m / 7h / 2d" timestamp string.
func relativeTimeLabel(_ date: Date?) -> String {
    guard let date else { return "" }
    let seconds = max(0, Date.now.timeIntervalSince(date))
    if seconds < 60 { return "now" }
    if seconds < 3600 { return "\(Int(seconds / 60))m" }
    if seconds < 86400 { return "\(Int(seconds / 3600))h" }
    return "\(Int(seconds / 86400))d"
}
