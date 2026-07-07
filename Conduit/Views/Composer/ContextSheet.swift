import SwiftUI

/// Context sheet (frame_030): optional Mode selection (Agent / Plan / Draft)
/// plus a list of non-functional "Add" sources shown for visual fidelity.
///
/// Shared between the new-session composer (pass a `mode` binding) and the
/// session follow-up bar (pass `nil` — mode only makes sense pre-session).
struct ContextSheet: View {
    /// When non-nil the Mode section is shown and bound to this value.
    var mode: Binding<ComposerMode>?
    @Environment(\.dismiss) private var dismiss

    @State private var comingSoon = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let mode {
                        // Mode
                        Text("Mode")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.top, 12)
                            .padding(.bottom, 4)

                        ModeRow(icon: "sparkles", title: "Agent",
                                isSelected: mode.wrappedValue == .agent) { mode.wrappedValue = .agent }
                        ModeRow(icon: "list.bullet.rectangle", title: "Plan",
                                isSelected: mode.wrappedValue == .plan) { mode.wrappedValue = .plan }
                        ModeRow(icon: "circle.dashed", title: "Draft",
                                isSelected: mode.wrappedValue == .draft) { mode.wrappedValue = .draft }
                    }

                    // Add
                    Text("Add")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, mode == nil ? 12 : 24)
                        .padding(.bottom, 4)

                    AddRow(icon: "photo", title: "Photos") { triggerComingSoon() }
                    AddRow(icon: "viewfinder", title: "Screenshots", showsChevron: true) { triggerComingSoon() }
                    AddRow(icon: "camera", title: "Camera") { triggerComingSoon() }
                    AddRow(icon: "folder", title: "Files") { triggerComingSoon() }
                    AddRow(icon: "point.3.connected.trianglepath.dotted", title: "MCP Servers",
                           trailingText: "1", showsChevron: true) { triggerComingSoon() }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Theme.background)
            .navigationTitle("Context")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    CircleIconButton(systemName: "xmark") { dismiss() }
                }
            }
            .toolbarBackground(Theme.background, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .overlay(alignment: .bottom) {
            if comingSoon {
                Text("Coming soon")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Theme.cardElevated, in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
    }

    private func triggerComingSoon() {
        withAnimation(.easeInOut(duration: 0.2)) { comingSoon = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            withAnimation(.easeInOut(duration: 0.25)) { comingSoon = false }
        }
    }
}

private struct ModeRow: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? Theme.working : Theme.textSecondary)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.working)
                }
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.separator).frame(height: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct AddRow: View {
    let icon: String
    let title: String
    var trailingText: String?
    var showsChevron: Bool = false
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24)
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if let trailingText {
                    Text(trailingText)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textSecondary)
                }
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.separator).frame(height: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview("With mode") {
    @Previewable @State var mode: ComposerMode = .agent
    ContextSheet(mode: $mode)
}

#Preview("Follow-up (no mode)") {
    ContextSheet(mode: nil)
}
