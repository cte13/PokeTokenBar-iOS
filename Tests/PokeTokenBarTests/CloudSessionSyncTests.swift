import XCTest
import PokeTokenBarShared
@testable import PokeTokenBar

// Claude Code on the web → Mac mirror, and Mac → iPhone usage ledger. CloudKit is injected out;
// the production closures sit behind CloudSyncGate and `AppEnv.isBundledApp`.

private let deviceKey = Data((1...32).map(UInt8.init))
private func line(_ id: String, _ date: Date, tokens: Int = 100) -> String {
    let ts = ISO8601DateFormatter().string(from: date)
    return #"{"type":"assistant","timestamp":"\#(ts)","requestId":"r\#(id)","message":{"id":"m\#(id)","model":"claude-opus-5-5","usage":{"input_tokens":\#(tokens),"output_tokens":0}}}"#
}

private actor Calls<T: Sendable> {
    var values: [T] = []
    func append(_ v: T) { values.append(v) }
}

private final class LedgerProvider: UsageProvider, @unchecked Sendable {
    let id: String
    let displayName: String
    nonisolated(unsafe) var ledger: [LocalUsageReader.Entry]?
    init(id: String, ledger: [LocalUsageReader.Entry]?) {
        self.id = id
        self.displayName = id.uppercased()
        self.ledger = ledger
    }
    func fetchDaily() async throws -> DailyUsage? {
        DailyUsage(date: LocalUsageReader.todayKey(), inputTokens: 1, outputTokens: 0, cacheCreationTokens: 0,
                   cacheReadTokens: 0, totalTokens: 1, totalCost: 0)
    }
    func fetchEnrichment() async -> ProviderEnrichment { ProviderEnrichment() }
    func phoneLedgerEntries(now: Date) async -> [LocalUsageReader.Entry]? { ledger }
}

final class CloudSessionMirrorTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-mirror-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func record(_ crypto: CloudSessionCrypto, rel: String, chunk: Int = 0, jsonl: String,
                        at date: Date) throws -> UsageCloudKit.CloudSessionRecord {
        UsageCloudKit.CloudSessionRecord(recordName: crypto.recordName(rel: rel, chunk: chunk), updatedAt: date,
                                         payload: try crypto.seal(CloudSessionPayload(rel: rel, chunk: chunk, jsonl: jsonl)))
    }

    /// End to end on the Mac side: a record becomes a file that the Claude scan counts, attributed
    /// to the session from its path — including a subagent chunk, counted with its parent.
    func testPulledRecordsAreCountedByTheClaudeScanUnderTheirSession() async throws {
        let crypto = try CloudSessionCrypto(privateKey: deviceKey)
        let now = Date()
        let records = [
            try record(crypto, rel: "proj/sess-1.jsonl", jsonl: line("1", now) + "\n", at: now),
            try record(crypto, rel: "proj/sess-1/subagents/agent-a.jsonl", chunk: 1, jsonl: line("2", now) + "\n", at: now),
        ]
        let mirror = CloudSessionMirror(root: root, fetch: { _, _ in records })
        let outcome = await mirror.pull(crypto: crypto, now: now)
        XCTAssertEqual(outcome, .init(written: 2, rejected: 0))

        let roots = LocalUsageReader.computeClaudeProjectRoots(
            configDirValue: nil, cloudSessionsRoot: root, home: root.appendingPathComponent("home"))
        XCTAssertTrue(roots.map(\.path).contains(root.resolvingSymlinksInPath().standardizedFileURL.path))
        let entries = LocalUsageReader.claudeEntries(modifiedSince: now.addingTimeInterval(-60), roots: [root])
        XCTAssertEqual(entries.map(\.total).reduce(0, +), 200)
        XCTAssertEqual(Set(entries.flatMap(\.claudeSessionIDs)), ["sess-1"])
    }

    func testUnchangedRecordIsNotRewrittenAndTheNextPullOverlapsTheWatermark() async throws {
        let crypto = try CloudSessionCrypto(privateKey: deviceKey)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let rec = try record(crypto, rel: "p/s.jsonl", jsonl: "x\n", at: t0)
        let sinces = Calls<Date>()
        let mirror = CloudSessionMirror(root: root, fetch: { _, since in await sinces.append(since); return [rec] })

        let first = await mirror.pull(crypto: crypto, now: t0)
        let second = await mirror.pull(crypto: crypto, now: t0.addingTimeInterval(60))
        XCTAssertEqual(first?.written, 1)
        XCTAssertEqual(second?.written, 0)
        let values = await sinces.values
        XCTAssertEqual(values.first, t0.addingTimeInterval(-CloudSessionMirror.initialLookback))
        XCTAssertEqual(values.last, t0.addingTimeInterval(-CloudSessionMirror.overlap))
    }

    /// A record this key cannot open is skipped — never written — but the watermark still
    /// moves past it, or every pull would re-download it forever.
    func testForeignRecordIsRejectedAndSkippedPast() async throws {
        let mine = try CloudSessionCrypto(privateKey: deviceKey)
        let theirs = try CloudSessionCrypto(privateKey: Data(repeating: 9, count: 32))
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let foreign = try record(theirs, rel: "p/s.jsonl", jsonl: "x\n", at: t0)
        let sinces = Calls<Date>()
        let mirror = CloudSessionMirror(root: root, fetch: { _, since in await sinces.append(since); return [foreign] })

        let outcome = await mirror.pull(crypto: mine, now: t0)
        XCTAssertEqual(outcome, .init(written: 0, rejected: 1))
        _ = await mirror.pull(crypto: mine, now: t0)
        let last = await sinces.values.last
        XCTAssertEqual(last, t0.addingTimeInterval(-CloudSessionMirror.overlap))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("c0").path))
    }

    /// A failed fetch (offline, missing index, gate disabled) must not advance anything.
    func testFailedFetchLeavesTheWatermarkAlone() async throws {
        let crypto = try CloudSessionCrypto(privateKey: deviceKey)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let sinces = Calls<Date>()
        let failing = CloudSessionMirror(root: root, fetch: { _, since in
            await sinces.append(since)
            throw CloudSyncGate.Disabled()
        })
        let outcome = await failing.pull(crypto: crypto, now: t0)
        XCTAssertNil(outcome)
        _ = await failing.pull(crypto: crypto, now: t0.addingTimeInterval(600))
        let values = await sinces.values
        XCTAssertEqual(values.last, t0.addingTimeInterval(600 - CloudSessionMirror.initialLookback))
    }

    /// Changing the key changes the channel: its history must be pulled from the start.
    func testANewKeyStartsFromTheInitialLookback() async throws {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let sinces = Calls<Date>()
        let mirror = CloudSessionMirror(root: root, fetch: { _, since in await sinces.append(since); return [] })
        _ = await mirror.pull(crypto: try CloudSessionCrypto(privateKey: deviceKey), now: t0)
        let rec = try record(try CloudSessionCrypto(privateKey: deviceKey), rel: "p/s.jsonl", jsonl: "", at: t0)
        let withRecord = CloudSessionMirror(root: root, fetch: { _, since in await sinces.append(since); return [rec] })
        _ = await withRecord.pull(crypto: try CloudSessionCrypto(privateKey: deviceKey), now: t0)
        _ = await withRecord.pull(crypto: try CloudSessionCrypto(privateKey: Data(repeating: 3, count: 32)), now: t0)
        let last = await sinces.values.last
        XCTAssertEqual(last, t0.addingTimeInterval(-CloudSessionMirror.initialLookback))
    }

    /// Second line of defence: even a payload that bypassed `open` cannot escape the mirror folder.
    func testWriteRefusesAPathOutsideTheMirror() async throws {
        let mirror = CloudSessionMirror(root: root, fetch: { _, _ in [] })
        do {
            _ = try await mirror.write(CloudSessionPayload(rel: "../../escape.jsonl", chunk: 0, jsonl: "x"))
            XCTFail("expected unsafePath")
        } catch {
            XCTAssertEqual(error as? CloudSessionCrypto.Failure, .unsafePath)
        }
    }
}

final class CloudSessionKeyStoreTests: XCTestCase {
    func testSaveRejectsAnInvalidKeyAndStoresAValidOneOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-key-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CloudSessionKeyStore(fileURL: dir.appendingPathComponent("k.txt"))
        XCTAssertThrowsError(try store.save("short"))
        XCTAssertNil(store.load())

        try store.save("  \(deviceKey.base64EncodedString())\n")
        XCTAssertEqual(store.load()?.channel, try CloudSessionCrypto(privateKey: deviceKey).channel)
        let perms = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.int16Value, 0o600)
        store.clear()
        XCTAssertNil(store.load())
    }
}

/// These reach the CloudKit calls through `CloudSyncGate`. The test runner has no iCloud
/// entitlement, so a helper that bypassed the gate would kill the suite with SIGTRAP instead of
/// logging `Disabled` — running them here is the regression guard (defect log, CloudKit section).
@MainActor
final class CloudSessionSettingsTests: XCTestCase {
    func testGenerateStoresAKeyAndSyncsThroughTheGateAndClearRemovesIt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-settings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CloudSessionKeyStore(fileURL: dir.appendingPathComponent("k.txt"))

        CloudSessionSettings.publish(store: store)   // nothing saved: no sync attempt
        let publicKey = try CloudSessionSettings.generate(store: store)
        XCTAssertEqual(store.load()?.publicKeyBase64, publicKey)
        XCTAssertEqual(Data(base64Encoded: publicKey)?.count, 32)
        CloudSessionSettings.clear(store: store)
        XCTAssertNil(store.load())
        try await Task.sleep(nanoseconds: 100_000_000)   // let the gated sync tasks run
    }

    /// A reinstalled Mac has no local key: it adopts the one in iCloud, so records already sealed
    /// to that key stay readable. A Mac that has a key keeps it, whatever iCloud holds.
    func testLaunchAdoptsTheICloudKeyOnlyWhenThereIsNoLocalOne() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-launch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CloudSessionKeyStore(fileURL: dir.appendingPathComponent("k.txt"))
        let remote = deviceKey.base64EncodedString()

        let adopted = await CloudSessionSettings.syncAtLaunch(store: store, fetch: { remote })
        XCTAssertTrue(adopted)
        XCTAssertEqual(store.loadRaw(), remote)

        try store.save(CloudSessionCrypto.generatePrivateKey())
        let local = store.loadRaw()
        let replaced = await CloudSessionSettings.syncAtLaunch(store: store, fetch: { remote })
        XCTAssertFalse(replaced)
        XCTAssertEqual(store.loadRaw(), local)

        store.clear()
        let nothing = await CloudSessionSettings.syncAtLaunch(store: store, fetch: { throw CloudSyncGate.Disabled() })
        XCTAssertFalse(nothing)
        XCTAssertNil(store.loadRaw())
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    func testMirrorReportsItsLastPull() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-lastpull-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let mirror = CloudSessionMirror(root: root, fetch: { _, _ in [] })
        let lastBefore = await mirror.lastPull()
        XCTAssertNil(lastBefore)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        _ = await mirror.pull(crypto: try CloudSessionCrypto(privateKey: deviceKey), now: t0)
        let lastAfter = await mirror.lastPull()
        XCTAssertEqual(lastAfter, t0)
    }
}

final class PhoneLedgerPublisherTests: XCTestCase {
    private var stateURL: URL!
    private let provider = PhoneUsageLedgerManifest.Provider(id: "claude_code", displayName: "Claude Code", reportsCost: true)

    override func setUp() {
        super.setUp()
        stateURL = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-ledger-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: stateURL)
        super.tearDown()
    }

    private func entry(_ id: String, _ day: Int, hour: Int = 10) -> LocalUsageReader.Entry {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
        return LocalUsageReader.Entry(id: id, date: date, localDay: LocalUsageReader.localDayFormatter().string(from: date),
                                      model: "claude-opus-5-5", input: 10, output: 0, cacheWrite: 0, cacheRead: 0)
    }

    private typealias Upload = (chunks: [String], deleting: [String], providers: [String])

    func testUploadsOnlyChangedChunksDeletesDaysThatLeftAndRetriesAfterAFailure() async {
        let uploads = Calls<Upload>()
        let failNext = Calls<Bool>()
        let publisher = PhoneLedgerPublisher(stateURL: stateURL, upload: { chunks, deleting, manifest in
            if await failNext.values.last == true { throw CloudSyncGate.Disabled() }
            await uploads.append((chunks.map(\.recordName), deleting, manifest.providers.map(\.id)))
        })
        let day15 = entry("a", 15), day16 = entry("b", 16)

        let first = await publisher.publish([.init(provider: provider, entries: [day15, day16])])
        XCTAssertEqual(first, 2)
        let unchanged = await publisher.publish([.init(provider: provider, entries: [day16, day15])])
        XCTAssertNil(unchanged, "same entries, different order: nothing to upload")

        await failNext.append(true)
        let failed = await publisher.publish([.init(provider: provider, entries: [day15, day16, entry("c", 16, hour: 11)])])
        XCTAssertNil(failed)
        await failNext.append(false)
        let retried = await publisher.publish([.init(provider: provider, entries: [day15, day16, entry("c", 16, hour: 11)])])
        XCTAssertEqual(retried, 1, "the failed chunk is retried; the untouched day is not")

        _ = await publisher.publish([.init(provider: provider, entries: [day16, entry("c", 16, hour: 11)])])
        let values = await uploads.values
        XCTAssertEqual(values.map(\.chunks), [["ul_claude_code_2026-09-15_0", "ul_claude_code_2026-09-16_0"],
                                              ["ul_claude_code_2026-09-16_0"], []])
        XCTAssertEqual(values.last?.deleting, ["ul_claude_code_2026-09-15_0"])
    }

    /// A provider that stops publishing (hidden on the Mac) must leave the manifest, so the phone
    /// goes back to the Mac's numbers for it instead of recounting from a stale ledger.
    func testDroppingAProviderPublishesAManifestWithoutIt() async {
        let uploads = Calls<Upload>()
        let publisher = PhoneLedgerPublisher(stateURL: stateURL, upload: { chunks, deleting, manifest in
            await uploads.append((chunks.map(\.recordName), deleting, manifest.providers.map(\.id)))
        })
        _ = await publisher.publish([.init(provider: provider, entries: [entry("a", 15)])])
        _ = await publisher.publish([])
        let values = await uploads.values
        XCTAssertEqual(values.last?.providers, [])
        XCTAssertEqual(values.last?.deleting, ["ul_claude_code_2026-09-15_0"])
    }

    func testNothingToPublishOnAFreshMacMakesNoCall() async {
        let uploads = Calls<Upload>()
        let publisher = PhoneLedgerPublisher(stateURL: stateURL, upload: { chunks, deleting, manifest in
            await uploads.append((chunks.map(\.recordName), deleting, manifest.providers.map(\.id)))
        })
        let result = await publisher.publish([])
        XCTAssertNil(result)
        let count = await uploads.values.count
        XCTAssertEqual(count, 0)
    }
}

@MainActor
final class UsageStoreCloudSessionTests: XCTestCase {
    nonisolated(unsafe) private var defaults: UserDefaults!
    nonisolated(unsafe) private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ptb-cloud-test-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// Only providers that opt in reach the ledger, and a hidden one does not — whatever its id.
    func testRefreshPublishesOptedInVisibleProvidersOnly() async throws {
        let e = LocalUsageReader.Entry(id: "x", date: Date(), localDay: LocalUsageReader.todayKey(), model: "m",
                                       input: 1, output: 0, cacheWrite: 0, cacheRead: 0)
        let published = Calls<[String]>()
        let store = UsageStore(
            providers: [LedgerProvider(id: "alpha", ledger: [e]), LedgerProvider(id: "beta", ledger: nil),
                        LedgerProvider(id: "gamma", ledger: [e])],
            pullCloudSessions: { false },
            publishPhoneLedger: { sources in await published.append(sources.map(\.provider.id)) },
            autoRefresh: false, defaults: defaults)
        store.setProvider("gamma", visible: false)
        await store.refresh()
        try await waitUntil { await published.values.last == ["alpha"] }
    }

    /// Mirrored files only exist after the pull, so a pull that changed something must trigger
    /// another refresh — otherwise cloud turns wait for the next poll (minutes).
    func testAPullThatWroteFilesTriggersAnotherRefresh() async throws {
        let pulls = Calls<Int>()
        let store = UsageStore(
            providers: [LedgerProvider(id: "alpha", ledger: nil)],
            pullCloudSessions: {
                await pulls.append(1)
                return await pulls.values.count == 1
            },
            publishPhoneLedger: { _ in },
            autoRefresh: false, defaults: defaults)
        await store.refresh()
        try await waitUntil { await pulls.values.count == 2 }
        try await Task.sleep(nanoseconds: 200_000_000)
        let count = await pulls.values.count
        XCTAssertEqual(count, 2, "an unchanged pull does not loop")
    }

    private func waitUntil(_ condition: @escaping () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<100 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("condition not met", file: file, line: line)
    }
}

final class PhoneProviderSnapshotBuilderTests: XCTestCase {
    func testEachProviderCarriesItsOwnPeriodsBurnAndSeries() {
        let today = LocalUsageReader.todayKey()
        let snapshot = ProviderSnapshot(
            providerID: "claude_code", displayName: "Claude Code",
            today: DailyUsage(date: today, inputTokens: 1, outputTokens: 2, cacheCreationTokens: 3, cacheReadTokens: 4,
                              totalTokens: 10, totalCost: 1.5),
            activeBlock: BlockUsage(id: "b", startTime: "", endTime: "", isActive: true, totalTokens: 10,
                                    costUSD: 1, tokensPerMinute: 7),
            weekTotal: PeriodUsage(period: "w", totalTokens: 100, totalCost: 2),
            monthTotal: PeriodUsage(period: "m", totalTokens: 1000, totalCost: 3),
            monthDaily: [DailyUsage(date: today, inputTokens: 0, outputTokens: 0, cacheCreationTokens: 0,
                                    cacheReadTokens: 0, totalTokens: 10, totalCost: 1.5)],
            fetchedAt: Date())
        let out = AppDelegate.phoneProviderSnapshots([snapshot], todayKey: today)
        XCTAssertEqual(out.first?.weekTokens, 100)
        XCTAssertEqual(out.first?.monthCost, 3)
        XCTAssertEqual(out.first?.tokensPerMinute, 7)
        XCTAssertEqual(out.first?.monthDaily, [PhoneDailyTrend(date: today, totalTokens: 10, totalCost: 1.5, isToday: true)])
    }
}
