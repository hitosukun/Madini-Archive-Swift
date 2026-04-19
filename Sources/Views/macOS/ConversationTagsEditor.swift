import SwiftUI
#if os(macOS)

/// Right-pane header tag editor. Presents the same tag list the sidebar
/// shows, but as a pulldown of checkbox rows — click a checkbox to
/// attach/detach the tag from the current conversation. Replaces the
/// earlier NSTokenField-based editor: the token field was powerful but
/// required the user to recall names (the whole list was never visible
/// at once). A pulldown of every tag with a direct attach checkbox is
/// how Finder, Mail, and Notes solve the same problem.
///
/// A "New tag" text field sits at the bottom of the popover: typing a
/// name and pressing Enter creates the tag and attaches it to the
/// current conversation in one action. `attachTag(named:toConversation:)`
/// upserts by name, so fresh names don't need a separate create step.
///
/// Sidebar refresh: mutations bump `archiveEvents.bookmarkRevision` so
/// the sidebar usage counts and attach indicators stay coherent with
/// changes made here.
struct ConversationTagsEditor: View {
    let conversationID: String

    @Environment(LibraryViewModel.self) private var libraryViewModel
    @Environment(ArchiveEvents.self) private var archiveEvents
    @EnvironmentObject private var services: AppServices

    @State private var allTags: [TagEntry] = []
    @State private var isPopoverOpen = false

    var body: some View {
        let attached = attachedNames()

        // Button-only body — the parent (ConversationHeaderView) is
        // responsible for horizontal layout now that this editor sits
        // on the same row as SourceOriginPill. Keeping a Spacer inside
        // here would make the pill expand to fill the header row and
        // push the date off to the right.
        Button {
            isPopoverOpen = true
        } label: {
            triggerLabel(attached: attached)
        }
        .buttonStyle(.plain)
        .fixedSize()
        // `.popover` is attached to the Button so its anchor rect is
        // the pill itself — the arrow lines up with the pill.
        .popover(isPresented: $isPopoverOpen, arrowEdge: .bottom) {
            TagCheckboxList(
                tags: sortedNonSystemTags,
                attachedNames: attached,
                onToggle: { tag in toggle(tag: tag, attached: attached) },
                onCreate: { name in createAndAttach(name: name) }
            )
            .frame(minWidth: 260, idealWidth: 280)
            .frame(minHeight: 200, maxHeight: 380)
        }
        .task(id: conversationID) { await refreshTags() }
        .task(id: archiveEvents.bookmarkRevision) { await refreshTags() }
    }

    // MARK: - Trigger

    @ViewBuilder
    private func triggerLabel(attached: Set<String>) -> some View {
        // Pill-shaped, content-width trigger. Sits on the leading edge
        // of the header row so it reads as a light chip rather than a
        // heavy full-width control — the Spacer in `body` keeps the
        // trailing side empty.
        HStack(spacing: 6) {
            Image(systemName: "tag")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            if attached.isEmpty {
                Text("タグを追加")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                // Inline chip preview so the attached tags are visible
                // at a glance without opening the popover. Kept on one
                // line (no FlowLayout) so the pill stays compact — if
                // many tags stack up, the line just extends horizontally
                // and the parent HStack clips via the trailing Spacer.
                HStack(spacing: 4) {
                    ForEach(Array(attached).sorted(), id: \.self) { name in
                        Text("#\(name)")
                            .font(.caption)
                            .foregroundStyle(.primary)
                    }
                }
                .lineLimit(1)
            }

            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Color.secondary.opacity(isPopoverOpen ? 0.14 : 0.08))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    isPopoverOpen ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.18),
                    lineWidth: isPopoverOpen ? 1.2 : 0.5
                )
        )
        .animation(.easeOut(duration: 0.15), value: isPopoverOpen)
        .contentShape(Capsule(style: .continuous))
    }

    // MARK: - Data

    private func attachedNames() -> Set<String> {
        Set((libraryViewModel.conversationTags[conversationID] ?? []).map(\.name))
    }

    /// System tags (Trash) are hidden — attaching Trash from the editor
    /// would be a footgun; it remains reachable from the sidebar.
    private var sortedNonSystemTags: [TagEntry] {
        allTags
            .filter { !$0.isSystem }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func refreshTags() async {
        do {
            allTags = try await services.tags.listTags()
        } catch {
            // Non-fatal: editor still works without the tag list (it
            // simply shows an empty popover) and we retry on the next
            // bookmark revision bump.
        }
    }

    private func toggle(tag: TagEntry, attached: Set<String>) {
        let wasAttached = attached.contains(tag.name)
        Task {
            if wasAttached {
                await libraryViewModel.detachTag(named: tag.name, fromConversation: conversationID)
            } else {
                await libraryViewModel.attachTag(named: tag.name, toConversation: conversationID)
            }
            archiveEvents.didChangeBookmarks()
        }
    }

    /// Create (if needed) + attach in one step. `attachTag` upserts by
    /// name, so a fresh name creates the tag; an existing name is a
    /// no-op attach. Either way the bookmark revision bump triggers
    /// `refreshTags()` and the new row appears checked in the popover.
    private func createAndAttach(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            await libraryViewModel.attachTag(named: trimmed, toConversation: conversationID)
            archiveEvents.didChangeBookmarks()
        }
    }
}

/// Checkbox list rendered inside the popover. Each row is a self-
/// contained button: clicking anywhere on the row toggles the tag.
/// Hover highlight makes the active row obvious in a dense list.
/// Bottom row is a text field that creates + attaches a new tag when
/// the user types a name and presses Enter.
private struct TagCheckboxList: View {
    let tags: [TagEntry]
    let attachedNames: Set<String>
    let onToggle: (TagEntry) -> Void
    let onCreate: (String) -> Void

    @State private var draftName: String = ""

    var body: some View {
        VStack(spacing: 0) {
            if tags.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tag")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text("タグがありません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("下の欄から新しいタグを追加できます")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(tags) { tag in
                            TagCheckboxRow(
                                tag: tag,
                                isAttached: attachedNames.contains(tag.name),
                                onToggle: { onToggle(tag) }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Divider()

            // New-tag input. Compact chip on the left (fixed width,
            // not full-bleed) so it reads as a small "create" helper
            // rather than a second primary action competing with the
            // checklist above. Create on Enter, clear the field so the
            // user can chain multiple adds without reopening the popover.
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    TextField("新しいタグ", text: $draftName)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .onSubmit(submit)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(width: 140)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
                )

                if !trimmedDraft.isEmpty {
                    Button("追加", action: submit)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private var trimmedDraft: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        let name = trimmedDraft
        guard !name.isEmpty else { return }
        onCreate(name)
        draftName = ""
    }
}

private struct TagCheckboxRow: View {
    let tag: TagEntry
    let isAttached: Bool
    let onToggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 10) {
                Image(systemName: isAttached ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .foregroundStyle(isAttached ? Color.accentColor : .secondary)

                Text("#\(tag.name)")
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                // Usage count — same "how many conversations carry this
                // tag" figure the sidebar shows, so users can recognize
                // popular tags vs one-offs without leaving the popover.
                Text("\(tag.usageCount)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovering ? Color.secondary.opacity(0.10) : Color.clear)
                    .padding(.horizontal, 4)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
#endif
