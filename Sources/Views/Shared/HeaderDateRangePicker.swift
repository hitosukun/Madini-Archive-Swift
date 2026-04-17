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
            HStack(spacing: 4) {
                Image(systemName: "calendar")
                    .font(.caption.weight(.semibold))
                if hasDateFilter {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: WorkspaceLayoutMetrics.chipCornerRadius, style: .continuous)
                    .fill(hasDateFilter ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.10))
            )
            .foregroundStyle(hasDateFilter ? Color.accentColor : Color.primary)
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
