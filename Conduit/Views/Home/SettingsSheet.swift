import SwiftUI

/// Simple settings sheet: API key entry + default model picker.
struct SettingsSheet: View {
    @Bindable var settings: AppSettings
    let api: ConductorAPI
    var onSaved: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draftKey = ""
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var validatedIdentity: Identity?

    private var selectedModel: ModelOption {
        settings.model(named: settings.defaultModelID) ?? .default
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("API Key")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                        SecureField("sk_…", text: $draftKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Theme.inputField, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                        if let identity = validatedIdentity ?? settings.connectedIdentity {
                            Label(identity.email ?? identity.userId, systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.working)
                        } else {
                            Text("The key is validated before it is stored securely on device.")
                                .font(.caption)
                                .foregroundStyle(Theme.textTertiary)
                        }
                        if let saveError {
                            Text(saveError)
                                .font(.caption)
                                .foregroundStyle(Theme.error)
                        }
                        Button {
                            save()
                        } label: {
                            if isSaving {
                                ProgressView().frame(maxWidth: .infinity)
                            } else {
                                Text("Connect").frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.textPrimary)
                        .disabled(isSaving || draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Default Model")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                        Menu {
                            ForEach(settings.availableModels) { model in
                                Button {
                                    settings.defaultModelID = model.modelID
                                } label: {
                                    if model.id == selectedModel.id {
                                        Label(model.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(model.displayName)
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text(selectedModel.displayName)
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Theme.inputField, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                        }
                    }
                }
                .padding(20)
            }
            .background(Theme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            .toolbarBackground(Theme.background, for: .navigationBar)
        }
        .presentationDetents([.medium])
        .onAppear { draftKey = settings.apiKey }
    }

    private func save() {
        let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        isSaving = true
        saveError = nil
        Task {
            defer { isSaving = false }
            do {
                let identity = try await api.identity(apiKey: key)
                try settings.saveValidatedAPIKey(key, identity: identity)
                validatedIdentity = identity
                await onSaved()
            } catch {
                saveError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

#Preview {
    SettingsSheet(settings: AppSettings(), api: MockConductorAPI(), onSaved: {})
}
