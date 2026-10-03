import Foundation
import Testing
@testable import PokeTokenBarShared

private let usageJSON = #"""
{"five_hour":{"utilization":42,"resets_at":"2026-10-02T09:00:00Z"},
 "seven_day":{"utilization":12,"resets_at":"2026-10-06T00:00:00Z"},
 "seven_day_opus":null,"seven_day_sonnet":null,
 "limits":[{"kind":"session","percent":42},{"kind":"weekly_all","percent":12},
           {"kind":"weekly_scoped","percent":30,"resets_at":"2026-10-06T00:00:00Z","scope":{"model":{"display_name":"Fable"}}}]}
"""#

private func fresh() throws -> LimitStatus {
    try JSONDecoder().decode(LimitStatus.self, from: Data(usageJSON.utf8))
}

private let macLimits = PhoneLimitStatus(
    claude5h: PhoneLimitWindow(label: "Claude 5시간", utilization: 5, resetsAt: nil, windowDuration: 18000),
    claudeWeekly: PhoneLimitWindow(label: "Claude 주간", utilization: 3, resetsAt: nil),
    claudeOpusWeekly: nil, claudeSonnetWeekly: nil,
    claudeScoped: [PhoneLimitWindow(label: "Claude 주간 Fable", utilization: 1, resetsAt: nil, scopeModel: "Fable")],
    codexPrimary: PhoneLimitWindow(label: "Codex 5시간", utilization: 54, resetsAt: nil),
    codexSecondary: nil, planDisplay: "Max 20x", warnThreshold: 70, critThreshold: 90)

struct PhoneClaudeLimitsTests {
    @Test func windowsFollowTheMacRulesAndCarryTheScopedModel() throws {
        let w = PhoneClaudeLimits.windows(try fresh(), labels: .reusing(nil))
        #expect(w.fiveHour?.utilization == 42)
        #expect(w.fiveHour?.windowDuration == LimitWindowSpan.fiveHour)
        #expect(w.fiveHour?.resetsAt == ISO8601Parser.date(from: "2026-10-02T09:00:00Z"))
        #expect(w.weekly?.utilization == 12)
        #expect(w.opusWeekly == nil, "no utilization → no window, like the Mac popover")
        #expect(w.scoped?.map(\.scopeModel) == ["Fable"], "session/weekly_all duplicate the legacy rows")
        #expect(w.scoped?.first?.utilization == 30)
    }

    /// A recount must not rename anything: labels come from the Mac's last payload, matched by
    /// window — scoped ones by model, never by the localized text.
    @Test func overlayKeepsTheMacLabelsAndEverythingThatIsNotClaude() throws {
        let out = PhoneClaudeLimits.overlay(macLimits, fresh: try fresh())
        #expect(out.claude5h?.label == "Claude 5시간")
        #expect(out.claude5h?.utilization == 42)
        #expect(out.claudeWeekly?.label == "Claude 주간")
        #expect(out.claudeScoped?.first?.label == "Claude 주간 Fable")
        #expect(out.claudeScoped?.first?.utilization == 30)
        #expect(out.codexPrimary == macLimits.codexPrimary)
        #expect(out.planDisplay == "Max 20x")
        #expect(out.warnThreshold == 70 && out.critThreshold == 90)
    }

    @Test func windowsTheMacNeverSentGetEnglishLabels() throws {
        let out = PhoneClaudeLimits.overlay(nil, fresh: try fresh())
        #expect(out.claude5h?.label == "Claude 5h")
        #expect(out.claudeScoped?.first?.label == "Claude Weekly Fable")
    }
}

// MARK: - The phone's own fetch

private actor FakeClaude {
    var key: SharedClaudeSessionKey?
    var keyFetchFails = false
    var status = 200
    var retryAfter: String?
    private(set) var requests: [URLRequest] = []

    func set(key: SharedClaudeSessionKey?) { self.key = key }
    func set(status: Int, retryAfter: String? = nil) { self.status = status; self.retryAfter = retryAfter }
    func set(keyFetchFails: Bool) { self.keyFetchFails = keyFetchFails }

    func fetchKey() throws -> SharedClaudeSessionKey? {
        if keyFetchFails { throw URLError(.notConnectedToInternet) }
        return key
    }

    func fetch(_ request: URLRequest) -> (Data, HTTPURLResponse) {
        requests.append(request)
        let headers = retryAfter.map { ["Retry-After": $0] } ?? [:]
        return (Data(usageJSON.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }

    nonisolated var remote: PhoneUsageSync.Remote {
        PhoneUsageSync.Remote(
            fetchPrivateKey: { nil }, fetchManifest: { nil }, fetchChunks: { _ in [:] },
            fetchCloudRecords: { _, _ in [] },
            fetchClaudeSessionKey: { try await self.fetchKey() },
            fetchClaudeUsage: { await self.fetch($0) })
    }
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let key = SharedClaudeSessionKey(key: "sk-ant-sid01-test", organizationID: "org-1")

private func macPayload(at date: Date) -> PhonePayload {
    PhonePayload(todayTokens: 1, todayCost: 0, weekTokens: 1, monthTokens: 1, lastUpdated: date,
                 serverVersion: "1", limits: macLimits, companion: nil, providers: [])
}

struct PhoneUsageSyncClaudeLimitsTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-limits-\(UUID().uuidString)")

    @Test func withoutASharedKeyNothingIsRequested() async {
        let claude = FakeClaude()
        let sync = PhoneUsageSync(directory: dir, remote: claude.remote)
        #expect(await sync.syncClaudeLimits(now: t0) == false)
        #expect(await claude.requests.isEmpty)
    }

    /// Sends the request the Mac sends, and shows the result only while it is newer than the Mac's.
    @Test func freshLimitsReplaceTheMacsOnlyWhileNewer() async throws {
        let claude = FakeClaude()
        await claude.set(key: key)
        let sync = PhoneUsageSync(directory: dir, remote: claude.remote)
        await sync.update(macPayload: macPayload(at: t0.addingTimeInterval(-600)))
        #expect(await sync.syncClaudeLimits(now: t0))

        let request = try #require(await claude.requests.first)
        #expect(request.url == ClaudeWebUsage.usageURL(organizationID: "org-1"))
        #expect(request.value(forHTTPHeaderField: "Cookie") == "sessionKey=sk-ant-sid01-test")
        #expect(await sync.display(now: t0)?.limits?.claude5h?.utilization == 42)

        await sync.update(macPayload: macPayload(at: t0.addingTimeInterval(60)))
        #expect(await sync.display(now: t0)?.limits?.claude5h?.utilization == 5, "the Mac's newer value wins")
    }

    /// The app and the widget share one budget: one request per cadence interval.
    @Test func requestsKeepToThePollCadence() async {
        let claude = FakeClaude()
        await claude.set(key: key)
        let sync = PhoneUsageSync(directory: dir, remote: claude.remote)
        await sync.syncClaudeLimits(now: t0)
        await sync.syncClaudeLimits(now: t0.addingTimeInterval(LimitsPollCadence.minimumInterval - 1))
        let widget = PhoneUsageSync(directory: dir, remote: claude.remote)
        await widget.syncClaudeLimits(now: t0.addingTimeInterval(60))
        #expect(await claude.requests.count == 1)
        await sync.syncClaudeLimits(now: t0.addingTimeInterval(LimitsPollCadence.minimumInterval))
        #expect(await claude.requests.count == 2)
    }

    @Test func aRejectedKeyIsNotRetriedUntilTheMacSharesANewOne() async {
        let claude = FakeClaude()
        await claude.set(key: key)
        await claude.set(status: 401)
        let sync = PhoneUsageSync(directory: dir, remote: claude.remote)
        await sync.syncClaudeLimits(now: t0)
        await sync.syncClaudeLimits(now: t0.addingTimeInterval(3600))
        #expect(await claude.requests.count == 1)

        await claude.set(status: 200)
        await claude.set(key: SharedClaudeSessionKey(key: "sk-ant-sid01-new", organizationID: "org-1"))
        #expect(await sync.syncClaudeLimits(now: t0.addingTimeInterval(3601)))
        #expect(await claude.requests.count == 2)
    }

    @Test(arguments: [(429, "120", 120.0), (429, nil, 600.0), (403, nil, 1800.0)])
    func throttledOrForbiddenBacksOff(status: Int, retryAfter: String?, wait: TimeInterval) async {
        let claude = FakeClaude()
        await claude.set(key: key)
        await claude.set(status: status, retryAfter: retryAfter)
        let sync = PhoneUsageSync(directory: dir, remote: claude.remote)
        await sync.syncClaudeLimits(now: t0)
        await claude.set(status: 200)
        // Past the cadence, still inside the backoff: nothing is sent.
        let insideBackoff = max(LimitsPollCadence.minimumInterval, wait - 1)
        if insideBackoff < wait {
            await sync.syncClaudeLimits(now: t0.addingTimeInterval(insideBackoff))
            #expect(await claude.requests.count == 1)
        }
        #expect(await sync.syncClaudeLimits(now: t0.addingTimeInterval(max(wait, LimitsPollCadence.minimumInterval))))
    }

    /// Removing the key on the Mac must stop the phone showing limits fetched with it.
    @Test func aRemovedKeyDropsThePhonesLimits() async {
        let claude = FakeClaude()
        await claude.set(key: key)
        let sync = PhoneUsageSync(directory: dir, remote: claude.remote)
        await sync.update(macPayload: macPayload(at: t0.addingTimeInterval(-600)))
        await sync.syncClaudeLimits(now: t0)
        await claude.set(key: nil)
        await sync.syncClaudeLimits(now: t0.addingTimeInterval(1))
        #expect(await sync.display(now: t0)?.limits?.claude5h?.utilization == 5)
    }

    /// Offline: an unreadable key record is not a removed key.
    @Test func aFailedKeyFetchKeepsTheCachedKey() async {
        let claude = FakeClaude()
        await claude.set(key: key)
        let sync = PhoneUsageSync(directory: dir, remote: claude.remote)
        await sync.syncClaudeLimits(now: t0)
        await claude.set(keyFetchFails: true)
        #expect(await sync.syncClaudeLimits(now: t0.addingTimeInterval(LimitsPollCadence.minimumInterval)))
    }
}
