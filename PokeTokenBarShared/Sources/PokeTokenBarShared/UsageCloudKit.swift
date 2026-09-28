import CloudKit

/// CloudKit I/O for counting on the iPhone: the Mac's usage ledger and the cloud-session secret
/// (private database), plus the cloud-session records written by the Claude Code hook (public
/// database). The Mac must reach these only through `CloudSyncGate` — `CKContainer` traps in a
/// process without the iCloud entitlement.
///
/// Writes follow the rule in the defect log's CloudKit section: `CKModifyRecordsOperation`
/// with `.allKeys`, never fetch-modify-save.
public enum UsageCloudKit {
    static let secretRecordType = "CloudSessionSecret"
    static let secretRecordName = "CloudSessionSecretCurrent"
    /// CloudKit rejects a modify with more than 400 items; stay well under it.
    static let batchSize = 200
    /// Every request here is best effort beside the usage refresh; none may hold it up for long.
    public static let requestTimeout: TimeInterval = 20

    // MARK: - Usage ledger (private)

    /// Saves changed chunks, deletes chunks that left the window, then writes the manifest.
    /// The manifest goes last so the phone never sees a record list naming chunks not yet saved.
    public static func publishLedger(chunks: [PhoneUsageLedger.Chunk], deleting: [String],
                                     manifest: PhoneUsageLedgerManifest) async throws {
        let now = Date()
        let records = chunks.map { makeChunkRecord($0, updatedAt: now) }
        let deletions = deleting.map { CKRecord.ID(recordName: $0) }
        for start in stride(from: 0, to: max(records.count, deletions.count), by: batchSize) {
            try await modify(save: Array(records.dropFirst(start).prefix(batchSize)),
                             delete: Array(deletions.dropFirst(start).prefix(batchSize)),
                             in: CloudKitSync.container.privateCloudDatabase)
        }
        try await modify(save: [try makeManifestRecord(manifest)], delete: [],
                         in: CloudKitSync.container.privateCloudDatabase)
    }

    public static func fetchLedgerManifest() async throws -> PhoneUsageLedgerManifest? {
        do {
            let record = try await CloudKitSync.container.privateCloudDatabase
                .record(for: CKRecord.ID(recordName: PhoneUsageLedger.manifestRecordName))
            guard let json = record["json"] as? String, let data = json.data(using: .utf8) else { return nil }
            return try decoder.decode(PhoneUsageLedgerManifest.self, from: data)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    /// Record name → payload for the named chunks. A chunk deleted meanwhile is simply absent.
    public static func fetchLedgerChunks(names: [String]) async throws -> [String: Data] {
        var out: [String: Data] = [:]
        let db = CloudKitSync.container.privateCloudDatabase
        for start in stride(from: 0, to: names.count, by: batchSize) {
            let ids = names.dropFirst(start).prefix(batchSize).map { CKRecord.ID(recordName: $0) }
            for (id, result) in try await db.records(for: Array(ids), desiredKeys: ["payload"]) {
                if case .success(let record) = result, let data = record["payload"] as? Data {
                    out[id.recordName] = data
                }
            }
        }
        return out
    }

    static func makeChunkRecord(_ chunk: PhoneUsageLedger.Chunk, updatedAt: Date) -> CKRecord {
        let record = CKRecord(recordType: PhoneUsageLedger.chunkRecordType,
                              recordID: CKRecord.ID(recordName: chunk.recordName))
        record["provider"] = chunk.provider
        record["day"] = chunk.day
        record["chunk"] = chunk.index
        record["payload"] = chunk.payload
        record["updatedAt"] = updatedAt
        return record
    }

    static func makeManifestRecord(_ manifest: PhoneUsageLedgerManifest) throws -> CKRecord {
        let record = CKRecord(recordType: PhoneUsageLedger.manifestRecordType,
                              recordID: CKRecord.ID(recordName: PhoneUsageLedger.manifestRecordName))
        record["json"] = String(decoding: try encoder.encode(manifest), as: UTF8.self)
        record["updatedAt"] = manifest.updatedAt
        return record
    }

    // MARK: - Cloud-session secret (private)

    /// The Mac saves the secret here so the iPhone and its widget pick it up with no step on the phone.
    public static func saveCloudSessionSecret(_ secret: String) async throws {
        let record = CKRecord(recordType: secretRecordType, recordID: CKRecord.ID(recordName: secretRecordName))
        record["secret"] = secret
        try await modify(save: [record], delete: [], in: CloudKitSync.container.privateCloudDatabase)
    }

    public static func fetchCloudSessionSecret() async throws -> String? {
        do {
            let record = try await CloudKitSync.container.privateCloudDatabase
                .record(for: CKRecord.ID(recordName: secretRecordName))
            return record["secret"] as? String
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    public static func deleteCloudSessionSecret() async throws {
        try await modify(save: [], delete: [CKRecord.ID(recordName: secretRecordName)],
                         in: CloudKitSync.container.privateCloudDatabase)
    }

    // MARK: - Cloud-session records (public)

    public struct CloudSessionRecord: Sendable, Equatable {
        public let recordName: String
        public let updatedAt: Date
        public let payload: Data

        public init(recordName: String, updatedAt: Date, payload: Data) {
            self.recordName = recordName
            self.updatedAt = updatedAt
            self.payload = payload
        }
    }

    /// Every record on `channel` updated after `since`, following the query cursor to the end.
    /// Needs the `channel` (queryable) and `updatedAt` (queryable) indexes in the CloudKit schema.
    public static func fetchCloudSessionRecords(channel: String, since: Date) async throws -> [CloudSessionRecord] {
        let query = CKQuery(recordType: CloudSessionCrypto.recordType,
                            predicate: cloudSessionPredicate(channel: channel, since: since))
        let configuration = CKOperation.Configuration()
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.qualityOfService = .utility
        return try await CloudKitSync.container.publicCloudDatabase.configuredWith(configuration: configuration) { db in
            var out: [CloudSessionRecord] = []
            var page = try await db.records(matching: query, desiredKeys: ["updatedAt", "payload"])
            while true {
                for (id, result) in page.matchResults {
                    guard case .success(let record) = result,
                          let payload = record["payload"] as? Data,
                          let updatedAt = record["updatedAt"] as? Date else { continue }
                    out.append(CloudSessionRecord(recordName: id.recordName, updatedAt: updatedAt, payload: payload))
                }
                guard let cursor = page.queryCursor else { return out }
                page = try await db.records(continuingMatchFrom: cursor, desiredKeys: ["updatedAt", "payload"])
            }
        }
    }

    static func cloudSessionPredicate(channel: String, since: Date) -> NSPredicate {
        NSPredicate(format: "channel == %@ AND updatedAt > %@", channel, since as NSDate)
    }

    // MARK: - Private

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    static func makeModifyOperation(save: [CKRecord], delete: [CKRecord.ID]) -> CKModifyRecordsOperation {
        let operation = CKModifyRecordsOperation(recordsToSave: save, recordIDsToDelete: delete)
        operation.savePolicy = .allKeys
        operation.qualityOfService = .utility
        operation.configuration.timeoutIntervalForRequest = requestTimeout
        return operation
    }

    private static func modify(save: [CKRecord], delete: [CKRecord.ID], in database: CKDatabase) async throws {
        guard !save.isEmpty || !delete.isEmpty else { return }
        let operation = makeModifyOperation(save: save, delete: delete)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success: continuation.resume()
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }
}
