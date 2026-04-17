import SwiftUI

/// Top bar rendered above the middle (content) pane's conversation list.
///
/// Mirrors the right pane's `ReaderWorkspaceHeaderBar` so the two panes
/// appear aligned. Houses the entry point for the "Tags" control panel
/// (floats over the right pane when opened), a sort-direction toggle,
/// wrap-capable active-filter chips, and the loaded/total count indicator.
struct LibraryListHeaderBar: View {
    @Bindable var viewModel: LibraryViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: WorkspaceLayoutMetrics.headerBarInteriorSpacing) {
                sortDirectionButton
                HeaderDateRangePicker(viewModel: viewModel)
                Spacer(minLength: 0)
                countLabel
            }
            .padding(.horizontal, WorkspaceLayoutMetrics.headerBarHorizontalPadding)
            .padding(.vertical, WorkspaceLayoutMetrics.headerBarVerticalPadding)
            .frame(minHeight: WorkspaceLayoutMetrics.headerBarMinHeight)

            if !viewModel.activeFilterChips.isEmpty {
                ActiveFilterChipsView(
                    chips: viewModel.activeFilterChips,
                    onClear: viewModel.clearFilterChip
                )
                .padding(.horizontal, WorkspaceLayoutMetrics.headerBarHorizontalPadding)
                .padding(.bottom, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var sortDirectionButton: some View {
        Button(action: viewModel.toggleSortDirection) {
            HStack(spacing: 4) {
                Image(systemName: viewModel.sortKey == .dateDesc ? "arrow.down" : "arrow.up")
                    .font(.caption.weight(.semibold))
                Text(viewModel.sortKey == .dateDesc ? "Newest" : "Oldest")
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: WorkspaceLayoutMetrics.chipCornerRadius, style: .continuous)
                    .fill(Color.secondary.opacity(0.10))
            )
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .help(viewModel.sortKey == .dateDesc ? "Switch to oldest first" : "Switch to newest first")
    }

    private var countLabel: some View {
        HStack(spacing: 4) {
            Text("\(viewModel.conversations.count)")
                .monospacedDigit()
            Text("/")
                .foregroundStyle(.tertiary)
            Text("\(viewModel.totalCount)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

private struct ActiveFilterChipsView: View {
    let chips: [LibraryActiveFilterChip]
    let onClear: (LibraryActiveFilterChip) -> Void

    var body: some View {
        FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(chips) { chip in
                FilterChipView(chip: chip, onClear: onClear)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FilterChipView: View {
    let chip: LibraryActiveFilterChip
    let onClear: (LibraryActiveFilterChip) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(chip.label)
                .font(.caption)
                .lineLimit(1)

            Button {
                onClear(chip)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.16))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(tint.opacity(0.24), lineWidth: 0.5)
        )
        .foregroundStyle(tint)
    }

    private var tint: Color {
        switch chip.kind {
        case .keyword: return .blue
        case .source: return .green
        case .model: return .purple
        case .dateFrom, .dateTo: return .orange
        case .role: return .pink
        case .bookmarkedOnly: return .yellow
        case .bookmarkTag: return .teal
        }
    }
}
