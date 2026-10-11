import Foundation
import Testing
@testable import PokeTokenBarShared

// The phone's trend layout, ported from the Mac (`MonthDailyTrendTests`, `DailyTrendStackTests`).
// Two contracts: the axis is the calendar month regardless of series length, and stacked segments
// add up exactly to the single-color bar's height.

private func usage(_ date: String, _ tokens: Int, cost: Double = 0) -> PhoneDailyTrend {
    PhoneDailyTrend(date: date, totalTokens: tokens, totalCost: cost, isToday: false)
}

private func provider(_ id: String, _ values: [(String, Int)], reportsCost: Bool = true) -> PhoneDailyTrendLayout.ProviderSeries {
    PhoneDailyTrendLayout.ProviderSeries(id: id, name: id, days: values.map { usage($0.0, $0.1, cost: 1) },
                                         reportsCost: reportsCost)
}

struct PhoneDailyTrendColumnTests {
    /// Column count is the month's length, not the series length — on the 1st too. Leap February and
    /// daylight-saving months follow the same rule.
    @Test func columnsSpanTheWholeCalendarMonthEvenOnTheFirst() {
        let cases: [(today: String, days: Int)] = [
            ("2026-10-01", 31), ("2026-09-15", 30), ("2026-02-01", 28), ("2028-02-29", 29),
            ("2026-03-08", 31), ("2026-11-01", 30), ("2026-12-31", 31),
        ]
        for (today, days) in cases {
            let columns = PhoneDailyTrendLayout.monthColumns(series: [usage(today, 10)], today: today)
            #expect(columns.count == days, "\(today)")
            #expect(columns.first?.date == String(today.prefix(8)) + "01", "\(today)")
            #expect(columns.last?.date == String(today.prefix(8)) + String(format: "%02d", days), "\(today)")
        }
    }

    @Test func daysAfterTodayAreFutureAndMissingPastDaysAreZero() {
        let columns = PhoneDailyTrendLayout.monthColumns(
            series: [usage("2026-10-01", 5), usage("2026-10-03", 7)], today: "2026-10-03")
        #expect(columns.prefix(3).map(\.tokens) == [5, 0, 7])
        #expect(columns.prefix(3).map(\.isFuture) == [false, false, false])
        #expect(columns.dropFirst(3).allSatisfy { $0.isFuture && $0.tokens == 0 })
    }

    /// Just after midnight a provider may still hold last month's series; those days stay off the axis
    /// and cannot raise the peak.
    @Test func daysFromAnotherMonthStayOffTheAxis() {
        let columns = PhoneDailyTrendLayout.monthColumns(
            series: [usage("2026-09-30", 900), usage("2026-10-01", 3)], today: "2026-10-01")
        #expect(columns.count == 31)
        #expect(!columns.contains { $0.date.hasPrefix("2026-09") })
        #expect(columns.map(\.tokens).max() == 3)
    }

    @Test func weekendTicksStopAtToday() {
        var seoul = Calendar(identifier: .gregorian)
        seoul.locale = Locale(identifier: "ko_KR")
        // 2026-10-03 Sat, 10-04 Sun, 10-10 Sat
        let columns = PhoneDailyTrendLayout.monthColumns(series: [usage("2026-10-03", 5)], today: "2026-10-03")
        func tick(_ day: Int) -> Bool { PhoneDailyTrendLayout.showsWeekendTick(columns[day - 1], calendar: seoul) }
        #expect(tick(3), "today, a Saturday, has a tick")
        #expect(!tick(4), "a future Sunday has none")
        #expect(!tick(10), "a future Saturday has none")
        #expect(!tick(2), "a past weekday has none")
        let late = PhoneDailyTrendLayout.monthColumns(series: [usage("2026-10-12", 5)], today: "2026-10-12")
        #expect(PhoneDailyTrendLayout.showsWeekendTick(late[10], calendar: seoul), "a past Sunday (11th) has one")
    }

    @Test func peakIsShownOnlyOnceMoreThanOneDayHasUsage() {
        let first = PhoneDailyTrendLayout.monthColumns(series: [usage("2026-10-01", 3)], today: "2026-10-01")
        #expect(!PhoneDailyTrendLayout.showsPeak(first))
        let second = PhoneDailyTrendLayout.monthColumns(
            series: [usage("2026-10-01", 3), usage("2026-10-02", 4)], today: "2026-10-02")
        #expect(PhoneDailyTrendLayout.showsPeak(second))
        let idleFirst = PhoneDailyTrendLayout.monthColumns(
            series: [usage("2026-10-01", 0), usage("2026-10-02", 4)], today: "2026-10-02")
        #expect(!PhoneDailyTrendLayout.showsPeak(idleFirst), "a zero day is not a used day")
    }

    @Test func axisLabelsCoverTheFirstEverySeventhAndAlwaysTodayWithoutCollisions() {
        let today = "2026-10-22"
        func label(_ day: Int) -> String? {
            PhoneDailyTrendLayout.axisLabel(for: String(format: "2026-10-%02d", day), today: today)
        }
        #expect(label(1) == "1")
        #expect(label(7) == "7")
        #expect(label(14) == "14")
        #expect(label(21) == nil, "a regular label next to today is dropped so the two cannot collide")
        #expect(label(22) == "22", "today is never dropped")
        #expect(label(23) == nil)
        #expect(label(28) == "28")
    }

    @Test func barHeightBoundaries() {
        #expect(PhoneDailyTrendLayout.barHeight(tokens: 0, peak: 100, track: 26, baseline: 1.5) == 1.5)
        #expect(PhoneDailyTrendLayout.barHeight(tokens: 100, peak: 0, track: 26, baseline: 1.5) == 1.5)
        #expect(PhoneDailyTrendLayout.barHeight(tokens: 100, peak: 100, track: 26, baseline: 1.5) == 26)
        #expect(PhoneDailyTrendLayout.barHeight(tokens: 1, peak: 1_000_000, track: 26, baseline: 1.5) == 1.5,
                "a tiny day never vanishes")
    }
}

struct PhoneDailyTrendStackTests {
    @Test func orderIsByMonthTotalWithUnusedProvidersDroppedAndTiesBrokenById() {
        let ordered = PhoneDailyTrendLayout.ordered([
            provider("small", [("2026-08-01", 10), ("2026-08-02", 3)]),
            provider("idle", [("2026-08-01", 0), ("2026-08-02", 0)]),
            provider("big", [("2026-08-01", 1), ("2026-08-02", 900)]),
            provider("tie-b", [("2026-08-01", 15)]),
            provider("tie-a", [("2026-08-02", 15)]),
        ])
        #expect(ordered.map(\.id) == ["big", "tie-a", "tie-b", "small"])
    }

    @Test func stackingNeedsTwoProvidersThatActuallyUsedSomethingThisMonth() {
        #expect(!PhoneDailyTrendLayout.isStacked(PhoneDailyTrendLayout.ordered([])))
        #expect(!PhoneDailyTrendLayout.isStacked(PhoneDailyTrendLayout.ordered([provider("a", [("2026-08-01", 10)])])))
        #expect(!PhoneDailyTrendLayout.isStacked(PhoneDailyTrendLayout.ordered([
            provider("a", [("2026-08-01", 10)]), provider("b", [("2026-08-01", 0)]),
        ])), "a zero-token provider does not count toward stacking")
        #expect(PhoneDailyTrendLayout.isStacked(PhoneDailyTrendLayout.ordered([
            provider("a", [("2026-08-01", 10)]), provider("b", [("2026-08-02", 1)]),
        ])))
    }

    @Test func segmentsAddUpExactlyToTheBarHeight() {
        let stack = PhoneDailyTrendLayout.ordered([
            provider("a", [("d", 333_333)]), provider("b", [("d", 222_221)]), provider("c", [("d", 7)]),
        ])
        for height in [1.5, 1.7, 9.3, 17.77, 26.0] {
            let segments = PhoneDailyTrendLayout.segments(on: "d", stack: stack, barHeight: height)
            #expect(segments.map(\.providerID) == ["a", "b", "c"])
            #expect(segments.reduce(0) { $0 + $1.height } == height, "sum drifted at \(height)")
            #expect(segments.allSatisfy { $0.height >= 0 })
        }
        let twoToOne = PhoneDailyTrendLayout.segments(
            on: "d", stack: PhoneDailyTrendLayout.ordered([provider("a", [("d", 200)]), provider("b", [("d", 100)])]),
            barHeight: 24)
        #expect(twoToOne.map(\.height) == [16, 8])
    }

    /// Order is by the month, not the day, so the month leader stays at the bottom on a day it used little.
    @Test func zeroTokenProvidersAreOmittedAndTheMonthLeaderStaysAtTheBottom() {
        let stack = PhoneDailyTrendLayout.ordered([
            provider("leader", [("2026-08-01", 1_000), ("2026-08-02", 10)]),
            provider("second", [("2026-08-01", 0), ("2026-08-02", 90)]),
        ])
        #expect(PhoneDailyTrendLayout.segments(on: "2026-08-01", stack: stack, barHeight: 20).map(\.providerID) == ["leader"])
        #expect(PhoneDailyTrendLayout.segments(on: "2026-08-02", stack: stack, barHeight: 20).map(\.providerID) == ["leader", "second"])
        #expect(PhoneDailyTrendLayout.segments(on: "2026-08-03", stack: stack, barHeight: 20).isEmpty)
    }

    @Test func colorsFollowRegistrationOrderNotUsageRankOrWhoElseIsActive() {
        let registry = ["first", "second", "third"]
        let a = PhoneDailyTrendLayout.colorIndices(for: ["first", "second"], registry: registry, paletteCount: 8)
        let b = PhoneDailyTrendLayout.colorIndices(for: ["second", "first"], registry: registry, paletteCount: 8)
        #expect(a == b)
        #expect(a == ["first": 0, "second": 1])
        #expect(PhoneDailyTrendLayout.colorIndices(for: ["third", "first"], registry: registry, paletteCount: 8)
                == ["first": 0, "third": 2])
        let wide = (0..<14).map { "p\($0)" }
        #expect(PhoneDailyTrendLayout.colorIndices(for: ["p8"], registry: wide, paletteCount: 8)["p8"] == 0)
        #expect(PhoneDailyTrendLayout.colorIndices(for: wide, registry: wide, paletteCount: 8).count == 14)
    }

    /// Only payload providers that carry their own daily series can be stacked; the rest are left to
    /// the combined bar. Payload order is preserved — it is the Mac's registration order.
    @Test func providerSeriesComeFromThePayloadInOrderAndSkipProvidersWithoutASeries() {
        let payload = PhonePayload(
            todayTokens: 0, todayCost: 0, weekTokens: 0, monthTokens: 0, lastUpdated: Date(), serverVersion: "",
            limits: nil, companion: nil,
            providers: [
                PhoneProviderSnapshot(id: "codex", displayName: "Codex", todayTokens: 1, todayCost: 0,
                                      monthDaily: [usage("2026-10-01", 1)]),
                PhoneProviderSnapshot(id: "old_mac", displayName: "Old", todayTokens: 1, todayCost: 0),
                PhoneProviderSnapshot(id: "claude_code", displayName: "Claude Code", todayTokens: 1, todayCost: 0,
                                      reportsCost: false, monthDaily: [usage("2026-10-01", 9)]),
            ])
        let series = PhoneDailyTrendLayout.providerSeries(from: payload)
        #expect(series.map(\.id) == ["codex", "claude_code"])
        #expect(series.map(\.reportsCost) == [true, false])
    }

    @Test func readoutSplitsByProviderOnlyWhenStackedAndSkipsFutureDays() {
        let stack = PhoneDailyTrendLayout.ordered([
            provider("a", [("2026-10-02", 600)]), provider("b", [("2026-10-02", 400)], reportsCost: false),
            provider("c", [("2026-10-01", 5)]),
        ])
        let columns = PhoneDailyTrendLayout.monthColumns(
            series: [usage("2026-10-01", 5, cost: 1), usage("2026-10-02", 1000, cost: 2)], today: "2026-10-02")
        let day = PhoneDailyTrendLayout.readout(for: columns[1], stack: stack)
        #expect(day?.tokens == 1000 && day?.cost == 2)
        #expect(day?.rows.map(\.id) == ["a", "b"], "providers idle that day are left out")
        #expect(day?.rows.map(\.cost) == [1, nil], "cost only for providers that bill")
        #expect(PhoneDailyTrendLayout.readout(for: columns[2], stack: stack) == nil, "future day")
        let single = PhoneDailyTrendLayout.readout(for: columns[1], stack: PhoneDailyTrendLayout.ordered([stack[0]]))
        #expect(single?.rows.isEmpty == true, "no split for a single-provider month")
    }
}

struct PokemonTypeColorTests {
    @Test func tableCoversTheEighteenMainSeriesTypesWithClassicColors() {
        let types = ["normal", "fire", "water", "electric", "grass", "ice", "fighting", "poison", "ground",
                     "flying", "psychic", "bug", "rock", "ghost", "dragon", "dark", "steel", "fairy"]
        #expect(Set(PokemonTypeColor.table.keys) == Set(types))
        #expect(PokemonTypeColor.hex(for: "fire") == 0xFF4422)
        #expect(PokemonTypeColor.hex(for: "Water") == 0x3399FF, "case-insensitive")
        #expect(PokemonTypeColor.hex(for: "stellar") == nil)
        #expect(PokemonTypeColor.hex(for: "") == nil)
    }

    @Test func rgbSplitsTheHexIntoUnitComponents() {
        let rgb = PokemonTypeColor.rgb(0xFF8000)
        #expect(rgb.red == 1 && rgb.green == 128.0 / 255 && rgb.blue == 0)
    }
}
