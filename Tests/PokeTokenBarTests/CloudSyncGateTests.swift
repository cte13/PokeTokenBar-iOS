import Foundation
import PokeTokenBarShared
import XCTest

@testable import PokeTokenBar

/// 자격증명 없는 Mac 빌드가 CloudKit 진입에서 SIGTRAP 으로 죽던 결함의 가드.
///
/// 테스트 러너 자체가 자격증명 없는 프로세스라, 여기서 게이트를 지나 `CloudKitSync` 에 닿으면
/// 테스트 실행 전체가 죽는다 — 즉 이 파일의 트리거 브랜치 테스트는 결함 조건을 **실제로** 재현한다.
/// (가드를 빼면 `swift test` 가 signal 5 로 끝나는 것을 확인했다.)
final class CloudSyncGateTests: XCTestCase {
    // MARK: 게이트 입력 — 실제 프로세스를 읽는다

    /// 러너는 서명에 iCloud 자격증명이 없다. 이게 참이면 아래 트리거 테스트들이 전제를 잃는다.
    func testTestRunnerIsReportedAsUnentitled() {
        XCTAssertFalse(CloudSyncGate.hasICloudEntitlement)
    }

    // MARK: 트리거 브랜치 — 자격증명 없는 프로세스에서 호출해도 살아남는다

    func testSaveWithoutEntitlementReturnsInsteadOfTrapping() async throws {
        try await CloudSyncGate.save(Self.samplePayload)
    }

    func testDeleteWithoutEntitlementReturnsInsteadOfTrapping() async throws {
        try await CloudSyncGate.delete()
    }

    // MARK: 판정(순수)

    func testParserRejectsMissingValue() {
        XCTAssertFalse(CloudSyncGate.entitlementAllowsContainer(nil))
    }

    func testParserRejectsEmptyArray() {
        XCTAssertFalse(CloudSyncGate.entitlementAllowsContainer([String]()))
    }

    func testParserRejectsOtherContainer() {
        XCTAssertFalse(CloudSyncGate.entitlementAllowsContainer(["iCloud.com.example.other"]))
    }

    func testParserRejectsNonArrayValue() {
        XCTAssertFalse(CloudSyncGate.entitlementAllowsContainer(CloudSyncGate.containerID))
    }

    func testParserAcceptsOurContainer() {
        XCTAssertTrue(CloudSyncGate.entitlementAllowsContainer(["iCloud.com.example.other", CloudSyncGate.containerID]))
    }

    /// 게이트가 보는 container id 가 실제 서명에 들어가는 값과 어긋나면 정식 빌드도 동기화를 잃는다.
    func testContainerIDMatchesTheEntitlementsFile() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/PokeTokenBar/PokeTokenBar.entitlements")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: Any])
        XCTAssertTrue(CloudSyncGate.entitlementAllowsContainer(plist[CloudSyncGate.entitlementKey]))
    }

    private static let samplePayload = PhonePayload(
        todayTokens: 1, todayCost: 0, weekTokens: 1, monthTokens: 1,
        lastUpdated: Date(timeIntervalSince1970: 1_700_000_000), serverVersion: "test",
        limits: nil, companion: nil, providers: [])
}
