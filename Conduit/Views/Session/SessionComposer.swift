import SwiftUI
import UIKit

/// Floating bottom composer: input pill, send/stop buttons, and (when focused)
/// a read-only model label. Matches frames 054 / 062.
///
/// NOTE: a session's model is fixed server-side at creation and POST /messages
/// takes only text, so the model is displayed but cannot be changed here.
struct SessionComposer: View {
    let modelName: String?
    let isWorking: Bool
    let queuedCount: Int
    let errorMessage: String?
    /// Called with the trimmed text when the user taps send.
    var onSend: (String) -> Void
    /// Called when the user taps the stop button.
    var onStop: () -> Void
    /// Called when the user dismisses the error banner.
    var onDismissError: () -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    private var trimmed: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var canSend: Bool { !trimmed.isEmpty }

    /// Chip label: local selection, else the session's model, else the default.
    private var modelChipName: String {
        modelName ?? ModelOption.default.displayName
    }

    var body: some View {
        VStack(spacing: 8) {
            if let errorMessage {
                errorBanner(errorMessage)
            }

            if queuedCount > 0 {
                Text("\(queuedCount) queued")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            }

            pill
        }
        // Horizontal margins + a small gap above the keyboard / home indicator so
        // the pill floats instead of touching the keyboard, like the Cursor app.
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    // MARK: Pill

    private var pill: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                TextField("Follow up…", text: $text, axis: .vertical)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textPrimary)
                    .tint(Theme.textPrimary)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.leading, 4)

                if canSend {
                    Button(action: sendTapped) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.background)
                            .frame(width: 30, height: 30)
                            .background(Theme.textPrimary, in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                if isWorking {
                    Button(action: stopTapped) {
                        Image(systemName: "square.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.background)
                            .frame(width: 30, height: 30)
                            .background(Theme.textPrimary, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if focused {
                HStack(spacing: 14) {
                    ModelChip(name: modelChipName)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                .stroke(Theme.separator, lineWidth: 1)
        )
    }

    private func sendTapped() {
        let value = trimmed
        guard !value.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        onSend(value)
        text = ""
        // Keep the keyboard up for the next follow-up.
        focused = true
    }

    private func stopTapped() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        onStop()
    }

    // MARK: Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.error)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismissError) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.error.opacity(0.15), in: RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerMedium, style: .continuous)
                .stroke(Theme.error.opacity(0.4), lineWidth: 1)
        )
    }
}

#Preview("Composer states") {
    VStack(spacing: 24) {
        Spacer()
        SessionComposer(modelName: "Fable 5", isWorking: false, queuedCount: 0, errorMessage: nil, onSend: { _ in }, onStop: {}, onDismissError: {})
        SessionComposer(modelName: "Fable 5", isWorking: true, queuedCount: 2, errorMessage: nil, onSend: { _ in }, onStop: {}, onDismissError: {})
        SessionComposer(modelName: "Opus 4.8", isWorking: false, queuedCount: 0, errorMessage: "Request failed (500)", onSend: { _ in }, onStop: {}, onDismissError: {})
    }
    .background(Theme.background)
    .preferredColorScheme(.dark)
}
