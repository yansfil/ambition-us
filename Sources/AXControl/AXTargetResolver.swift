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
        return store.makeTarget(element, pid: pid, observedAt: clock.now(), maxTitleLength: options.maxTitleLength)
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
