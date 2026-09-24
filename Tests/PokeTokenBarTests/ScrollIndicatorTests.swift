import XCTest
import SwiftUI
@testable import PokeTokenBar

@MainActor
final class ScrollIndicatorTests: XCTestCase {

    /// 팝오버 및 설정 화면의 모든 ScrollView 는 폭 360pt 좁은 화면에서 오버레이 스크롤 막대가
    /// 우측 수치·통계·차트·토글을 가리는 결함을 방지하기 위해 `.scrollIndicators(.never)` 를 명시해야 한다.
    func testEveryMacOSUIScrollViewHidesScrollIndicators() throws {
        let uiSources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // PokeTokenBarTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // repo root
            .appendingPathComponent("Sources/PokeTokenBar/UI")

        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: uiSources, includingPropertiesForKeys: nil))

        var totalScrollViews = 0
        var missingIndicators: [String] = []

        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let content = try String(contentsOf: url, encoding: .utf8)
            let lines = content.components(separatedBy: "\n")

            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Skip comments
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") {
                    continue
                }
                guard trimmed.contains("ScrollView {") || trimmed.contains("ScrollView(") else {
                    continue
                }

                totalScrollViews += 1
                // Look ahead up to 35 lines for .scrollIndicators(.never)
                let window = lines[index..<min(index + 35, lines.count)].joined(separator: "\n")
                if !window.contains(".scrollIndicators(.never)") {
                    missingIndicators.append("\(url.lastPathComponent):\(index + 1)")
                }
            }
        }

        XCTAssertEqual(totalScrollViews, 8, "Expected exactly 8 ScrollViews in Sources/PokeTokenBar/UI")
        XCTAssertTrue(missingIndicators.isEmpty, """
            All macOS ScrollViews in Sources/PokeTokenBar/UI must explicitly specify .scrollIndicators(.never)
            to prevent overlay scrollbars from blocking screen content.
            Missing at: \(missingIndicators.joined(separator: ", "))
            """)
    }

    /// 팝오버 및 주요 뷰가 정상적으로 호스팅되고 렌더링되는지 확인한다.
    func testShopAndBagViewsRenderWithoutCrashing() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("scroll-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        var state = CompanionState()
        state.language = .en
        state.inventory[ItemKind.rareCandy.rawValue] = 3
        try JSONEncoder().encode(state).write(to: file)
        let store = CompanionStore(fileURL: file)
        let nav = PopoverNavigation()

        let shopHost = NSHostingController(rootView: ShopView(store: store, nav: nav)
            .frame(width: PopoverMetrics.contentWidth, height: 520))
        shopHost.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(shopHost.view.fittingSize.height, 0)

        let bagHost = NSHostingController(rootView: BagView(store: store, nav: nav)
            .frame(width: PopoverMetrics.contentWidth, height: 520))
        bagHost.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(bagHost.view.fittingSize.height, 0)
    }
}
