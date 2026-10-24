import AppKit
import SwiftUI

/// 앱 메뉴의 "Settings…"(⌘,) 항목을 찾는다.
///
/// **왜 필요한가.** 이 앱의 설정 화면은 팝오버 안에만 있다(`PopoverView` 가 `SettingsView` 를 렌더).
/// 예전엔 SwiftUI `Settings { … }` 씬이 ⌘, 를 가져가 **빈 창** 을 띄웠다. 이제 앱은 `_EmptyScene()`
/// 만 두고(#448) 창을 하나도 등록하지 않으므로, ⌘, 는 `install` 이 앱 메뉴에 넣는 우리 항목이 맡는다.
/// 시스템이 항목을 이미 만들어 둔 경우를 위해 찾기·리타깃 경로도 유지한다.
///
/// **왜 셀렉터로 찾나.** 제목("Settings…")은 시스템 로케일을 따라 번역된다 — 한국어 시스템에서는
/// "설정…" 이라 제목 매칭은 그 기기에서 조용히 실패한다. 셀렉터는 로케일과 무관하다.
enum SettingsMenuItem {
    /// macOS 13+ 는 `showSettingsWindow:`, 그 이전은 `showPreferencesWindow:`.
    /// 문서화된 API 가 아니라 관측된 이름이라, 못 찾는 경우가 정상 경로로 존재한다 —
    /// 그때 `install` 은 항목을 새로 만든다.
    static let actions: [Selector] = [
        Selector(("showSettingsWindow:")),
        Selector(("showPreferencesWindow:")),
    ]

    /// 메뉴 트리를 훑어 설정 항목을 돌려준다(서브메뉴 포함).
    ///
    /// 셀렉터를 먼저 보고, 못 찾으면 **⌘, 키 조합** 으로 찾는다. 실측(2026-09-02): SwiftUI 의
    /// `Settings` 씬이 만든 항목은 `showSettingsWindow:`·`showPreferencesWindow:` 어느 쪽도 아니었고,
    /// 셀렉터만 보던 구현은 항목이 눈앞에 있는데도 못 찾아 폴백 브리지로 떨어졌다(빈 창이 잠깐 뜸).
    /// 우리가 가로채려는 건 결국 "⌘, 를 누르면 열리는 것" 이므로, 키 조합이 셀렉터 이름보다
    /// 계약에 가깝고 SwiftUI 내부 변경에도 덜 흔들린다.
    static func find(in menu: NSMenu) -> NSMenuItem? {
        if let bySelector = first(in: menu, where: { item in
            guard let action = item.action else { return false }
            return actions.contains(action)
        }) {
            return bySelector
        }
        return first(in: menu) {
            $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command)
        }
    }

    private static func first(
        in menu: NSMenu, where matches: (NSMenuItem) -> Bool
    ) -> NSMenuItem? {
        for item in menu.items {
            if matches(item) { return item }
            if let submenu = item.submenu, let found = first(in: submenu, where: matches) {
                return found
            }
        }
        return nil
    }

    /// 찾은 항목을 주어진 target/action 으로 돌린다. 성공하면 true.
    @discardableResult
    static func retarget(in menu: NSMenu, to target: AnyObject, action: Selector) -> Bool {
        guard let item = find(in: menu) else { return false }
        item.target = target
        item.action = action
        return true
    }

    /// ⌘, 를 우리 액션에 연결한다: 기존 설정 항목이 있으면 돌리고, 없으면 앱 메뉴(첫 번째 최상위
    /// 항목의 서브메뉴)의 첫 구분선 뒤 — "About" 다음 — 에 새로 넣는다. 앱 메뉴가 아직 없으면 false.
    @discardableResult
    static func install(in menu: NSMenu, to target: AnyObject, action: Selector, title: String) -> Bool {
        if retarget(in: menu, to: target, action: action) { return true }
        guard let appMenu = menu.items.first?.submenu else { return false }
        let item = NSMenuItem(title: title, action: action, keyEquivalent: ",")
        item.keyEquivalentModifierMask = [.command]
        item.target = target
        let index = appMenu.items.firstIndex(where: \.isSeparatorItem).map { $0 + 1 } ?? appMenu.items.count
        appMenu.insertItem(item, at: index)
        return true
    }
}
