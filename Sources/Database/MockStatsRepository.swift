import Foundation

/// Stand-in `StatsRepository` for the mock data path (no archive.db
/// installed). Returns small fixed datasets so the Dashboard view
/// renders end-to-end in previews and on developer machines that
/// haven't yet imported a real archive — the user still sees the
/// chart layouts and can verify the mode-switching plumbing without
/// having to seed a SQLite file first.
///
/// The numbers are deliberately not realistic: they're shaped to
/// exercise each chart's edge cases (zero days, single-source
/// dominance, "Unknown" model bucket) rather than impersonate a
/// production archive.
struct MockStatsRepository: StatsRepository {
    func sourceBreakdown(filter: ArchiveSearchFilter) async throws -> [SourceCount] {
        // Mirrors the canonical universe so the view's color mapping
        // (`SourceAppearance`) lights up every brand without tripping
        // over the "others" bucket — markdown stays excluded per the
        // shared WHERE convention.
        [
            SourceCount(label: "chatgpt", count: 547),
            SourceCount(label: "gemini", count: 55),
            SourceCount(label: "claude", count: 27)
        ]
    }

    func modelBreakdown(filter: ArchiveSearchFilter) async throws -> [ModelCount] {
        [
            ModelCount(label: "gpt-4o", count: 312),
            ModelCount(label: "gpt-4o-mini", count: 184),
            ModelCount(label: "claude-3.5-sonnet", count: 26),
            ModelCount(label: "gemini-1.5-pro", count: 47),
            ModelCount(label: "Unknown", count: 60)
        ]
    }

    func monthlyBreakdown(filter: ArchiveSearchFilter) async throws -> [MonthlyCount] {
        // 12 months trailing from "this month" — hard-coding the
        // labels (rather than computing from `Date()`) keeps preview
        // output stable across runs and across the test machine's
        // clock.
        let labels = [
            "2025-05", "2025-06", "2025-07", "2025-08", "2025-09",
            "2025-10", "2025-11", "2025-12", "2026-01", "2026-02",
            "2026-03", "2026-04"
        ]
        let conversations = [12, 18, 25, 32, 40, 28, 35, 22, 18, 26, 31, 24]
        let prompts = [240, 360, 500, 640, 800, 560, 700, 440, 360, 520, 620, 480]
        return zip(labels, zip(conversations, prompts)).map { label, counts in
            MockStatsRepository.makeMonthly(
                yearMonth: label,
                conversationCount: counts.0,
                promptCount: counts.1
            )
        }
    }

    func dailyHeatmap(filter: ArchiveSearchFilter) async throws -> [DailyCount] {
        // Synthetic 60-day window centred on today's mock date.
        // `seed`-driven so the heatmap is deterministic — we want
        // the same preview every time, not new random tiles each
        // launch.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")

        let calendar = Calendar(identifier: .gregorian)
        let endDate = formatter.date(from: "2026-04-28") ?? Date()
        var seeds: [Int] = []
        var seed: Int = 1
        for _ in 0..<60 {
            seed = (seed * 1103515245 &+ 12345) & 0x7FFFFFFF
            seeds.append(seed % 18)
        }
        return (0..<60).reversed().enumerated().compactMap { index, daysAgo in
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: endDate) else {
                return nil
            }
            return DailyCount(
                date: formatter.string(from: day),
                promptCount: seeds[index]
            )
        }
    }

    func hourWeekdayHeatmap(filter: ArchiveSearchFilter) async throws -> [HourWeekdayCount] {
        // Lean toward weekday evenings / weekend afternoons so the
        // resulting heatmap looks like a believable usage pattern
        // rather than uniform noise.
        var cells: [HourWeekdayCount] = []
        for weekday in 0..<7 {
            for hour in 0..<24 {
                let isEvening = (hour >= 19 && hour <= 23)
                let isAfternoon = (hour >= 13 && hour <= 18)
                let isWeekend = (weekday == 0 || weekday == 6)
                var count = 0
                if isEvening && !isWeekend { count = 6 }
                if isAfternoon && isWeekend { count = 9 }
                if isAfternoon && !isWeekend { count = 3 }
                if hour >= 1 && hour <= 6 { count = 0 }
                cells.append(HourWeekdayCount(weekday: weekday, hour: hour, count: count))
            }
        }
        return cells
    }

    private static func makeMonthly(
        yearMonth: String,
        conversationCount: Int,
        promptCount: Int
    ) -> MonthlyCount {
        MonthlyCount(
            yearMonth: yearMonth,
            conversationCount: conversationCount,
            promptCount: promptCount
        )
    }
}
