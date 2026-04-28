#if os(macOS)
import SwiftUI
import Charts

/// Dashboard / Stats middle pane. Renders five bounded aggregations
/// over the active `ArchiveSearchFilter` — every chart updates
/// atomically when the user changes the sidebar source filter or
/// the search bar text upstream.
///
/// The single `StatsViewModel` is the authority on data + load
/// state; this view is purely presentational. It's deliberately a
/// `ScrollView` of stacked sections rather than a multi-pane
/// dashboard — the user told us they read these charts "top to
/// bottom in one pass to feel the archive".
struct StatsContentPane: View {
    @Bindable var viewModel: StatsViewModel
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
            VStack(alignment: .leading, spacing: 28) {
                sourceSection
                modelSection
                monthlySection
                dailyHeatmapSection
                hourWeekdaySection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 24)
        }
    }

    // MARK: - Source breakdown

    private var sourceSection: some View {
        StatsCard(
            title: "ソース別",
            subtitle: "会話数 (Markdown は除外)"
        ) {
            Chart(viewModel.sourceCounts, id: \.label) { item in
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
            .frame(height: max(120, CGFloat(viewModel.sourceCounts.count) * 36 + 40))
        }
    }

    // MARK: - Model breakdown

    private var modelSection: some View {
        StatsCard(
            title: "モデル別",
            subtitle: "上位 10 件 (空欄は \"Unknown\" に集約)"
        ) {
            Chart(viewModel.modelCounts, id: \.label) { item in
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
            .frame(height: max(120, CGFloat(viewModel.modelCounts.count) * 30 + 40))
        }
    }

    // MARK: - Monthly breakdown

    private var monthlySection: some View {
        StatsCard(
            title: "月別",
            subtitle: "過去 24 ヶ月",
            trailing: AnyView(
                Picker("系列", selection: $monthlySeriesMode) {
                    ForEach(MonthlySeriesMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 200)
            )
        ) {
            Chart(viewModel.monthlyCounts, id: \.yearMonth) { item in
                BarMark(
                    x: .value("月", item.yearMonth),
                    y: .value(monthlySeriesMode.title, monthlySeriesMode.value(for: item))
                )
                .foregroundStyle(.tint)
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 8))
            }
            .frame(height: 220)
        }
    }

    // MARK: - Daily heatmap

    private var dailyHeatmapSection: some View {
        StatsCard(
            title: "日付別ヒートマップ",
            subtitle: "プロンプト数 / 日 (過去 365 日上限)"
        ) {
            DailyHeatmapView(buckets: viewModel.dailyCounts)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Hour × weekday heatmap

    private var hourWeekdaySection: some View {
        StatsCard(
            title: "時刻 × 曜日ヒートマップ",
            subtitle: "プロンプト数 (会話の代表時刻に集約)"
        ) {
            Chart(viewModel.hourWeekdayCounts, id: \.self) { cell in
                RectangleMark(
                    x: .value("時刻", cell.hour),
                    y: .value("曜日", weekdayLabel(cell.weekday))
                )
                .foregroundStyle(by: .value("件数", cell.count))
            }
            .chartXScale(domain: 0...23)
            .chartXAxis {
                AxisMarks(values: stride(from: 0, through: 23, by: 3).map { $0 })
            }
            .chartYAxis {
                AxisMarks(preset: .extended, values: weekdayOrder)
            }
            .chartForegroundStyleScale(
                range: Gradient(colors: [
                    Color.gray.opacity(0.10),
                    Color.accentColor.opacity(0.85)
                ])
            )
            .frame(height: 220)
        }
    }

    private var weekdayOrder: [String] {
        (0..<7).map(weekdayLabel)
    }

    private func weekdayLabel(_ index: Int) -> String {
        // strftime('%w'): Sunday=0..Saturday=6
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

private enum MonthlySeriesMode: String, CaseIterable, Identifiable {
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

    private static let cellSize: CGFloat = 12
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
        // Lay out buckets in column-major order: each column is one
        // week, top row = Sunday at column anchor. Buckets arrive in
        // ascending date order from the repository so we know the
        // first index is the oldest day.
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
                            Color.clear.frame(width: Self.cellSize, height: Self.cellSize)
                        }
                    }
                }
            }
        }
    }

    /// Pad the leading edge so the first bucket starts on the
    /// correct weekday — without padding, all weeks would shift if
    /// the data window starts on, say, Wednesday. We use the
    /// sibling `Calendar` only to compute the leading offset; the
    /// bucket dates themselves come straight from SQLite's
    /// `'localtime'` formatting and we don't reparse them.
    private func normalized(_ source: [DailyCount]) -> [DailyCount] {
        guard let first = source.first else { return source }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let firstDate = formatter.date(from: first.date) else { return source }

        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1 // Sunday — matches strftime('%w')'s Sunday=0 axis.
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
            .frame(width: Self.cellSize, height: Self.cellSize)
            .help("\(bucket.date): \(bucket.promptCount) prompts")
    }
}

// MARK: - Stats card chrome

private struct StatsCard<Body: View>: View {
    let title: String
    let subtitle: String?
    let trailing: AnyView?
    @ViewBuilder let content: () -> Body

    init(
        title: String,
        subtitle: String? = nil,
        trailing: AnyView? = nil,
        @ViewBuilder content: @escaping () -> Body
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 0.7)
        }
    }
}

#endif
