import SwiftUI

// MARK: - Dense row primitive

/// Dense sidebar row used by the PROJECTS and TRIAGE sections.
///
/// Deliberately denser than the existing `SidebarSelectionRow` (which
/// is chunkier at 7pt vertical padding + 10pt corner radius + 0.18
/// accent-fill selection) because the project list is a
/// list-of-many — a user with a dozen projects would waste half the
/// sidebar on padding with the chunkier primitive. Metrics read from
/// `ProjectSidebarMetrics` so the SwiftUI rendering matches the
/// `tools/toolbar-mock/index.html` rhythm.
///
/// Kept private to this file because it's specific to project-style
/// rows (glyph column + label + count); exposing it broadly would
/// tempt reuse in places where `SidebarSelectionRow`'s roomier
/// treatment still reads correctly.
private struct ProjectSidebarRow: View {
    let title: String
    let count: Int
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: ProjectSidebarMetrics.rowInteriorSpacing) {
                Image(systemName: systemImage)
                    .font(.system(size: ProjectSidebarMetrics.rowGlyphFontSize))
                    .frame(width: ProjectSidebarMetrics.rowGlyphColumnWidth)
                    // Glyph follows the row's emphasis — tertiary for an
                    // unselected row reads as "navigation chrome, not
                    // a control", primary when selected promotes it to
                    // "this is where we are". Matches the mock's
                    // `.sb-glyph` default → `.is-selected` override.
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)

                Text(title)
                    .font(.system(size: ProjectSidebarMetrics.rowLabelFontSize))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: ProjectSidebarMetrics.rowCountLeadingPadding)

                Text("\(count)")
                    .font(.system(size: ProjectSidebarMetrics.rowCountFontSize))
                    .monospacedDigit()
                    // Count stays tertiary in both states — the mock
                    // softens it to 0.72 opacity on selection rather
                    // than promoting to primary, which read as "badge
                    // didn't move but whole row lit up" (desired).
                    .foregroundStyle(isSelected ? Color.primary.opacity(0.72) : Color.secondary)
            }
            .padding(.horizontal, ProjectSidebarMetrics.rowHorizontalPadding)
            .padding(.vertical, ProjectSidebarMetrics.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(
                    cornerRadius: ProjectSidebarMetrics.rowBackgroundCornerRadius,
                    style: .continuous
                )
                .fill(isSelected
                      ? Color.accentColor.opacity(0.22)
                      : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - PROJECTS section

/// The PROJECTS section of the sidebar — one row per user-visible
/// project, driven by `SidebarProjectsViewModel.projects`.
/// The parent (`MacOSRootView.section(title:)`) owns the collapsible
/// "PROJECTS" header and the outer padding; this view renders only
/// the list body.
///
/// Projects are shown in the persisted `sortIndex` order the
/// repository already applies. External-bound projects (from ChatGPT /
/// Claude / Gemini folder imports) and Madini-local projects share
/// the same row presentation — the provenance distinction surfaces
/// later in the viewer-card's membership glyph, not here.
///
/// **Selection is intentionally local.** The `selection` binding sits
/// in `MacOSRootView` and does not yet feed into
/// `LibraryViewModel.filter`. That wiring lands in a follow-up commit
/// so this one is reviewable against the mock in isolation.
struct SidebarProjectsSection: View {
    let viewModel: SidebarProjectsViewModel
    @Binding var selection: ProjectScope

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: ProjectSidebarMetrics.rowVerticalPadding
        ) {
            if viewModel.isLoading && viewModel.projects.isEmpty {
                // First-load skeleton — small spinner rather than the
                // full row set so the sidebar doesn't flash four
                // zero-count placeholder rows before the real data
                // arrives.
                ProgressView().controlSize(.small)
            } else if viewModel.projects.isEmpty {
                // Empty state — matches the mock's "no projects yet"
                // treatment (muted italic hint text). Keeps the
                // section from collapsing to zero height so the user
                // can still see the "PROJECTS" header and infer that
                // the section exists.
                Text("No projects yet")
                    .font(.system(size: ProjectSidebarMetrics.rowLabelFontSize))
                    .italic()
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, ProjectSidebarMetrics.rowHorizontalPadding)
            } else {
                ForEach(viewModel.projects) { project in
                    ProjectSidebarRow(
                        title: project.name,
                        count: viewModel.count(for: project.id),
                        // Folder glyph mirrors the mock's 📁 — and
                        // stays identical whether the project came
                        // from an external LLM import or was created
                        // locally. The external binding informs the
                        // viewer-card, not the sidebar.
                        systemImage: "folder",
                        isSelected: selection == .project(project.id)
                    ) {
                        selection = .project(project.id)
                    }
                }
            }
        }
    }
}

// MARK: - TRIAGE section

/// The TRIAGE section: Inbox (unassigned threads with actionable
/// suggestion) + Orphans (unassigned threads with no actionable
/// suggestion). Two fixed rows, counts read live off
/// `SidebarProjectsViewModel.counts`.
///
/// Split into a sibling view (rather than a second block inside
/// `SidebarProjectsSection`) because the parent `MacOSRootView` wraps
/// each one in its own collapsible `section(title:)` — a user who's
/// finished triaging for the day wants to collapse TRIAGE without
/// also folding away the PROJECTS list they navigate into.
struct SidebarTriageSection: View {
    let viewModel: SidebarProjectsViewModel
    @Binding var selection: ProjectScope

    var body: some View {
        VStack(
            alignment: .leading,
            spacing: ProjectSidebarMetrics.rowVerticalPadding
        ) {
            ProjectSidebarRow(
                title: "Inbox",
                count: viewModel.inboxCount,
                // `tray` reads as "pending arrivals waiting for a
                // verdict" — matches the mock's 📥 without the OS
                // emoji font's inconsistent color rendering.
                systemImage: "tray",
                isSelected: selection == .inbox
            ) {
                selection = .inbox
            }

            ProjectSidebarRow(
                title: "Orphans",
                count: viewModel.orphansCount,
                // `questionmark.circle` signals "we couldn't find a
                // home" without leaning on negative-space glyphs
                // (empty folder, broken link) that read as errors.
                // The mock uses 🏝 which doesn't have a good SF
                // Symbols equivalent.
                systemImage: "questionmark.circle",
                isSelected: selection == .orphans
            ) {
                selection = .orphans
            }
        }
    }
}
