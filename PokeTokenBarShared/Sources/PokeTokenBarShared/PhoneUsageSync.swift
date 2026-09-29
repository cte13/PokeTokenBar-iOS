import Foundation

/// The iPhone side of counting without the Mac. The app and the widget both use it, sharing its
/// state through the App Group container:
///
/// 1. `update(macPayload:)` — the Mac's last payload (iCloud or LAN), kept raw. The overlay must
///    start from the Mac's own numbers every time; re-overlaying a displayed payload would
///    judge the Mac's freshness by the phone's timestamp.
/// 2. `syncLedger()` — the Mac's ledger (private DB, only changed chunks) and cloud-session
///    records (public DB, since the watermark), cached on disk.
/// 3. `display()` — `PhoneLedgerOverlay` over the cached state, or the Mac payload as-is when
///    the Mac has never published a ledger (older Mac builds).
public actor PhoneUsageSync {
    public static let shared = PhoneUsageSync()

    public struct Remote: Sendable {
        public var fetchPrivateKey: @Sendable () async throws -> String?
        public var fetchManifest: @Sendable () async throws -> PhoneUsageLedgerManifest?
        public var fetchChunks: @Sendable ([String]) async throws -> [String: Data]
        public var fetchCloudRecords: @Sendable (_ channel: String, _ since: Date) async throws -> [UsageCloudKit.CloudSessionRecord]

        public init(fetchPrivateKey: @escaping @Sendable () async throws -> String?,
                    fetchManifest: @escaping @Sendable () async throws -> PhoneUsageLedgerManifest?,
                    fetchChunks: @escaping @Sendable ([String]) async throws -> [String: Data],
                    fetchCloudRecords: @escaping @Sendable (String, Date) async throws -> [UsageCloudKit.CloudSessionRecord]) {
            self.fetchPrivateKey = fetchPrivateKey
            self.fetchManifest = fetchManifest
            self.fetchChunks = fetchChunks
            self.fetchCloudRecords = fetchCloudRecords
        }

        public static let cloudKit = Remote(
            fetchPrivateKey: { try await UsageCloudKit.fetchCloudSessionKey() },
            fetchManifest: { try await UsageCloudKit.fetchLedgerManifest() },
            fetchChunks: { try await UsageCloudKit.fetchLedgerChunks(names: $0) },
            fetchCloudRecords: { try await UsageCloudKit.fetchCloudSessionRecords(channel: $0, since: $1) })
    }

    /// Same rules as the Mac's mirror (`CloudSessionMirror`): re-read behind the watermark for
    /// container clock skew, and reach back past the month window on the first pull.
    public static let cloudOverlap: TimeInterval = 10 * 60
    public static let cloudRetention: TimeInterval = 40 * 24 * 3600

    struct State: Codable, Equatable {
        var macPayload: PhonePayload?
        var manifest: PhoneUsageLedgerManifest?
        /// Chunk record name → digest of the payload stored on disk.
        var chunkDigests: [String: String] = [:]
        /// Base64 device private key for cloud-session records (from the Mac, via the private DB).
        var privateKey: String?
        var cloudChannel: String?
        var cloudWatermark: Date?
        /// Cloud record name → its `updatedAt`, for pruning.
        var cloudRecords: [String: Date] = [:]
        /// Last time the ledger was read successfully — the freshness the dashboard shows.
        var ledgerSyncedAt: Date?
    }

    private let directory: URL
    private let remote: Remote
    private var state: State
    /// Decoded entries per chunk/record file. The key is the chunk digest or the record's
    /// `updatedAt`, so a rewritten file misses and nothing needs explicit invalidation.
    private var decoded: [String: (key: String, entries: [UsageEntry])] = [:]

    public init(directory: URL = PhoneUsageSync.defaultDirectory(), remote: Remote = .cloudKit) {
        self.directory = directory
        self.remote = remote
        self.state = Self.loadState(in: directory)
    }

    /// The app and the widget are separate processes over the same files: start every operation
    /// from what is on disk, not from what this process last saw.
    private static func loadState(in directory: URL) -> State {
        (try? Data(contentsOf: directory.appendingPathComponent("state.json")))
            .flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    private func reload() { state = Self.loadState(in: directory) }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: PayloadCache.appGroup)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("usage-ledger", isDirectory: true)
    }

    // MARK: - Mac payload

    /// Keeps the newer of the stored and the given payload (the LAN and iCloud paths can deliver
    /// them out of order).
    public func update(macPayload: PhonePayload) {
        reload()
        guard macPayload.lastUpdated >= (state.macPayload?.lastUpdated ?? .distantPast) else { return }
        state.macPayload = macPayload
        save()
    }

    public var macPayload: PhonePayload? {
        reload()
        return state.macPayload
    }

    // MARK: - Ledger

    /// Reads what changed since the last sync. Returns false when the manifest could not be read;
    /// the cached state then stays as it was (including `ledgerSyncedAt`). A failed cloud pull does
    /// not fail the sync — the Mac's ledger alone is still a correct, if less fresh, count.
    @discardableResult
    public func syncLedger(now: Date = Date()) async -> Bool {
        let manifest: PhoneUsageLedgerManifest?
        do {
            manifest = try await remote.fetchManifest()
        } catch {
            return false
        }
        reload()
        if let manifest {
            let wanted = Dictionary(manifest.records.map { ($0.name, $0.digest) }, uniquingKeysWith: { a, _ in a })
            let stale = wanted.filter { state.chunkDigests[$0.key] != $0.value }.map(\.key)
            let fetched: [String: Data]
            do {
                fetched = stale.isEmpty ? [:] : try await remote.fetchChunks(stale.sorted())
            } catch {
                return false
            }
            for (name, data) in fetched {
                write(data, to: chunkURL(name))
                state.chunkDigests[name] = wanted[name]
            }
            for name in state.chunkDigests.keys where wanted[name] == nil {
                try? FileManager.default.removeItem(at: chunkURL(name))
                state.chunkDigests[name] = nil
            }
        }
        state.manifest = manifest
        await syncCloudSessions(now: now)
        state.ledgerSyncedAt = now
        save()
        return true
    }

    private func syncCloudSessions(now: Date) async {
        if let key = try? await remote.fetchPrivateKey() { state.privateKey = key }
        guard let key = state.privateKey, let crypto = try? CloudSessionCrypto(base64PrivateKey: key) else { return }
        if state.cloudChannel != crypto.channel {
            // New key: its records are a different set. Drop the old ones and start over.
            for name in state.cloudRecords.keys { try? FileManager.default.removeItem(at: cloudURL(name)) }
            state.cloudRecords = [:]
            state.cloudWatermark = nil
            state.cloudChannel = crypto.channel
        }
        let since = state.cloudWatermark.map { $0.addingTimeInterval(-Self.cloudOverlap) }
            ?? now.addingTimeInterval(-Self.cloudRetention)
        guard let records = try? await remote.fetchCloudRecords(crypto.channel, since) else { return }
        for record in records {
            write(record.payload, to: cloudURL(record.recordName))
            state.cloudRecords[record.recordName] = record.updatedAt
            state.cloudWatermark = max(state.cloudWatermark ?? record.updatedAt, record.updatedAt)
        }
        let cutoff = now.addingTimeInterval(-Self.cloudRetention)
        for (name, updatedAt) in state.cloudRecords where updatedAt < cutoff {
            try? FileManager.default.removeItem(at: cloudURL(name))
            state.cloudRecords[name] = nil
        }
    }

    // MARK: - Display

    /// The payload the dashboard and widget show. nil only when there is neither a Mac payload nor
    /// a ledger to count from.
    public func display(now: Date = Date()) -> PhonePayload? {
        reload()
        guard let manifest = state.manifest else { return state.macPayload }
        let fmt = UsageAggregation.localDayFormatter()
        var entries: [String: [UsageEntry]] = [:]
        let providerByChunk = Dictionary(manifest.records.map { ($0.name, $0.provider) }, uniquingKeysWith: { a, _ in a })
        for (name, digest) in state.chunkDigests {
            guard let provider = providerByChunk[name] else { continue }
            entries[provider, default: []] += cachedEntries(name, key: digest) {
                (try? Data(contentsOf: chunkURL(name))).flatMap { try? PhoneUsageLedger.decode(payload: $0, fmt: fmt) } ?? []
            }
        }
        if let key = state.privateKey, let crypto = try? CloudSessionCrypto(base64PrivateKey: key) {
            for (name, updatedAt) in state.cloudRecords {
                entries[CloudSessionCrypto.providerID, default: []] += cachedEntries(
                    name, key: "\(updatedAt.timeIntervalSince1970)") {
                    (try? Data(contentsOf: cloudURL(name))).flatMap { try? crypto.open($0).entries(fmt: fmt) } ?? []
                }
            }
        }
        return PhoneLedgerOverlay.apply(macPayload: state.macPayload, manifest: manifest, entries: entries,
                                        countedAt: state.ledgerSyncedAt ?? .distantPast, now: now)
    }

    // MARK: - Storage

    private func cachedEntries(_ name: String, key: String, load: () -> [UsageEntry]) -> [UsageEntry] {
        if let hit = decoded[name], hit.key == key { return hit.entries }
        let entries = load()
        decoded[name] = (key, entries)
        return entries
    }

    private func chunkURL(_ name: String) -> URL { directory.appendingPathComponent("chunks").appendingPathComponent(safe(name)) }
    private func cloudURL(_ name: String) -> URL { directory.appendingPathComponent("cloud").appendingPathComponent(safe(name)) }

    /// Record names come from CloudKit; keep them to one path component.
    private func safe(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
    }

    private func write(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private func save() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: directory.appendingPathComponent("state.json"), options: .atomic)
    }
}
