import SwiftUI

/// Left-sidebar Tags section. Reuses the existing
/// `SortAndTagsInspectorViewModel` (renamed spiritually — the VM is tag-only
/// since the Sorting controls were removed in a prior iteration).
///
/// Each row is a drag source carrying a `TagDragPayload`, so the user can
/// drop a tag onto any conversation card in the middle pane to attach it.
struct SidebarTagsSection: View {
    let libraryViewModel: LibraryViewModel

    @Environment(ArchiveEvents.self) private var archiveEvents
    @EnvironmentObject private var services: AppServices
    @State private var viewModel: SortAndTagsInspectorViewModel?
    @State private var tagPendingDeletion: TagEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if let viewModel {
                createTagField(viewModel: viewModel)
                tagList(viewModel: viewModel)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task {
            if viewModel == nil {
                viewModel = SortAndTagsInspectorViewModel(
                    tagRepository: services.tags,
                    libraryViewModel: libraryViewModel,
                    archiveEvents: archiveEvents
                )
            }
            await viewModel?.loadInitial()
        }
        .onChange(of: libraryViewModel.selectedConversationId) { _, _ in
            Task { await viewModel?.refreshCurrentConversationTags() }
        }
        .alert(
            "Delete tag?",
            isPresented: Binding(
                get: { tagPendingDeletion != nil },
                set: { if !$0 { tagPendingDeletion = nil } }
            ),
            presenting: tagPendingDeletion
        ) { tag in
            Button("Delete", role: .destructive) {
                viewModel?.deleteTag(tag)
                tagPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                tagPendingDeletion = nil
            }
        } message: { tag in
            Text("“\(tag.name)” will be detached from all conversations.")
        }
    }

    @ViewBuilder
    private func createTagField(viewModel: SortAndTagsInspectorViewModel) -> some View {
        HStack(spacing: 6) {
            TextField("New tag", text: viewModel.pendingTagNameBinding())
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .onSubmit(viewModel.createPendingTag)

            Button {
                viewModel.createPendingTag()
            } label: {
                Image(systemName: "plus")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(viewModel.pendingTagName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder
    private func tagList(viewModel: SortAndTagsInspectorViewModel) -> some View {
        if viewModel.tags.isEmpty {
            Text("No tags yet")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(viewModel.tags) { tag in
                    SidebarTagRow(
                        tag: tag,
                        isFilterActive: viewModel.isTagFilterActive(tag),
                        isAttachedToSelection: viewModel.isTagAttachedToSelection(tag),
                        hasSelection: viewModel.selectedConversationID != nil,
                        onToggleFilter: { viewModel.toggleTagFilter(tag) },
                        onToggleAttach: { viewModel.toggleAttachmentToSelection(tag) },
                        onRename: { newName in viewModel.renameTag(tag, to: newName) },
                        onRequestDelete: { tagPendingDeletion = tag }
                    )
                }
            }
        }
    }
}

private struct SidebarTagRow: View {
    let tag: TagEntry
    let isFilterActive: Bool
    let isAttachedToSelection: Bool
    let hasSelection: Bool
    let onToggleFilter: () -> Void
    let onToggleAttach: () -> Void
    let onRename: (String) -> Void
    let onRequestDelete: () -> Void

    @State private var isHovering = false
    @State private var isEditing = false
    @State private var draftName: String = ""

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggleFilter) {
                HStack(spacing: 6) {
                    Image(systemName: isFilterActive ? "line.3.horizontal.decrease.circle.fill" : "number")
                        .font(.caption2)
                        .foregroundStyle(isFilterActive ? Color.accentColor : .secondary)

                    if isEditing {
                        TextField("Tag name", text: $draftName, onCommit: commitRename)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                    } else {
                        Text(tag.name)
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .onTapGesture(count: 2) { beginEditing() }
                    }

                    Text("\(tag.usageCount)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onToggleAttach) {
                Image(systemName: isAttachedToSelection ? "checkmark.circle.fill" : "plus.circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isAttachedToSelection ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!hasSelection)
            .help(hasSelection
                  ? (isAttachedToSelection ? "Detach from selected conversation" : "Attach to selected conversation")
                  : "Select a conversation first")

            if isHovering && !tag.isSystem {
                Menu {
                    Button("Rename") { beginEditing() }
                    Button("Delete", role: .destructive, action: onRequestDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isFilterActive ? Color.accentColor.opacity(0.12) : (isHovering ? Color.secondary.opacity(0.08) : Color.clear))
        )
        .onHover { isHovering = $0 }
        .draggable(TagDragPayload(name: tag.name)) {
            Text("#\(tag.name)")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.teal.opacity(0.9)))
                .foregroundStyle(.white)
        }
    }

    private func beginEditing() {
        draftName = tag.name
        isEditing = true
    }

    private func commitRename() {
        if !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onRename(draftName)
        }
        isEditing = false
    }
}
