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
    /// Largest height the focused composer can occupy after an upward drag.
    /// `SessionView` derives this from the space above the keyboard.
    var maxExpandedHeight: CGFloat = 420
    /// Called with the trimmed text when the user taps send.
    var onSend: (String) -> Void
    /// Called when the user taps the stop button.
    var onStop: () -> Void
    /// Called when the user dismisses the error banner.
    var onDismissError: () -> Void

    @State private var text = ""
    @State private var compactHeight: CGFloat = 0
    @State private var resizedHeight: CGFloat?
    @State private var dragStartHeight: CGFloat?
    @State private var editorWidth: CGFloat = 300
    @State private var focusedControlsVisible = false
    @State private var isInteractingWithHandle = false
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
        .onChange(of: focused) { _, isFocused in
            if isFocused {
                focusedControlsVisible = true
                return
            }

            // A touch on the handle briefly moves input focus away from the
            // editor. Keep the focused chrome alive long enough for its drag
            // gesture to take ownership, then collapse only on a genuine blur.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                guard !focused, !isInteractingWithHandle else { return }
                focusedControlsVisible = false
                resizedHeight = nil
                dragStartHeight = nil
            }
        }
        .onChange(of: maxExpandedHeight) { _, newValue in
            guard let resizedHeight else { return }
            self.resizedHeight = min(resizedHeight, max(newValue, compactHeight))
        }
    }

    // MARK: Pill

    private var pill: some View {
        VStack(spacing: 10) {
            if focusedControlsVisible {
                resizeHandle
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
            }

            HStack(alignment: .top, spacing: 10) {
                editor

                if !focusedControlsVisible {
                    actionButtons
                }
            }

            if focusedControlsVisible {
                if resizedHeight != nil {
                    Spacer(minLength: 0)
                }

                HStack(spacing: 14) {
                    ModelChip(name: modelChipName)
                    Spacer()
                    actionButtons
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(height: resizedHeight, alignment: .top)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                .stroke(Theme.separator, lineWidth: 1)
        )
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.height
        } action: { height in
            if resizedHeight == nil {
                compactHeight = height
            }
        }
        .animation(.easeInOut(duration: 0.18), value: focusedControlsVisible)
    }

    /// `TextEditor` guarantees that Return inserts a real newline. Its height
    /// is measured from the draft so the compact composer grows line by line;
    /// after a handle drag it instead fills all space above the action row.
    @ViewBuilder
    private var editor: some View {
        let field = ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text("Follow up…")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }

            TextEditor(text: $text)
                .font(.system(size: 16))
                .foregroundStyle(Theme.textPrimary)
                .tint(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .focused($focused)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.width
                } action: { width in
                    editorWidth = width
                }
        }

        if resizedHeight == nil {
            field.frame(height: naturalEditorHeight, alignment: .topLeading)
        } else {
            field.frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var naturalEditorHeight: CGFloat {
        let font = UIFont.systemFont(ofSize: 16)
        // Appending a space makes a trailing newline contribute its own line.
        let measuredText = text.isEmpty ? " " : text + " "
        let bounds = (measuredText as NSString).boundingRect(
            with: CGSize(width: max(1, editorWidth - 10), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        let contentHeight = ceil(bounds.height) + 16
        let minimumHeight: CGFloat = focusedControlsVisible ? 64 : 36
        let maximumHeight = ceil(font.lineHeight * 10) + 16
        return min(max(contentHeight, minimumHeight), maximumHeight)
    }

    private var resizeHandle: some View {
        Button(action: toggleExpanded) {
            Capsule()
                .fill(Theme.textTertiary.opacity(0.45))
                .frame(width: 36, height: 5)
                .frame(maxWidth: .infinity)
                .frame(height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(resizeGesture)
        .accessibilityLabel("Resize composer")
        .accessibilityHint("Swipe up to expand or down to collapse")
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard focusedControlsVisible else { return }
                isInteractingWithHandle = true
                focused = true
                if dragStartHeight == nil {
                    dragStartHeight = resizedHeight ?? compactHeight
                }
                guard let dragStartHeight else { return }
                let upperBound = max(maxExpandedHeight, compactHeight)
                resizedHeight = min(
                    upperBound,
                    max(compactHeight, dragStartHeight - value.translation.height)
                )
            }
            .onEnded { value in
                guard let dragStartHeight else { return }
                let upperBound = max(maxExpandedHeight, compactHeight)
                let projectedHeight = dragStartHeight - value.predictedEndTranslation.height
                let snapThreshold = compactHeight + ((upperBound - compactHeight) * 0.35)

                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    resizedHeight = projectedHeight >= snapThreshold ? upperBound : nil
                }
                focused = true
                isInteractingWithHandle = false
                self.dragStartHeight = nil
            }
    }

    private func toggleExpanded() {
        guard focusedControlsVisible else { return }
        focused = true
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            resizedHeight = resizedHeight == nil
                ? max(maxExpandedHeight, compactHeight)
                : nil
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
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
