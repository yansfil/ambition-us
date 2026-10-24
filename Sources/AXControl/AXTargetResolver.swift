import AgentContracts
import ApplicationServices
import CoreGraphics
import Foundation

/// 전역 좌표·키보드 포커스를 UITarget으로 바꾼다.
/// AXUIElement는 store의 token 뒤에 두고 밖으로는 UITarget만 내보낸다.
public final class AXTargetResolver: UITargetResolving {
    public struct Options: Sendable {
        /// 버튼 안의 글자·아이콘을 맞히면 버튼으로 올린다.
        public var promoteToInteractiveAncestor: Bool
        /// 올릴 때 따라 올라갈 최대 단계.
        public var maxPromotionDepth: Int
        public var maxTitleLength: Int

        /// 시선이 닿은 묶음 안에서 포커스된 입력 칸을 찾을 때 허용하는 거리(포인트)와 깊이.
        public var focusedFieldRadius: CGFloat = 260
        public var maxFocusContainerDepth: Int = 14

        public init(promoteToInteractiveAncestor: Bool = true, maxPromotionDepth: Int = 3, maxTitleLength: Int = 120) {
            self.promoteToInteractiveAncestor = promoteToInteractiveAncestor
            self.maxPromotionDepth = maxPromotionDepth
            self.maxTitleLength = maxTitleLength
        }
    }

    public let store: AXElementStore
    private let clock: any MonotonicClock
    private let options: Options

    public init(store: AXElementStore = AXElementStore(), clock: any MonotonicClock = AXUptimeClock(), options: Options = .init()) {
        self.store = store
        self.clock = clock
        self.options = options
    }

    public func target(at point: CGPoint) async -> UITarget? {
        await store.onReadQueue { [self] in resolveTarget(at: point) }
    }

    public func focusedTarget() async -> UITarget? {
        await store.onReadQueue { [self] in resolveFocused() }
    }

    /// token의 현재 상태를 다시 읽은 UITarget. 요소가 사라졌으면 nil.
    public func refresh(_ target: UITarget) async -> UITarget? {
        await store.onReadQueue { [self] in
            guard let element = store.element(for: target.token), let pid = element.pid(), pid == target.pid,
                  element.copyAttribute(AXAttr.role).error != .invalidUIElement else { return nil }
            return store.makeTarget(element, pid: pid, observedAt: clock.now(), maxTitleLength: options.maxTitleLength)
        }
    }

    // MARK: 구현(읽기 큐에서 실행)

    private func resolveTarget(at point: CGPoint) -> UITarget? {
        guard AXIsProcessTrusted() else { return nil }
        guard var element = store.hitTest(point), let pid = element.pid() else { return nil }
        if store.ensureChromiumAccessibility(pid: pid), let retry = store.hitTest(point), retry.pid() == pid {
            element = retry
        }
        if options.promoteToInteractiveAncestor {
            element = promote(element)
        }
        let target = store.makeTarget(element, pid: pid, observedAt: clock.now(), maxTitleLength: options.maxTitleLength)
        if target.isEditable { return target }
        // 터미널·웹 편집기처럼 실제 입력 칸이 묶음(AXGroup) 안에 숨어 있으면, 시선이 닿은 묶음 안의 포커스된 입력 칸을 대상으로 한다.
        if let focused = focusedEditable(inside: element, pid: pid, near: point) { return focused }
        return target
    }

    /// 포커스된 편집 가능 요소가 `container` 안에 있고 시선 점 가까이에 있으면 그 요소.
    private func focusedEditable(inside container: AXElementRef, pid: pid_t, near point: CGPoint) -> UITarget? {
        guard let focused = AXElementRef.application(pid).element(AXAttr.focusedUIElement),
              focused != container else { return nil }
        var ancestor = focused.element(AXAttr.parent)
        var depth = 0
        while let current = ancestor, depth < options.maxFocusContainerDepth {
            if current == container { break }
            ancestor = current.element(AXAttr.parent)
            depth += 1
        }
        guard ancestor == container else { return nil }
        let target = store.makeTarget(focused, pid: pid, observedAt: clock.now(), maxTitleLength: options.maxTitleLength)
        guard target.isEditable, !target.isSecure else { return nil }
        let frame = target.frame
        let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
        guard (dx * dx + dy * dy).squareRoot() <= options.focusedFieldRadius else { return nil }
        return target
    }

    private func resolveFocused() -> UITarget? {
        guard AXIsProcessTrusted() else { return nil }
        let systemWide = AXElementRef.systemWide()
        var focused = systemWide.element(AXAttr.focusedUIElement)
        if focused == nil, let app = systemWide.element(AXAttr.focusedApplication) {
            focused = app.element(AXAttr.focusedUIElement)
        }
        guard let element = focused, let pid = element.pid(), !store.excludedPIDs.contains(pid) else { return nil }
        store.ensureChromiumAccessibility(pid: pid)
        return store.makeTarget(element, pid: pid, observedAt: clock.now(), maxTitleLength: options.maxTitleLength)
    }

    private func promote(_ element: AXElementRef) -> AXElementRef {
        var current = element
        for _ in 0..<max(0, options.maxPromotionDepth) {
            guard let parent = current.element(AXAttr.parent) else { break }
            let childRole = current.string(AXAttr.role) ?? "AXUnknown"
            let parentRole = parent.string(AXAttr.role) ?? "AXUnknown"
            guard AXSemantics.shouldPromote(childRole: childRole, childActions: current.actionNames(),
                                            parentRole: parentRole, parentActions: parent.actionNames()) else {
                // 묶음 안의 글자처럼 한 단계 더 위에 컨트롤이 있을 수 있으므로 수동 역할이면 계속 올라간다.
                if AXSemantics.passiveRoles.contains(childRole), AXSemantics.passiveRoles.contains(parentRole) {
                    current = parent
                    continue
                }
                break
            }
            return parent
        }
        return element
    }
}
