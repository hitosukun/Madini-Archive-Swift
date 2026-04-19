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
        // No internal "TAGS" header — the parent sidebar wraps this view
        // in its shared `section(title:)` helper so Tags can collapse
        // alongside Library and Sources. Drawing our own header here
        // too would produce a duplicate title stack.
        VStack(alignment: .leading, spacing: 8) {
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
        // Right-pane tag editor (and any other surface that ends with a
        // `archiveEvents.didChangeBookmarks()`) edits the tag bindings
        // directly — we need to refetch the tag list so usage counts and
        // "attached to selection" check marks reflect the change without
        // requiring a manual refresh.
        .task(id: archiveEvents.bookmarkRevision) {
            await viewModel?.refreshTags()
            await viewModel?.refreshCurrentConversationTags()
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
                ForEach(Self.orderedTags(viewModel.tags)) { tag in
                    SidebarTagRow(
                        tag: tag,
                        isFilterActive: viewModel.isTagFilterActive(tag),
                        isAttachedToSelection: viewModel.isTagAttachedToSelection(tag),
                        hasSelection: viewModel.selectedConversationID != nil,
                        onToggleFilter: { viewModel.toggleTagFilter(tag) },
                        onToggleAttach: { viewModel.toggleAttachmentToSelection(tag) },
                        onRename: { newName in viewModel.renameTag(tag, to: newName) },
                        onRequestDelete: { tagPendingDeletion = tag },
                        onAttachDroppedConversations: { conversationIDs in
                            // Multi-select drag: the user may drop several
                            // selected cards at once. We attach sequentially
                            // (each attach is its own transaction) and
                            // refresh once at the end so tag counts / chip
                            // strips update in one pass instead of N.
                            Task {
                                for conversationID in conversationIDs {
                                    await libraryViewModel.attachTag(
                                        named: tag.name,
                                        toConversation: conversationID
                                    )
                                }
                                await viewModel.refreshCurrentConversationTags()
                                await viewModel.refreshTags()
                            }
                        }
                    )
                }
            }
        }
    }

    /// Force the Trash system tag to always sit at the very top of the
    /// list so it reads as the rescue lane regardless of alphabetical
    /// ordering. Other system tags (if any are ever added) come next,
    /// then user tags sorted by name (mirrors `listTags()` ORDER BY).
    private static func orderedTags(_ tags: [TagEntry]) -> [TagEntry] {
        tags.sorted { lhs, rhs in
            let lhsRank = rank(lhs)
            let rhsRank = rank(rhs)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func rank(_ tag: TagEntry) -> Int {
        if tag.systemKey == "trash" { return 0 }
        if tag.isSystem { return 1 }
        return 2
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
    let onAttachDroppedConversations: ([String]) -> Void

    @State private var isHovering = false
    @State private var isEditing = false
    @State private var isDropTargeted = false
    @State private var draftName: String = ""

    private var isTrash: Bool { tag.systemKey == "trash" }

    var body: some View {
        HStack(spacing: 8) {
            // Tag-name area: doubles as the filter toggle (single tap) and
            // the drag handle. Was previously wrapped in a `Button`, but
            // `Button`'s press-gesture greedily captured mouse-down events
            // before SwiftUI's `.draggable` recognizer could see the
            // movement — so the user had to mash hard or wait for a long
            // press before the drag would start, which read as "the tag
            // won't pick up". Replacing the button with a plain HStack +
            // `.contentShape` + `.onTapGesture` makes the drag recognizer
            // the gesture-priority winner: a quick click still fires the
            // tap, but any movement-after-press flips to a drag instantly.
            HStack(spacing: 8) {
                Image(systemName: leadingIconName)
                    .foregroundStyle(leadingIconColor)

                if isEditing {
                    TextField("Tag name", text: $draftName, onCommit: commitRename)
                        .textFieldStyle(.roundedBorder)
                } else {
                    Text(tag.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .onTapGesture(count: 2) {
                            // Trash is locked; don't let the user rename it via double-tap.
                            if !tag.isSystem { beginEditing() }
                        }
                }

                Text("\(tag.usageCount)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .draggable(TagDragPayload(name: tag.name)) {
                // Neutral drag preview — matches the monochrome treatment of
                // tag chips elsewhere (card row, saved-filter list). The `#`
                // prefix + capsule shape already signal "tag" without needing
                // a colored fill.
                Text("#\(tag.name)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.thinMaterial))
                    .overlay(
                        Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
                    .foregroundStyle(.primary)
            }
            // Tap-to-toggle-filter sits AFTER `.draggable` so the drag
            // recognizer registers first; SwiftUI still routes a movement-
            // free press to this tap handler on release.
            .onTapGesture { onToggleFilter() }

            Button(action: onToggleAttach) {
                Image(systemName: isAttachedToSelection ? "checkmark.circle.fill" : "plus.circle")
                    .foregroundStyle(isAttachedToSelection ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!hasSelection)
            .help(hasSelection
                  ? (isAttachedToSelection ? "Detach from selected conversation" : "Attach to selected conversation")
                  : "Select a conversation first")

            // Always render the ellipsis menu so hovering does not shift
            // the row's layout (was causing the +/✓ button to move,
            // making it hard to click). Opacity-gated to stay invisible
            // until hover / for system tags (Trash is system).
            Menu {
                Button("Rename") { beginEditing() }
                Button("Delete", role: .destructive, action: onRequestDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(isHovering && !tag.isSystem ? 1 : 0)
            .allowsHitTesting(isHovering && !tag.isSystem)
        }
        .font(.body)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(rowBackground)
        )
        .overlay(
            // Accent border when a conversation card is being dragged over
            // this row — gives the user a clear signal that the drop will
            // land here. Width and opacity tuned to be visible against both
            // the default sidebar tint and selection highlights.
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(
                    Color.accentColor.opacity(isDropTargeted ? 0.9 : 0),
                    lineWidth: 2
                )
        )
        .onHover { isHovering = $0 }
        // Accept dragged conversation card(s) → attach this tag to each.
        // When the drag originated from a multi-selected List row, SwiftUI
        // delivers one payload per selected item, so we forward the full
        // array to the handler rather than just the first element.
        // (The reverse direction — picking a tag UP from this row — is
        // handled by `.draggable` on the inner tag-name HStack above, so
        // it doesn't fight with the +/− attach button or the menu.)
        .dropDestination(for: ConversationDragPayload.self) { payloads, _ in
            guard !payloads.isEmpty else { return false }
            onAttachDroppedConversations(payloads.map { $0.id })
            return true
        } isTargeted: { newValue in
            if isDropTargeted != newValue { isDropTargeted = newValue }
        }
    }

    /// Leading glyph differentiates Trash (rescue lane) from regular
    /// `#tag` rows. Color tracks filter-active state on both.
    private var leadingIconName: String {
        if isTrash { return "trash" }
        return isFilterActive ? "line.3.horizontal.decrease.circle.fill" : "number"
    }

    private var leadingIconColor: Color {
        isFilterActive ? Color.accentColor : .secondary
    }

    private var rowBackground: Color {
        if isDropTargeted { return Color.accentColor.opacity(0.22) }
        if isFilterActive { return Color.accentColor.opacity(0.12) }
        if isHovering { return Color.secondary.opacity(0.08) }
        return .clear
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
