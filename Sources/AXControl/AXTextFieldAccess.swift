import AgentContracts
import ApplicationServices
import Foundation

/// 받아쓰기 원장에 넘길 입력란 상태. 오프셋은 UTF-16 단위(AXSelectedTextRange와 같다).
public struct AXTextFieldState: Sendable, Equatable {
    public let value: String
    public let selectionLocation: Int
    public let selectionLength: Int
    public init(value: String, selectionLocation: Int, selectionLength: Int) {
        self.value = value; self.selectionLocation = selectionLocation; self.selectionLength = selectionLength
    }
}

/// token으로 가리킨 입력란의 값·선택 범위를 읽고 캐럿을 옮긴다.
///
/// 받아쓰기 원장은 편집 직전·직후 필드 상태를 비교해 사용자 개입을 감지한다. 보안(비밀번호) 필드와
/// Gaze 자신의 창은 읽지 않는다. resolver·executor와 같은 `AXElementStore`를 써야 token이 통한다.
public final class AXTextFieldAccess: Sendable {
    public let store: AXElementStore

    public init(store: AXElementStore) {
        self.store = store
    }

    /// 값과 선택 범위. 요소가 사라졌거나 보안 필드거나 범위를 읽을 수 없으면 nil.
    public func state(of target: UITarget) async -> AXTextFieldState? {
        await store.onReadQueue { [store] in
            guard let element = Self.liveElement(target, store: store) else { return nil }
            let a = element.attributes([AXAttr.value, AXAttr.selectedTextRange])
            guard let range = Self.rangeValue(a[AXAttr.selectedTextRange]) else { return nil }
            let value = AXElementRef.stringValue(a[AXAttr.value]) ?? ""
            return AXTextFieldState(value: value, selectionLocation: range.location, selectionLength: range.length)
        }
    }

    /// 선택 범위(길이 0이면 캐럿)를 바꾼다. 성공하면 true.
    @discardableResult
    public func setSelection(of target: UITarget, location: Int, length: Int) async -> Bool {
        await store.onReadQueue { [store] in
            guard location >= 0, length >= 0, let element = Self.liveElement(target, store: store) else { return false }
            var range = CFRange(location: location, length: length)
            guard let value = AXValueCreate(.cfRange, &range) else { return false }
            return element.set(AXAttr.selectedTextRange, value) == .success
        }
    }

    private static func liveElement(_ target: UITarget, store: AXElementStore) -> AXElementRef? {
        guard AXIsProcessTrusted(), !target.isSecure, !store.excludedPIDs.contains(target.pid),
              let element = store.element(for: target.token), element.pid() == target.pid else { return nil }
        let role = element.string(AXAttr.role) ?? ""
        guard !AXSemantics.isSecure(role: role, subrole: element.string(AXAttr.subrole)) else { return nil }
        return element
    }

    static func rangeValue(_ value: CFTypeRef?) -> CFRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange(location: 0, length: 0)
        return AXValueGetValue(unsafeDowncast(value as AnyObject, to: AXValue.self), .cfRange, &range) ? range : nil
    }
}
