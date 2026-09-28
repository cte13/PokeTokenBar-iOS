import Foundation
import PokeTokenBarShared

/// provider 확장 포인트 — 새 소스(Gemini/OpenCode 등)는 이 protocol 구현체 추가만으로 확장
protocol UsageProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// Whether this provider contributes to cost aggregates / per-row cost UI.
    /// Cost provenance distinguishes source records, estimates, and unpriced usage.
    var reportsCost: Bool { get }

    /// 오늘 합계 (critical path) — 메뉴바 숫자와 stale 판정의 기준.
    /// 데이터 소스 자체가 없거나 오늘 사용량이 없으면 nil.
    func fetchDaily() async throws -> DailyUsage?

    /// 블록/주월 누적 상세 (best effort) — 느리거나 실패해도 메뉴바 숫자에 영향 없음.
    func fetchEnrichment() async -> ProviderEnrichment

    /// Opt-in: every entry in the enrichment window, for the iPhone's usage ledger
    /// (`PhoneLedgerPublisher`), so the phone can count this provider with the Mac off.
    /// nil (the default) keeps the provider out of the ledger — the phone then shows the Mac's
    /// last numbers for it. Adding a provider to the ledger is implementing this, nothing else.
    func phoneLedgerEntries(now: Date) async -> [LocalUsageReader.Entry]?
}

extension UsageProvider {
    var reportsCost: Bool { true }
    func phoneLedgerEntries(now: Date) async -> [LocalUsageReader.Entry]? { nil }
}

/// 부가 정보 수집 결과 — the struct and its one assembly site (`ProviderEnrichment.local`) live in
/// PokeTokenBarShared so the iPhone assembles its ledger count the same way.
typealias ProviderEnrichment = PokeTokenBarShared.ProviderEnrichment
