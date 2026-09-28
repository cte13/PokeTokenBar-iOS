import CryptoKit
import Foundation

/// The Mac's own usage entries, published to the private CloudKit database so the iPhone can count
/// (totals, cost, burn) with the Mac asleep or off.
///
/// Why entries and not totals: the phone also reads cloud-session records directly, and the Mac
/// mirrors those same records into its own scan. Only entries can be merged without double
/// counting — `UsageAggregation.dedupKeepMax` collapses a turn seen by both paths.
///
/// Layout: one `UsageLedgerChunk` record per (provider, Mac-local day, chunk), plus one
/// `UsageLedgerManifest` record listing every chunk with its digest. The phone reads the manifest
/// and fetches only chunks whose digest changed — by record ID, so no query index is needed.
/// Which providers publish is the provider's choice (`UsageProvider.phoneLedgerEntries`), never a
/// provider-id branch here.
public enum PhoneUsageLedger {
    public static let chunkRecordType = "UsageLedgerChunk"
    public static let manifestRecordType = "UsageLedgerManifest"
    public static let manifestRecordName = "UsageLedgerManifest"
    /// A compact entry deflates to well under 100 bytes, so a full chunk stays far below
    /// CloudKit's 1 MB record limit even for a very heavy day.
    public static let chunkSize = 4000

    /// Compact wire form of `UsageEntry`. `localDay` is not sent — it depends on the reader's
    /// time zone, so the phone derives it from `t`. Claude account provenance stays on the Mac.
    struct WireEntry: Codable, Equatable {
        let i: String
        let t: Double
        let m: String
        let n: [Int]
        var c: Double?
        var e: Bool?
        var u: Bool?
    }

    public struct Chunk: Sendable, Equatable {
        public let provider: String
        public let day: String
        public let index: Int
        /// Deflated JSON — what goes into the record's `payload` field.
        public let payload: Data
        /// SHA-256 of the uncompressed JSON; the manifest carries it so unchanged chunks are skipped.
        public let digest: String

        public var recordName: String { PhoneUsageLedger.recordName(provider: provider, day: day, index: index) }
    }

    public static func recordName(provider: String, day: String, index: Int) -> String {
        "ul_\(provider)_\(day)_\(index)"
    }

    /// Partitions one provider's entries into day chunks. Entries are sorted by time (then id) so
    /// a day that is still growing only changes its last chunk.
    public static func chunks(provider: String, entries: [UsageEntry]) throws -> [Chunk] {
        let byDay = Dictionary(grouping: entries, by: \.localDay)
        var out: [Chunk] = []
        for day in byDay.keys.sorted() {
            let sorted = byDay[day]!.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
            for (index, start) in stride(from: 0, to: sorted.count, by: chunkSize).enumerated() {
                let slice = Array(sorted[start..<min(start + chunkSize, sorted.count)])
                let json = try encode(slice)
                out.append(Chunk(provider: provider, day: day, index: index,
                                 payload: try (json as NSData).compressed(using: .zlib) as Data,
                                 digest: SHA256.hash(data: json).map { String(format: "%02x", $0) }.joined()))
            }
        }
        return out
    }

    /// Deterministic JSON (sorted keys) so the digest only moves when the entries do.
    static func encode(_ entries: [UsageEntry]) throws -> Data {
        let wire = entries.map { e in
            WireEntry(i: e.id, t: e.date.timeIntervalSince1970, m: e.model,
                      n: [e.input, e.output, e.cacheWrite, e.cacheRead],
                      c: e.explicitCost, e: e.costIsEstimate, u: e.costUnavailable)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(wire)
    }

    /// Record payload → entries, with `localDay` in the reader's time zone.
    public static func decode(payload: Data,
                              fmt: DateFormatter = UsageAggregation.localDayFormatter()) throws -> [UsageEntry] {
        let json = try (payload as NSData).decompressed(using: .zlib) as Data
        return try JSONDecoder().decode([WireEntry].self, from: json).compactMap { w in
            guard w.n.count == 4 else { return nil }
            let date = Date(timeIntervalSince1970: w.t)
            // The ledger is written by our own Mac, but it still crosses a network: clamp like any
            // external log so a corrupt value cannot trap on the first sum (defect-log SIGTRAP entry).
            let n = w.n.map { UsageAggregation.intOrNil($0) ?? 0 }
            return UsageEntry(id: w.i, date: date, localDay: fmt.string(from: date), model: w.m,
                              input: n[0], output: n[1], cacheWrite: n[2], cacheRead: n[3],
                              explicitCost: w.c, costIsEstimate: w.e, costUnavailable: w.u)
        }
    }
}

/// What the Mac published, and which providers the phone may therefore count itself.
public struct PhoneUsageLedgerManifest: Codable, Sendable, Equatable {
    public struct Provider: Codable, Sendable, Equatable {
        public let id: String
        public let displayName: String
        public let reportsCost: Bool

        public init(id: String, displayName: String, reportsCost: Bool) {
            self.id = id
            self.displayName = displayName
            self.reportsCost = reportsCost
        }
    }

    public struct Record: Codable, Sendable, Equatable {
        public let name: String
        public let provider: String
        public let digest: String

        public init(name: String, provider: String, digest: String) {
            self.name = name
            self.provider = provider
            self.digest = digest
        }
    }

    public var v = 1
    public let updatedAt: Date
    /// Providers whose entries the ledger carries in full for the current window. The phone
    /// replaces exactly these providers' numbers with its own count.
    public let providers: [Provider]
    public let records: [Record]

    public init(updatedAt: Date, providers: [Provider], records: [Record]) {
        self.updatedAt = updatedAt
        self.providers = providers
        self.records = records
    }

    public init(updatedAt: Date, providers: [Provider], chunks: [PhoneUsageLedger.Chunk]) {
        self.init(updatedAt: updatedAt, providers: providers,
                  records: chunks.map { Record(name: $0.recordName, provider: $0.provider, digest: $0.digest) })
    }
}
