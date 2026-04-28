import Foundation
import Observation

/// `@Observable` driver for the Dashboard (Stats) middle pane.
///
/// Responsibilities:
/// - Hold the filter scope the user is currently looking at.
/// - Re-fetch all five aggregations when the filter changes.
/// - Surface loading / error state so the view doesn't show stale
///   half-loaded charts.
///
/// **Why one model, not five.** Stats charts are conceptually one
/// "view" — the user expects all five to update atomically when
/// they tweak the filter, and they expect a single spinner / error
/// banner instead of five competing ones. We fan out to the
/// repository in parallel via `async let` so the round-trip cost is
/// the slowest single query, not the sum.
///
/// **Why not memoize.** Per AGENTS.md, Stats is a derived view —
/// caching would put us back in the "stale after import" hole. The
/// 5,000-conversation scale we currently target finishes all five
/// queries well under one human-perceptible frame; if 100x scale
/// proves otherwise the right move is to add the index, not the
/// cache.
@MainActor
@Observable
final class StatsViewModel {
    private let stats: any StatsRepository

    var filter: ArchiveSearchFilter {
        didSet {
            guard filter != oldValue else { return }
            scheduleRefresh()
        }
    }

    private(set) var sourceCounts: [SourceCount] = []
    private(set) var modelCounts: [ModelCount] = []
    private(set) var monthlyCounts: [MonthlyCount] = []
    private(set) var dailyCounts: [DailyCount] = []
    private(set) var hourWeekdayCounts: [HourWeekdayCount] = []

    private(set) var isLoading: Bool = false
    private(set) var errorText: String?

    /// True iff every aggregation came back empty. The view uses
    /// this to swap the chart stack for a single
    /// `ContentUnavailableView` rather than rendering five empty
    /// frames.
    var isEmpty: Bool {
        sourceCounts.isEmpty
            && modelCounts.isEmpty
            && monthlyCounts.isEmpty
            && dailyCounts.isEmpty
            && hourWeekdayCounts.isEmpty
    }

    /// Generation token used to discard stale results from older
    /// fetches. When the filter changes mid-fetch we don't want the
    /// in-flight task to overwrite the new task's results when it
    /// finally returns.
    private var fetchGeneration: Int = 0

    init(stats: any StatsRepository, filter: ArchiveSearchFilter = ArchiveSearchFilter()) {
        self.stats = stats
        self.filter = filter
    }

    /// First load. Called from `.task` on the Stats view's mount —
    /// `filter`'s `didSet` would also trigger a fetch on subsequent
    /// changes, but mount is the one entry point where the value
    /// hasn't actually changed yet.
    func loadIfNeeded() {
        // Allow re-loading on every mount: switching back and forth
        // between Stats and another mode shouldn't preserve a stale
        // render. Cheap because every method is a bounded GROUP BY.
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        fetchGeneration += 1
        let generation = fetchGeneration
        let snapshot = filter
        Task { [weak self] in
            await self?.refresh(filter: snapshot, generation: generation)
        }
    }

    private func refresh(filter: ArchiveSearchFilter, generation: Int) async {
        isLoading = true
        errorText = nil

        do {
            async let sources = stats.sourceBreakdown(filter: filter)
            async let models = stats.modelBreakdown(filter: filter)
            async let monthly = stats.monthlyBreakdown(filter: filter)
            async let daily = stats.dailyHeatmap(filter: filter)
            async let hourWeekday = stats.hourWeekdayHeatmap(filter: filter)

            let (s, m, mo, d, hw) = try await (sources, models, monthly, daily, hourWeekday)

            // Drop results from a stale generation. A newer fetch
            // has already started and its result is the one we want
            // on screen.
            guard generation == fetchGeneration else { return }

            sourceCounts = s
            modelCounts = m
            monthlyCounts = mo
            dailyCounts = d
            hourWeekdayCounts = hw
            isLoading = false
        } catch {
            guard generation == fetchGeneration else { return }
            errorText = error.localizedDescription
            isLoading = false
        }
    }
}
