import Foundation
import PokeTokenBarShared

// Counting Claude Code on the web, and counting on the iPhone with the Mac off.
//
// - Cloud sessions run in disposable containers; a hook there (`scripts/cloud-session-sync`)
//   uploads encrypted, usage-only transcript chunks to the public CloudKit database.
//   `CloudSessionMirror` pulls them and writes each chunk as a transcript file under a folder that
//   `LocalUsageReader` scans as a Claude root, so every Mac number (totals, burn, companion)
//   includes cloud work with no special casing.
// - `PhoneLedgerPublisher` uploads this Mac's own entries to the private database so the phone
//   can count on its own (`PhoneLedgerOverlay`).
// Every CloudKit call goes through `CloudSyncGate`.

/// The device private key for cloud-session records (X25519, base64). The cloud environment only
/// ever holds the matching public key. A 0600 file beside `session-key.json`, not Keychain —
/// `CredentialFileProtection` explains why.
struct CloudSessionKeyStore: Sendable {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? AppStatePaths.directory().appendingPathComponent("cloud-session-key.txt")
    }

    func load() -> CloudSessionCrypto? {
        loadRaw().flatMap { try? CloudSessionCrypto(base64PrivateKey: $0) }
    }

    func loadRaw() -> String? {
        (try? String(contentsOf: fileURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Rejects anything that is not a valid 32-byte private key.
    func save(_ base64PrivateKey: String) throws {
        let trimmed = base64PrivateKey.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try CloudSessionCrypto(base64PrivateKey: trimmed)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: fileURL)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil,
                                       attributes: [.posixPermissions: NSNumber(value: Int16(0o600))])
        try Data(trimmed.utf8).write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: fileURL.path)
        CredentialFileProtection.excludeFromBackup(fileURL)
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

/// Mirrors cloud-session records into `<state>/cloud-sessions/c<chunk>/<rel>`.
///
/// The `c<chunk>/` prefix keeps each chunk a separate file while leaving the tail of the path in
/// the shape `claudeSessionID(forTranscript:)` reads (`<project>/<session>.jsonl`,
/// `<project>/<session>/subagents/<agent>.jsonl`), so chunks of one session share its session id.
actor CloudSessionMirror {
    static let shared = CloudSessionMirror()

    /// `updatedAt` is the container's clock, not CloudKit's. Re-reading a window behind the
    /// watermark covers skew; rewriting an unchanged file is skipped, and dedup covers the rest.
    static let overlap: TimeInterval = 10 * 60
    /// First pull reaches back this far — past the month window every total is built from.
    static let initialLookback: TimeInterval = 40 * 24 * 3600

    typealias Fetch = @Sendable (_ channel: String, _ since: Date) async throws -> [UsageCloudKit.CloudSessionRecord]

    struct Outcome: Equatable {
        var written = 0
        var rejected = 0
    }

    private let root: URL
    private let fetch: Fetch
    private var inFlight = false

    init(root: URL = CloudSessionMirror.defaultRoot(),
         fetch: @escaping Fetch = { try await CloudSyncGate.fetchCloudSessionRecords(channel: $0, since: $1) }) {
        self.root = root
        self.fetch = fetch
    }

    static func defaultRoot() -> URL { AppStatePaths.directory().appendingPathComponent("cloud-sessions") }

    /// Pulls records newer than the watermark and writes the changed ones. Returns nil when a pull
    /// is already running or the fetch failed (logged), otherwise how many files changed.
    func pull(crypto: CloudSessionCrypto, now: Date = Date()) async -> Outcome? {
        guard !inFlight else { return nil }
        inFlight = true
        defer { inFlight = false }

        var state = loadState(channel: crypto.channel)
        let since = state.watermark.map { $0.addingTimeInterval(-Self.overlap) }
            ?? now.addingTimeInterval(-Self.initialLookback)
        let records: [UsageCloudKit.CloudSessionRecord]
        do {
            records = try await fetch(crypto.channel, since)
        } catch {
            AppLog.writeIfChanged("cloud-session-pull", "cloud sessions: pull failed: \(error)")
            return nil
        }
        var outcome = Outcome()
        for record in records {
            do {
                if try write(try crypto.open(record.payload)) { outcome.written += 1 }
                state.watermark = max(state.watermark ?? record.updatedAt, record.updatedAt)
            } catch {
                // A record we cannot open is not ours (wrong key, or someone else's channel
                // collision) — skip it but still advance past it.
                outcome.rejected += 1
                state.watermark = max(state.watermark ?? record.updatedAt, record.updatedAt)
            }
        }
        state.lastPull = now
        saveState(state)
        if outcome.written > 0 || outcome.rejected > 0 {
            AppLog.write("cloud sessions: \(records.count) record(s), \(outcome.written) file(s) updated, \(outcome.rejected) rejected")
        }
        return outcome
    }

    /// Writes the chunk if its bytes changed. `rel` was validated by `CloudSessionCrypto.open`;
    /// the containment check here is the second line of defence for a path from a public record.
    func write(_ payload: CloudSessionPayload) throws -> Bool {
        let base = root.standardizedFileURL
        let file = base.appendingPathComponent("c\(payload.chunk)").appendingPathComponent(payload.rel)
            .standardizedFileURL
        guard file.path.hasPrefix(base.path + "/") else { throw CloudSessionCrypto.Failure.unsafePath }
        let data = Data(payload.jsonl.utf8)
        if (try? Data(contentsOf: file)) == data { return false }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return true
    }

    // MARK: State (hidden file: `jsonlFiles` skips it, and it is not `.jsonl` anyway)

    struct State: Codable, Equatable {
        var channel: String
        var watermark: Date?
        var lastPull: Date?
    }

    private var stateURL: URL { root.appendingPathComponent(".state.json") }

    /// A different key means a different channel: start over rather than skip its history.
    private func loadState(channel: String) -> State {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(State.self, from: data),
              state.channel == channel else { return State(channel: channel) }
        return state
    }

    private func saveState(_ state: State) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    func lastPull() -> Date? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return (try? JSONDecoder().decode(State.self, from: data))?.lastPull
    }
}

/// Publishes this Mac's entries for providers that opt in (`UsageProvider.phoneLedgerEntries`)
/// to the private database, uploading only chunks whose digest changed.
actor PhoneLedgerPublisher {
    static let shared = PhoneLedgerPublisher()

    typealias Publish = @Sendable (_ chunks: [PhoneUsageLedger.Chunk], _ deleting: [String],
                                   _ manifest: PhoneUsageLedgerManifest) async throws -> Void

    struct Source: Sendable {
        let provider: PhoneUsageLedgerManifest.Provider
        let entries: [LocalUsageReader.Entry]
    }

    private let stateURL: URL
    private let upload: Publish
    private var inFlight = false
    /// The newest sources that arrived while an upload was running. Dropping them used to delay a
    /// cloud turn's arrival on the phone by a whole refresh interval — the pull that mirrors a cloud
    /// record triggers a refresh whose publish lands exactly while the previous one is uploading.
    private var pending: [Source]?

    init(stateURL: URL = AppStatePaths.directory().appendingPathComponent("phone-ledger-manifest.json"),
         upload: @escaping Publish = { try await CloudSyncGate.publishLedger(chunks: $0, deleting: $1, manifest: $2) }) {
        self.stateURL = stateURL
        self.upload = upload
    }

    /// Returns how many chunks were uploaded, or nil when nothing was attempted (unchanged, or
    /// queued behind a running upload) or the upload failed. A failure leaves the saved manifest
    /// untouched, so the next refresh retries the same chunks. Sources that arrive mid-upload are
    /// kept (newest wins) and published as soon as that upload finishes.
    @discardableResult
    func publish(_ sources: [Source], now: Date = Date()) async -> Int? {
        guard !inFlight else {
            pending = sources
            return nil
        }
        inFlight = true
        defer { inFlight = false }
        let result = await publishOnce(sources, now: now)
        while let next = pending {
            pending = nil
            await publishOnce(next, now: Date())
        }
        return result
    }

    @discardableResult
    private func publishOnce(_ sources: [Source], now: Date) async -> Int? {
        var chunks: [PhoneUsageLedger.Chunk] = []
        do {
            for source in sources {
                chunks += try PhoneUsageLedger.chunks(provider: source.provider.id, entries: source.entries)
            }
        } catch {
            AppLog.writeIfChanged("phone-ledger", "phone ledger: encoding failed: \(error)")
            return nil
        }
        let manifest = PhoneUsageLedgerManifest(updatedAt: now, providers: sources.map(\.provider), chunks: chunks)
        let previous = loadManifest()
        let previousDigests = Dictionary((previous?.records ?? []).map { ($0.name, $0.digest) }, uniquingKeysWith: { a, _ in a })
        let changed = chunks.filter { previousDigests[$0.recordName] != $0.digest }
        let current = Set(chunks.map(\.recordName))
        let removed = (previous?.records ?? []).map(\.name).filter { !current.contains($0) }
        // A first run with nothing to publish stays silent — no empty manifest from a Mac that
        // never published (and no CloudKit call from test stores with stub providers).
        guard !changed.isEmpty || !removed.isEmpty || (previous?.providers ?? []) != manifest.providers else { return nil }

        do {
            try await upload(changed, removed, manifest)
        } catch {
            AppLog.writeIfChanged("phone-ledger", "phone ledger: upload failed: \(error)")
            return nil
        }
        saveManifest(manifest)
        AppLog.writeIfChanged("phone-ledger", "phone ledger: published \(changed.count) chunk(s), removed \(removed.count)")
        return changed.count
    }

    private func loadManifest() -> PhoneUsageLedgerManifest? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(PhoneUsageLedgerManifest.self, from: data)
    }

    private func saveManifest(_ manifest: PhoneUsageLedgerManifest) {
        try? JSONEncoder().encode(manifest).write(to: stateURL, options: .atomic)
    }
}

/// Settings actions for the cloud-session key pair. The private key is also written to the private
/// database — that is how the iPhone and its widget get it with no step on the phone, and how a
/// reinstalled Mac gets it back.
@MainActor
enum CloudSessionSettings {
    /// Creates the key pair and returns its public key (what the cloud environment needs).
    @discardableResult
    static func generate(store: CloudSessionKeyStore = CloudSessionKeyStore()) throws -> String {
        let privateKey = CloudSessionCrypto.generatePrivateKey()
        try store.save(privateKey)
        publish(store: store)
        return try CloudSessionCrypto(base64PrivateKey: privateKey).publicKeyBase64
    }

    static func clear(store: CloudSessionKeyStore = CloudSessionKeyStore()) {
        store.clear()
        Task {
            do { try await CloudSyncGate.deleteCloudSessionKey() }
            catch { AppLog.write("cloud sessions: key delete failed: \(error)") }
        }
    }

    static func publish(store: CloudSessionKeyStore = CloudSessionKeyStore()) {
        guard let raw = store.loadRaw(), store.load() != nil else { return }
        Task {
            do { try await CloudSyncGate.saveCloudSessionKey(raw) }
            catch { AppLog.writeIfChanged("cloud-session-key", "cloud sessions: key sync failed: \(error)") }
        }
    }

    /// At launch: publish the local key (a key made by a build without the iCloud entitlement, or
    /// offline, still reaches the phone), or — with no local key — adopt the one in iCloud, so a
    /// reinstalled Mac keeps reading the records sealed to it. Returns true when a key was adopted.
    @discardableResult
    static func syncAtLaunch(store: CloudSessionKeyStore = CloudSessionKeyStore(),
                             fetch: @escaping @Sendable () async throws -> String? = {
                                 try await CloudSyncGate.fetchCloudSessionKey()
                             }) async -> Bool {
        if store.load() != nil {
            publish(store: store)
            return false
        }
        guard let remote = try? await fetch(), (try? store.save(remote)) != nil else { return false }
        AppLog.write("cloud sessions: restored the device key from iCloud")
        return true
    }
}
