import ApplicationServices
import CoreGraphics
import Foundation

/// AXUIElement 래퍼. 모듈 안에서만 쓴다. CFEqual/CFHash로 같은 요소를 판정한다.
struct AXElementRef: @unchecked Sendable, Hashable {
    let raw: AXUIElement

    static func == (lhs: AXElementRef, rhs: AXElementRef) -> Bool { CFEqual(lhs.raw, rhs.raw) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(raw)) }

    static func systemWide() -> AXElementRef { AXElementRef(raw: AXUIElementCreateSystemWide()) }
    static func application(_ pid: pid_t) -> AXElementRef { AXElementRef(raw: AXUIElementCreateApplication(pid)) }
}

enum AXAttr {
    static let role = "AXRole"
    static let subrole = "AXSubrole"
    static let roleDescription = "AXRoleDescription"
    static let title = "AXTitle"
    static let description = "AXDescription"
    static let value = "AXValue"
    static let placeholder = "AXPlaceholderValue"
    static let help = "AXHelp"
    static let position = "AXPosition"
    static let size = "AXSize"
    static let focused = "AXFocused"
    static let enabled = "AXEnabled"
    static let hidden = "AXHidden"
    static let children = "AXChildren"
    static let parent = "AXParent"
    static let windows = "AXWindows"
    static let focusedWindow = "AXFocusedWindow"
    static let mainWindow = "AXMainWindow"
    static let focusedUIElement = "AXFocusedUIElement"
    static let focusedApplication = "AXFocusedApplication"
    static let selectedText = "AXSelectedText"
    static let selectedTextRange = "AXSelectedTextRange"
    static let main = "AXMain"
}

extension AXElementRef {
    func copyAttribute(_ name: String) -> (value: CFTypeRef?, error: AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(raw, name as CFString, &value)
        return (value, error)
    }

    func string(_ name: String) -> String? {
        AXElementRef.stringValue(copyAttribute(name).value)
    }

    func bool(_ name: String) -> Bool? {
        let value = copyAttribute(name).value
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    func element(_ name: String) -> AXElementRef? {
        AXElementRef.elementValue(copyAttribute(name).value)
    }

    func elements(_ name: String) -> [AXElementRef] {
        guard let array = copyAttribute(name).value as? [AnyObject] else { return [] }
        return array.compactMap { AXElementRef.elementValue($0) }
    }

    func frame() -> CGRect? {
        guard let origin = AXElementRef.pointValue(copyAttribute(AXAttr.position).value),
              let size = AXElementRef.sizeValue(copyAttribute(AXAttr.size).value) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    func isSettable(_ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(raw, name as CFString, &settable) == .success && settable.boolValue
    }

    func actionNames() -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(raw, &names) == .success, let names = names as? [String] else { return [] }
        return names
    }

    @discardableResult
    func set(_ name: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(raw, name as CFString, value)
    }

    @discardableResult
    func perform(_ action: String) -> AXError {
        AXUIElementPerformAction(raw, action as CFString)
    }

    func pid() -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(raw, &pid) == .success ? pid : nil
    }

    func setMessagingTimeout(_ seconds: Float) {
        AXUIElementSetMessagingTimeout(raw, seconds)
    }

    func elementAtPosition(_ point: CGPoint) -> (element: AXElementRef?, error: AXError) {
        var element: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(raw, Float(point.x), Float(point.y), &element)
        return (element.map(AXElementRef.init(raw:)), error)
    }

    /// 여러 속성을 한 번의 IPC로 읽는다. 실패한 속성은 nil.
    func attributes(_ names: [String]) -> [String: AnyObject] {
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(raw, names as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &values)
        guard error == .success, let array = values as? [AnyObject], array.count == names.count else { return [:] }
        var result: [String: AnyObject] = [:]
        for (name, value) in zip(names, array) where !AXElementRef.isErrorValue(value) {
            result[name] = value
        }
        return result
    }

    /// 자기 자신 또는 조상(최대 depth 단계)이 target인지.
    /// 웹 콘텐츠(Chromium·Electron·Safari) 안의 요소인지. 이런 요소는 AX 값 쓰기가 앱 상태에 반영되지 않는 경우가 많다.
    func isInsideWebArea(maxDepth: Int = 40) -> Bool {
        var current: AXElementRef? = self
        var depth = 0
        while let node = current, depth <= maxDepth {
            if node.string(AXAttr.role) == "AXWebArea" { return true }
            current = node.element(AXAttr.parent)
            depth += 1
        }
        return false
    }

    func isSelfOrDescendant(of target: AXElementRef, maxDepth: Int = 12) -> Bool {
        var current: AXElementRef? = self
        var depth = 0
        while let node = current, depth <= maxDepth {
            if node == target { return true }
            current = node.element(AXAttr.parent)
            depth += 1
        }
        return false
    }

    // MARK: 값 변환

    static func isErrorValue(_ value: AnyObject) -> Bool {
        let cf = value as CFTypeRef
        guard CFGetTypeID(cf) == AXValueGetTypeID() else { return false }
        return AXValueGetType(unsafeDowncast(value, to: AXValue.self)) == .axError
    }

    static func stringValue(_ value: CFTypeRef?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        if CFGetTypeID(value) == CFBooleanGetTypeID() { return (value as? NSNumber)?.boolValue == true ? "1" : "0" }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func elementValue(_ value: CFTypeRef?) -> AXElementRef? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXElementRef(raw: unsafeDowncast(value as AnyObject, to: AXUIElement.self))
    }

    static func pointValue(_ value: CFTypeRef?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(unsafeDowncast(value as AnyObject, to: AXValue.self), .cgPoint, &point) ? point : nil
    }

    static func sizeValue(_ value: CFTypeRef?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(unsafeDowncast(value as AnyObject, to: AXValue.self), .cgSize, &size) ? size : nil
    }
}

extension AXError {
    var codeName: String {
        switch self {
        case .success: "success"
        case .failure: "failure"
        case .illegalArgument: "illegalArgument"
        case .invalidUIElement: "invalidUIElement"
        case .invalidUIElementObserver: "invalidUIElementObserver"
        case .cannotComplete: "cannotComplete"
        case .attributeUnsupported: "attributeUnsupported"
        case .actionUnsupported: "actionUnsupported"
        case .notificationUnsupported: "notificationUnsupported"
        case .notImplemented: "notImplemented"
        case .notificationAlreadyRegistered: "notificationAlreadyRegistered"
        case .notificationNotRegistered: "notificationNotRegistered"
        case .apiDisabled: "apiDisabled"
        case .noValue: "noValue"
        case .parameterizedAttributeUnsupported: "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: "notEnoughPrecision"
        @unknown default: "AXError(\(rawValue))"
        }
    }
}
