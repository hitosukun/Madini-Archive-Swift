#if os(macOS)
import SwiftUI
import Charts

// MARK: - Chart kind (selection identity)
//
// Phase 5 (γ) splits the Dashboard middle pane into two surfaces:
// `StatsContentPane` (compact summary, lives in the center column)
// and `StatsDetailPane` (zoomed-in single-chart view, lives in the
// detail / right column). Both panes share `StatsChartKind` so the
// parent (`DesignMockRootView`) can hand a single binding to the
// pair.
//
// Phase 5 (β) also added per-data-point click drill-down from the
// detail pane back into the conversation list. (γ) drops that wire
// entirely — the detail pane is read-only. The user filters the
// Dashboard scope through the existing sidebar / search-bar
// channels, and `StatsContentPane` re-aggregates whenever those
// upstream filters change. Removing the drill-down also removes
// the crash path that Phase 5 (β) hit on month-bar click followed
// by a sidebar interaction.

/// One of the five Stats charts. Used both as the "currently
/// highlighted card in the center pane" identity and as the
/// dispatch key for `StatsDetailPane`.
enum StatsChartKind: String, CaseIterable, Identifiable, Hashable {
    case sourceBreakdown
    case modelBreakdown
    case monthly
    case dailyHeatmap
    case hourWeekday

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sourceBreakdown: return "ソース別"
        case .modelBreakdown: return "モデル別"
        case .monthly: return "月別"
        case .dailyHeatmap: return "日付別ヒートマップ"
        case .hourWeekday: return "時刻 × 曜日ヒートマップ"
        }
    }

    var compactSubtitle: String {
        switch self {
        case .sourceBreakdown: return "会話数 (Markdown は除外)"
        case .modelBreakdown:  return "上位 10 件 (空欄は \"Unknown\" に集約)"
        case .monthly:         return "過去 24 ヶ月"
        case .dailyHeatmap:    return "過去 90 日 (詳細で 365 日表示)"
        case .hourWeekday:     return "プロンプト数 (会話の代表時刻)"
        }
    }
}

// MARK: - Compact center pane

/// Center / content column of the `.stats` layout. Renders the five
/// charts as a vertical stack of compact cards. Each card is a
/// `Button` — clicking selects it for detail rendering on the right.
/// Re-clicking the active card clears the selection (Mail.app
/// reading-pane convention).
struct StatsContentPane: View {
    @Bindable var viewModel: StatsViewModel
    /// Currently-highlighted chart. Nil = nothing selected; the
    /// detail pane shows a "select a chart" placeholder until the
    /// user picks one.
    @Binding var selectedChart: StatsChartKind?
    @State private var monthlySeriesMode: MonthlySeriesMode = .conversations

    var body: some View {
        Group {
            if let errorText = viewModel.errorText {
                errorState(message: errorText)
            } else if viewModel.isLoading && viewModel.isEmpty {
                loadingState
            } else if viewModel.isEmpty {
                emptyState
            } else {
                chartsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .task {
            viewModel.loadIfNeeded()
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Stats を集計中…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(message: String) -> some View {
        ContentUnavailableView(
            "集計に失敗しました",
            systemImage: "exclamationmark.triangle",
            description: Text(message)
        )
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "集計対象がありません",
            systemImage: "chart.bar.xaxis",
            description: Text("現在のフィルタに該当する会話がありません。サイドバーや検索を変えて再度お試しください。")
        )
    }

    private var chartsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                selectableCard(.sourceBreakdown) {
                    StatsCharts.sourceBar(viewModel.sourceCounts, size: .compact)
                }
                selectableCard(.modelBreakdown) {
                    StatsCharts.modelBar(viewModel.modelCounts, size: .compact)
                }
                selectableCard(.monthly, trailing: monthlySeriesPicker) {
                    StatsCharts.monthlyBar(
                        viewModel.monthlyCounts,
                        seriesMode: monthlySeriesMode,
                        size: .compact
                    )
                }
                selectableCard(.dailyHeatmap) {
                    DailyHeatmapView(
                        buckets: viewModel.dailyCounts.suffix(90).map { $0 },
                        cellSize: 11
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                selectableCard(.hourWeekday) {
                    StatsCharts.hourWeekdayHeatmap(
                        viewModel.hourWeekdayCounts,
                        size: .compact
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
    }

    private var monthlySeriesPicker: AnyView {
        AnyView(
            Picker("系列", selection: $monthlySeriesMode) {
                ForEach(MonthlySeriesMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .frame(width: 180)
        )
    }

    /// Wraps a chart in a Button that selects the parent's
    /// `selectedChart` slot. Re-clicking the active card clears
    /// the selection — same card-click toggles the detail pane back
    /// to its placeholder, which mirrors how Mail's reading-pane
    /// selection works.
    @ViewBuilder
    private func selectableCard<Content: View>(
        _ kind: StatsChartKind,
        trailing: AnyView? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        let isSelected = selectedChart == kind
        Button {
            if isSelected {
                selectedChart = nil
            } else {
                selectedChart = kind
            }
        } label: {
            StatsCard(
                title: kind.title,
                subtitle: kind.compactSubtitle,
                trailing: trailing,
                isSelected: isSelected
            ) {
                content()
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Detail pane

/// Detail / right column of the `.stats` layout. Shows the same
/// chart the center pane just highlighted, but rendered larger.
///
/// Phase 5 (γ): no per-data-point click handling. The pane is
/// read-only — it answers "what does this aggregate look like up
/// close" and nothing else. Drill-down to the conversation list is
/// out of scope; the user navigates via the sidebar / search bar.
struct StatsDetailPane: View {
    @Bindable var viewModel: StatsViewModel
    let chart: StatsChartKind?
    @State private var monthlySeriesMode: MonthlySeriesMode = .conversations

    var body: some View {
        Group {
            if let chart {
                detailContent(for: chart)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }

    private var placeholder: some View {
        ContentUnavailableView(
            "左のチャートを選択",
            systemImage: "chart.bar.xaxis",
            description: Text("中央のチャートをクリックすると、ここに拡大版が表示されます。")
        )
    }

    @ViewBuilder
    private func detailContent(for kind: StatsChartKind) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                detailHeader(for: kind)

                switch kind {
                case .sourceBreakdown:
                    StatsCharts.sourceBar(viewModel.sourceCounts, size: .detail)
                case .modelBreakdown:
                    StatsCharts.modelBar(viewModel.modelCounts, size: .detail)
                case .monthly:
                    monthlySeriesPicker
                    StatsCharts.monthlyBar(
                        viewModel.monthlyCounts,
                        seriesMode: monthlySeriesMode,
                        size: .detail
                    )
                case .dailyHeatmap:
                    DailyHeatmapView(
                        buckets: viewModel.dailyCounts,
                        cellSize: 14
                    )
                case .hourWeekday:
                    StatsCharts.hourWeekdayHeatmap(viewModel.hourWeekdayCounts, size: .detail)
                }
            }
            .padding(20)
        }
    }

    private func detailHeader(for kind: StatsChartKind) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(kind.title)
                .font(.title3.weight(.semibold))
            Text(kind.compactSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var monthlySeriesPicker: some View {
        Picker("系列", selection: $monthlySeriesMode) {
            ForEach(MonthlySeriesMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
        .frame(width: 220, alignment: .leading)
    }
}

// MARK: - Shared chart rendering

/// Two render sizes the same chart code uses. `.compact` is the
/// center-pane summary; `.detail` is the right-pane zoom. Splitting
/// per-chart sizing here keeps the StatsCard chrome and the actual
/// chart in lockstep, and avoids duplicating Chart bodies between
/// the two panes.
private enum ChartRenderSize {
    case compact
    case detail
}

/// Stateless chart factories. Each returns a SwiftUI Chart sized
/// for its render context. Phase 5 (γ): no tap handling — the
/// charts are pure visualizations. (Phase 5 (β) had `BarTapOverlay`
/// / `HourWeekdayTapOverlay` modifiers wired through here for
/// drill-down; both were removed when the drill-down spec was
/// dropped.)
private enum StatsCharts {

    static func sourceBar(_ items: [SourceCount], size: ChartRenderSize) -> some View {
        let rowHeight: CGFloat = size == .compact ? 28 : 36
        let height = max(120, CGFloat(items.count) * rowHeight + 40)
        return Chart(items, id: \.label) { item in
            BarMark(
                x: .value("件数", item.count),
                y: .value("ソース", item.label)
            )
            .foregroundStyle(SourceAppearance.color(for: item.label))
            .annotation(position: .trailing) {
                Text("\(item.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        Text(label)
                            .font(.callout.weight(.medium))
                    }
                }
            }
        }
        .frame(height: height)
    }

    static func modelBar(_ items: [ModelCount], size: ChartRenderSize) -> some View {
        let rowHeight: CGFloat = size == .compact ? 24 : 30
        let height = max(120, CGFloat(items.count) * rowHeight + 40)
        return Chart(items, id: \.label) { item in
            BarMark(
                x: .value("件数", item.count),
                y: .value("モデル", item.label)
            )
            .foregroundStyle(SourceAppearance.color(forModel: item.label))
            .annotation(position: .trailing) {
                Text("\(item.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: height)
    }

    static func monthlyBar(
        _ items: [MonthlyCount],
        seriesMode: MonthlySeriesMode,
        size: ChartRenderSize
    ) -> some View {
        let height: CGFloat = size == .compact ? 180 : 280
        return Chart(items, id: \.yearMonth) { item in
            BarMark(
                x: .value("月", item.yearMonth),
                y: .value(seriesMode.title, seriesMode.value(for: item))
            )
            .foregroundStyle(.tint)
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: size == .compact ? 6 : 12))
        }
        .frame(height: height)
    }

    static func hourWeekdayHeatmap(
        _ cells: [HourWeekdayCount],
        size: ChartRenderSize
    ) -> some View {
        let height: CGFloat = size == .compact ? 200 : 320
        return Chart(cells, id: \.self) { cell in
            RectangleMark(
                x: .value("時刻", cell.hour),
                y: .value("曜日", weekdayLabel(cell.weekday))
            )
            .foregroundStyle(by: .value("件数", cell.count))
        }
        .chartXScale(domain: 0...23)
        .chartXAxis {
            AxisMarks(values: stride(from: 0, through: 23, by: size == .compact ? 6 : 3).map { $0 })
        }
        .chartYAxis {
            AxisMarks(preset: .extended, values: (0..<7).map(weekdayLabel))
        }
        .chartForegroundStyleScale(
            range: Gradient(colors: [
                Color.gray.opacity(0.10),
                Color.accentColor.opacity(0.85)
            ])
        )
        .frame(height: height)
    }

    private static func weekdayLabel(_ index: Int) -> String {
        switch index {
        case 0: return "Sun"
        case 1: return "Mon"
        case 2: return "Tue"
        case 3: return "Wed"
        case 4: return "Thu"
        case 5: return "Fri"
        case 6: return "Sat"
        default: return "?"
        }
    }
}

// MARK: - Monthly series mode

enum MonthlySeriesMode: String, CaseIterable, Identifiable {
    case conversations
    case prompts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conversations: return "会話数"
        case .prompts: return "プロンプト数"
        }
    }

    func value(for bucket: MonthlyCount) -> Int {
        switch self {
        case .conversations: return bucket.conversationCount
        case .prompts: return bucket.promptCount
        }
    }
}

// MARK: - Daily heatmap (custom grid — Charts doesn't render the
// GitHub-style calendar shape natively)

private struct DailyHeatmapView: View {
    let buckets: [DailyCount]
    let cellSize: CGFloat

    private static let cellSpacing: CGFloat = 2
    private static let rows: Int = 7

    var body: some View {
        if buckets.isEmpty {
            Text("データなし")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                grid
                    .padding(.vertical, 4)
            }
        }
    }

    private var grid: some View {
        let normalized = normalized(buckets)
        let columns = Int((Double(normalized.count) / Double(Self.rows)).rounded(.up))
        let maxCount = max(1, normalized.map(\.promptCount).max() ?? 1)

        return HStack(alignment: .top, spacing: Self.cellSpacing) {
            ForEach(0..<columns, id: \.self) { col in
                VStack(spacing: Self.cellSpacing) {
                    ForEach(0..<Self.rows, id: \.self) { row in
                        let index = col * Self.rows + row
                        if index < normalized.count {
                            cell(for: normalized[index], maxCount: maxCount)
                        } else {
                            Color.clear.frame(width: cellSize, height: cellSize)
                        }
                    }
                }
            }
        }
    }

    private func normalized(_ source: [DailyCount]) -> [DailyCount] {
        guard let first = source.first else { return source }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let firstDate = formatter.date(from: first.date) else { return source }

        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1
        let weekday = calendar.component(.weekday, from: firstDate) - 1
        guard weekday > 0 else { return source }

        var padded: [DailyCount] = []
        for offset in stride(from: weekday, to: 0, by: -1) {
            guard let priorDate = calendar.date(byAdding: .day, value: -offset, to: firstDate) else {
                continue
            }
            padded.append(DailyCount(date: formatter.string(from: priorDate), promptCount: 0))
        }
        return padded + source
    }

    private func cell(for bucket: DailyCount, maxCount: Int) -> some View {
        let intensity = Double(bucket.promptCount) / Double(maxCount)
        let baseColor: Color = bucket.promptCount == 0
            ? Color.gray.opacity(0.12)
            : Color.accentColor.opacity(max(0.18, intensity))
        return RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(baseColor)
            .frame(width: cellSize, height: cellSize)
            .help("\(bucket.date): \(bucket.promptCount) prompts")
    }
}

// MARK: - Stats card chrome

private struct StatsCard<Body: View>: View {
    let title: String
    let subtitle: String?
    let trailing: AnyView?
    /// Phase 5: when true the card paints a thin accent ring + faint
    /// fill so the user can tell which chart's detail they're
    /// currently looking at on the right pane.
    let isSelected: Bool
    @ViewBuilder let content: () -> Body

    init(
        title: String,
        subtitle: String? = nil,
        trailing: AnyView? = nil,
        isSelected: Bool = false,
        @ViewBuilder content: @escaping () -> Body
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.isSelected = isSelected
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if let trailing {
                    trailing
                }
            }

            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected
                      ? Color.accentColor.opacity(0.08)
                      : Color.clear)
        )
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.10),
                    lineWidth: isSelected ? 1.2 : 0.6
                )
        }
    }
}

#endif
