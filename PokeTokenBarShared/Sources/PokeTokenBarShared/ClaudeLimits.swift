import Foundation

// Claude's official usage limits. The Mac fetches them (OAuth or claude.ai session key), and the
// iPhone fetches them itself with the session key the Mac shares (`PhoneClaudeLimits`), so the
// response model, the request and the small pure helpers live here — one copy for both devices.

// MARK: - 한도 창 길이

/// 한도 창의 길이 — 페이스(균등 소진) 기준선을 그리려면 리셋 시각만으론 부족하고 창 길이가 있어야 한다.
/// 프로바이더마다 길이를 알리는 방식이 다르므로(Codex=명시 분 수, Antigravity=창 이름, Claude=kind·필드명)
/// 변환을 여기 한 곳에 모은다 — 프로바이더 분기가 UI 로 새지 않게 하는 확장 규약.
public enum LimitWindowSpan {
    public static let fiveHour: TimeInterval = 5 * 3600
    public static let sevenDay: TimeInterval = 7 * 24 * 3600

    /// 분 단위 창 길이. 0 이하는 길이로 쓸 수 없어 nil.
    public static func fromMinutes(_ minutes: Int?) -> TimeInterval? {
        guard let minutes, minutes > 0 else { return nil }
        return TimeInterval(minutes) * 60
    }

    /// oauth `limits[]` 의 kind. weekly_scoped(모델별 주간)도 창 길이는 주간과 같다.
    public static func fromKind(_ kind: String?) -> TimeInterval? {
        switch kind {
        case "session": return fiveHour
        case "weekly_all", "weekly_scoped": return sevenDay
        default: return nil
        }
    }
}

// MARK: - OAuth limits (api.anthropic.com/api/oauth/usage)

public struct LimitWindow: Codable, Sendable, Equatable {
    public var utilization: Double?
    public var resetsAt: String?

    public init(utilization: Double? = nil, resetsAt: String? = nil) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    public var resetDate: Date? {
        guard let resetsAt else { return nil }
        return ISO8601Parser.date(from: resetsAt)
    }

    /// No running window: the API sends 0% without a reset date until the account's next message.
    public var hasNotStarted: Bool { utilization == 0 && resetDate == nil }

    private enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

public struct LimitStatus: Codable, Sendable, Equatable {
    public var fiveHour: LimitWindow?
    public var sevenDay: LimitWindow?
    public var sevenDayOpus: LimitWindow?
    public var sevenDaySonnet: LimitWindow?
    public var limits: [OAuthLimitEntry]?
    /// 계정 구독 정보 — HTTP usage 응답이 아니라 OAuth 자격증명(Keychain)에서 주입한다.
    /// CodingKeys 에 없어 디코드 시 무시되고, OAuthLimitsProvider.fetch 가 채운다.
    public var subscriptionType: String?
    public var rateLimitTier: String?
    /// 토큰의 실제 주인 — usage 응답이 아니라 profile endpoint(OAuthProfileCache)에서 주입한다.
    /// 같은 기기에서 두 계정이 하나의 Keychain 항목을 덮어쓸 때 어느 계정의 한도인지 구분하는 라벨.
    public var accountEmail: String?
    public var accountOrganizationName: String?

    public init(fiveHour: LimitWindow? = nil, sevenDay: LimitWindow? = nil, sevenDayOpus: LimitWindow? = nil,
                sevenDaySonnet: LimitWindow? = nil, limits: [OAuthLimitEntry]? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
        self.limits = limits
    }

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case limits
    }

    /// subscriptionType(max/pro/free) + rateLimitTier 배수를 합친 표시 문자열.
    /// 예: subscriptionType="max", rateLimitTier="default_claude_max_20x" → "Max 20x".
    /// 배수는 등급과 무관하게 tier 에 배수 토큰이 있을 때만 붙는다(Max 전용 분기 아님).
    /// tier 에 배수 토큰이 없으면 등급명만("Pro"/"Free"), 구독 정보가 없으면 nil.
    public var planDisplay: String? {
        guard let subscriptionType, !subscriptionType.isEmpty else { return nil }
        let base = subscriptionType.prefix(1).uppercased() + subscriptionType.dropFirst()
        if let tier = rateLimitTier, let multiplier = Self.tierMultiplier(from: tier) {
            return "\(base) \(multiplier)"
        }
        return base
    }

    /// 계정 라벨 — "email · 조직명". 개인 플랜의 자동 생성 조직명("<email>'s Organization")은
    /// 이메일과 중복 정보라 생략한다(조직명에 이메일이 포함되는지로 판정). 이메일 없으면 nil —
    /// 조직명만으로는 어느 로그인인지 특정되지 않아 부분 라벨을 만들지 않는다.
    public var accountDisplay: String? {
        guard let accountEmail, !accountEmail.isEmpty else { return nil }
        guard let org = accountOrganizationName, !org.isEmpty, !org.contains(accountEmail) else {
            return accountEmail
        }
        return "\(accountEmail) · \(org)"
    }

    /// rateLimitTier 끝의 배수 토큰("20x"/"5x") 추출 — "_" 로 나눠 숫자+x 형태를 찾는다.
    /// 배수가 없는 등급("default_claude_pro")은 nil → 등급명만 표시.
    private static func tierMultiplier(from tier: String) -> String? {
        for part in tier.split(separator: "_") where part.hasSuffix("x") {
            let digits = part.dropLast()
            if !digits.isEmpty, digits.allSatisfy(\.isNumber) { return String(part) }
        }
        return nil
    }

    /// 레거시 필드가 못 담는 윈도우 — session(=five_hour)·weekly_all(=seven_day)은 레거시 행이
    /// 이미 표시하므로 제외하고, weekly_scoped(모델별 주간) 등 나머지만 추가 노출.
    /// 레거시 필드가 전부 비면(신형 응답만 오는 경우) limits 전체를 표시 대상으로 폴백.
    public var scopedLimitEntries: [OAuthLimitEntry] {
        let entries = limits ?? []
        if fiveHour == nil && sevenDay == nil { return entries }
        return entries.filter { $0.kind != "session" && $0.kind != "weekly_all" }
    }
}

/// oauth/usage 신형 `limits[]` 엔트리 — 레거시 five_hour/seven_day 를 일반화한 목록.
/// 구 seven_day_opus/seven_day_sonnet 는 null 로 바뀌었고, 모델별 주간 한도는
/// kind=weekly_scoped + scope.model.displayName 으로 여기에만 온다.
public struct OAuthLimitEntry: Codable, Sendable, Equatable {
    public var kind: String?
    public var group: String?
    public var percent: Double?
    public var severity: String?
    public var resetsAt: String?
    public var scope: Scope?
    public var isActive: Bool?

    public init(kind: String?, group: String?, percent: Double?, severity: String?,
                resetsAt: String?, scope: Scope?, isActive: Bool?) {
        self.kind = kind
        self.group = group
        self.percent = percent
        self.severity = severity
        self.resetsAt = resetsAt
        self.scope = scope
        self.isActive = isActive
    }

    public struct Scope: Codable, Sendable, Equatable {
        public var model: Model?
        public init(model: Model?) { self.model = model }
        public struct Model: Codable, Sendable, Equatable {
            public var displayName: String?
            public init(displayName: String?) { self.displayName = displayName }
            private enum CodingKeys: String, CodingKey { case displayName = "display_name" }
        }
    }

    public var resetDate: Date? {
        guard let resetsAt else { return nil }
        return ISO8601Parser.date(from: resetsAt)
    }

    public var windowSpan: TimeInterval? { LimitWindowSpan.fromKind(kind) }

    private enum CodingKeys: String, CodingKey {
        case kind, group, percent, severity, scope
        case resetsAt = "resets_at"
        case isActive = "is_active"
    }
}


/// One request to claude.ai's usage endpoint with a session key — the request the Mac's
/// `SessionKeyLimitsProvider` and the iPhone both send, built in one place so headers cannot drift.
///
/// Verification trap: Cloudflare challenges curl on this endpoint (`cf-mitigated: challenge`);
/// URLSession passes. Probe with `scripts/probe-session-key.swift`, not curl.
public enum ClaudeWebUsage {
    public static let base = URL(string: "https://claude.ai/api")!

    /// claude.ai expects browser requests — without Origin/Referer/UA it may refuse.
    public static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    public static func usageURL(organizationID: String) -> URL {
        base.appendingPathComponent("organizations").appendingPathComponent(organizationID)
            .appendingPathComponent("usage")
    }

    public static func request(_ url: URL, sessionKey: String, timeout: TimeInterval = 15) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        // The cookie goes in as a header. A shared cookie store could overwrite it and swap accounts.
        request.httpShouldHandleCookies = false
        request.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        return request
    }

    /// Retry-After 헤더(초 형식만) 파싱 — HTTP-date 형식·비정상 값은 nil(백오프 기본값 사용).
    /// 서버가 과도한 값을 줘도 1시간으로 캡.
    public static func retryAfterSeconds(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)),
              seconds > 0 else { return nil }
        return min(seconds, 3600)
    }
}

/// When a 5-hour window runs out at the current burn — pure, shared by the Mac's forecast and the
/// phone's own count.
public enum ClaudeLimitForecast {
    public static func depletion(blockTokens: Int, tokensPerMinute: Double, utilization: Double,
                                 now: Date) -> Date? {
        guard utilization >= 5, utilization < 100, blockTokens > 0,
              tokensPerMinute >= 10_000 else { return nil }
        let tokensPerPercent = Double(blockTokens) / utilization
        let minutesLeft = (100 - utilization) * tokensPerPercent / tokensPerMinute
        guard minutesLeft.isFinite, minutesLeft < 60 * 24 else { return nil }
        return now.addingTimeInterval(minutesLeft * 60)
    }
}

/// 원격 한도 endpoint 의 최소 조회 간격.
///
/// 사용량 스캔 주기(`refreshInterval`, 1~15분)는 **로컬 파일 읽기**를 위한 값인데, 한도 조회가 같은
/// 틱에 묶여 있어서 그 설정이 그대로 외부 endpoint 호출 빈도가 됐다. 2분으로 두자 실측으로 429 가
/// 반복됐다(`claude limits rate-limited: backing off 300s`, 2026-08-30). 사용자는 "사용량을 자주
/// 갱신"을 고른 것이지 "비공식 endpoint 를 자주 두드림"을 고른 게 아니다.
///
/// 429 백오프(`applyLimitsBackoffIfRateLimited`)와는 역할이 다르다 — 백오프는 이미 맞고 나서
/// 물러나는 사후 대응이고, 이 게이트는 애초에 그 빈도로 두드리지 않게 하는 사전 조건이다. 둘은 겹쳐서 쓴다.
public enum LimitsPollCadence {
    /// 5분. 한도 창(5시간·주간)은 이보다 훨씬 느리게 움직이고, UI 의 stale 기준(`claudeLimitsStale`,
    /// 15분)보다 넉넉히 짧아 "오래된 값" 표시를 유발하지 않는다.
    ///
    /// 값의 출처는 OpenCode Go 가 먼저 쓰던 `opencodeGoPollInterval` 이다 — 그 엔드포인트는 3-table
    /// join 이고 공식 캐시 헤더/폴링 가이드가 없어(anomalyco/opencode#16513 리뷰 지적) 실패 사용자도
    /// 최대 12 req/h 로 묶으려고 5분을 골랐다. 같은 근거가 나머지 원격 한도에도 그대로 적용된다.
    public static let minimumInterval: TimeInterval = 300

    /// 마지막 **시도** 기준이다(성공 아님). rate limit 은 요청 수를 세지 성공 수를 세지 않으므로,
    /// 실패한 요청도 간격에 포함해야 게이트가 의미를 갖는다.
    public static func shouldFetch(lastAttemptAt: Date?,
                            now: Date = Date(),
                            minimumInterval: TimeInterval = minimumInterval) -> Bool
    {
        guard let lastAttemptAt else { return true }   // 첫 조회는 항상 통과(기동 직후 빈 화면 방지)
        return now.timeIntervalSince(lastAttemptAt) >= minimumInterval
    }
}
