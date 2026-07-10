import SwiftUI

/// Sheet for choosing the model. Active section (current, checkmark) + More
/// section listing the server-provided catalog.
struct ModelPickerSheet: View {
    /// The currently-active model (checkmarked in the Active section).
    let selectedModel: ModelOption
    let models: [ModelOption]
    /// Called with the chosen model; the sheet dismisses itself after.
    var onSelect: (ModelOption) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""

    private var filtered: [ModelOption] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return models }
        return models.filter {
            $0.displayName.lowercased().contains(q) || ($0.effortTag?.lowercased().contains(q) ?? false)
        }
    }

    private var active: ModelOption? {
        filtered.first { $0.id == selectedModel.id }
    }

    private var more: [ModelOption] {
        filtered.filter { $0.id != selectedModel.id }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    searchField

                    if let active {
                        section("Active") {
                            ModelRow(model: active, isSelected: true) { select(active) }
                        }
                    }

                    if !more.isEmpty {
                        section("More") {
                            ForEach(more) { m in
                                ModelRow(model: m, isSelected: false) { select(m) }
                            }
                        }
                    }

                    if filtered.isEmpty {
                        Text("No models found")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.top, 48)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .background(Theme.background)
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    CircleIconButton(systemName: "xmark") { dismiss() }
                }
            }
            .toolbarBackground(Theme.background, for: .navigationBar)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.textSecondary)
            TextField("Search", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Theme.inputField, in: Capsule())
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 20)
                .padding(.bottom, 6)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func select(_ model: ModelOption) {
        onSelect(model)
        dismiss()
    }
}

private struct ModelRow: View {
    let model: ModelOption
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Text(model.displayName)
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.textPrimary)
                if let tag = model.effortTag {
                    Text(tag)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                } else {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.separator).frame(height: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ModelPickerSheet(selectedModel: .default, models: ModelOption.fallback) { _ in }
}
