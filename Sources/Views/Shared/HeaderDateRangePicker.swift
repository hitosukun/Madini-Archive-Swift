import SwiftUI

/// Popover-style date range picker hosted in the middle-pane header bar.
/// The dates live on `LibraryViewModel.filter.{dateFrom,dateTo}` as
/// `YYYY-MM-DD` strings.
struct HeaderDateRangePicker: View {
    @Bindable var viewModel: LibraryViewModel
    @State private var isPresented = false

    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            ZStack {
                // `.title3` (~20pt) vs the prior `.body` (~17pt) — the
                // icon-only toolbar chips (calendar, viewer-mode toggle,
                // export) kept reading as undersized against the 30pt
                // chip height and the text-carrying sort pill beside
                // them. One typography step up gives these glyphs
                // clear presence without overflowing the chip.
                Image(systemName: "calendar")
                    .font(.title3.weight(.semibold))

                // Active-state badge dot — sits as a top-trailing pip
                // on the icon rather than as an inline sibling, so the
                // square chip stays centered on its glyph regardless of
                // filter state. Apple's own toolbar buttons (Mail's
                // "Unread" badge on the filter button, etc.) decorate
                // the chip the same way.
                if hasDateFilter {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .offset(x: 7, y: -6)
                }
            }
            // Rounded-square icon chip — matches Apple's titlebar
            // sidebar-toggle shape so this button and the macOS-supplied
            // sidebar toggle read as one family. `isActive` flips the
            // chrome to accent when a date filter is set.
            .headerIconChipStyle(isActive: hasDateFilter)
        }
        .buttonStyle(.plain)
        .help("Filter by date range")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverBody
                .padding(16)
                .frame(width: 260)
        }
    }

    private var hasDateFilter: Bool {
        (viewModel.filter.dateFrom?.isEmpty == false) || (viewModel.filter.dateTo?.isEmpty == false)
    }

    private var popoverBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Date range")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            DatePicker(
                "From",
                selection: Binding(
                    get: { parse(viewModel.filter.dateFrom) ?? Date() },
                    set: { viewModel.applyDateFrom(Self.isoFormatter.string(from: $0)) }
                ),
                displayedComponents: .date
            )

            DatePicker(
                "To",
                selection: Binding(
                    get: { parse(viewModel.filter.dateTo) ?? Date() },
                    set: { viewModel.applyDateTo(Self.isoFormatter.string(from: $0)) }
                ),
                displayedComponents: .date
            )

            HStack {
                Spacer()
                Button("Clear") {
                    viewModel.applyDateFrom("")
                    viewModel.applyDateTo("")
                }
                .disabled(!hasDateFilter)
            }
        }
    }

    private func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return Self.isoFormatter.date(from: value)
    }
}
