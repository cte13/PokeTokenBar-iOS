import Foundation
import Testing
@testable import PokeTokenBarShared

/// A scriptable stand-in for CloudKit. Counts what the sync asks for, so tests can check that
/// unchanged chunks are not fetched again.
private actor FakeCloud {
    var secret: String?
    var manifest: PhoneUsageLedgerManifest?
    var chunks: [String: Data] = [:]
    var cloud: [UsageCloudKit.CloudSessionRecord] = []
    var manifestFails = false
    private(set) var chunkRequests: [[String]] = []
    private(set) var cloudSince: [Date] = []

    func set(manifest: PhoneUsageLedgerManifest?, chunks: [PhoneUsageLedger.Chunk]) {
        self.manifest = manifest
        self.chunks = Dictionary(chunks.map { ($0.recordName, $0.payload) }, uniquingKeysWith: { a, _ in a })
    }
    func set(secret: String?) { self.secret = secret }
    func set(cloud: [UsageCloudKit.CloudSessionRecord]) { self.cloud = cloud }
    func set(manifestFails: Bool) { self.manifestFails = manifestFails }

    func fetchManifest() throws -> PhoneUsageLedgerManifest? {
        if manifestFails { throw CancellationError() }
        return manifest
    }
    func fetchChunks(_ names: [String]) -> [String: Data] {
        chunkRequests.append(names)
        return chunks.filter { names.contains($0.key) }
    }
    func fetchCloud(_ since: Date) -> [UsageCloudKit.CloudSessionRecord] {
        cloudSince.append(since)
        return cloud.filter { $0.updatedAt > since }
    }

    nonisolated var remote: PhoneUsageSync.Remote {
        PhoneUsageSync.Remote(
            fetchSecret: { await self.secret },
            fetchManifest: { try await self.fetchManifest() },
            fetchChunks: { await self.fetchChunks($0) },
            fetchCloudRecords: { _, since in await self.fetchCloud(since) })
    }
}

private let fmt = UsageAggregation.localDayFormatter()
private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 12))!
private let claude = PhoneUsageLedgerManifest.Provider(id: "claude_code", displayName: "Claude Code", reportsCost: true)
private let secret = Data((1...32).map(UInt8.init))

private func entry(_ id: String, _ date: Date, tokens: Int = 100) -> UsageEntry {
    UsageEntry(id: id, date: date, localDay: fmt.string(from: date), model: "claude-opus-5-5",
               input: tokens, output: 0, cacheWrite: 0, cacheRead: 0)
}

private func claudeLine(_ id: String, _ date: Date, tokens: Int = 100) -> String {
    let ts = ISO8601DateFormatter().string(from: date)
    return #"{"type":"assistant","timestamp":"\#(ts)","requestId":"\#(id)","message":{"id":"\#(id)","usage":{"input_tokens":\#(tokens)}}}"#
}

private func publish(_ cloud: FakeCloud, _ entries: [UsageEntry]) async throws {
    let chunks = try PhoneUsageLedger.chunks(provider: "claude_code", entries: entries)
    await cloud.set(manifest: PhoneUsageLedgerManifest(updatedAt: now, providers: [claude], chunks: chunks), chunks: chunks)
}

private func macPayload(todayTokens: Int, at date: Date) -> PhonePayload {
    PhonePayload(todayTokens: todayTokens, todayCost: 0, weekTokens: todayTokens, monthTokens: todayTokens,
                 lastUpdated: date, serverVersion: "1", limits: nil, companion: nil,
                 providers: [PhoneProviderSnapshot(id: "claude_code", displayName: "Claude Code",
                                                   todayTokens: todayTokens, todayCost: 0,
                                                   weekTokens: todayTokens, monthTokens: todayTokens)])
}

struct PhoneUsageSyncTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ptb-sync-\(UUID().uuidString)")

    @Test func withoutAManifestTheMacPayloadIsShownAsIs() async {
        let cloud = FakeCloud()
        let sync = PhoneUsageSync(directory: dir, remote: cloud.remote)
        await sync.update(macPayload: macPayload(todayTokens: 42, at: now))
        #expect(await sync.syncLedger(now: now))
        #expect(await sync.display(now: now)?.todayTokens == 42)
    }

    /// The whole point: Mac ledger + a cloud turn the Mac never saw, the Mac's payload hours old.
    @Test func ledgerAndCloudRecordsAreCountedTogetherOnce() async throws {
        let cloud = FakeCloud()
        let shared = entry("both|both", now.addingTimeInterval(-3600))  // Claude ids are message.id|requestId
        try await publish(cloud, [shared, entry("mac-only", now.addingTimeInterval(-7200))])
        let crypto = try CloudSessionCrypto(secret: secret)
        let jsonl = claudeLine("both", shared.date) + "\n" + claudeLine("cloud-only", now.addingTimeInterval(-60)) + "\n"
        await cloud.set(secret: secret.base64EncodedString())
        await cloud.set(cloud: [UsageCloudKit.CloudSessionRecord(
            recordName: crypto.recordName(rel: "p/s.jsonl", chunk: 0), updatedAt: now,
            payload: try crypto.seal(CloudSessionPayload(rel: "p/s.jsonl", chunk: 0, jsonl: jsonl)))])

        let sync = PhoneUsageSync(directory: dir, remote: cloud.remote)
        await sync.update(macPayload: macPayload(todayTokens: 200, at: now.addingTimeInterval(-3 * 3600)))
        #expect(await sync.syncLedger(now: now))
        let shown = await sync.display(now: now)
        #expect(shown?.todayTokens == 300)
        #expect(shown?.lastUpdated == now)
    }

    @Test func onlyChangedChunksAreFetchedAndRemovedOnesAreDropped() async throws {
        let cloud = FakeCloud()
        let yesterday = entry("y", now.addingTimeInterval(-86400))
        try await publish(cloud, [yesterday, entry("t", now)])
        let sync = PhoneUsageSync(directory: dir, remote: cloud.remote)
        await sync.syncLedger(now: now)
        try await publish(cloud, [yesterday, entry("t", now), entry("t2", now.addingTimeInterval(-10))])
        await sync.syncLedger(now: now)
        try await publish(cloud, [entry("t", now), entry("t2", now.addingTimeInterval(-10))])
        await sync.syncLedger(now: now)

        let requests = await cloud.chunkRequests
        #expect(requests.count == 2)
        #expect(requests.last == ["ul_claude_code_\(fmt.string(from: now))_0"])
        #expect(await sync.display(now: now)?.weekTokens == 200, "yesterday's chunk left the manifest")
    }

    /// Offline: keep counting from what is cached, and do not claim a fresh count.
    @Test func aFailedManifestReadKeepsTheCacheAndItsTimestamp() async throws {
        let cloud = FakeCloud()
        try await publish(cloud, [entry("t", now)])
        let sync = PhoneUsageSync(directory: dir, remote: cloud.remote)
        await sync.syncLedger(now: now)
        await cloud.set(manifestFails: true)
        #expect(await sync.syncLedger(now: now.addingTimeInterval(600)) == false)
        let shown = await sync.display(now: now.addingTimeInterval(600))
        #expect(shown?.todayTokens == 100)
        #expect(shown?.lastUpdated == now)
    }

    /// The widget and the app are separate processes over the same files.
    @Test func aSecondInstanceSeesTheFirstInstancesState() async throws {
        let cloud = FakeCloud()
        try await publish(cloud, [entry("t", now)])
        let app = PhoneUsageSync(directory: dir, remote: cloud.remote)
        let widget = PhoneUsageSync(directory: dir, remote: cloud.remote)
        _ = await widget.display(now: now)
        await app.syncLedger(now: now)
        #expect(await widget.display(now: now)?.todayTokens == 100)
    }

    @Test func anOlderMacPayloadDoesNotReplaceANewerOne() async {
        let sync = PhoneUsageSync(directory: dir, remote: FakeCloud().remote)
        await sync.update(macPayload: macPayload(todayTokens: 2, at: now))
        await sync.update(macPayload: macPayload(todayTokens: 1, at: now.addingTimeInterval(-60)))
        #expect(await sync.macPayload?.todayTokens == 2)
    }

    @Test func cloudPullsOverlapTheWatermarkAndANewSecretStartsOver() async throws {
        let cloud = FakeCloud()
        try await publish(cloud, [])
        let crypto = try CloudSessionCrypto(secret: secret)
        await cloud.set(secret: secret.base64EncodedString())
        await cloud.set(cloud: [UsageCloudKit.CloudSessionRecord(
            recordName: "cu_x", updatedAt: now,
            payload: try crypto.seal(CloudSessionPayload(rel: "p/s.jsonl", chunk: 0, jsonl: claudeLine("c", now) + "\n")))])
        let sync = PhoneUsageSync(directory: dir, remote: cloud.remote)
        await sync.syncLedger(now: now)
        await sync.syncLedger(now: now)
        await cloud.set(secret: Data(repeating: 5, count: 32).base64EncodedString())
        await sync.syncLedger(now: now)

        let since = await cloud.cloudSince
        #expect(since == [now.addingTimeInterval(-PhoneUsageSync.cloudRetention),
                          now.addingTimeInterval(-PhoneUsageSync.cloudOverlap),
                          now.addingTimeInterval(-PhoneUsageSync.cloudRetention)])
        #expect(await sync.display(now: now)?.todayTokens == 0, "the old secret's record no longer opens")
    }
}
