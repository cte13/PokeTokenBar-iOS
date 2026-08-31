import XCTest
@testable import PokeTokenBar

final class AntigravityTierSummaryTests: XCTestCase {
    private let response = """
    {
      "cloudaicompanionProject": "projects/849302-secret-account-project",
      "currentTier": {"id": "free-tier", "name": "Free", "description": "1,000 requests per day",
                      "upgradeSubscriptionUri": "https://example.com/upgrade"},
      "paidTier": {"id": "paid-tier", "name": "Pro", "description": "Higher limits"},
      "allowedTiers": [{"id": "free-tier", "name": "Free"}, {"id": "paid-tier", "name": "Pro"}],
      "gcpManaged": false
    }
    """

    /// 이 요약이 존재하는 이유 — 한도가 설명 문구에 산문으로 적혀 있을 수 있어서.
    func testKeepsTierIdentityAndDescription() {
        let summary = AntigravityTierSummary.describe(Data(response.utf8))
        XCTAssertTrue(summary.contains("id=free-tier"))
        XCTAssertTrue(summary.contains("name=Free"))
        XCTAssertTrue(summary.contains("1,000 requests per day"), "한도 단서가 될 설명이 빠졌다")
        XCTAssertTrue(summary.contains("allowedTiers[2]"))
    }

    /// 진단이 로그에 계정 식별자를 남기면 안 된다. 주의가 아니라 테스트로 지킨다.
    func testProjectIdentifierIsNeverIncluded() {
        let summary = AntigravityTierSummary.describe(Data(response.utf8))
        XCTAssertFalse(summary.contains("849302"), "계정 프로젝트 식별자가 로그로 샜다")
        XCTAssertFalse(summary.contains("cloudaicompanionProject"))
    }

    /// 화이트리스트라, 응답에 새 필드가 생겨도 자동으로 새어 나가지 않는다.
    func testUnlistedFieldsAreDropped() {
        let summary = AntigravityTierSummary.describe(Data(response.utf8))
        XCTAssertFalse(summary.contains("example.com"), "화이트리스트에 없는 필드가 포함됐다")
        XCTAssertFalse(summary.contains("upgradeSubscriptionUri"))
    }

    func testLongDescriptionsAreClipped() {
        let long = String(repeating: "x", count: 500)
        let data = Data("{\"currentTier\":{\"description\":\"\(long)\"}}".utf8)
        let summary = AntigravityTierSummary.describe(data, maxFieldLength: 20)
        XCTAssertTrue(summary.contains("…"))
        XCTAssertLessThan(summary.count, 80, "로그 회전 예산을 잡아먹는다")
    }

    func testMissingOrMalformedInputIsReportedNotEchoed() {
        XCTAssertEqual(AntigravityTierSummary.describe(Data("<html>nope</html>".utf8)), "<JSON 아님>")
        XCTAssertEqual(AntigravityTierSummary.describe(Data("{}".utf8)), "<티어 필드 없음>")
    }
}
