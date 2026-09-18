import XCTest
@testable import PokeTokenBar

/// #227: `/login` to a second Team email rewrites `~/.claude/.credentials.json` with a
/// new still-valid token. The in-memory cache used to return the previous token until
/// `expiresAt`, so official 5h/weekly bars (and the #199 account label) stayed on the
/// old account while companion EXP kept moving from local jsonl.
///
/// These tests call the production `accessToken` path with an injected file URL.
/// Restoring the cache-before-file early return reintroduces the bug and must fail
/// `testClaudeAutoPollPicksUpInPlaceAccountSwitch` (verified by injection).
final class CredentialSwitchCacheTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ptb-cred-switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        KeychainReader.resetQueryCountForTesting()
    }

    override func tearDownWithError() throws {
        KeychainReader.copyMatchingForTesting = nil
        URLProtocol.unregisterClass(ClaudeUsageURLProtocol.self)
        ClaudeUsageURLProtocol.reset()
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
    }

    // MARK: Claude

    func testClaudeAutoPollPicksUpInPlaceAccountSwitch() async throws {
        let file = tempDir.appendingPathComponent("credentials.json")
        try writeClaudeCredentials(to: file, token: "token-account-a", subscription: "max")
        let cache = OAuthAccessTokenCache(credentialsFileURL: file)

        let first = try await cache.accessToken(allowKeychainPrompt: false)
        XCTAssertEqual(first, "token-account-a")
        let planA = await cache.planInfo()
        XCTAssertEqual(planA.subscriptionType, "max")

        try writeClaudeCredentials(to: file, token: "token-account-b", subscription: "team")
        let second = try await cache.accessToken(allowKeychainPrompt: false)
        XCTAssertEqual(
            second, "token-account-b",
            "auto-poll must re-read the credentials file; a still-unexpired cached token is the #227 bug")
        let planB = await cache.planInfo()
        XCTAssertEqual(planB.subscriptionType, "team")
        XCTAssertEqual(KeychainReader.queryCount, 0, "account switch via file must not touch Keychain")
    }

    /// File gone after a successful load (logout / CLAUDE_CONFIG_DIR leftover mop-up):
    /// keep serving the cached token on the auto path. Do not fall through to Keychain.
    func testClaudeAutoPollKeepsCacheWhenCredentialsFileDisappears() async throws {
        let file = tempDir.appendingPathComponent("credentials.json")
        try writeClaudeCredentials(to: file, token: "token-account-a", subscription: "max")
        let cache = OAuthAccessTokenCache(credentialsFileURL: file)

        _ = try await cache.accessToken(allowKeychainPrompt: false)
        try FileManager.default.removeItem(at: file)

        let stillCached = try await cache.accessToken(allowKeychainPrompt: false)
        XCTAssertEqual(stillCached, "token-account-a")
        XCTAssertEqual(KeychainReader.queryCount, 0)
    }

    /// `"claudeAiOauth": null` is logout-in-place, not "no file". Must not wipe a live
    /// cache — leftover mcpOAuth-only files under the default path are why
    /// `credentialsFileIsAccountOAuthMissing` already ignores CLAUDE_CONFIG_DIR.
    func testClaudeAutoPollKeepsCacheWhenFileDropsAccountOAuth() async throws {
        let file = tempDir.appendingPathComponent("credentials.json")
        try writeClaudeCredentials(to: file, token: "token-account-a", subscription: "max")
        let cache = OAuthAccessTokenCache(credentialsFileURL: file)

        _ = try await cache.accessToken(allowKeychainPrompt: false)
        try Data(#"{"claudeAiOauth":null}"#.utf8).write(to: file)

        let stillCached = try await cache.accessToken(allowKeychainPrompt: false)
        XCTAssertEqual(stillCached, "token-account-a")
        XCTAssertEqual(KeychainReader.queryCount, 0)
    }

    /// #300: Keychain-only install (no credentials file). The previous account's token is still
    /// valid, so a 401 never arrives and the in-memory cache used to answer the Refresh button
    /// forever. Restoring `bypassCache: false` on that path must fail this test.
    func testManualRefreshRereadsKeychainWhenCachedTokenIsStillValid() async throws {
        let file = tempDir.appendingPathComponent("credentials.json")
        try writeClaudeCredentials(to: file, token: "token-account-a", subscription: "team")
        let cache = OAuthAccessTokenCache(credentialsFileURL: file)
        _ = try await cache.accessToken(allowKeychainPrompt: false)
        try FileManager.default.removeItem(at: file)

        let savedGate = KeychainAccessGate.isDisabled
        KeychainAccessGate.isDisabled = false
        defer { KeychainAccessGate.isDisabled = savedGate }

        KeychainReader.resetQueryCountForTesting()
        installKeychainToken("token-account-b", subscription: "team")
        URLProtocol.registerClass(ClaudeUsageURLProtocol.self)
        AppEnv.allowLiveFetchForTesting = true
        defer {
            AppEnv.allowLiveFetchForTesting = false
            URLProtocol.unregisterClass(ClaudeUsageURLProtocol.self)
            ClaudeUsageURLProtocol.reset()
            KeychainReader.copyMatchingForTesting = nil
        }

        let provider = OAuthLimitsProvider(accessTokenCache: cache)
        _ = try await provider.fetch(allowKeychainPrompt: true)

        XCTAssertGreaterThan(KeychainReader.queryCount, 0, "Refresh must open Keychain, not the memory cache")
        XCTAssertEqual(
            ClaudeUsageURLProtocol.authorization,
            "Bearer token-account-b",
            "a still-valid cached token must not hide the account now in Keychain (#300)")

        KeychainReader.resetQueryCountForTesting()
        let auto = try await cache.accessToken(allowKeychainPrompt: false)
        XCTAssertEqual(auto, "token-account-b", "user refresh should have replaced the cache")
        XCTAssertEqual(KeychainReader.queryCount, 0, "auto-poll must still not touch Keychain")
    }

    /// Same class as #300 on the Antigravity user-refresh path. The Claude case above is the
    /// live trigger; this keeps the one-line twin from being "fixed" back independently.
    func testAntigravityUserRefreshAlsoBypassesStillValidCache() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/PokeTokenBar/Core/AntigravityRateLimitsProvider.swift"),
            encoding: .utf8)
        let fetch = source.range(of: "public func fetch(allowKeychainPrompt")
        XCTAssertNotNil(fetch)
        let body = String(source[(fetch?.lowerBound ?? source.startIndex)...].prefix(700))
        XCTAssertTrue(
            body.contains("bypassCache: allowKeychainPrompt"),
            "Antigravity user refresh must skip a still-valid cached token, same as Claude #300")
    }

    // MARK: Antigravity (same class)

    func testAntigravityAutoPollPicksUpTokenFileSwitch() async throws {
        let file = tempDir.appendingPathComponent("jetski-standalone-oauth-token")
        try writeAntigravityToken(to: file, token: "agy-account-a")
        let cache = AntigravityTokenCache(tokenFileURLs: [file])

        let first = try await cache.accessToken(allowKeychainPrompt: false)
        XCTAssertEqual(first, "agy-account-a")

        try writeAntigravityToken(to: file, token: "agy-account-b")
        let second = try await cache.accessToken(allowKeychainPrompt: false)
        XCTAssertEqual(
            second, "agy-account-b",
            "Antigravity file tokens are stored with expiresAt=nil, so cache-until-expiry never refreshes")
        XCTAssertEqual(KeychainReader.queryCount, 0)
    }

    func testAntigravityAutoPollKeepsCacheWhenTokenFileDisappears() async throws {
        let file = tempDir.appendingPathComponent("jetski-standalone-oauth-token")
        try writeAntigravityToken(to: file, token: "agy-account-a")
        let cache = AntigravityTokenCache(tokenFileURLs: [file])

        _ = try await cache.accessToken(allowKeychainPrompt: false)
        try FileManager.default.removeItem(at: file)

        let stillCached = try await cache.accessToken(allowKeychainPrompt: false)
        XCTAssertEqual(stillCached, "agy-account-a")
        XCTAssertEqual(KeychainReader.queryCount, 0)
    }

    func testAntigravityAutoPollReadsNestedTokenObject() async throws {
        let file = tempDir.appendingPathComponent("jetski-standalone-oauth-token")
        try writeAntigravityNestedToken(
            to: file,
            accessToken: "ya29.nested-token-value",
            refreshToken: "1//sample-refresh-token",
            expiry: "2099-01-01T00:00:00Z"
        )
        let cache = AntigravityTokenCache(tokenFileURLs: [file])

        let token = try await cache.accessToken(allowKeychainPrompt: false)
        XCTAssertEqual(token, "ya29.nested-token-value")
        XCTAssertEqual(KeychainReader.queryCount, 0)
    }

    func testAntigravityAutoPollPicksUpNestedTokenSwitch() async throws {
        let file = tempDir.appendingPathComponent("jetski-standalone-oauth-token")
        try writeAntigravityNestedToken(to: file, accessToken: "ya29.nested-a")
        let cache = AntigravityTokenCache(tokenFileURLs: [file])

        let first = try await cache.accessToken(allowKeychainPrompt: false)
        XCTAssertEqual(first, "ya29.nested-a")

        try writeAntigravityNestedToken(to: file, accessToken: "ya29.nested-b")
        let second = try await cache.accessToken(allowKeychainPrompt: false)
        XCTAssertEqual(second, "ya29.nested-b")
        XCTAssertEqual(KeychainReader.queryCount, 0)
    }

    func testAntigravityAutoPollReadsTopLevelAccessToken() async throws {
        let file = tempDir.appendingPathComponent("jetski-standalone-oauth-token")
        let json = "{\"access_token\":\"ya29.top-level-token\",\"refresh_token\":\"1//sample\",\"expiry\":\"2099-01-01T00:00:00Z\"}"
        try Data(json.utf8).write(to: file, options: .atomic)
        let cache = AntigravityTokenCache(tokenFileURLs: [file])

        let token = try await cache.accessToken(allowKeychainPrompt: false)
        XCTAssertEqual(token, "ya29.top-level-token")
        XCTAssertEqual(KeychainReader.queryCount, 0)
    }

    func testAntigravityGoogleClientIDIsConfigured() {
        // client_secret 은 저장소에 두지 않는다 — 설치된 바이너리에서 런타임에 읽는다(defect-log §자격증명).
        XCTAssertFalse(AntigravityRateLimitsProvider.googleClientID.isEmpty)
    }

    func testNearExpiryAccountSwitchDoesNotFallBackToPreviousCachedAccount() async throws {
        let file = tempDir.appendingPathComponent("jetski-standalone-oauth-token")
        // 1. Account A is written with valid lifetime (1 hour).
        let formatter = ISO8601DateFormatter()
        try writeAntigravityNestedToken(
            to: file,
            accessToken: "ya29.account-a",
            refreshToken: "1//refresh-a",
            expiry: formatter.string(from: Date().addingTimeInterval(3600))
        )
        let cache = AntigravityTokenCache(tokenFileURLs: [file])

        let first = try await cache.accessToken(allowKeychainPrompt: false)
        XCTAssertEqual(first, "ya29.account-a")

        // 2. File switches to Account B whose token is near-expiry (30s remaining <= 60s margin, so isExpired == true).
        try writeAntigravityNestedToken(
            to: file,
            accessToken: "ya29.account-b",
            refreshToken: nil,
            expiry: formatter.string(from: Date().addingTimeInterval(30))
        )

        // 3. Cache must NOT fall back to Account A. B has no refresh token, so the auto path may give up —
        //    but it must never answer with the previous account's token.
        let second = try? await cache.accessToken(allowKeychainPrompt: false)
        XCTAssertNotEqual(
            second, "ya29.account-a",
            "Near-expiry account switch in file must not return the previous account's cached token"
        )
        XCTAssertEqual(KeychainReader.queryCount, 0)
    }

    func testExpiredFileRefreshesAndSubsequentPollRetainsRefreshedToken() async throws {
        let file = tempDir.appendingPathComponent("jetski-standalone-oauth-token")
        // Expired token in file (e.g. expired in 2020) with valid refresh_token
        try writeAntigravityNestedToken(
            to: file,
            accessToken: "ya29.initial-expired",
            refreshToken: "1//refresh-test",
            expiry: "2020-01-01T00:00:00Z"
        )

        let refreshes = RefreshCounter()
        let cache = AntigravityTokenCache(
            tokenFileURLs: [file],
            tokenRefresher: { refreshToken, _ in
                refreshes.increment()
                XCTAssertEqual(refreshToken, "1//refresh-test")
                return .success(AntigravityOAuthCredential(
                    accessToken: "ya29.refreshed-token", refreshToken: refreshToken,
                    expiresAt: Date().addingTimeInterval(3600)))
            },
            clientSecretSource: { ["GOCSPX-test"] })

        // 1st poll: expired file triggers refresh -> receives refreshed token
        let first = try await cache.accessToken(allowKeychainPrompt: false)
        XCTAssertEqual(first, "ya29.refreshed-token")
        XCTAssertEqual(refreshes.count, 1)

        // 2nd poll: disk file still contains expired initial token, but cache retains refreshed token without another refresh
        let second = try await cache.accessToken(allowKeychainPrompt: false)
        XCTAssertEqual(second, "ya29.refreshed-token")
        XCTAssertEqual(
            refreshes.count, 1,
            "Subsequent poll with matching source credential must retain refreshed cache without another refresh"
        )
        XCTAssertEqual(KeychainReader.queryCount, 0)
    }

    func testExpiredFileRejectedRefreshDoesNotReachKeychain() async throws {
        let file = tempDir.appendingPathComponent("jetski-standalone-oauth-token")
        try writeAntigravityNestedToken(
            to: file,
            accessToken: "ya29.original-token",
            refreshToken: "1//refresh-fail",
            expiry: "2020-01-01T00:00:00Z"
        )

        let refreshes = RefreshCounter()
        let cache = AntigravityTokenCache(
            tokenFileURLs: [file],
            tokenRefresher: { _, _ in
                refreshes.increment()
                return .credentialRejected
            },
            clientSecretSource: { ["GOCSPX-test"] })
        _ = try? await cache.accessToken(allowKeychainPrompt: false)
        XCTAssertGreaterThanOrEqual(refreshes.count, 1)
        XCTAssertEqual(KeychainReader.queryCount, 0)
    }

    // MARK: fixtures

    private func writeClaudeCredentials(
        to url: URL, token: String, subscription: String, expiresIn: TimeInterval = 3600
    ) throws {
        let expiresAt = Int(Date().addingTimeInterval(expiresIn).timeIntervalSince1970)
        let json = """
        {"claudeAiOauth":{"accessToken":"\(token)","expiresAt":\(expiresAt),"subscriptionType":"\(subscription)"}}
        """
        try Data(json.utf8).write(to: url, options: .atomic)
    }

    private func installKeychainToken(_ token: String, subscription: String) {
        let expiresAt = Int(Date().addingTimeInterval(3600).timeIntervalSince1970)
        let json = """
        {"claudeAiOauth":{"accessToken":"\(token)","expiresAt":\(expiresAt),"subscriptionType":"\(subscription)"}}
        """
        let data = Data(json.utf8)
        KeychainReader.copyMatchingForTesting = { query, result in
            if (query[kSecReturnData as String] as? Bool) == true {
                result = data as CFData
                return errSecSuccess
            }
            // Accounts query must succeed. errSecItemNotFound there is "no credential",
            // not the single-item fallback (#232).
            if (query[kSecReturnAttributes as String] as? Bool) == true {
                result = [[kSecAttrAccount as String: "hello@example.com"]] as CFArray
                return errSecSuccess
            }
            return errSecItemNotFound
        }
    }

    private func writeAntigravityToken(to url: URL, token: String) throws {
        let json = "{\"token\":\"\(token)\"}"
        try Data(json.utf8).write(to: url, options: .atomic)
    }

    private func writeAntigravityNestedToken(
        to url: URL,
        accessToken: String,
        refreshToken: String? = nil,
        expiry: String? = nil
    ) throws {
        var tokenDict: [String: Any] = [
            "access_token": accessToken,
            "token_type": "Bearer"
        ]
        if let refreshToken { tokenDict["refresh_token"] = refreshToken }
        if let expiry { tokenDict["expiry"] = expiry }
        let root: [String: Any] = [
            "auth_method": "oauth",
            "token": tokenDict
        ]
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
        try data.write(to: url, options: .atomic)
    }
}

private final class RefreshCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

/// Intercepts the usage call so the Refresh path can be asserted without a live token.
private final class ClaudeUsageURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var authorization: String?

    static func reset() { authorization = nil }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.anthropic.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        if url.path == "/api/oauth/usage" {
            Self.authorization = request.value(forHTTPHeaderField: "Authorization")
            let body = Data(#"{"five_hour":{"utilization":11},"seven_day":{"utilization":22}}"#.utf8)
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
        } else {
            let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
