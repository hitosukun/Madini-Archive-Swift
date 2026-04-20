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
                        onDropConversations: { conversationIDs in
                            // Trash has been repurposed from "attach the
                            // system Trash tag" to "clear every tag from
                            // each dropped conversation". The view-model
                            // path captures a snapshot for undo before
                            // detaching, and publishes `pendingTrashUndo`
                            // so the root-view toast can surface the
                            // Undo button. Other tag rows follow the
                            // original attach path (multi-select drag
                            // delivers all selected ids at once; we
                            // attach sequentially and refresh once at
                            // the end so chip strips / tag counts update
                            // in a single pass).
                            Task {
                                if tag.systemKey == "trash" {
                                    await libraryViewModel.purgeTags(
                                        fromConversations: conversationIDs
                                    )
                                } else {
                                    for conversationID in conversationIDs {
                                        await libraryViewModel.attachTag(
                                            named: tag.name,
                                            toConversation: conversationID
                                        )
                                    }
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
    /// Receives the dropped conversation id set. The parent decides
    /// whether this means "attach this tag" (normal rows) or "purge all
    /// tags from these conversations" (Trash row) — the row doesn't
    /// need to know which; it just forwards the ids.
    let onDropConversations: ([String]) -> Void

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
            tagNameContent
                // Trash is a drop target only — it represents the "clear
                // every tag" lane, and letting the user pick it up would
                // let them drop "#Trash" onto a conversation, which is
                // the old semantics we're retiring. Skip `.draggable`
                // here so the row still accepts drops via the
                // `.dropDestination` modifier below but cannot be the
                // source of a drag.
                .modifier(TagRowDragSourceModifier(
                    isDraggable: !isTrash,
                    tagName: tag.name
                ))
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
        // Accept dragged conversation card(s). For normal rows the
        // parent forwards the ids to `attachTag`; for the Trash row the
        // parent switches to `purgeTags` (see `SidebarTagsSection.tagList`).
        // This row doesn't branch on `isTrash` itself — that decision
        // lives one layer up with the view-model calls.
        //
        // When the drag originated from a multi-selected List/Table row,
        // SwiftUI delivers one payload per selected item, so we flatten
        // the payloads and dedupe ids before forwarding.
        .dropDestination(for: ConversationDragPayload.self) { payloads, _ in
            guard !payloads.isEmpty else { return false }
            let conversationIDs = payloads
                .flatMap(\.conversationIDs)
                .reduce(into: [String]()) { partialResult, id in
                    if !partialResult.contains(id) {
                        partialResult.append(id)
                    }
                }
            onDropConversations(conversationIDs)
            return true
        } isTargeted: { newValue in
            if isDropTargeted != newValue { isDropTargeted = newValue }
        }
    }

    /// Tag-name area — doubles as the filter-toggle tap target and (for
    /// non-Trash rows) the drag handle. Extracted as a computed property
    /// so the `TagRowDragSourceModifier` below can gate `.draggable`
    /// cleanly without duplicating the layout.
    private var tagNameContent: some View {
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

/// Conditionally attaches `.draggable(TagDragPayload)` to a view. Kept
/// as a ViewModifier (instead of an inline `if`) so the return type
/// stays the same whether or not the row is draggable — without this,
/// SwiftUI's Group-based branching would change the view identity when
/// a tag is retroactively promoted/demoted to/from system status.
/// Right now only Trash flips the gate, but keeping the identity stable
/// is cheap insurance against future system tags.
private struct TagRowDragSourceModifier: ViewModifier {
    let isDraggable: Bool
    let tagName: String

    func body(content: Content) -> some View {
        if isDraggable {
            content.draggable(TagDragPayload(name: tagName)) {
                // Neutral drag preview — matches the monochrome treatment of
                // tag chips elsewhere (card row, saved-filter list). The `#`
                // prefix + capsule shape already signal "tag" without needing
                // a colored fill.
                Text("#\(tagName)")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.thinMaterial))
                    .overlay(
                        Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
                    .foregroundStyle(.primary)
            }
        } else {
            content
        }
    }
}
