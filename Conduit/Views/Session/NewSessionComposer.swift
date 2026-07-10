import SwiftUI

/// Expanded composer card for spawning a sibling session in the current
/// workspace: multiline starting-message field and a bottom action row (model
/// chip + send). Mirrors the home screen's `ExpandedComposer`, minus the repo
/// picker — the workspace is fixed.
struct NewSessionComposer: View {
    /// Preselected model (the current session's model).
    let initialModel: ModelOption
    let models: [ModelOption]
    /// Called with the trimmed starting message and chosen model on send.
    var onSubmit: (String, ModelOption) async throws -> Void
    /// Dismisses the composer without sending.
    var onDismiss: () -> Void

    @State private var prompt = ""
    @State private var selectedModel: ModelOption
    @State private var showModelPicker = false
    @State private var isSubmitting = false
    @State private var submitError: String?
    @FocusState private var promptFocused: Bool

    init(
        initialModel: ModelOption,
        models: [ModelOption],
        onSubmit: @escaping (String, ModelOption) async throws -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.initialModel = initialModel
        self.models = models
        self.onSubmit = onSubmit
        self.onDismiss = onDismiss
        self._selectedModel = State(initialValue: initialModel)
    }

    var body: some View {
        VStack(spacing: 14) {
            topRow
            promptField
            if let submitError {
                Text(submitError)
                    .font(.caption)
                    .foregroundStyle(Theme.error)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            bottomRow
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerLarge, style: .continuous)
                .stroke(Theme.separator, lineWidth: 1)
        )
        .onAppear { promptFocused = true }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(selectedModel: selectedModel, models: models) { selectedModel = $0 }
        }
    }

    // MARK: Top row

    private var topRow: some View {
        HStack(spacing: 8) {
            Text("New session")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Image(systemName: "cloud")
                .font(.system(size: 17))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: Prompt field

    private var promptField: some View {
        ZStack(alignment: .topLeading) {
            if prompt.isEmpty {
                Text("Plan, ask, build…")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 2)
            }
            TextField("", text: $prompt, axis: .vertical)
                .font(.system(size: 17))
                .foregroundStyle(Theme.textPrimary)
                .focused($promptFocused)
                .lineLimit(1...8)
                .tint(Theme.working)
        }
        .frame(minHeight: 44, alignment: .topLeading)
    }

    // MARK: Bottom row

    private var canSend: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var bottomRow: some View {
        HStack(spacing: 14) {
            ModelChip(name: selectedModel.displayName) { showModelPicker = true }

            Spacer(minLength: 8)

            if canSend || isSubmitting {
                Button(action: submit) {
                    Group {
                        if isSubmitting {
                            ProgressView().tint(Theme.background)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 16, weight: .bold))
                        }
                    }
                        .foregroundStyle(Theme.background)
                        .frame(width: 34, height: 34)
                        .background(Theme.textPrimary, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: canSend)
    }

    private func submit() {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSubmitting = true
        submitError = nil
        Task {
            defer { isSubmitting = false }
            do {
                try await onSubmit(trimmed, selectedModel)
                promptFocused = false
                onDismiss()
            } catch {
                submitError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                promptFocused = true
            }
        }
    }
}

#Preview("Dark") {
    ZStack {
        Theme.background.ignoresSafeArea()
        VStack {
            Spacer()
            NewSessionComposer(initialModel: .default, models: ModelOption.fallback, onSubmit: { _, _ in }, onDismiss: {})
                .padding(16)
        }
    }
    .preferredColorScheme(.dark)
}

#Preview("Light") {
    ZStack {
        Theme.background.ignoresSafeArea()
        VStack {
            Spacer()
            NewSessionComposer(initialModel: .default, models: ModelOption.fallback, onSubmit: { _, _ in }, onDismiss: {})
                .padding(16)
        }
    }
    .preferredColorScheme(.light)
}
