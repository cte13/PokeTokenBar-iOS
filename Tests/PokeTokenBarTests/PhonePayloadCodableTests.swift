import XCTest
import PokeTokenBarShared

/// Mac → iPhone 페이로드(PhoneLimitStatus) 스키마 회귀 — 새 필드는 구 버전과 양방향 호환돼야 한다.
/// TokenFormatter 가 app target 과 shared package 양쪽에 있어 import 를 섞으면 모호해지므로
/// shared 타입만 쓰는 테스트를 별도 파일로 둔다.
final class PhonePayloadCodableTests: XCTestCase {
    /// 구 Mac 이 보낸 페이로드(OpenCode Go·claudeScoped 필드 없음)도 폰 코드에서 깨지지 않는다 — nil 로 디코드.
    func testLimitStatusDecodesLegacyPayloadWithoutOpenCodeGo() throws {
        let legacy = Data("""
        {"claude5h":{"label":"5h Session","utilization":42,"resetsAt":null},
         "planDisplay":null}
        """.utf8)
        let status = try JSONDecoder().decode(PhoneLimitStatus.self, from: legacy)
        XCTAssertEqual(status.claude5h?.label, "5h Session")
        XCTAssertNil(status.claudeScoped)
        XCTAssertNil(status.opencodeGo5h)
        XCTAssertNil(status.opencodeGoWeekly)
        XCTAssertNil(status.opencodeGoMonthly)
    }

    /// 모델별(scoped) 주간 창 왕복 + orderedWindows 순서/포함 검증.
    func testLimitStatusRoundTripsScopedAndOrders() throws {
        let status = PhoneLimitStatus(
            claude5h: PhoneLimitWindow(label: "Claude 5h", utilization: 2, resetsAt: nil),
            claudeWeekly: PhoneLimitWindow(label: "Claude Weekly", utilization: 13, resetsAt: nil),
            claudeOpusWeekly: nil, claudeSonnetWeekly: nil,
            claudeScoped: [PhoneLimitWindow(label: "Claude Weekly Fable", utilization: 41, resetsAt: nil)],
            codexPrimary: PhoneLimitWindow(label: "Codex 5h", utilization: 61, resetsAt: nil),
            codexSecondary: nil,
            opencodeGo5h: PhoneLimitWindow(label: "Go 5h", utilization: 92, resetsAt: nil),
            opencodeGoWeekly: nil, opencodeGoMonthly: nil,
            planDisplay: "Max 20x")
        let decoded = try JSONDecoder().decode(
            PhoneLimitStatus.self, from: JSONEncoder().encode(status))
        XCTAssertEqual(decoded.claudeScoped?.map(\.label), ["Claude Weekly Fable"])
        XCTAssertEqual(decoded.orderedWindows.map(\.label),
                       ["Claude 5h", "Claude Weekly", "Claude Weekly Fable", "Codex 5h", "Go 5h"])
    }

    // MARK: 한도 이력

    /// 이력 필드가 없는 구 Mac 페이로드는 nil 로 떨어져야 한다 — 폰이 카드를 안 그리면 그만이고,
    /// 디코드 전체가 깨지면 구 Mac 과 페어링된 폰이 사용량까지 통째로 잃는다.
    func testLimitStatusDecodesPayloadWithoutHistory() throws {
        let legacy = Data("""
        {"claude5h":{"label":"5h Session","utilization":42,"resetsAt":null},
         "planDisplay":null}
        """.utf8)
        XCTAssertNil(try JSONDecoder().decode(PhoneLimitStatus.self, from: legacy).history)
    }

    func testLimitHistoryRoundTrips() throws {
        let end = Date(timeIntervalSince1970: 1_700_000_000)
        let status = PhoneLimitStatus(
            claude5h: nil, claudeWeekly: nil, claudeOpusWeekly: nil, claudeSonnetWeekly: nil,
            codexPrimary: nil, codexSecondary: nil, planDisplay: nil,
            warnThreshold: 80, critThreshold: 95,
            history: [PhoneLimitHistorySeries(
                label: "Claude 5h",
                windows: [
                    PhoneLimitHistoryWindow(peak: 40, end: end, truncated: false),
                    PhoneLimitHistoryWindow(peak: 97, end: end.addingTimeInterval(3600), truncated: true),
                ],
                peak: 97, median: 68.5, atOrAbove: 1)])

        let decoded = try JSONDecoder().decode(
            PhoneLimitStatus.self, from: JSONEncoder().encode(status))
        let series = try XCTUnwrap(decoded.history?.first)
        XCTAssertEqual(series.label, "Claude 5h")
        XCTAssertEqual(series.windows.map(\.peak), [40, 97])
        XCTAssertEqual(series.median, 68.5)
        XCTAssertEqual(series.atOrAbove, 1)
        XCTAssertTrue(series.hasTruncated, "관측 공백이 섞인 시리즈는 폰이 그렇게 표시해야 한다")
    }

    /// 창이 전부 완전 관측이면 "일부 미관측" 안내를 띄우면 안 된다 — 반대 방향 가드.
    func testFullyObservedSeriesIsNotFlaggedTruncated() {
        let series = PhoneLimitHistorySeries(
            label: "Claude Weekly",
            windows: [PhoneLimitHistoryWindow(peak: 12, end: .distantPast, truncated: false)],
            peak: 12, median: 12, atOrAbove: 0)
        XCTAssertFalse(series.hasTruncated)
    }

    /// 프로바이더 그룹(위젯 파이+퍼센트 행용) — 제목·순서·빈 그룹 제외를 고정한다.
    func testLimitGroupsByProviderOmitEmpty() {
        let status = PhoneLimitStatus(
            claude5h: PhoneLimitWindow(label: "Claude 5h", utilization: 2, resetsAt: nil),
            claudeWeekly: PhoneLimitWindow(label: "Claude Weekly", utilization: 13, resetsAt: nil),
            claudeOpusWeekly: nil, claudeSonnetWeekly: nil,
            claudeScoped: [PhoneLimitWindow(label: "Claude Weekly Fable", utilization: 41, resetsAt: nil)],
            codexPrimary: nil, codexSecondary: nil,   // Codex 미사용 → 그룹 없음
            opencodeGo5h: PhoneLimitWindow(label: "Go 5h", utilization: 92, resetsAt: nil),
            opencodeGoWeekly: PhoneLimitWindow(label: "Go Weekly", utilization: 74, resetsAt: nil),
            opencodeGoMonthly: PhoneLimitWindow(label: "Go Monthly", utilization: 38, resetsAt: nil),
            planDisplay: nil)

        let groups = status.limitGroups
        XCTAssertEqual(groups.map(\.title), ["Claude", "Go"], "창 없는 프로바이더는 그룹 생성 안 함")
        XCTAssertEqual(groups[0].windows.count, 3, "Claude = 5h+주간+scoped(Fable)")
        XCTAssertEqual(groups[1].windows.map(\.label), ["Go 5h", "Go Weekly", "Go Monthly"])
        // 그룹 창 순서는 orderedWindows 와 동일 소스여야 한다(두 순서가 어긋나면 위젯/앱 불일치).
        XCTAssertEqual(groups.flatMap(\.windows).map(\.label), status.orderedWindows.map(\.label))
    }

    /// 새 필드 왕복 — Go 세 창이 인코딩·디코딩을 그대로 통과한다.
    func testLimitStatusRoundTripsOpenCodeGoWindows() throws {
        let status = PhoneLimitStatus(
            claude5h: nil, claudeWeekly: nil, claudeOpusWeekly: nil, claudeSonnetWeekly: nil,
            codexPrimary: nil, codexSecondary: nil,
            opencodeGo5h: PhoneLimitWindow(label: "Go 5h", utilization: 2, resetsAt: Date(timeIntervalSince1970: 1_785_000_000)),
            opencodeGoWeekly: PhoneLimitWindow(label: "Go Weekly", utilization: 41, resetsAt: nil),
            opencodeGoMonthly: PhoneLimitWindow(label: "Go Monthly", utilization: 20, resetsAt: nil),
            planDisplay: nil)
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(PhoneLimitStatus.self, from: data)
        XCTAssertEqual(decoded.opencodeGo5h?.label, "Go 5h")
        XCTAssertEqual(decoded.opencodeGo5h?.utilization, 2)
        XCTAssertEqual(decoded.opencodeGoWeekly?.label, "Go Weekly")
        XCTAssertEqual(decoded.opencodeGoMonthly?.utilization, 20)
    }

    /// 새 필드(antigravity·임계값·주/월 비용·burn·컴패니언 확장)가 없는 구 페이로드도 nil/기본값으로 디코드된다.
    func testNewOptionalFieldsDecodeAsNilFromLegacyPayload() throws {
        let legacy = Data("""
        {"todayTokens":1,"todayCost":0.5,"weekTokens":2,"monthTokens":3,
         "lastUpdated":0,"serverVersion":"1.0",
         "limits":{"claude5h":{"label":"Claude 5h","utilization":42,"resetsAt":null},"planDisplay":null},
         "companion":{"name":"Pikachu","speciesID":25,"isShiny":false,"isEgg":false,"progress":0.1,
                      "stageText":"Stage 1/3","rarity":"common","dexCount":1,"eggProgress":0,"displayState":"idle"},
         "providers":[]}
        """.utf8)
        let payload = try JSONDecoder().decode(PhonePayload.self, from: legacy)
        XCTAssertNil(payload.weekCost)
        XCTAssertNil(payload.monthCost)
        XCTAssertNil(payload.burn)
        XCTAssertNil(payload.limits?.antigravity)
        XCTAssertNil(payload.limits?.warnThreshold)
        XCTAssertEqual(payload.limits?.effectiveWarnThreshold, 80)
        XCTAssertEqual(payload.limits?.effectiveCritThreshold, 95)
        XCTAssertNil(payload.companion?.representativeSpeciesID)
        XCTAssertNil(payload.companion?.statusText)
        XCTAssertNil(payload.companion?.lineNodes)
    }

    /// `lockedReason` 없는 구 Mac 의 상점 엔트리도 nil 로 디코드된다 — 새 폰이 구 Mac 과 붙었을 때
    /// 상점 전체가 빈 목록으로 떨어지지 않게 (PhonePayload 의 shop 은 실패 시 통째로 [] 가 된다).
    func testShopEntryDecodesLegacyPayloadWithoutLockedReason() throws {
        let legacy = Data("""
        {"id":"egg:plain","isEgg":true,"name":"Fresh Egg","itemDescription":"Reroll",
         "price":100,"ownedCount":0,"isPassive":false,"isOwned":false,"canAfford":true,
         "fallbackEmoji":"🥚"}
        """.utf8)
        let entry = try JSONDecoder().decode(PhoneShopEntry.self, from: legacy)
        XCTAssertNil(entry.lockedReason)
        XCTAssertTrue(entry.canAfford)
    }

    /// 확장 필드 왕복 + Antigravity 그룹이 orderedWindows 의 마지막에 온다.
    func testExtendedFieldsRoundTrip() throws {
        let limits = PhoneLimitStatus(
            claude5h: PhoneLimitWindow(label: "Claude 5h", utilization: 2, resetsAt: nil),
            claudeWeekly: nil, claudeOpusWeekly: nil, claudeSonnetWeekly: nil,
            codexPrimary: nil, codexSecondary: nil,
            antigravity: [PhoneLimitWindow(label: "Antigravity Gemini 5h", utilization: 75, resetsAt: nil)],
            planDisplay: "Max", warnThreshold: 60, critThreshold: 90)
        let companion = PhoneCompanionState(
            name: "Pikachu", speciesID: 25, isShiny: false, isEgg: false, progress: 0.4,
            stageText: "Stage 1/3", rarity: "common", dexCount: 3, eggProgress: 0, displayState: "focus",
            representativeSpeciesID: 6, representativeIsShiny: true, statusText: "In focus mode now.",
            natureText: "Jolly",
            lineNodes: [PhoneEvoNode(speciesID: 25, name: "Pikachu", state: .current),
                        PhoneEvoNode(speciesID: nil, name: nil, state: .future)])
        let payload = PhonePayload(
            todayTokens: 1, todayCost: 0.5, weekTokens: 2, monthTokens: 3,
            lastUpdated: Date(timeIntervalSince1970: 0), serverVersion: "2.6.0",
            limits: limits, companion: companion, providers: [],
            weekCost: 12.5, monthCost: 40,
            burn: PhoneBurnForecast(depletionDate: Date(timeIntervalSince1970: 100), beforeReset: true, tokensPerMinute: 900))
        let data = try JSONEncoder().encode(payload)
        let back = try JSONDecoder().decode(PhonePayload.self, from: data)
        XCTAssertEqual(back, payload)
        XCTAssertEqual(back.limits?.limitGroups.map(\.title), ["Claude", "Antigravity"])
        XCTAssertEqual(back.limits?.orderedWindows.last?.label, "Antigravity Gemini 5h")
        XCTAssertEqual(back.companion?.lineNodes?.last?.speciesID, nil)
    }

    /// catchLog 과 dex 확장 필드(details, unownForms, isRepresentative)가 없는 구 Mac 페이로드도
    /// 기본값(catchLog=[], isRepresentative=false, details=nil)으로 안전하게 디코드된다.
    func testLegacyPayloadWithoutCatchLogAndDetailsDecodesSafely() throws {
        let legacy = Data("""
        {"todayTokens":1,"todayCost":0.5,"weekTokens":2,"monthTokens":3,
         "lastUpdated":0,"serverVersion":"1.0",
         "dex":[{"id":25,"name":"Pikachu","rarity":"common","isShiny":false,"isRaising":false}],
         "providers":[]}
        """.utf8)
        let payload = try JSONDecoder().decode(PhonePayload.self, from: legacy)
        XCTAssertEqual(payload.catchLog, [])
        let species = try XCTUnwrap(payload.dex.first)
        XCTAssertEqual(species.id, 25)
        XCTAssertNil(species.isRepresentative)
        XCTAssertNil(species.unownFormCount)
        XCTAssertNil(species.unownForms)
        XCTAssertNil(species.details)
    }

    /// catchLog 및 개체 프로필(IV, 실능치, 기술)의 인코딩/디코딩 왕복을 검증한다.
    func testCatchLogRoundTripsWithIndividualProfile() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let entry = PhoneDexEntry(
            id: "11111111-2222-3333-4444-555555555555",
            baseID: 25,
            finalID: 26,
            rarity: "common",
            isShiny: true,
            isRaising: true,
            isReleased: false,
            natureName: "Adamant",
            caughtAt: date,
            chainOrder: [25, 26],
            chainNames: [25: "Pikachu", 26: "Raichu"],
            unownForm: nil,
            profile: PhoneIndividualProfile(
                level: 30,
                gender: "male",
                genderLabel: "♂",
                abilityName: "Static",
                abilityIsHidden: false,
                stats: [PhoneComputedStat(name: "hp", label: "HP", value: 85, iv: 31)],
                moves: [PhoneKnownMove(name: "Thunderbolt", learnedAtLevel: 25)]
            )
        )
        let payload = PhonePayload(
            todayTokens: 10, todayCost: 1.0, weekTokens: 20, monthTokens: 30,
            lastUpdated: date, serverVersion: "2.7.0",
            limits: nil, companion: nil, providers: [],
            catchLog: [entry]
        )
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(PhonePayload.self, from: data)
        XCTAssertEqual(decoded.catchLog.count, 1)
        let decEntry = decoded.catchLog[0]
        XCTAssertEqual(decEntry.id, entry.id)
        XCTAssertEqual(decEntry.finalID, 26)
        XCTAssertTrue(decEntry.isShiny)
        XCTAssertTrue(decEntry.isRaising)
        XCTAssertEqual(decEntry.natureName, "Adamant")
        XCTAssertEqual(decEntry.chainNames[26], "Raichu")
        let prof: PhoneIndividualProfile = try XCTUnwrap(decEntry.profile)
        XCTAssertEqual(prof.level, 30)
        XCTAssertEqual(prof.genderLabel, "♂")
        XCTAssertEqual(prof.stats.first?.name, "hp")
        XCTAssertEqual(prof.stats.first?.value, 85)
        XCTAssertEqual(prof.stats.first?.iv, 31)
        XCTAssertEqual(prof.moves.first?.name, "Thunderbolt")
    }

    /// 종족 상세 정보(타입, 종족값, 특성, 기술목록)와 안농 폼 목록의 인코딩/디코딩 왕복을 검증한다.
    func testDexSpeciesDetailsAndUnownFormsRoundTrip() throws {
        let details = PhoneSpeciesDetails(
            types: ["electric"],
            height: 4,
            weight: 60,
            baseStatTotal: 320,
            baseStats: [
                PhoneBaseStat(name: "hp", label: "HP", value: 35),
                PhoneBaseStat(name: "attack", label: "Attack", value: 55),
            ],
            possibleAbilities: [
                PhoneAbilityOption(name: "Static", isHidden: false),
                PhoneAbilityOption(name: "Lightning Rod", isHidden: true),
            ],
            moveList: [
                PhoneMoveListing(name: "Thunder Shock", methods: ["Level Up"]),
            ]
        )
        let species = PhoneDexSpecies(
            id: 201,
            name: "Unown",
            rarity: "rare",
            isShiny: false,
            isRaising: true,
            isRepresentative: true,
            unownFormCount: 3,
            unownForms: [
                PhoneUnownForm(form: "a", symbol: "A", isShiny: false),
                PhoneUnownForm(form: "b", symbol: "B", isShiny: true),
            ],
            details: details
        )
        let data = try JSONEncoder().encode(species)
        let decoded = try JSONDecoder().decode(PhoneDexSpecies.self, from: data)
        XCTAssertEqual(decoded.id, 201)
        XCTAssertEqual(decoded.isRepresentative, true)
        XCTAssertEqual(decoded.unownFormCount, 3)
        XCTAssertEqual(decoded.unownForms?.count, 2)
        XCTAssertEqual(decoded.unownForms?[1].form, "b")
        XCTAssertEqual(decoded.unownForms?[1].symbol, "B")
        XCTAssertTrue(decoded.unownForms?[1].isShiny ?? false)
        XCTAssertEqual(decoded.details?.types, ["electric"])
        XCTAssertEqual(decoded.details?.baseStatTotal, 320)
        XCTAssertEqual(decoded.details?.baseStats.count, 2)
        XCTAssertEqual(decoded.details?.possibleAbilities.count, 2)
        XCTAssertEqual(decoded.details?.moveList.first?.methods, ["Level Up"])
    }
}
