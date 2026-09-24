import Foundation
import PokeTokenBarShared
import Security

/// Mac 쪽 CloudKit 진입점의 단일 게이트 — 자격증명 없는 프로세스는 동기화를 건너뛴다.
///
/// `CKContainer(identifier:)` 는 iCloud container 자격증명이 없으면 throw 하지 않고 **SIGTRAP** 으로
/// 프로세스를 죽인다. 그래서 호출부의 `do/catch` 로는 못 막고, 들어가기 전에 전제조건을 직접 본다.
/// 로우 `swift build` 바이너리·`build-app.sh` 번들(서명에 entitlements 없음)이 여기 걸린다
/// (defect-log "외부 동기화" 항목). `AppEnv.isBundledApp` 로는 안 된다 — build-app.sh 번들도 번들이다.
///
/// `CloudKitSync.*` 를 Mac 코드에서 직접 부르지 말고 이 래퍼를 거친다.
enum CloudSyncGate {
    /// `Sources/PokeTokenBar/PokeTokenBar.entitlements` 와 `CloudKitSync.containerID` 와 같은 값.
    /// (Shared 의 containerID 는 internal 이라 여기서 다시 적는다 — 테스트가 entitlements 파일과 대조한다.)
    static let containerID = "iCloud.io.github.chattymin.poketokenbar"
    static let entitlementKey = "com.apple.developer.icloud-container-identifiers"

    /// 실행 중인 프로세스의 서명이 이 container 를 허용하는가. 프로세스 수명 동안 변하지 않으므로 1회 계산.
    static let hasICloudEntitlement: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(task, entitlementKey as CFString, nil)
        return entitlementAllowsContainer(value)
    }()

    /// 자격증명 값 판정(순수) — 배열에 우리 container id 가 있어야 참.
    static func entitlementAllowsContainer(_ value: Any?) -> Bool {
        guard let ids = value as? [String] else { return false }
        return ids.contains(containerID)
    }

    static func save(_ payload: PhonePayload) async throws {
        guard allowed() else { return }
        try await CloudKitSync.save(payload)
    }

    static func delete() async throws {
        guard allowed() else { return }
        try await CloudKitSync.delete()
    }

    /// 비허용이면 한 번만 로그를 남긴다 — save 는 매 refresh 마다 불리므로 반복 기록하지 않는다.
    private static func allowed() -> Bool {
        if hasICloudEntitlement { return true }
        AppLog.writeIfChanged("cloudSyncGate", "CloudKit sync disabled: process lacks the iCloud entitlement",
                              repeatAfter: .infinity)
        return false
    }
}
