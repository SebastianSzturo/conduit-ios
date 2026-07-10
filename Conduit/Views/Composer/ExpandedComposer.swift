import SwiftUI

/// Expanded composer card (frames 008/013): repo chip + cloud, multiline text
/// field, and a bottom action row (model chip and send).
struct ExpandedComposer: View {
    let store: HomeStore
    @Bindable var composer: ComposerState
    /// Completes only after workspace creation succeeds. A failure leaves the
    /// draft and composer open so the user can retry without retyping.
    var onSubmit: (
        NewSessionRequest,
        @escaping (Result<Void, Error>) -> Void
    ) -> Void
    /// Dismisses the expanded composer without sending.
    var onDismiss: () -> Void

    @FocusState private var promptFocused: Bool
    @State private var showRepoPicker = false
    @State private var showModelPicker = false
    @State private var isSubmitting = false
    @State private var submitError: String?

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
        .onAppear {
            composer.syncDefaultProjectIfNeeded()
            promptFocused = true
        }
        .sheet(isPresented: $showRepoPicker) {
            RepoPickerSheet(store: store, composer: composer)
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(selectedModel: composer.selectedModel, models: composer.availableModels) { composer.selectModel($0) }
        }
    }

    // MARK: Top row

    private var topRow: some View {
        HStack(spacing: 8) {
            Button {
                showRepoPicker = true
            } label: {
                HStack(spacing: 6) {
                    Text(repoLabel)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(composer.branch)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            Image(systemName: "cloud")
                .font(.system(size: 17))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var repoLabel: String {
        guard let project = composer.selectedProject else { return "Select repo" }
        let slug = project.repoSlug
        if let slash = slug.lastIndex(of: "/") {
            return String(slug[slug.index(after: slash)...])
        }
        return project.name
    }

    // MARK: Prompt field

    private var promptField: some View {
        ZStack(alignment: .topLeading) {
            if composer.prompt.isEmpty {
                Text("Plan, ask, build…")
                    .font(.system(size: 17))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 2)
            }
            TextField("", text: $composer.prompt, axis: .vertical)
                .font(.system(size: 17))
                .foregroundStyle(Theme.textPrimary)
                .focused($promptFocused)
                .lineLimit(1...8)
                .tint(Theme.working)
        }
        .frame(minHeight: 44, alignment: .topLeading)
    }

    // MARK: Bottom row

    private var bottomRow: some View {
        HStack(spacing: 14) {
            ModelChip(name: composer.selectedModel.displayName) { showModelPicker = true }

            Spacer(minLength: 8)

            if composer.canSend || isSubmitting {
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
        .animation(.easeInOut(duration: 0.15), value: composer.canSend)
    }

    private func submit() {
        guard let request = composer.makeRequest() else { return }
        isSubmitting = true
        submitError = nil
        onSubmit(request) { result in
            isSubmitting = false
            switch result {
            case .success:
                composer.reset()
                promptFocused = false
                onDismiss()
            case .failure(let error):
                submitError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                promptFocused = true
            }
        }
    }
}

private func expandedComposerPreview() -> some View {
    let store = HomeStore(api: MockConductorAPI())
    let settings = AppSettings()
    let composer = ComposerState(store: store, settings: settings)
    composer.selectedProject = MockConductorAPI.sampleProjects[0]
    return ZStack {
        Theme.background.ignoresSafeArea()
        VStack {
            Spacer()
            ExpandedComposer(
                store: store,
                composer: composer,
                onSubmit: { _, completion in completion(.success(())) },
                onDismiss: {}
            )
                .padding(16)
        }
    }
}

#Preview("Dark") {
    expandedComposerPreview()
        .preferredColorScheme(.dark)
}

#Preview("Light") {
    expandedComposerPreview()
        .preferredColorScheme(.light)
}
