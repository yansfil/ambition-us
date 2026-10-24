import AgentContracts
import CoreGraphics
import Foundation

/// 접근성 속성 해석 규칙. 실제 UI 없이 검사할 수 있도록 순수 함수로 둔다.
public enum AXSemantics {
    public static let pressAction = "AXPress"
    public static let secureSubrole = "AXSecureTextField"

    /// 글자를 입력받는 역할.
    public static let textEntryRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// 사용자가 "이 버튼"처럼 가리킬 때 실제 동작 대상이 되는 역할.
    public static let interactiveRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXMenuButton", "AXCheckBox", "AXRadioButton",
        "AXPopUpButton", "AXDisclosureTriangle", "AXTab", "AXSwitch", "AXToggle", "AXDockItem",
    ]

    /// 스스로는 동작이 없고 상위 컨트롤의 일부일 가능성이 높은 역할.
    public static let passiveRoles: Set<String> = ["AXStaticText", "AXImage", "AXGroup", "AXUnknown"]

    /// 값이 숫자인 역할. setValue 때 숫자로 변환해 쓴다.
    public static let numericValueRoles: Set<String> = [
        "AXSlider", "AXIncrementor", "AXCheckBox", "AXRadioButton", "AXSwitch", "AXToggle", "AXValueIndicator",
        "AXLevelIndicator", "AXProgressIndicator", "AXScrollBar",
    ]

    /// 누르면 값이 바뀌어 다시 읽어 검증할 수 있는 역할.
    public static let toggleRoles: Set<String> = ["AXCheckBox", "AXRadioButton", "AXSwitch", "AXToggle", "AXDisclosureTriangle"]

    /// 트리 텍스트에 보여줄 가치가 없는 동작.
    public static let noiseActions: Set<String> = ["AXScrollToVisible", "AXShowDefaultUI", "AXShowAlternateUI"]

    /// 트리를 압축할 때 줄을 만들지 않고 자식만 올리는 역할.
    public static let flattenableRoles: Set<String> = ["AXGroup", "AXUnknown"]

    public static func isSecure(role: String, subrole: String?) -> Bool {
        subrole == secureSubrole || role == secureSubrole
    }

    public static func isEditable(role: String, subrole: String?, valueSettable: Bool, selectedTextSettable: Bool) -> Bool {
        let textual = textEntryRoles.contains(role) || subrole == secureSubrole || subrole == "AXSearchField"
        return textual && (valueSettable || selectedTextSettable)
    }

    public static func isInteractive(role: String, actions: [String]) -> Bool {
        interactiveRoles.contains(role) || actions.contains(pressAction)
    }

    /// 시선이 닿은 요소가 버튼 안의 글자·아이콘이면 버튼 자체로 올릴지 판단한다.
    public static func shouldPromote(childRole: String, childActions: [String], parentRole: String, parentActions: [String]) -> Bool {
        guard passiveRoles.contains(childRole) else { return false }
        let meaningful = childActions.filter { !noiseActions.contains($0) && $0 != "AXShowMenu" }
        guard meaningful.isEmpty else { return false }
        return isInteractive(role: parentRole, actions: parentActions)
    }

    /// 줄바꿈·탭을 공백으로 바꾸고 연속 공백을 하나로 줄인다.
    public static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    public static func truncate(_ text: String, maxLength: Int) -> String {
        guard maxLength > 0, text.count > maxLength else { return text }
        return String(text.prefix(max(1, maxLength - 1))) + "…"
    }

    static func clean(_ text: String?, maxLength: Int) -> String? {
        guard let text else { return nil }
        let collapsed = collapseWhitespace(text)
        return collapsed.isEmpty ? nil : truncate(collapsed, maxLength: maxLength)
    }

    /// UITarget.title에 쓸 이름. 제목 → 설명 → 자리표시자 → 값(비밀번호 제외) → 도움말 순.
    public static func label(title: String?, description: String?, value: String?, placeholder: String?,
                             help: String?, isSecure: Bool, maxLength: Int = 120) -> String? {
        let candidates: [String?] = [title, description, placeholder, isSecure ? nil : value, help]
        for candidate in candidates {
            if let cleaned = clean(candidate, maxLength: maxLength) { return cleaned }
        }
        return nil
    }

    /// "AXTextField" → "text field".
    public static func humanizedRole(_ role: String) -> String {
        humanize(role.hasPrefix("AX") ? String(role.dropFirst(2)) : role)
    }

    /// "AXScrollUpByPage" → "scroll up by page".
    public static func humanizedAction(_ action: String) -> String {
        humanize(action.hasPrefix("AX") ? String(action.dropFirst(2)) : action)
    }

    /// AXPress(기본 동작)와 잡음 동작을 뺀 나머지.
    public static func secondaryActions(_ actions: [String]) -> [String] {
        actions.filter { $0 != pressAction && !noiseActions.contains($0) }
    }

    static func humanize(_ camel: String) -> String {
        var words: [String] = []
        var current = ""
        let chars = Array(camel)
        for (i, ch) in chars.enumerated() {
            let boundary = ch.isUppercase && !current.isEmpty
                && (!(chars[i - 1].isUppercase) || (i + 1 < chars.count && chars[i + 1].isLowercase))
            if boundary || ch == "_" || ch == " " {
                if !current.isEmpty { words.append(current) }
                current = ch == "_" || ch == " " ? "" : String(ch)
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.map { $0.count > 1 && $0.allSatisfy(\.isUppercase) ? $0 : $0.lowercased() }.joined(separator: " ")
    }

    /// 텍스트 삽입 검증. 값이 바뀌었고 삽입한 문자열의 등장 횟수가 늘었으면 확인된 것으로 본다.
    public static func insertionVerified(before: String?, after: String?, inserted: String) -> Bool {
        guard let after, !inserted.isEmpty, after != before else { return false }
        return occurrences(of: inserted, in: after) > occurrences(of: inserted, in: before ?? "")
    }

    static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var range = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, options: [.literal], range: range) {
            count += 1
            range = found.upperBound..<haystack.endIndex
        }
        return count
    }

    /// setValue 검증. 숫자 역할은 수치로, 나머지는 문자열로 비교한다.
    public static func valueMatches(expected: String, actual: String?, role: String) -> Bool {
        guard let actual else { return false }
        if actual == expected { return true }
        if numericValueRoles.contains(role), let a = Double(actual), let e = Double(expected) {
            return abs(a - e) < 1e-6
        }
        return false
    }
}

/// Electron·Chromium 앱은 기본적으로 접근성 트리를 만들지 않는다. 켜는 속성을 결정한다.
public enum ChromiumAccessibility {
    public enum Kind: String, Sendable, Equatable { case electron, chromium, native }

    public static let chromiumBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
        "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "company.thebrowser.Browser",
        "com.citrolabs.ego.lite",
    ]

    /// 번들 ID와 Contents/Frameworks 안의 프레임워크 이름으로 종류를 판정한다.
    public static func kind(bundleID: String?, frameworkNames: [String]) -> Kind {
        if frameworkNames.contains("Electron Framework.framework") { return .electron }
        if let bundleID, chromiumBundleIDs.contains(bundleID) { return .chromium }
        let chromiumFrameworks = ["Chromium Embedded Framework.framework", "Google Chrome Framework.framework",
                                  "Microsoft Edge Framework.framework", "Brave Browser Framework.framework",
                                  "Chromium Framework.framework", "Vivaldi Framework.framework"]
        if frameworkNames.contains(where: chromiumFrameworks.contains) { return .chromium }
        return .native
    }

    /// 앱 요소에 true로 설정할 속성을 시도 순서대로 돌려준다. 첫 성공에서 멈춘다.
    /// AXEnhancedUserInterface는 창 애니메이션·위치 조정 부작용이 있어 Chromium 계열에서만 마지막 수단으로 쓴다.
    public static func attributesToEnable(for kind: Kind) -> [String] {
        switch kind {
        case .electron: ["AXManualAccessibility"]
        case .chromium: ["AXManualAccessibility", "AXEnhancedUserInterface"]
        case .native: []
        }
    }
}

/// 실행 직전에 다시 읽은 요소 상태.
public struct LiveElementState: Sendable, Equatable {
    public let pid: Int32
    public let role: String
    public let subrole: String?
    public let frame: CGRect?

    public init(pid: Int32, role: String, subrole: String?, frame: CGRect?) {
        self.pid = pid; self.role = role; self.subrole = subrole; self.frame = frame
    }
}

/// 제안이 만들어진 시점의 UITarget과 실행 직전 상태를 비교한다.
public enum TargetValidation {
    public struct Tolerance: Sendable, Equatable {
        /// 중심점이 이 거리(포인트)보다 많이 움직이면 다른 화면으로 본다.
        public var maxCenterDrift: CGFloat
        /// 너비·높이 비율이 1/x ~ x 밖이면 다른 요소로 본다. 입력하며 자라는 글상자를 감안해 넉넉히 둔다.
        public var maxSizeRatio: CGFloat

        public init(maxCenterDrift: CGFloat = 48, maxSizeRatio: CGFloat = 2.5) {
            self.maxCenterDrift = maxCenterDrift
            self.maxSizeRatio = maxSizeRatio
        }
    }

    public static func validate(expected: UITarget, live: LiveElementState, tolerance: Tolerance = .init()) -> AXControlError? {
        if live.pid != expected.pid {
            return AXControlError(.elementStale, "pid changed from \(expected.pid) to \(live.pid)")
        }
        if live.role != expected.role {
            return AXControlError(.elementStale, "role changed from \(expected.role) to \(live.role)")
        }
        let old = expected.frame.standardized
        guard old.width > 0 || old.height > 0, let liveFrame = live.frame?.standardized else { return nil }
        let drift = hypot(liveFrame.midX - old.midX, liveFrame.midY - old.midY)
        if drift > tolerance.maxCenterDrift {
            return AXControlError(.elementMoved, "element moved \(Int(drift.rounded()))pt since it was observed")
        }
        if !ratioWithin(old.width, liveFrame.width, tolerance.maxSizeRatio)
            || !ratioWithin(old.height, liveFrame.height, tolerance.maxSizeRatio) {
            return AXControlError(.elementMoved, "element size changed from \(sizeText(old)) to \(sizeText(liveFrame))")
        }
        return nil
    }

    private static func ratioWithin(_ a: CGFloat, _ b: CGFloat, _ limit: CGFloat) -> Bool {
        if a <= 1 && b <= 1 { return true }
        let lo = max(min(a, b), 1), hi = max(a, b)
        return hi / lo <= limit
    }

    private static func sizeText(_ r: CGRect) -> String { "\(Int(r.width))x\(Int(r.height))" }
}

/// 시스템 전역 히트 테스트가 Gaze 자신의 창(오버레이)을 맞혔을 때, 창 목록에서 아래에 있는 창의 주인을 고른다.
public enum HitTestFallback {
    public struct WindowInfo: Sendable, Equatable {
        public let ownerPID: Int32
        public let layer: Int
        public let bounds: CGRect
        public let alpha: Double

        public init(ownerPID: Int32, layer: Int, bounds: CGRect, alpha: Double) {
            self.ownerPID = ownerPID; self.layer = layer; self.bounds = bounds; self.alpha = alpha
        }
    }

    /// 앞에서 뒤 순서의 창 목록에서 점을 포함하고 제외 대상이 아닌 창 주인 pid들(중복 없이, 앞쪽부터).
    /// Dock처럼 화면 전체를 덮는 투명 창을 가진 시스템 앱이 있어 호출자는 요소가 나올 때까지 차례로 시도한다.
    public static func candidatePIDs(at point: CGPoint, windows: [WindowInfo], excludedPIDs: Set<Int32>) -> [Int32] {
        var result: [Int32] = []
        for window in windows {
            guard !excludedPIDs.contains(window.ownerPID), window.alpha > 0.01, window.layer >= 0 else { continue }
            guard window.bounds.width > 1, window.bounds.height > 1, window.bounds.contains(point) else { continue }
            if !result.contains(window.ownerPID) { result.append(window.ownerPID) }
        }
        return result
    }
}
