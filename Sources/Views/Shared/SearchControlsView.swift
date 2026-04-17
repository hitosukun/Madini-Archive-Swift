import SwiftUI

struct SearchControlsView: View {
    @Bindable var viewModel: SearchViewModel
    var showsQuerySection: Bool = true
    var showsAdvancedInline: Bool = false
    @State private var showsAdvancedFilters = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsQuerySection {
                sectionCard {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Query")

                        HStack(spacing: 8) {
                            TextField("Search conversations", text: viewModel.searchTextBinding())
                                .textFieldStyle(.roundedBorder)
                                .onSubmit {
                                    viewModel.performSearchNow()
                                }

                            Button("Search") {
                                viewModel.performSearchNow()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }

            sectionCard {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("Filters")

                    if showsAdvancedInline {
                        HStack(spacing: 8) {
                            compactField(title: "Source") {
                                Picker("Source", selection: viewModel.sourceSelectionBinding()) {
                                    Text("All").tag(nil as String?)
                                    ForEach(viewModel.sourceOptions) { option in
                                        Text(option.value).tag(option.value as String?)
                                    }
                                }
                                .labelsHidden()
                            }

                            compactField(title: "Model") {
                                Picker("Model", selection: viewModel.modelSelectionBinding()) {
                                    Text("All").tag(nil as String?)
                                    ForEach(viewModel.modelOptions) { option in
                                        Text(option.value).tag(option.value as String?)
                                    }
                                }
                                .labelsHidden()
                            }
                        }
                    } else {
                        regularField(title: "Source") {
                            Picker("Source", selection: viewModel.sourceSelectionBinding()) {
                                Text("All Sources").tag(nil as String?)
                                ForEach(viewModel.sourceOptions) { option in
                                    Text("\(option.value) (\(option.count))")
                                        .tag(option.value as String?)
                                }
                            }
                            .labelsHidden()
                        }

                        regularField(title: "Model") {
                            Picker("Model", selection: viewModel.modelSelectionBinding()) {
                                Text("All Models").tag(nil as String?)
                                ForEach(viewModel.modelOptions) { option in
                                    Text("\(option.value) (\(option.count))")
                                        .tag(option.value as String?)
                                }
                            }
                            .labelsHidden()
                        }
                    }

                    Toggle("Bookmarked only", isOn: viewModel.bookmarkedOnlyBinding())
                    #if os(macOS)
                        .toggleStyle(.checkbox)
                    #endif

                    if showsAdvancedInline {
                        HStack(spacing: 8) {
                            compactField(title: "From") {
                                TextField("YYYY-MM-DD", text: viewModel.dateFromBinding())
                                    .textFieldStyle(.roundedBorder)
                            }

                            compactField(title: "To") {
                                TextField("YYYY-MM-DD", text: viewModel.dateToBinding())
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Roles")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            FlexibleRoleRow(
                                selectedRoles: Set(viewModel.selectedRoles),
                                onToggle: { role in
                                    viewModel.toggleRole(role)
                                }
                            )
                        }
                    }

                    if viewModel.hasActiveFilters {
                        Button("Clear Filters") {
                            viewModel.clearFilters()
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            if showsAdvancedInline {
                if viewModel.hasActiveFilters {
                    Text(viewModel.filterSummaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 4)
                }
            } else {
                sectionCard {
                    DisclosureGroup(isExpanded: $showsAdvancedFilters) {
                        VStack(alignment: .leading, spacing: 10) {
                            regularField(title: "Date From") {
                                TextField("YYYY-MM-DD", text: viewModel.dateFromBinding())
                                    .textFieldStyle(.roundedBorder)
                            }

                            regularField(title: "Date To") {
                                TextField("YYYY-MM-DD", text: viewModel.dateToBinding())
                                    .textFieldStyle(.roundedBorder)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Roles")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                FlexibleRoleRow(
                                    selectedRoles: Set(viewModel.selectedRoles),
                                    onToggle: { role in
                                        viewModel.toggleRole(role)
                                    }
                                )
                            }

                            if viewModel.hasActiveFilters {
                                Text(viewModel.filterSummaryText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Label("Advanced Filters", systemImage: "line.3.horizontal.decrease.circle")
                            .font(.subheadline.weight(.medium))
                    }
                }
            }

            sectionCard {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("Saved View")

                    if showsAdvancedInline {
                        HStack(spacing: 8) {
                            TextField("Saved view name", text: viewModel.pendingSavedViewNameBinding())
                                .textFieldStyle(.roundedBorder)

                            Button("Save") {
                                viewModel.saveCurrentView()
                            }
                            .buttonStyle(.bordered)
                            .disabled(!viewModel.canSaveCurrentView)
                        }
                    } else {
                        TextField("Saved view name", text: viewModel.pendingSavedViewNameBinding())
                            .textFieldStyle(.roundedBorder)

                        Button("Save View") {
                            viewModel.saveCurrentView()
                        }
                        .buttonStyle(.bordered)
                        .disabled(!viewModel.canSaveCurrentView)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func regularField<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private func compactField<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}

private struct FlexibleRoleRow: View {
    let selectedRoles: Set<MessageRole>
    let onToggle: (MessageRole) -> Void

    private let columns = [
        GridItem(.flexible(minimum: 80), spacing: 8),
        GridItem(.flexible(minimum: 80), spacing: 8),
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach([MessageRole.user, .assistant, .tool, .system], id: \.rawValue) { role in
                Button {
                    onToggle(role)
                } label: {
                    Text(role.displayName)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(selectedRoles.contains(role) ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                        .foregroundStyle(selectedRoles.contains(role) ? Color.accentColor : .primary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
