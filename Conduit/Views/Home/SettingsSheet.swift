import SwiftUI

/// Simple settings sheet: API key entry + default model picker.
struct SettingsSheet: View {
    @Bindable var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    private var selectedModel: ModelOption {
        ModelOption.named(settings.defaultModelID) ?? .default
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("API Key")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                        SecureField("sk_…", text: $settings.apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .foregroundStyle(Theme.textPrimary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .background(Theme.inputField, in: RoundedRectangle(cornerRadius: Theme.cornerSmall, style: .continuous))
                        Text("Stored securely on device.")
                            .font(.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Default Model")
                            .font(.footnote)
                            .foregroundStyle(Theme.textSecondary)
                        Menu {
                            ForEach(ModelOption.all) { model in
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
    }
}

#Preview {
    SettingsSheet(settings: AppSettings())
}
