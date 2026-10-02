import Foundation
import PokeTokenBarShared

// The usage aggregates and the ISO parser live in PokeTokenBarShared (the iPhone counts too).
typealias DailyUsage = PokeTokenBarShared.DailyUsage
typealias BlockUsage = PokeTokenBarShared.BlockUsage
typealias PeriodUsage = PokeTokenBarShared.PeriodUsage
typealias ISO8601Parser = PokeTokenBarShared.ISO8601Parser

// MARK: - ccusage daily

struct DailyReport: Decodable, Sendable {
    var daily: [DailyUsage]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        daily = try c.decodeIfPresent([DailyUsage].self, forKey: .daily) ?? []
    }

    private enum CodingKeys: String, CodingKey { case daily }
}

// MARK: - ccusage blocks

struct BlocksReport: Decodable, Sendable {
    var blocks: [BlockUsage]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blocks = try c.decodeIfPresent([BlockUsage].self, forKey: .blocks) ?? []
    }

    private enum CodingKeys: String, CodingKey { case blocks }
}

// MARK: - ccusage weekly / monthly

struct WeeklyReport: Decodable, Sendable {
    var weekly: [PeriodUsage]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        weekly = try c.decodeIfPresent([PeriodUsage].self, forKey: .weekly) ?? []
    }
    private enum CodingKeys: String, CodingKey { case weekly }
}

struct MonthlyReport: Decodable, Sendable {
    var monthly: [PeriodUsage]
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        monthly = try c.decodeIfPresent([PeriodUsage].self, forKey: .monthly) ?? []
    }
    private enum CodingKeys: String, CodingKey { case monthly }
}

// Claude limit models (LimitWindowSpan, LimitWindow, LimitStatus, OAuthLimitEntry) live in
// PokeTokenBarShared (`ClaudeLimits.swift`) — the iPhone fetches Claude limits itself.
typealias LimitWindowSpan = PokeTokenBarShared.LimitWindowSpan
typealias LimitWindow = PokeTokenBarShared.LimitWindow
typealias LimitStatus = PokeTokenBarShared.LimitStatus
typealias OAuthLimitEntry = PokeTokenBarShared.OAuthLimitEntry

// MARK: - Codex app-server rate limits

struct CodexRateLimitWindow: Decodable, Sendable {
    var usedPercent: Int
    var windowDurationMins: Int?
    var resetsAt: Int?

    var resetDate: Date? {
        guard let resetsAt else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(resetsAt))
    }

    var windowSpan: TimeInterval? { LimitWindowSpan.fromMinutes(windowDurationMins) }

    var displayName: String {
        switch windowDurationMins {
        case 300: return "5시간 세션"
        case 10_080: return "주간"
        case let mins? where mins >= 60 && mins % 60 == 0: return "\(mins / 60)시간"
        case let mins?: return "\(mins)분"
        case nil: return "한도"
        }
    }
}

struct CodexCreditsSnapshot: Decodable, Sendable {
    var balance: String?
    var hasCredits: Bool
    var unlimited: Bool
}

struct CodexSpendControlLimit: Decodable, Sendable {
    var limit: String
    var remainingPercent: Int
    var resetsAt: Int
    var used: String

    var usedPercent: Int { max(0, min(100, 100 - remainingPercent)) }
    var resetDate: Date { Date(timeIntervalSince1970: TimeInterval(resetsAt)) }
}

struct CodexRateLimitSnapshot: Decodable, Sendable {
    var limitId: String?
    var limitName: String?
    var primary: CodexRateLimitWindow?
    var secondary: CodexRateLimitWindow?
    var credits: CodexCreditsSnapshot?
    var individualLimit: CodexSpendControlLimit?
    var planType: String?
    var rateLimitReachedType: String?

    var hasVisibleLimit: Bool {
        primary != nil || secondary != nil || individualLimit != nil
    }

    /// bucket 표시명 — limitName/limitId 기반 ("codex" → "Codex", "codex_other" → "Codex other").
    var bucketDisplayName: String {
        let raw = limitName ?? limitId ?? "codex"
        let spaced = raw.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
}

struct CodexRateLimitStatus: Decodable, Sendable {
    var rateLimits: CodexRateLimitSnapshot
    var rateLimitsByLimitId: [String: CodexRateLimitSnapshot]?

    /// 전체 bucket 목록 — codex TUI `app_server_rate_limit_snapshots` 미러링.
    /// 서버 top-level(rateLimits)은 "codex" bucket 우선이라 codex_other 등 나머지 bucket은
    /// rateLimitsByLimitId 에만 있다. top-level + byLimitId 나머지를 limitId 기준 dedup 후 합성.
    var snapshots: [CodexRateLimitSnapshot] {
        var result = [rateLimits]
        guard let byLimitId = rateLimitsByLimitId else { return result }
        // 서버는 limitId 없는 스냅샷을 "codex" 키로 넣는다(account_processor.rs) —
        // top-level 과 같은 키/ID 는 중복이므로 제외. 정렬은 dict 순서 비결정성 제거용.
        let primaryKey = rateLimits.limitId ?? "codex"
        for (limitId, snapshot) in byLimitId.sorted(by: { $0.key < $1.key }) {
            if limitId == primaryKey { continue }
            if let id = snapshot.limitId, id == rateLimits.limitId { continue }
            result.append(snapshot)
        }
        return result
    }

    var visibleSnapshots: [CodexRateLimitSnapshot] { snapshots.filter(\.hasVisibleLimit) }

    var hasVisibleLimit: Bool { !visibleSnapshots.isEmpty }

    /// 메뉴바 표기·경고 판정용 — 전체 bucket 중 최대 5h(primary) 사용률.
    var maxPrimaryUsedPercent: Int? {
        visibleSnapshots.compactMap { $0.primary?.usedPercent }.max()
    }

    /// 전체 bucket 중 최대 secondary 사용률 — iPhone companion 표시용.
    var maxSecondaryUsedPercent: Int? {
        visibleSnapshots.compactMap { $0.secondary?.usedPercent }.max()
    }
}

// MARK: - OpenCode Go limits (opencode.ai/zen/go/v1/usage)

/// OpenCode Go 구독의 한도 창 하나 — 달러 예산($12/$30/$60)의 사용률 백분율.
/// 달러 한도 자체는 응답에 없으므로(공식 문서상 고정) %만 표시한다.
struct OpenCodeGoLimitWindow: Decodable, Sendable {
    /// "ok" | "rate-limited" — 창 소진 시 "rate-limited".
    var status: String?
    var percent: Int?
    var resetsAt: String?

    var utilization: Double? { percent.map(Double.init) }
    var isRateLimited: Bool { status == "rate-limited" }
    var resetDate: Date? { resetsAt.flatMap { ISO8601Parser.date(from: $0) } }
}

/// OpenCode Go 구독 한도 — 5h rolling / 주간 / 월간 세 창. 응답은 `{"usage": {...}}` 로 중첩된다.
/// 200 응답 자체가 Go 구독 보유를 뜻한다(미구독 키는 403).
struct OpenCodeGoLimitStatus: Decodable, Sendable {
    var rolling: OpenCodeGoLimitWindow?
    var weekly: OpenCodeGoLimitWindow?
    var monthly: OpenCodeGoLimitWindow?

    init(rolling: OpenCodeGoLimitWindow? = nil,
         weekly: OpenCodeGoLimitWindow? = nil,
         monthly: OpenCodeGoLimitWindow? = nil) {
        self.rolling = rolling
        self.weekly = weekly
        self.monthly = monthly
    }

    private enum CodingKeys: String, CodingKey { case usage }
    private enum WindowKeys: String, CodingKey { case rolling, weekly, monthly }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let usage = try container.nestedContainer(keyedBy: WindowKeys.self, forKey: .usage)
        rolling = try usage.decodeIfPresent(OpenCodeGoLimitWindow.self, forKey: .rolling)
        weekly = try usage.decodeIfPresent(OpenCodeGoLimitWindow.self, forKey: .weekly)
        monthly = try usage.decodeIfPresent(OpenCodeGoLimitWindow.self, forKey: .monthly)
    }

    var hasVisibleLimit: Bool {
        rolling?.utilization != nil || weekly?.utilization != nil || monthly?.utilization != nil
    }

    /// 세 창 중 어느 하나라도 소진(rate-limited) 상태면 true — "한도 도달" 배지 표시용.
    var isRateLimited: Bool {
        [rolling, weekly, monthly].contains { $0?.isRateLimited == true }
    }

    /// 메뉴바 표기·경고 판정용 — 세 창 중 최대 사용률.
    var maxUsedPercent: Int? {
        [rolling?.percent, weekly?.percent, monthly?.percent].compactMap { $0 }.max()
    }
}

// MARK: - Antigravity Quota Summary (CloudCode PredictionService)

public struct AntigravityQuotaBucket: Decodable, Sendable {
    public var bucketId: String
    public var displayName: String
    public var window: String? // "5h", "weekly"
    public var resetTime: String?
    public var description: String?
    public var remainingFraction: Double

    public var resetDate: Date? {
        guard let resetTime else { return nil }
        return ISO8601Parser.date(from: resetTime)
    }

    /// 사용률 (0.0 ~ 100.0%) — remainingFraction(0.0~1.0)을 역산
    public var usedPercent: Double {
        max(0.0, min(100.0, (1.0 - remainingFraction) * 100.0))
    }

    public var is5HourWindow: Bool {
        window == "5h" || bucketId.contains("5h")
    }

    public var isWeeklyWindow: Bool {
        window == "weekly" || bucketId.contains("weekly")
    }

    /// 행 제목(`L.antigravityWindow`)과 같은 판정을 쓴다 — 이름과 마커가 다른 창을 가리키면 안 된다.
    public var windowSpan: TimeInterval? {
        if is5HourWindow { return LimitWindowSpan.fiveHour }
        if isWeeklyWindow { return LimitWindowSpan.sevenDay }
        return nil
    }

    public init(
        bucketId: String,
        displayName: String,
        window: String? = nil,
        resetTime: String? = nil,
        description: String? = nil,
        remainingFraction: Double
    ) {
        self.bucketId = bucketId
        self.displayName = displayName
        self.window = window
        self.resetTime = resetTime
        self.description = description
        self.remainingFraction = remainingFraction
    }
}

public struct AntigravityQuotaGroup: Decodable, Sendable {
    public var displayName: String
    public var description: String?
    public var buckets: [AntigravityQuotaBucket]

    public var fiveHourBucket: AntigravityQuotaBucket? {
        buckets.first(where: { $0.is5HourWindow })
    }

    public var weeklyBucket: AntigravityQuotaBucket? {
        buckets.first(where: { $0.isWeeklyWindow })
    }

    public init(
        displayName: String,
        description: String? = nil,
        buckets: [AntigravityQuotaBucket] = []
    ) {
        self.displayName = displayName
        self.description = description
        self.buckets = Self.sortBuckets(buckets)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decode(String.self, forKey: .displayName)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        let rawBuckets = try container.decodeIfPresent([AntigravityQuotaBucket].self, forKey: .buckets) ?? []
        buckets = Self.sortBuckets(rawBuckets)
    }

    private enum CodingKeys: String, CodingKey {
        case displayName, description, buckets
    }

    public static func sortBuckets(_ buckets: [AntigravityQuotaBucket]) -> [AntigravityQuotaBucket] {
        buckets.sorted { a, b in
            if a.is5HourWindow && !b.is5HourWindow { return true }
            if !a.is5HourWindow && b.is5HourWindow { return false }
            if a.isWeeklyWindow && !b.isWeeklyWindow { return true }
            if !a.isWeeklyWindow && b.isWeeklyWindow { return false }
            return a.bucketId < b.bucketId
        }
    }
}

public struct AntigravityRateLimitStatus: Decodable, Sendable {
    public var groups: [AntigravityQuotaGroup]
    public var description: String?

    public var hasVisibleLimit: Bool {
        !groups.isEmpty && groups.contains(where: { !$0.buckets.isEmpty })
    }

    /// 메뉴바 표기·경고 판정용 — 전체 그룹 중 최대 5h 사용률
    public var maxPrimaryUsedPercent: Double? {
        groups.compactMap { $0.fiveHourBucket?.usedPercent }.max()
    }

    public var geminiGroup: AntigravityQuotaGroup? {
        groups.first(where: { $0.displayName.localizedCaseInsensitiveContains("gemini") })
    }

    public var thirdPartyGroup: AntigravityQuotaGroup? {
        groups.first(where: {
            $0.displayName.localizedCaseInsensitiveContains("claude")
            || $0.displayName.localizedCaseInsensitiveContains("gpt")
            || $0.displayName.localizedCaseInsensitiveContains("3p")
        })
    }

    public init(groups: [AntigravityQuotaGroup] = [], description: String? = nil) {
        self.groups = Self.sortGroups(groups)
        self.description = description
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawGroups = try container.decodeIfPresent([AntigravityQuotaGroup].self, forKey: .groups) ?? []
        groups = Self.sortGroups(rawGroups)
        description = try container.decodeIfPresent(String.self, forKey: .description)
    }

    private enum CodingKeys: String, CodingKey {
        case groups, description
    }

    public static func sortGroups(_ groups: [AntigravityQuotaGroup]) -> [AntigravityQuotaGroup] {
        groups.sorted { a, b in
            let aIsGemini = a.displayName.localizedCaseInsensitiveContains("gemini")
            let bIsGemini = b.displayName.localizedCaseInsensitiveContains("gemini")
            if aIsGemini && !bIsGemini { return true }
            if !aIsGemini && bIsGemini { return false }
            return a.displayName < b.displayName
        }
    }
}

// MARK: - Cursor dashboard limits (api2.cursor.sh Connect RPC)

public struct CursorPlanUsage: Decodable, Sendable {
    public var totalSpend: Int?
    public var includedSpend: Int?
    public var bonusSpend: Int?
    public var remaining: Int?
    public var limit: Int?
    public var autoPercentUsed: Double?
    public var apiPercentUsed: Double?
    public var totalPercentUsed: Double?

    public var usedPercent: Double? {
        if let totalPercentUsed { return totalPercentUsed }
        guard let limit, limit > 0, let includedSpend else { return nil }
        return Double(includedSpend) / Double(limit) * 100
    }

    public var remainingDollars: Double? {
        guard let remaining else { return nil }
        return Double(remaining) / 100
    }

    public var limitDollars: Double? {
        guard let limit else { return nil }
        return Double(limit) / 100
    }

    public init(
        totalSpend: Int? = nil,
        includedSpend: Int? = nil,
        bonusSpend: Int? = nil,
        remaining: Int? = nil,
        limit: Int? = nil,
        autoPercentUsed: Double? = nil,
        apiPercentUsed: Double? = nil,
        totalPercentUsed: Double? = nil
    ) {
        self.totalSpend = totalSpend
        self.includedSpend = includedSpend
        self.bonusSpend = bonusSpend
        self.remaining = remaining
        self.limit = limit
        self.autoPercentUsed = autoPercentUsed
        self.apiPercentUsed = apiPercentUsed
        self.totalPercentUsed = totalPercentUsed
    }
}

public struct CursorRateLimitStatus: Decodable, Sendable {
    public var billingCycleStart: String?
    public var billingCycleEnd: String?
    public var planUsage: CursorPlanUsage?
    public var displayMessage: String?

    public var hasVisibleLimit: Bool {
        guard let usage = planUsage else { return false }
        if let limit = usage.limit, limit > 0 { return true }
        return usage.totalPercentUsed != nil
    }

    public var billingCycleEndDate: Date? {
        guard let billingCycleEnd else { return nil }
        return Self.epochDate(billingCycleEnd)
    }

    public init(
        billingCycleStart: String? = nil,
        billingCycleEnd: String? = nil,
        planUsage: CursorPlanUsage? = nil,
        displayMessage: String? = nil
    ) {
        self.billingCycleStart = billingCycleStart
        self.billingCycleEnd = billingCycleEnd
        self.planUsage = planUsage
        self.displayMessage = displayMessage
    }

    static func epochDate(_ raw: String) -> Date? {
        guard let epoch = Double(raw) else { return nil }
        if epoch > 1e12 { return Date(timeIntervalSince1970: epoch / 1000) }
        if epoch > 1e9 { return Date(timeIntervalSince1970: epoch) }
        return nil
    }
}

// MARK: - Provider snapshot

struct ProviderSnapshot: Sendable, Identifiable {
    var providerID: String
    var displayName: String
    var today: DailyUsage?
    var activeBlock: BlockUsage?
    var weekTotal: PeriodUsage?
    var monthTotal: PeriodUsage?
    /// This month's day-by-day totals (month start → today, empty days as zeros), or `nil` when
    /// the provider cannot produce a series. Defaulted so existing call sites stay unchanged.
    var monthDaily: [DailyUsage]? = nil
    var fetchedAt: Date
    /// Mirrors `UsageProvider.reportsCost`. Default keeps existing call sites unchanged.
    var reportsCost: Bool = true

    var id: String { providerID }
    var todayTotalTokens: Int { today?.totalTokens ?? 0 }
}
