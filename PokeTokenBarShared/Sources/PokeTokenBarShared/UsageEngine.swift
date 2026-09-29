import Foundation

// The token-counting engine shared by the Mac app and the iPhone.
//
// The Mac used to be the only device that counted: it parsed local transcripts and sent the phone
// finished totals. To count on the phone with the Mac off (cloud sessions + the Mac's usage ledger),
// both devices must fold the same entries into the same numbers, so the normalized entry, the
// price table and every aggregation live here — one site, not a phone copy that drifts.
// The Mac keeps its historical names (`LocalUsageReader.Entry`, `DailyUsage`, …) as typealiases.

// MARK: - Cost provenance

/// Provenance of the amount, independent of whether a subscription or API key was used.
/// A source-reported amount is not necessarily an invoice or a charge.
public struct CostCoverage: Codable, Sendable, Equatable {
    public var reported = false
    public var estimated = false
    public var unknown = false

    public init(reported: Bool = false, estimated: Bool = false, unknown: Bool = false) {
        self.reported = reported
        self.estimated = estimated
        self.unknown = unknown
    }

    public static let empty = CostCoverage()
    public static let source = CostCoverage(reported: true)
    public static let estimate = CostCoverage(estimated: true)
    public static let unavailable = CostCoverage(unknown: true)
    public var hasKnown: Bool { reported || estimated }

    public mutating func merge(_ other: CostCoverage) {
        reported = reported || other.reported
        estimated = estimated || other.estimated
        unknown = unknown || other.unknown
    }
}

public struct UsageCost: Sendable, Equatable {
    public var amount: Double = 0
    public var coverage: CostCoverage = .empty

    public init(amount: Double = 0, coverage: CostCoverage = .empty) {
        self.amount = amount
        self.coverage = coverage
    }

    public mutating func add(_ other: UsageCost) {
        amount += other.amount
        coverage.merge(other.coverage)
    }
}

// MARK: - Prices

/// Standard token rates in USD. These estimate API-equivalent usage, not subscription bills.
public struct ModelRate: Equatable, Sendable {
    public let input: Double        // USD per token
    public let output: Double
    public let cacheWrite: Double   // cache creation
    public let cacheRead: Double

    public init(input: Double, output: Double, cacheWrite: Double, cacheRead: Double) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }

    public static let zero = ModelRate(input: 0, output: 0, cacheWrite: 0, cacheRead: 0)

    /// USD per **million** tokens 로 선언(가독성) → per-token 으로 변환.
    public static func perMillion(_ input: Double, _ output: Double, _ cacheWrite: Double, _ cacheRead: Double) -> ModelRate {
        ModelRate(input: input / 1_000_000, output: output / 1_000_000,
                  cacheWrite: cacheWrite / 1_000_000, cacheRead: cacheRead / 1_000_000)
    }
}

public enum ModelPricing {
    /// Standard API prices, checked 2026-09-11: https://developers.openai.com/api/docs/pricing
    /// Historical GPT rates: https://developers.openai.com/api/docs/models/<model-id>
    /// The table is a current-price estimate, not a historical invoice ledger.
    public static let table: [String: ModelRate] = [
        // Claude rates, checked 2026-09-13: https://platform.claude.com/docs/en/about-claude/pricing
        // (base input, output, 5m cache write, cache hit — the header URL above covers GPT only).
        // Claude 5 family. Exact rows are mandatory: the model-family fallback that used to
        // price these was removed in #289, which left them unpriced and the cost row blank (#303).
        "claude-opus-5":              .perMillion(5, 25, 6.25, 0.5),
        // Opus 5.5, checked 2026-09-25: cheaper than Opus 5, cache read cut to $0.20/MTok (0.05× input).
        "claude-opus-5-5":            .perMillion(4, 20, 5, 0.2),
        "claude-sonnet-5":            .perMillion(2, 10, 2.5, 0.2),
        "claude-opus-4-20250514":     .perMillion(15, 75, 18.75, 1.5),
        "claude-sonnet-4-20250514":   .perMillion(3, 15, 3.75, 0.3),
        "claude-sonnet-4-5-20250929": .perMillion(3, 15, 3.75, 0.3),
        "claude-opus-4-8":            .perMillion(5, 25, 6.25, 0.5),
        "claude-opus-4-7":            .perMillion(5, 25, 6.25, 0.5),
        "claude-sonnet-4-6":          .perMillion(3, 15, 3.75, 0.3),
        "claude-haiku-4-5-20251001":  .perMillion(1, 5, 1.25, 0.1),
        "claude-fable-5":             .perMillion(10, 50, 12.5, 1.0), // LiteLLM 스냅샷 가격 등재됨(2026-08) — 기존 미가격 $0 플레이스홀더 대체
        // Fable 5.1: same base rates as Fable 5, cache read cut to $0.25/MTok (0.025× input).
        "claude-fable-5-1":           .perMillion(10, 50, 12.5, 0.25),
        "gpt-6-astra":                .perMillion(10, 50, 12.5, 1),
        "gpt-5.6-sol":                .perMillion(4, 20, 5, 0.4),
        "gpt-5.6-terra":              .perMillion(2, 12, 2.5, 0.2),
        "gpt-5.6-luna":               .perMillion(0.2, 1.2, 0.25, 0.02),
        "gpt-5":                      .perMillion(1.25, 10, 0, 0.125),
        "gpt-5-codex":                .perMillion(1.25, 10, 0, 0.125),
        "gpt-5.1":                    .perMillion(1.25, 10, 0, 0.125),
        "gpt-5.1-codex":              .perMillion(1.25, 10, 0, 0.125),
        "gpt-5.2":                    .perMillion(1.75, 14, 0, 0.175),
        "gpt-5.2-codex":              .perMillion(1.75, 14, 0, 0.175),
        "gpt-5.3-codex":              .perMillion(1.75, 14, 0, 0.175),
        "gpt-5.4":                    .perMillion(2.5, 15, 0, 0.25),
        "gpt-5.5":                    .perMillion(5, 30, 0, 0.5),
        // Text token rates: https://ai.google.dev/gemini-api/docs/pricing
        // Cache storage duration and audio rates cannot be recovered from these logs.
        "gemini-2.5-pro":             .perMillion(1.25, 10, 0, 0.125),
        "gemini-2.5-flash":           .perMillion(0.30, 2.5, 0, 0.03),
        // Distinct SKU. A "flash" substring match would bill this at Flash rates.
        "gemini-2.5-flash-lite":      .perMillion(0.10, 0.40, 0, 0.01),
        "gemini-2.0-flash":           .perMillion(0.10, 0.4, 0, 0.025),
    ]

    // Only documented model identities and simple provider namespaces are normalized.
    // A model containing "gpt"/"opus" is not evidence that it shares another model's price.
    private static let aliases: [String: String] = [
        "gpt-5.6": "gpt-5.6-sol",
        "claude-sonnet-4": "claude-sonnet-4-20250514",
        "claude-opus-4": "claude-opus-4-20250514",
        "claude-sonnet-4-5": "claude-sonnet-4-5-20250929",
        "claude-haiku-4-5": "claude-haiku-4-5-20251001",
        "gpt-5-2025-08-07": "gpt-5",
        "gpt-5.1-2025-11-13": "gpt-5.1",
        "gpt-5.2-2025-12-11": "gpt-5.2",
        "gpt-5.4-2026-03-05": "gpt-5.4",
        "gpt-5.5-2026-04-23": "gpt-5.5",
    ]

    private static func modelKey(_ model: String) -> String {
        var key = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["openai/", "anthropic/", "google/", "models/"] where key.hasPrefix(prefix) {
            key = String(key.dropFirst(prefix.count))
            break
        }
        return aliases[key] ?? key
    }

    /// Compatibility for callers that only need a numeric rate. New aggregation uses
    /// estimatedCost so an unknown model remains distinguishable from a genuine zero.
    public static func rate(for model: String) -> ModelRate { table[modelKey(model)] ?? .zero }

    /// One request's disjoint token buckets. Never pass daily/session aggregates here:
    /// request size controls long-context pricing. Total-only logs cannot reconstruct
    /// the bucket split; callers must mark those estimates as unavailable.
    /// Excludes Fast/Batch/Flex, regional uplift, tools, storage and subscription terms.
    /// In particular Codex's Astra allowance differs from this API-equivalent estimate.
    public static func estimatedCost(model: String, input: Int, output: Int,
                                     cacheWrite: Int, cacheRead: Int) -> Double? {
        let key = modelKey(model)
        guard let r = table[key], input >= 0, output >= 0, cacheWrite >= 0, cacheRead >= 0 else { return nil }
        // Zero in this column means no supported separate write rate, not free write tokens.
        guard cacheWrite == 0 || r.cacheWrite > 0 else { return nil }
        let prompt = Double(input) + Double(cacheRead) + Double(cacheWrite)
        let longContext = ["gpt-6-astra", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna",
                           "gpt-5.5", "gpt-5.4"].contains(key) && prompt > 272_000
            || key == "gemini-2.5-pro" && prompt > 200_000
        let inputMultiplier = longContext ? 2.0 : 1.0
        let outputMultiplier = longContext ? 1.5 : 1.0
        return (Double(input) * r.input + Double(cacheWrite) * r.cacheWrite
                + Double(cacheRead) * r.cacheRead) * inputMultiplier
            + Double(output) * r.output * outputMultiplier
    }

    /// Where `noteUnpriced` reports. The Mac points this at its log file at launch; the phone has
    /// no log and leaves it nil.
    nonisolated(unsafe) public static var unpricedLogger: (@Sendable (String) -> Void)?

    /// A model the table cannot price renders as "Unavailable" with no other trace — Opus 5.5
    /// went unnoticed until a screenshot. Log each unpriced identity once per process so a new
    /// model shows up in the log the first time a provider reports it.
    public static func noteUnpriced(_ model: String) {
        guard firstUnpricedSighting(model) else { return }
        unpricedLogger?("Unpriced model: \(model) — its cost shows as Unavailable until ModelPricing.table has a row")
    }

    /// True only the first time `model` is seen (normalized) — the dedupe behind `noteUnpriced`.
    public static func firstUnpricedSighting(_ model: String) -> Bool {
        let key = modelKey(model)
        unpricedLock.lock(); defer { unpricedLock.unlock() }
        return unpricedSeen.insert(key).inserted
    }

    nonisolated(unsafe) private static var unpricedSeen: Set<String> = []
    private static let unpricedLock = NSLock()

    public static func cost(model: String, input: Int, output: Int, cacheWrite: Int, cacheRead: Int) -> Double {
        estimatedCost(model: model, input: input, output: output,
                      cacheWrite: cacheWrite, cacheRead: cacheRead) ?? 0
    }
}

// MARK: - Aggregates

public struct DailyUsage: Decodable, Sendable {
    public var date: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationTokens: Int
    public var cacheReadTokens: Int
    public var totalTokens: Int
    public var totalCost: Double
    public var costCoverage: CostCoverage = .source
    public var usageCost: UsageCost { UsageCost(amount: totalCost, coverage: costCoverage) }
    /// totalTokens per source model when the provider reports it (nil otherwise).
    public var models: [String: Int]?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // ccusage ≤18 은 "date", ≥20 은 "period" 로 일자를 준다
        date = try c.decodeIfPresent(String.self, forKey: .date)
            ?? c.decodeIfPresent(String.self, forKey: .period) ?? ""
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cacheCreationTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreationTokens) ?? 0
        cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens)
            ?? c.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0
        // totalTokens 없으면 4종 토큰 합으로 폴백
        totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens)
            ?? (inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens)
        totalCost = try c.decodeIfPresent(Double.self, forKey: .totalCost)
            ?? c.decodeIfPresent(Double.self, forKey: .costUSD) ?? 0
        costCoverage = try c.decodeIfPresent(CostCoverage.self, forKey: .costCoverage)
            ?? (totalTokens == 0 ? .empty : (totalCost > 0 ? .estimate : .unavailable))
        models = try c.decodeIfPresent([String: Int].self, forKey: .models)
    }

    public init(date: String, inputTokens: Int, outputTokens: Int,
                cacheCreationTokens: Int, cacheReadTokens: Int, totalTokens: Int, totalCost: Double,
                models: [String: Int]? = nil, costCoverage: CostCoverage = .source) {
        self.date = date
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.totalTokens = totalTokens
        self.totalCost = totalCost
        self.costCoverage = costCoverage
        self.models = models
    }

    private enum CodingKeys: String, CodingKey {
        case costCoverage
        case date, period, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens
        case cachedInputTokens, totalTokens, totalCost, costUSD, models
    }
}

public struct BlockUsage: Decodable, Sendable {
    public var id: String
    public var startTime: String
    public var endTime: String
    public var isActive: Bool
    public var totalTokens: Int
    public var costUSD: Double
    public var costCoverage: CostCoverage = .source
    public var usageCost: UsageCost { UsageCost(amount: costUSD, coverage: costCoverage) }
    /// ccusage blocks 의 burnRate.tokensPerMinute — 한도 소진 예측과 companion 표시 상태에 사용
    public var tokensPerMinute: Double?

    public var endDate: Date? { ISO8601Parser.date(from: endTime) }

    public init(id: String, startTime: String, endTime: String, isActive: Bool,
                totalTokens: Int, costUSD: Double, tokensPerMinute: Double?, costCoverage: CostCoverage = .source) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.isActive = isActive
        self.totalTokens = totalTokens
        self.costUSD = costUSD
        self.costCoverage = costCoverage
        self.tokensPerMinute = tokensPerMinute
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        startTime = try c.decodeIfPresent(String.self, forKey: .startTime) ?? ""
        endTime = try c.decodeIfPresent(String.self, forKey: .endTime) ?? ""
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive) ?? false
        totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens) ?? 0
        costUSD = try c.decodeIfPresent(Double.self, forKey: .costUSD) ?? 0
        costCoverage = try c.decodeIfPresent(CostCoverage.self, forKey: .costCoverage)
            ?? (totalTokens == 0 ? .empty : (costUSD > 0 ? .estimate : .unavailable))
        if let burn = try? c.decodeIfPresent(BurnRate.self, forKey: .burnRate) {
            tokensPerMinute = burn.tokensPerMinute
        }
    }

    private struct BurnRate: Decodable {
        var tokensPerMinute: Double?
    }

    private enum CodingKeys: String, CodingKey {
        case costCoverage
        case id, startTime, endTime, isActive, totalTokens, costUSD, burnRate
    }
}

public struct PeriodUsage: Decodable, Sendable {
    /// 주 시작일("2026-05-31") 또는 월("2026-06")
    public var period: String
    public var totalTokens: Int
    public var totalCost: Double
    public var costCoverage: CostCoverage = .source
    public var usageCost: UsageCost { UsageCost(amount: totalCost, coverage: costCoverage) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        period = try c.decodeIfPresent(String.self, forKey: .week)
            ?? c.decodeIfPresent(String.self, forKey: .month)
            ?? c.decodeIfPresent(String.self, forKey: .period) ?? ""
        let input = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        let output = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        let cacheW = try c.decodeIfPresent(Int.self, forKey: .cacheCreationTokens) ?? 0
        let cacheR = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens)
            ?? c.decodeIfPresent(Int.self, forKey: .cachedInputTokens) ?? 0
        totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens)
            ?? (input + output + cacheW + cacheR)
        totalCost = try c.decodeIfPresent(Double.self, forKey: .totalCost)
            ?? c.decodeIfPresent(Double.self, forKey: .costUSD) ?? 0
        costCoverage = try c.decodeIfPresent(CostCoverage.self, forKey: .costCoverage)
            ?? (totalTokens == 0 ? .empty : (totalCost > 0 ? .estimate : .unavailable))
    }

    public init(period: String, totalTokens: Int, totalCost: Double, costCoverage: CostCoverage = .source) {
        self.period = period
        self.totalTokens = totalTokens
        self.totalCost = totalCost
        self.costCoverage = costCoverage
    }

    public init(period: String, daily: [DailyUsage]) {
        self.period = period
        totalTokens = daily.reduce(0) { $0 + $1.totalTokens }
        totalCost = daily.reduce(0) { $0 + $1.totalCost }
        costCoverage = daily.reduce(into: .empty) { $0.merge($1.costCoverage) }
    }

    private enum CodingKeys: String, CodingKey {
        case costCoverage
        case week, month, period, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens
        case cachedInputTokens, totalTokens, totalCost, costUSD
    }
}

// MARK: - Normalized entry

/// One model request, normalized from whatever log a provider writes. Every aggregate is a fold of these.
public struct UsageEntry: Sendable, Codable, Equatable {
    public let id: String
    public var date: Date
    public var localDay: String
    public let model: String
    public let input, output, cacheWrite, cacheRead: Int
    /// Prefer a valid source-recorded amount (including zero) to model-table estimates.
    /// The source may itself estimate this amount; it is not necessarily a charge.
    public var explicitCost: Double? = nil
    public var costIsEstimate: Bool? = nil
    /// The source cannot reconstruct model/request token buckets for a price-table estimate.
    public var costUnavailable: Bool? = nil
    /// Claude only: the session the turn belongs to, from the transcript path. Lets usage be split
    /// between Claude accounts (`ClaudeAccountUsageAttribution`). Kept for old cache blobs.
    public var sessionID: String? = nil
    /// Claude only: every transcript session that contained this turn. A branch can replay the
    /// same turn under a new session id, so global dedup must retain all provenance for account
    /// attribution instead of whichever file happened to be scanned first.
    public var sessionIDs: [String]? = nil

    public init(id: String, date: Date, localDay: String, model: String,
                input: Int, output: Int, cacheWrite: Int, cacheRead: Int,
                explicitCost: Double? = nil, costIsEstimate: Bool? = nil, costUnavailable: Bool? = nil,
                sessionID: String? = nil, sessionIDs: [String]? = nil) {
        self.id = id
        self.date = date
        self.localDay = localDay
        self.model = model
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.explicitCost = explicitCost
        self.costIsEstimate = costIsEstimate
        self.costUnavailable = costUnavailable
        self.sessionID = sessionID
        self.sessionIDs = sessionIDs
    }

    public var claudeSessionIDs: [String] {
        Array(Set((sessionIDs ?? []) + (sessionID.map { [$0] } ?? []))).sorted()
    }
    public var total: Int { input + output + cacheWrite + cacheRead }
}

public struct UsageBucket: Sendable {
    public var input = 0, output = 0, cacheWrite = 0, cacheRead = 0
    public var cost = 0.0
    public var costCoverage: CostCoverage = .empty
    public var total: Int { input + output + cacheWrite + cacheRead }

    public init() {}

    public mutating func add(_ e: UsageEntry) {
        input += e.input; output += e.output; cacheWrite += e.cacheWrite; cacheRead += e.cacheRead
        // Zero-usage/replay records must not make an unknown-only total look partially priced.
        guard e.total > 0 else { return }
        if let reported = e.explicitCost, reported.isFinite, reported >= 0 {
            cost += reported
            costCoverage.merge(e.costIsEstimate == true ? .estimate : .source)
        } else if e.costUnavailable != true,
                  let estimate = ModelPricing.estimatedCost(model: e.model, input: e.input, output: e.output,
                                                            cacheWrite: e.cacheWrite, cacheRead: e.cacheRead) {
            cost += estimate
            costCoverage.merge(.estimate)
        } else {
            if e.costUnavailable != true { ModelPricing.noteUnpriced(e.model) }
            costCoverage.merge(.unavailable)
        }
    }
}

// MARK: - Aggregation

public enum UsageAggregation {

    /// 활성 블록(번 레이트)과 enrichment 스캔 하한이 공유하는 5시간 롤링 윈도우 길이.
    public static let blockWindow: TimeInterval = 5 * 3600

    /// 같은 `(message.id, requestId)` 가 스트리밍/재개로 여러 번 로깅될 때 cacheRead/input 은 고정이나
    /// output 은 증가하므로, **id 별 total 이 가장 큰(=완성된) 항목**을 남긴다(전역 dedup).
    /// 포크가 같은 턴을 더 늦은 시각으로 다시 기록할 수 있으므로, 턴 시각은 중복 중 가장 이른 값을 보존한다.
    /// (first-occurrence 를 남기면 부분 output 만 잡혀 비용이 크게 과소집계됨.)
    public static func dedupKeepMax(_ entries: [UsageEntry]) -> [UsageEntry] {
        var byID: [String: UsageEntry] = [:]
        for e in entries {
            guard let existing = byID[e.id] else {
                byID[e.id] = e
                continue
            }
            var kept = e.total > existing.total ? e : existing
            let earliest = e.date < existing.date ? e : existing
            kept.date = earliest.date
            kept.localDay = earliest.localDay
            let sessions = Array(Set(existing.claudeSessionIDs + e.claudeSessionIDs)).sorted()
            kept.sessionID = sessions.first
            kept.sessionIDs = sessions.count > 1 ? sessions : nil
            byID[e.id] = kept
        }
        return Array(byID.values)
    }

    /// One Claude Code transcript line → entry, or nil when the line is not an assistant turn with
    /// usage. Claude Code writes `(message.id, requestId)` per turn; that pair is the dedup id.
    /// Callers pre-filter on `"usage"`/`"assistant"` substrings before paying for JSON parsing.
    public static func parseClaudeLine(_ line: String, fmt: DateFormatter) -> UsageEntry? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["type"] as? String) == "assistant",
              let msg = obj["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any],
              let ts = obj["timestamp"] as? String,
              let date = ISO8601Parser.date(from: ts) else { return nil }
        let model = msg["model"] as? String ?? "unknown"
        let id = (msg["id"] as? String ?? "") + "|" + (obj["requestId"] as? String ?? "")
        return UsageEntry(
            id: id, date: date, localDay: fmt.string(from: date), model: model,
            input: intValue(usage["input_tokens"]),
            output: intValue(usage["output_tokens"]),
            cacheWrite: intValue(usage["cache_creation_input_tokens"]),
            cacheRead: intValue(usage["cache_read_input_tokens"]))
    }

    /// 특정 로컬 날짜의 합계 → DailyUsage. 해당 날짜 데이터 없으면 nil.
    /// `includeModels` 를 켠 프로바이더만 per-model 내역을 채운다 — 끄면 `models` 는 nil 이라
    /// 팝오버의 per-model 행이 그 프로바이더에서는 뜨지 않는다(현재는 Pi·omp 가 opt-in).
    public static func daily(entries: [UsageEntry], localDay: String, includeModels: Bool = false) -> DailyUsage? {
        var b = UsageBucket()
        var models: [String: Int]? = includeModels ? [:] : nil
        for e in entries where e.localDay == localDay {
            b.add(e)
            if includeModels { models?[e.model, default: 0] += e.total }
        }
        guard b.total > 0 else { return nil }
        return DailyUsage(date: localDay, inputTokens: b.input, outputTokens: b.output,
                          cacheCreationTokens: b.cacheWrite, cacheReadTokens: b.cacheRead,
                          totalTokens: b.total, totalCost: b.cost, models: models, costCoverage: b.costCoverage)
    }

    /// 로컬 날짜 [start, end] (포함) 범위 합계 → PeriodUsage.
    public static func period(entries: [UsageEntry], periodKey: String, fromDay: String, toDay: String) -> PeriodUsage {
        var b = UsageBucket()
        for e in entries where e.localDay >= fromDay && e.localDay <= toDay { b.add(e) }
        return PeriodUsage(period: periodKey, totalTokens: b.total, totalCost: b.cost, costCoverage: b.costCoverage)
    }

    /// Day-by-day totals for the **current month**, month start through `now`, in date order.
    ///
    /// This is a group-by over entries the enrichment scan has already loaded — the same set
    /// `period()` folds into a single scalar. No extra read, no new parsing, no `Entry` field.
    ///
    /// Two things are deliberate here.
    ///
    /// 1. **Cross-month sessions are truncated.** The scan window is an mtime filter, so a
    ///    session that started last month and continued into this one is read in full and drags
    ///    last month's entries along with it. Grouping the entries by `localDay` and emitting
    ///    whatever comes out would paint a partially-filled, jagged previous month — a picture
    ///    that is not true, because the *other* files from last month were never scanned. So the
    ///    date axis is built **from the month range** and totals are folded onto it: an entry
    ///    outside the range has no slot to land in. The `localDay` window matches `period()`'s
    ///    exactly, which makes `sum(monthDailySeries) == monthTotal.totalTokens` an invariant
    ///    (`testEnrichmentSeriesAndMonthTotalStayInAgreement` holds the two together).
    /// 2. **Days with no usage are explicit zeros, not omissions.** Bar position *is* the date in
    ///    the popover; dropping empty days would slide every later bar onto the wrong day.
    ///
    /// Scope is baked in rather than parameterised — a caller cannot widen this to a rolling
    /// window or last month, which is where this area has had month-boundary regressions before
    /// (see `enrichmentScanStart`).
    /// - Parameter timeZone: 테스트 주입 구멍. 기본값은 `Entry.localDay` 를 만든 것과 같은 현지 시간대다
    ///   — 다른 값을 주면 축의 날짜 문자열이 엔트리의 `localDay` 와 어긋나므로 프로덕션에선 기본값만 쓴다.
    ///   DST 가 없는 시간대(예: Asia/Seoul)에서만 테스트하면 하루 전진 결함이 통과하기 때문에 뚫었다.
    public static func monthDailySeries(entries: [UsageEntry], now: Date,
                                        timeZone: TimeZone = .current) -> [DailyUsage]
    {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        let fmt = localDayFormatter(timeZone: timeZone)

        var days: [String] = []
        var cursor = calendar.startOfDay(for: startOfMonth(now, calendar: calendar))
        let lastDay = calendar.startOfDay(for: now)
        while cursor <= lastDay {
            days.append(fmt.string(from: cursor))
            // `date(byAdding:)` rather than +86400 — a DST day is 23 or 25 hours long and a fixed
            // stride would drift the axis off the calendar for the rest of the month
            // (`testAxisLengthMatchesTheDayOfMonthInEveryMonthAndAcrossDSTTimeZones`).
            // The `else` is an API-forced unwrap with no reachable trigger on a Gregorian date,
            // like the `?? date` in `startOfMonth`/`startOfWeek` — not a guard worth a test.
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        // `days` 는 여기서 항상 비어 있지 않다 — `startOfMonth(now) <= now` 라 위 루프가 최소 한 번
        // 돈다. 그래서 empty 가드를 두지 않는다(도달 불가한 분기는 커버리지에 ^0 으로 남고, 읽는 사람
        // 에게 "빌 수 있다"는 잘못된 신호를 준다). 아래 `Set`·`map` 은 빈 배열에서도 안전하다.
        let inMonth = Set(days)
        var buckets: [String: UsageBucket] = [:]
        for e in entries where inMonth.contains(e.localDay) {
            buckets[e.localDay, default: UsageBucket()].add(e)
        }

        return days.map { day in
            let b = buckets[day] ?? UsageBucket()
            return DailyUsage(date: day, inputTokens: b.input, outputTokens: b.output,
                              cacheCreationTokens: b.cacheWrite, cacheReadTokens: b.cacheRead,
                              totalTokens: b.total, totalCost: b.cost, costCoverage: b.costCoverage)
        }
    }

    /// 최근 5시간 롤링 윈도우 기반 활성 블록(번 레이트 추정용).
    public static func activeBlock(entries: [UsageEntry], now: Date) -> BlockUsage? {
        let windowStart = now.addingTimeInterval(-blockWindow)
        // Claude Code can write `<synthetic>` assistant records whose usage fields are all zero
        // even when no Claude request ran (for example, a local wrapper/session bootstrap). Those
        // records are parser-valid metadata, not usage: exclude them from both existence and the
        // block start time so they cannot create or stretch a carrier snapshot/tab.
        let recent = entries.filter { $0.date >= windowStart && $0.total > 0 }.sorted { $0.date < $1.date }
        guard let first = recent.first else { return nil }
        var b = UsageBucket()
        for e in recent { b.add(e) }
        let minutes = max(1, now.timeIntervalSince(first.date) / 60)
        let tpm = Double(b.total) / minutes
        let iso = ISO8601DateFormatter()
        return BlockUsage(
            id: "block-\(Int(first.date.timeIntervalSince1970))",
            startTime: iso.string(from: first.date),
            endTime: iso.string(from: first.date.addingTimeInterval(blockWindow)),
            isActive: true, totalTokens: b.total, costUSD: b.cost, tokensPerMinute: tpm, costCoverage: b.costCoverage)
    }

    // MARK: 유틸

    /// `calendar` 는 테스트가 시간대를 주입하기 위한 구멍이다 — 기본값은 프로덕션과 동일한 현지 달력.
    public static func startOfMonth(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    public static func startOfWeek(_ date: Date) -> Date {
        Calendar.current.dateInterval(of: .weekOfYear, for: date)?.start ?? date
    }

    /// enrichment(활성 블록·이번 주·이번 달)를 한 번의 스캔에서 모두 도출하므로, mtime 하한은
    /// 그 세 윈도우 중 **가장 이른 시작**이어야 한다. append-only 로그에서 "범위 시작 이전에 수정된
    /// 파일엔 범위 내 엔트리가 없다"는 전제가 성립하려면 스캔 하한 ≤ 모든 표시 윈도우의 시작이어야 하기 때문.
    ///
    /// 함정: monthStart 만 하한으로 쓰면 **월초**에 이번 주 시작(weekStart)이 지난달로 넘어가고
    /// (2026년 12개월 중 11개월이 그렇다) 자정 직후엔 5h 블록이 어제로 넘어가, 지난달에 수정된 세션
    /// 파일이 스캔에서 빠지며 주간 합계·번레이트가 며칠간 과소집계된다. min 으로 그 경계를 흡수한다.
    /// (OpenCode/Hermes 경로엔 이미 `now-7일` 하한이 있었으나 Claude/Codex/Gemini 경로엔 없어
    /// 드리프트했다 — 네 프로바이더가 이 단일 소스를 공유하게 통일.)
    public static func enrichmentScanStart(now: Date) -> Date {
        min(startOfMonth(now), startOfWeek(now), now.addingTimeInterval(-blockWindow))
    }

    public static func monthKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"; f.timeZone = .current; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    public static func todayKey() -> String { localDayFormatter().string(from: Date()) }

    public static func localDayFormatter(timeZone: TimeZone = .current) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }

    // MARK: 숫자 추출 (외부 로그 방어)

    /// 파싱 상한 — 실사용(수십억)의 10만 배라 정상 사용량을 자르지 않는다.
    /// `Int.max` 로 잡지 않는 이유: 클램프 자체는 되지만 `output + thoughts` 처럼 **파싱 직후 더하는**
    /// 지점에서 다시 오버플로 트랩이 난다. 이 값끼리 여러 번 더해도 Int64 안에 머무는 상한이어야 한다.
    public static let maxParsedTokenValue = 1_000_000_000_000_000

    /// 숫자를 안전한 Int 로. 값이 없거나 숫자가 아니면 0.
    ///
    /// 예전엔 `Int(d)` 를 직접 불러 `1e30` 같은 값에서 **트랩(크래시)** 했다. 사용량 로그는 앱 밖에서
    /// 오고(손편집·전송 손상·업스트림 버그) 그 파일은 디스크에 남으므로, 한 번 들어오면 새로고침마다
    /// 그리고 재기동마다 다시 죽는다 — 사용자가 파일을 손으로 지우기 전까지 앱을 못 쓴다.
    /// 클램프는 크래시보다 안전한 열화다. `intOrNil` 과 같은 규칙을 쓰되 부재를 0 으로 접는다.
    public static func intValue(_ v: Any?) -> Int { intOrNil(v) ?? 0 }

    /// 숫자가 실제로 있을 때만 값을 준다. JSON `null`(=`NSNull`)·문자열·키 부재는 모두 nil —
    /// `usage["x"] != nil` 로 존재를 판정하면 null 이 "값 있음"으로 통과해 0 으로 뭉개진다.
    public static func doubleOrNil(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, !(v is NSNull) else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    public static func intOrNil(_ v: Any?) -> Int? {
        guard let d = doubleOrNil(v) else { return nil }
        guard d > 0 else { return 0 }                            // 음수 토큰은 없다
        // 비정상 큰 값에 트랩되지 않게. 상한이 maxParsedTokenValue 인 이유는 그 정의 주석 참조.
        return d >= Double(maxParsedTokenValue) ? maxParsedTokenValue : Int(d)
    }
}

// MARK: - Provider enrichment

/// 부가 정보 수집 결과. *OK 플래그가 false 면 수집 실패 → 이전 값 유지.
public struct ProviderEnrichment: Sendable {
    public var activeBlock: BlockUsage?
    public var blocksOK = false
    public var weekTotal: PeriodUsage?
    public var monthTotal: PeriodUsage?
    /// Day-by-day totals for the current month (month start → today, empty days as zeros).
    /// Comes out of the same scan as `monthTotal` and is gated by the same `periodsOK`.
    /// `nil` means this provider cannot produce a series; aggregation uses available providers.
    public var monthDaily: [DailyUsage]?
    public var periodsOK = false

    public init(activeBlock: BlockUsage? = nil, blocksOK: Bool = false, weekTotal: PeriodUsage? = nil,
                monthTotal: PeriodUsage? = nil, monthDaily: [DailyUsage]? = nil, periodsOK: Bool = false) {
        self.activeBlock = activeBlock
        self.blocksOK = blocksOK
        self.weekTotal = weekTotal
        self.monthTotal = monthTotal
        self.monthDaily = monthDaily
        self.periodsOK = periodsOK
    }
}

extension ProviderEnrichment {
    /// Assembles the whole enrichment — active block, this week, this month, this month's daily
    /// series — from one already-loaded set of entries.
    ///
    /// Every local provider shares this one site, and so does the iPhone's ledger count. The
    /// assembly used to be copied per provider (twelve near-identical bodies), which is the shape
    /// the defect log warns about for the append-only watermark loop (#157): a field added later
    /// gets filled in some copies and not others, and the gap is invisible in a dev environment
    /// that does not use that provider.
    public static func local(entries: [UsageEntry], now: Date = Date()) -> ProviderEnrichment {
        let fmt = UsageAggregation.localDayFormatter()
        let weekStart = UsageAggregation.startOfWeek(now)
        let monthStart = UsageAggregation.startOfMonth(now)

        var result = ProviderEnrichment()
        // Block (burn rate) computation is provider-generic — the companion rhythm follows all providers.
        result.activeBlock = UsageAggregation.activeBlock(entries: entries, now: now)
        result.blocksOK = true

        let week = UsageAggregation.period(
            entries: entries, periodKey: fmt.string(from: weekStart),
            fromDay: fmt.string(from: weekStart), toDay: fmt.string(from: now))
        let month = UsageAggregation.period(
            entries: entries, periodKey: UsageAggregation.monthKey(now),
            fromDay: fmt.string(from: monthStart), toDay: fmt.string(from: now))
        let series = UsageAggregation.monthDailySeries(entries: entries, now: now)

        result.weekTotal = week
        result.monthTotal = month
        result.monthDaily = series
        result.periodsOK = true
        return result
    }
}

// MARK: - ISO8601 with fractional seconds

public enum ISO8601Parser {
    /// resets_at 은 마이크로초("...034464+00:00") 또는 밀리초("....303Z") 형태 — 둘 다 처리.
    /// ISO8601DateFormatter 는 non-Sendable 이라 호출마다 생성 (파싱 빈도 낮음).
    public static func date(from string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: string) { return d }
        // 소수점 자릿수가 3자리가 아니면 3자리로 절단 후 재시도
        if let dotIndex = string.firstIndex(of: ".") {
            let afterDot = string.index(after: dotIndex)
            if let tzIndex = string[afterDot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
                let frac = String(string[afterDot..<tzIndex]).prefix(3)
                let padded = String(frac).padding(toLength: 3, withPad: "0", startingAt: 0)
                let rebuilt = String(string[..<dotIndex]) + "." + padded + String(string[tzIndex...])
                if let d = fractional.date(from: rebuilt) { return d }
            }
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
