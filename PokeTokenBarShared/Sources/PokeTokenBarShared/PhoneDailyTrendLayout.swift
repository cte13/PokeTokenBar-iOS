import Foundation

/// Layout math for the phone's daily trend card — the Mac's `DailyTrendMetrics` and
/// `DailyTrendStack` (upstream #395, #348) on `PhoneDailyTrend` series, kept pure so both
/// contracts can be checked without a view:
///
/// - The axis is the **calendar month**, not the series. The series ends today, so dividing the
///   row by its length made a single bar fill the row on the 1st and moved every bar and label
///   daily through the first weeks. Padding happens here, at the view boundary; the data series
///   still ends today.
/// - A stacked bar's segments **add up exactly** to the single-color bar's height for that day,
///   and a month with at most one provider renders exactly as the unstacked row.
public enum PhoneDailyTrendLayout {

    // MARK: Columns

    public struct Column: Equatable, Identifiable, Sendable {
        public let date: String
        public let tokens: Int
        public let cost: Double
        /// After today: no bar, no tap, no weekend tick.
        public let isFuture: Bool
        public var id: String { date }

        public init(date: String, tokens: Int, cost: Double, isFuture: Bool) {
            self.date = date
            self.tokens = tokens
            self.cost = cost
            self.isFuture = isFuture
        }
    }

    /// One column per day of `today`'s calendar month. Days in the series keep their numbers, past
    /// days missing from it are zero, days after today are `isFuture`. Dates from another month (a
    /// provider still holding last month's series just after midnight) stay off the axis. If `today`
    /// cannot be parsed the series is returned as-is (API guard, not a branch to design for).
    public static func monthColumns(series: [PhoneDailyTrend], today: String) -> [Column] {
        let month = String(today.prefix(7))   // "yyyy-MM"
        guard let year = Int(today.prefix(4)), let monthNumber = Int(month.suffix(2)),
              let todayOfMonth = Int(today.suffix(2)),
              let length = daysInMonth(year: year, month: monthNumber)
        else {
            return series.map { Column(date: $0.date, tokens: $0.totalTokens, cost: $0.totalCost, isFuture: false) }
        }
        var tokensByDay: [String: (tokens: Int, cost: Double)] = [:]
        for day in series {
            var sum = tokensByDay[day.date] ?? (0, 0)
            sum.tokens += day.totalTokens
            sum.cost += day.totalCost
            tokensByDay[day.date] = sum
        }
        return (1...length).map { day in
            let date = String(format: "%@-%02d", month, day)
            let sum = tokensByDay[date]
            return Column(date: date, tokens: sum?.tokens ?? 0, cost: sum?.cost ?? 0, isFuture: day > todayOfMonth)
        }
    }

    /// `tokens` as a share of `peak` inside `track`, never below `baseline` so a small day stays
    /// visible and an empty day still marks its slot.
    public static func barHeight(tokens: Int, peak: Int, track: Double, baseline: Double) -> Double {
        guard peak > 0, tokens > 0 else { return baseline }
        let ratio = min(1, Double(tokens) / Double(peak))
        return max(baseline, ratio * track)
    }

    /// Weekend ticks only under past days and today — under a future column with no bar above it
    /// they read as stray "__ __" marks.
    public static func showsWeekendTick(_ column: Column, calendar: Calendar = .current) -> Bool {
        !column.isFuture && isWeekend(column.date, calendar: calendar)
    }

    /// `calendar` is a test seam: which days are the weekend is a locale decision.
    public static func isWeekend(_ date: String, calendar: Calendar = .current) -> Bool {
        guard let parsed = UsageAggregation.localDayFormatter().date(from: date) else { return false }
        return calendar.isDateInWeekend(parsed)
    }

    /// The caption's peak repeats the readout while only one day has usage.
    public static func showsPeak(_ columns: [Column]) -> Bool {
        columns.filter { $0.tokens > 0 }.count > 1
    }

    /// Axis numbers on the 1st, every `labelInterval` days, and always today. A regular label within
    /// `minimumSeparation` of today is dropped so two-digit numbers cannot collide at full-month
    /// column widths; today itself is never dropped, so the axis is never empty.
    public static func axisLabel(for date: String, today: String, labelInterval: Int = 7,
                                 minimumSeparation: Int = 3) -> String? {
        guard let dayOfMonth = Int(date.suffix(2)) else { return nil }
        if date == today { return "\(dayOfMonth)" }
        let isRegular = dayOfMonth == 1 || (labelInterval > 0 && dayOfMonth % labelInterval == 0)
        guard isRegular else { return nil }
        if let todayOfMonth = Int(today.suffix(2)),
           abs(dayOfMonth - todayOfMonth) < minimumSeparation { return nil }
        return "\(dayOfMonth)"
    }

    /// Month, day and weekday in the locale's own order (ko "10. 3. (토)", en "Sat, 10/3").
    public static func dayStamp(_ date: String, locale: Locale = .current) -> String {
        guard let parsed = UsageAggregation.localDayFormatter().date(from: date) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("MdE")
        return formatter.string(from: parsed)
    }

    /// Gregorian day count; date keys are `en_US_POSIX` Gregorian, and no time of day is involved,
    /// so UTC keeps daylight-saving changes out of it.
    private static func daysInMonth(year: Int, month: Int) -> Int? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let range = calendar.range(of: .day, in: .month, for: first) else { return nil }
        return range.count
    }

    // MARK: Stacking by provider

    public struct ProviderSeries: Equatable, Sendable {
        public let id: String
        public let name: String
        public let days: [PhoneDailyTrend]
        public let reportsCost: Bool

        public init(id: String, name: String, days: [PhoneDailyTrend], reportsCost: Bool) {
            self.id = id
            self.name = name
            self.days = days
            self.reportsCost = reportsCost
        }
    }

    public struct Segment: Equatable, Sendable {
        public let providerID: String
        public let tokens: Int
        public let height: Double

        public init(providerID: String, tokens: Int, height: Double) {
            self.providerID = providerID
            self.tokens = tokens
            self.height = height
        }
    }

    /// Every payload provider that carries its own daily series, in payload order (the Mac's
    /// registration order, which is what keeps a provider's color stable).
    public static func providerSeries(from payload: PhonePayload) -> [ProviderSeries] {
        payload.providers.compactMap { provider in
            guard let days = provider.monthDaily else { return nil }
            return ProviderSeries(id: provider.id, name: provider.displayName, days: days,
                                  reportsCost: provider.reportsCost)
        }
    }

    /// Providers that used anything this month, largest month total first (bottom of the stack).
    /// Ties break on id so the order cannot flip between refreshes.
    public static func ordered(_ providers: [ProviderSeries]) -> [ProviderSeries] {
        let totals: [(provider: ProviderSeries, tokens: Int)] = providers.map { provider in
            (provider, provider.days.reduce(0) { $0 + $1.totalTokens })
        }
        return totals
            .filter { $0.tokens > 0 }
            .sorted { lhs, rhs in
                lhs.tokens != rhs.tokens ? lhs.tokens > rhs.tokens : lhs.provider.id < rhs.provider.id
            }
            .map(\.provider)
    }

    /// With one provider (or none) the row stays the plain single-color bar.
    public static func isStacked(_ ordered: [ProviderSeries]) -> Bool { ordered.count > 1 }

    /// Segments of `date`'s bar, bottom → top in `ordered` order. Zero-token providers are left out.
    /// Heights come from cumulative shares, so they add up to exactly `barHeight` with no rounding
    /// drift. Empty when nobody used anything that day.
    public static func segments(on date: String, stack ordered: [ProviderSeries],
                                barHeight: Double) -> [Segment] {
        let parts = ordered.compactMap { provider -> (String, Int)? in
            let tokens = provider.days.first { $0.date == date }?.totalTokens ?? 0
            return tokens > 0 ? (provider.id, tokens) : nil
        }
        let total = parts.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return [] }

        var segments: [Segment] = []
        var running = 0
        var placed = 0.0
        for (index, part) in parts.enumerated() {
            running += part.1
            let top = index == parts.count - 1 ? barHeight : barHeight * Double(running) / Double(total)
            segments.append(Segment(providerID: part.0, tokens: part.1, height: top - placed))
            placed = top
        }
        return segments
    }

    /// Palette slot per provider id: its index in `registry` modulo the palette, and nothing else,
    /// so a provider keeps its color as others become active or idle and as ranks shift.
    public static func colorIndices(for ids: [String], registry: [String], paletteCount: Int) -> [String: Int] {
        var slots: [String: Int] = [:]
        for id in ids {
            slots[id] = (registry.firstIndex(of: id) ?? 0) % paletteCount
        }
        return slots
    }

    // MARK: Day readout

    public struct ReadoutRow: Equatable, Sendable {
        public let id: String
        public let name: String
        public let tokens: Int
        /// nil when the provider does not bill.
        public let cost: Double?
    }

    public struct Readout: Equatable, Sendable {
        public let date: String
        public let tokens: Int
        public let cost: Double
        /// Per-provider split in stack order; only when the bars stack, and only providers that
        /// used something that day.
        public let rows: [ReadoutRow]
    }

    /// What the caption says for one column: the day's total, and when stacked, each provider's share.
    /// nil for a future column.
    public static func readout(for column: Column, stack: [ProviderSeries]) -> Readout? {
        guard !column.isFuture else { return nil }
        let rows: [ReadoutRow] = isStacked(stack) ? stack.compactMap { provider in
            guard let usage = provider.days.first(where: { $0.date == column.date }), usage.totalTokens > 0
            else { return nil }
            return ReadoutRow(id: provider.id, name: provider.name, tokens: usage.totalTokens,
                              cost: provider.reportsCost ? usage.totalCost : nil)
        } : []
        return Readout(date: column.date, tokens: column.tokens, cost: column.cost, rows: rows)
    }
}
