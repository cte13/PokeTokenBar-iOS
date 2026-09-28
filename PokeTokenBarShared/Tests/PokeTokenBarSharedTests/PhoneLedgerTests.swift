import Foundation
import Testing
@testable import PokeTokenBarShared

/// Local-calendar fixture: Wednesday 2026-09-16 12:00 — the day before is in the same week and
/// month whether the locale starts weeks on Sunday or Monday.
private let cal = Calendar.current
private func local(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}
private let now = local(2026, 9, 16)
private let fmt = UsageAggregation.localDayFormatter()

private func entry(_ id: String, _ date: Date, tokens: Int = 1000, model: String = "claude-opus-5-5") -> UsageEntry {
    UsageEntry(id: id, date: date, localDay: fmt.string(from: date), model: model,
               input: tokens, output: 0, cacheWrite: 0, cacheRead: 0)
}

private let claude = PhoneUsageLedgerManifest.Provider(id: "claude_code", displayName: "Claude Code", reportsCost: true)
private func manifest(_ providers: [PhoneUsageLedgerManifest.Provider] = [claude]) -> PhoneUsageLedgerManifest {
    PhoneUsageLedgerManifest(updatedAt: now, providers: providers, records: [])
}

private func macSnapshot(_ id: String, today: Int, week: Int, month: Int, tpm: Double? = nil) -> PhoneProviderSnapshot {
    PhoneProviderSnapshot(id: id, displayName: id, todayTokens: today, todayCost: 1,
                          weekTokens: week, weekCost: 2, monthTokens: month, monthCost: 3,
                          tokensPerMinute: tpm,
                          monthDaily: [PhoneDailyTrend(date: "2026-09-01", totalTokens: month - today, totalCost: 2)])
}

private func macPayload(at date: Date, providers: [PhoneProviderSnapshot]) -> PhonePayload {
    PhonePayload(todayTokens: providers.reduce(0) { $0 + $1.todayTokens }, todayCost: 0,
                 weekTokens: 0, monthTokens: 0, lastUpdated: date, serverVersion: "9.9",
                 limits: nil, companion: nil, providers: providers)
}

struct PhoneUsageLedgerCodecTests {
    @Test func roundTripKeepsEveryFieldAndDerivesLocalDayOnRead() throws {
        var e = entry("m|r", local(2026, 9, 16, 23, 30), tokens: 5)
        e.explicitCost = 0.25
        e.costIsEstimate = false
        e.sessionID = "stays-on-the-mac"
        let chunk = try #require(try PhoneUsageLedger.chunks(provider: "p", entries: [e]).first)
        let back = try PhoneUsageLedger.decode(payload: chunk.payload)
        #expect(back.count == 1)
        #expect(back[0].id == "m|r" && back[0].input == 5 && back[0].explicitCost == 0.25 && back[0].costIsEstimate == false)
        #expect(back[0].date == e.date)
        #expect(back[0].sessionID == nil)

        let utcPlus14 = UsageAggregation.localDayFormatter(timeZone: TimeZone(secondsFromGMT: 14 * 3600)!)
        let shifted = try PhoneUsageLedger.decode(payload: chunk.payload, fmt: utcPlus14)
        #expect(shifted[0].localDay == utcPlus14.string(from: e.date))
    }

    @Test func chunksAreOnePerDayAndSplitAtChunkSize() throws {
        let day1 = (0..<(PhoneUsageLedger.chunkSize + 1)).map { entry("a\($0)", local(2026, 9, 15, 1).addingTimeInterval(Double($0))) }
        let day2 = [entry("b", local(2026, 9, 16, 1))]
        let chunks = try PhoneUsageLedger.chunks(provider: "p", entries: day2 + day1.shuffled())
        #expect(chunks.map(\.recordName) == ["ul_p_2026-09-15_0", "ul_p_2026-09-15_1", "ul_p_2026-09-16_0"])
        #expect(try PhoneUsageLedger.decode(payload: chunks[1].payload).map(\.id) == ["a\(PhoneUsageLedger.chunkSize)"])
    }

    /// A growing day must only change its last chunk, or every refresh re-uploads the whole day.
    @Test func appendingToADayChangesOnlyItsLastChunkDigest() throws {
        let base = (0..<(PhoneUsageLedger.chunkSize + 3)).map { entry("a\($0)", local(2026, 9, 16, 1).addingTimeInterval(Double($0))) }
        let before = try PhoneUsageLedger.chunks(provider: "p", entries: base)
        let after = try PhoneUsageLedger.chunks(provider: "p", entries: base + [entry("late", local(2026, 9, 16, 11))])
        #expect(before[0].digest == after[0].digest)
        #expect(before[1].digest != after[1].digest)
        #expect(try PhoneUsageLedger.chunks(provider: "p", entries: base.reversed()).map(\.digest) == before.map(\.digest))
    }
}

struct PhoneLedgerOverlayTests {
    /// The goal: Mac asleep since yesterday, cloud turns today. Claude is recounted from entries;
    /// the Mac-only provider keeps its week/month but shows nothing for today.
    @Test func macAsleepSinceYesterdayCountsLedgerAndZeroesOtherProvidersToday() {
        let mac = macPayload(at: local(2026, 9, 15, 22), providers: [
            macSnapshot("claude_code", today: 999, week: 999, month: 999),
            macSnapshot("codex", today: 50, week: 500, month: 5000, tpm: 12),
        ])
        let entries = ["claude_code": [entry("y", local(2026, 9, 15, 20)), entry("t", local(2026, 9, 16, 11))]]
        let out = PhoneLedgerOverlay.apply(macPayload: mac, manifest: manifest(), entries: entries, countedAt: now, now: now)

        #expect(out.providers.map(\.id) == ["claude_code"], "codex has nothing current, so no tab")
        #expect(out.todayTokens == 1000)
        #expect(out.weekTokens == 2000 + 500)
        #expect(out.monthTokens == 2000 + 5000)
        #expect(out.burn?.tokensPerMinute == 1000.0 / 60, "only the ledger block — codex's rate is 14h old")
        #expect(out.lastUpdated == now)
        #expect(out.serverVersion == "9.9")
    }

    @Test func aTurnInBothTheMacLedgerAndACloudRecordCountsOnce() {
        let turn = entry("msg|req", local(2026, 9, 16, 10), tokens: 700)
        let out = PhoneLedgerOverlay.apply(macPayload: nil, manifest: manifest(),
                                           entries: ["claude_code": [turn, turn, entry("other", local(2026, 9, 16, 10, 5))]],
                                           countedAt: now, now: now)
        #expect(out.todayTokens == 1700)
    }

    /// Only providers the manifest names are recounted — without the Mac's full ledger, cloud-only
    /// entries would replace the Mac's own Claude usage with a fraction of it.
    @Test func providersOutsideTheManifestKeepTheMacNumbers() {
        let mac = macPayload(at: now.addingTimeInterval(-60), providers: [macSnapshot("claude_code", today: 999, week: 999, month: 999)])
        let out = PhoneLedgerOverlay.apply(macPayload: mac, manifest: manifest([]),
                                           entries: ["claude_code": [entry("t", now)]], countedAt: now, now: now)
        #expect(out.todayTokens == 999)
    }

    @Test func recountedProviderKeepsItsPlaceAndANewOneIsAppended() {
        let mac = macPayload(at: now.addingTimeInterval(-60), providers: [
            macSnapshot("codex", today: 5, week: 5, month: 5), macSnapshot("claude_code", today: 1, week: 1, month: 1),
        ])
        let other = PhoneUsageLedgerManifest.Provider(id: "gemini", displayName: "Gemini", reportsCost: false)
        let out = PhoneLedgerOverlay.apply(macPayload: mac, manifest: manifest([claude, other]),
                                           entries: ["claude_code": [entry("a", now)], "gemini": [entry("g", now, tokens: 10)]],
                                           countedAt: now, now: now)
        #expect(out.providers.map(\.id) == ["codex", "claude_code", "gemini"])
        #expect(out.providers[1].todayTokens == 1000)
        #expect(out.todayCost == 1 + (out.providers[1].todayCost), "gemini does not report cost")
    }

    /// Mac numbers still describe the current day while it is recent: kept as-is, burn included.
    @Test func freshMacNumbersForOtherProvidersAreKept() {
        let mac = macPayload(at: now.addingTimeInterval(-120), providers: [macSnapshot("codex", today: 50, week: 500, month: 5000, tpm: 12)])
        let out = PhoneLedgerOverlay.apply(macPayload: mac, manifest: manifest(), entries: [:], countedAt: now, now: now)
        #expect(out.providers.map(\.id) == ["codex"])
        #expect(out.todayTokens == 50)
        #expect(out.burn?.tokensPerMinute == 12)
        #expect(out.dailyTrend?.first?.totalTokens == 4950)
    }

    @Test func aMacSnapshotFromLastMonthContributesNothing() {
        let mac = macPayload(at: local(2026, 8, 31, 23), providers: [macSnapshot("codex", today: 50, week: 500, month: 5000, tpm: 12)])
        let out = PhoneLedgerOverlay.apply(macPayload: mac, manifest: manifest(), entries: [:],
                                           countedAt: local(2026, 9, 1, 9), now: local(2026, 9, 1, 9))
        #expect(out.monthTokens == 0)
        #expect(out.monthCost == 0)
        #expect(out.dailyTrend?.allSatisfy { $0.totalTokens == 0 } == true)
        #expect(out.burn == nil)
    }

    /// Late-night work keeps a 5-hour block alive after midnight: a carrier tab with zero today.
    @Test func activeBlockFromLastNightKeepsACarrierTab() {
        let justAfterMidnight = local(2026, 9, 16, 0, 30)
        let out = PhoneLedgerOverlay.apply(macPayload: nil, manifest: manifest(),
                                           entries: ["claude_code": [entry("n", local(2026, 9, 15, 23, 30))]],
                                           countedAt: justAfterMidnight, now: justAfterMidnight)
        #expect(out.providers.map(\.id) == ["claude_code"])
        #expect(out.todayTokens == 0)
        #expect((out.burn?.tokensPerMinute ?? 0) > 0)
    }

    @Test func aPastDepletionForecastIsDropped() {
        var mac = macPayload(at: now.addingTimeInterval(-3600), providers: [])
        mac = PhonePayload(todayTokens: 0, todayCost: 0, weekTokens: 0, monthTokens: 0, lastUpdated: mac.lastUpdated,
                           serverVersion: "", limits: nil, companion: nil, providers: [],
                           burn: PhoneBurnForecast(depletionDate: now.addingTimeInterval(-1), beforeReset: true, tokensPerMinute: 5))
        let out = PhoneLedgerOverlay.apply(macPayload: mac, manifest: manifest(), entries: [:], countedAt: now, now: now)
        #expect(out.burn == nil)
    }
}
