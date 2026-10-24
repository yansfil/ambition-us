import AgentContracts
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// 승인된 제안을 실행한다. 의미 동작(AXSelectedText/AXValue/AXPress)을 먼저 쓰고,
/// 불가능할 때만 합성 입력(CGEvent)으로 내려간다.
///
/// 검증 수준(Orca computer-use와 같은 의미):
/// - `verified`: 바뀐 값을 다시 읽어 확인했다.
/// - `unverifiedAccessibility`: AX 호출은 성공했지만 결과를 확인하지 못했다.
/// - `unverifiedSynthetic`: 합성 입력을 보냈을 뿐 결과는 알 수 없다.
/// 확인되지 않은 동작을 성공으로 보고하면 안 된다. 상위 계층은 verification을 함께 보여줘야 한다.
public final class AXActionExecutor: ActionExecuting {
    public struct Options: Sendable {
        public var tolerance: TargetValidation.Tolerance
        /// 의미 동작이 없을 때 합성 클릭·타이핑·드래그를 허용한다.
        public var allowSyntheticFallback: Bool
        /// 값 재확인 횟수와 간격. 앱이 비동기로 값을 갱신하는 경우를 감안한다.
        public var verificationAttempts: Int
        public var verificationInterval: TimeInterval
        /// 실행 시점에 제안이 만료됐으면 거절한다(같은 시계를 주입했을 때만 의미가 있다).
        public var rejectExpiredProposals: Bool

        public init(tolerance: TargetValidation.Tolerance = .init(), allowSyntheticFallback: Bool = true,
                    verificationAttempts: Int = 5, verificationInterval: TimeInterval = 0.06,
                    rejectExpiredProposals: Bool = true) {
            self.tolerance = tolerance
            self.allowSyntheticFallback = allowSyntheticFallback
            self.verificationAttempts = verificationAttempts
            self.verificationInterval = verificationInterval
            self.rejectExpiredProposals = rejectExpiredProposals
        }
    }

    public let store: AXElementStore
    private let clock: any MonotonicClock
    private let input: InputSynthesizer
    private let options: Options
    /// 동작은 읽기 큐와 분리해 직렬 실행한다(긴 타이핑이 시선 히트 테스트를 막지 않게).
    private let actionQueue = DispatchQueue(label: "gaze.axcontrol.action", qos: .userInitiated)

    public init(store: AXElementStore, clock: any MonotonicClock = AXUptimeClock(),
                input: InputSynthesizer = InputSynthesizer(), options: Options = .init()) {
        self.store = store
        self.clock = clock
        self.input = input
        self.options = options
    }

    public func execute(_ proposal: ActionProposal) async -> ActionOutcome {
        let primary = Self.primaryTarget(of: proposal.action)
        if options.rejectExpiredProposals, clock.now() > proposal.expiresAt {
            return outcome(proposal, .failure(AXControlError(.proposalExpired, "proposal expired before execution"), primary))
        }
        let result: StepResult = await withCheckedContinuation { continuation in
            actionQueue.async { [self] in continuation.resume(returning: perform(proposal.action)) }
        }
        return outcome(proposal, result)
    }

    // MARK: 결과

    struct StepResult: Sendable {
        var status: ActionOutcome.Status
        var verification: ActionOutcome.Verification
        var target: UITarget?
        var reason: String?

        static func failure(_ error: AXControlError, _ target: UITarget?) -> StepResult {
            StepResult(status: .failed, verification: .none, target: target, reason: error.reason)
        }

        static func success(_ verification: ActionOutcome.Verification, _ target: UITarget?, note: String? = nil) -> StepResult {
            StepResult(status: .succeeded, verification: verification, target: target, reason: note)
        }
    }

    private func outcome(_ proposal: ActionProposal, _ result: StepResult) -> ActionOutcome {
        ActionOutcome(proposalID: proposal.id, status: result.status, verification: result.verification,
                      target: result.target ?? Self.primaryTarget(of: proposal.action), time: clock.now(),
                      reason: result.reason)
    }

    static func primaryTarget(of action: AgentAction) -> UITarget {
        switch action {
        case .typeText(let target, _), .press(let target), .setValue(let target, _): target
        case .move(let source, _): source
        }
    }

    // MARK: 실행(동작 큐)

    private func perform(_ action: AgentAction) -> StepResult {
        guard AXIsProcessTrusted() else {
            return .failure(AXControlError(.accessibilityPermissionMissing, "grant Accessibility access to act on apps"),
                            Self.primaryTarget(of: action))
        }
        do {
            switch action {
            case .typeText(let target, let text): return try typeText(target, text)
            case .setValue(let target, let value): return try setValue(target, value)
            case .press(let target): return try press(target)
            case .move(let source, let destination): return try move(source, destination)
            }
        } catch let error as AXControlError {
            return .failure(error, Self.primaryTarget(of: action))
        } catch {
            return .failure(AXControlError(.accessibilityError, "\(error)"), Self.primaryTarget(of: action))
        }
    }

    /// token을 다시 찾아 pid/role/frame을 확인한다.
    private func resolveLive(_ target: UITarget) throws -> (AXElementRef, LiveElementState) {
        if store.excludedPIDs.contains(target.pid) {
            throw AXControlError(.ownProcessRejected, "refusing to act on Gaze's own windows")
        }
        guard let element = store.element(for: target.token) else {
            throw AXControlError(.elementNotFound, "token \(target.token) is unknown or expired; refresh app state")
        }
        let read = element.copyAttribute(AXAttr.role)
        switch read.error {
        case .success: break
        case .invalidUIElement:
            store.registry.remove(token: target.token)
            throw AXControlError(.elementStale, "element no longer exists")
        case .cannotComplete:
            throw AXControlError(.actionTimeout, "app did not answer accessibility requests")
        default:
            throw AXControlError(.accessibilityError, "reading role failed (\(read.error.codeName))")
        }
        let live = LiveElementState(pid: element.pid() ?? -1, role: AXElementRef.stringValue(read.value) ?? "AXUnknown",
                                    subrole: element.string(AXAttr.subrole), frame: element.frame())
        if let error = TargetValidation.validate(expected: target, live: live, tolerance: options.tolerance) {
            throw error
        }
        return (element, live)
    }

    private func rejectSecure(_ target: UITarget, _ live: LiveElementState) throws {
        if target.isSecure || AXSemantics.isSecure(role: live.role, subrole: live.subrole) {
            throw AXControlError(.secureFieldRejected, "refusing to type into a secure (password) field")
        }
    }

    // MARK: typeText

    private func typeText(_ target: UITarget, _ text: String) throws -> StepResult {
        guard !text.isEmpty else { throw AXControlError(.invalidArgument, "text is empty") }
        let (element, live) = try resolveLive(target)
        try rejectSecure(target, live)
        let before = element.string(AXAttr.value)
        element.set(AXAttr.focused, kCFBooleanTrue)

        // 웹·Electron 입력칸(터미널, 채팅창 등)은 AX로 값을 바꿔도 입력 이벤트가 나지 않아 앱 상태에 반영되지 않는다.
        // 이런 곳은 처음부터 실제 키 입력으로 넣는다.
        if !element.isInsideWebArea() {
            // 1) 커서 위치에 삽입: AXSelectedText 설정.
            if element.isSettable(AXAttr.selectedText), element.set(AXAttr.selectedText, text as CFString) == .success {
                let result = insertionResult(element, before: before, text: text, target: target, synthetic: false)
                // 값이 전혀 바뀌지 않았으면 앱이 무시한 것이므로 키 입력으로 다시 넣어도 중복되지 않는다.
                if result.verification == .verified || element.string(AXAttr.value) != before || !options.allowSyntheticFallback {
                    return result
                }
            } else if element.isSettable(AXAttr.value), let before {
                // 2) 값 끝에 덧붙이기: AXValue 설정. 커서가 중간에 있었다면 위치가 다를 수 있다.
                let expected = before + text
                if element.set(AXAttr.value, expected as CFString) == .success {
                    if let after = poll({ element.string(AXAttr.value) }, until: { $0 == expected }) ?? element.string(AXAttr.value) {
                        if after == expected { return .success(.verified, target) }
                        if after != before || !options.allowSyntheticFallback {
                            return .success(.unverifiedAccessibility, target, note: "value was set but read back differently")
                        }
                    } else {
                        return .success(.unverifiedAccessibility, target, note: "value was set but could not be read back")
                    }
                }
            }
        }

        // 3) 실제 키 입력. 대상에 포커스가 있음을 확인(없으면 클릭해서 맞춤)한 뒤에만 보낸다.
        guard options.allowSyntheticFallback else {
            throw AXControlError(.valueNotSettable, "element accepts neither AXSelectedText nor AXValue")
        }
        if InputSynthesizer.isSecureEventInputEnabled() {
            throw AXControlError(.secureInputActive, "secure event input is on; synthetic typing would be dropped")
        }
        try focusForTyping(element, live, pid: target.pid)
        let app = AXElementRef.application(target.pid)
        if let focused = app.element(AXAttr.focusedUIElement),
           AXSemantics.isSecure(role: focused.string(AXAttr.role) ?? "", subrole: focused.string(AXAttr.subrole)) {
            throw AXControlError(.secureFieldRejected, "focused element is a secure field")
        }
        input.type(text, pid: Self.isFrontmost(target.pid) ? nil : target.pid)
        return insertionResult(element, before: before, text: text, target: target, synthetic: true)
    }

    /// 키 입력 전에 대상 앱을 앞으로 가져오고 대상(또는 그 자손)에 포커스를 맞춘다. 안 되면 대상 중심을 클릭한다.
    private func focusForTyping(_ element: AXElementRef, _ live: LiveElementState, pid: pid_t) throws {
        if !Self.isFrontmost(pid) {
            NSRunningApplication(processIdentifier: pid)?.activate()
            _ = poll({ Self.isFrontmost(pid) }, until: { $0 })
        }
        func hasFocus() -> Bool {
            guard let focused = AXElementRef.application(pid).element(AXAttr.focusedUIElement) else { return false }
            return focused.isSelfOrDescendant(of: element) || element.isSelfOrDescendant(of: focused)
        }
        if hasFocus() { return }
        element.set(AXAttr.focused, kCFBooleanTrue)
        if poll(hasFocus, until: { $0 }) { return }
        let point = try clickablePoint(element, live)
        input.click(at: point)
        guard poll(hasFocus, until: { $0 }) else {
            throw AXControlError(.windowNotFocused, "could not focus the target text field")
        }
    }

    static func isFrontmost(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private func insertionResult(_ element: AXElementRef, before: String?, text: String, target: UITarget,
                                 synthetic: Bool) -> StepResult {
        let after = poll({ element.string(AXAttr.value) }, until: { AXSemantics.insertionVerified(before: before, after: $0, inserted: text) })
        if AXSemantics.insertionVerified(before: before, after: after, inserted: text) {
            return .success(.verified, target)
        }
        // 삽입은 되돌리기 어렵고 재시도하면 중복 입력이 되므로 실패가 아니라 "확인 안 됨"으로 보고한다.
        let note = after == nil ? "value could not be read back" : "read-back value does not show the inserted text"
        return .success(synthetic ? .unverifiedSynthetic : .unverifiedAccessibility, target, note: note)
    }

    // MARK: setValue

    private func setValue(_ target: UITarget, _ value: String) throws -> StepResult {
        let (element, live) = try resolveLive(target)
        try rejectSecure(target, live)
        guard element.isSettable(AXAttr.value) else {
            throw AXControlError(.valueNotSettable, "\(live.role) does not accept direct value writes")
        }
        if AXSemantics.textEntryRoles.contains(live.role) { element.set(AXAttr.focused, kCFBooleanTrue) }
        let cfValue: CFTypeRef = AXSemantics.numericValueRoles.contains(live.role) && Double(value) != nil
            ? NSNumber(value: Double(value)!) : value as CFString
        let error = element.set(AXAttr.value, cfValue)
        switch error {
        case .success: break
        case .cannotComplete: throw AXControlError(.actionTimeout, "app did not confirm the value write; effect unknown")
        case .invalidUIElement: throw AXControlError(.elementStale, "element disappeared before the value write")
        default: throw AXControlError(.accessibilityError, "setting value failed (\(error.codeName))")
        }
        let after = poll({ element.string(AXAttr.value) }, until: { AXSemantics.valueMatches(expected: value, actual: $0, role: live.role) })
        if AXSemantics.valueMatches(expected: value, actual: after, role: live.role) {
            return .success(.verified, target)
        }
        guard let after else {
            return .success(.unverifiedAccessibility, target, note: "value was set but could not be read back")
        }
        // 값 쓰기는 반복해도 안전하므로 불일치는 실패로 보고해 재시도·재관찰을 유도한다.
        throw AXControlError(.verificationFailed, "read back \"\(AXSemantics.truncate(after, maxLength: 80))\" instead of the requested value")
    }

    // MARK: press

    private func press(_ target: UITarget) throws -> StepResult {
        let (element, live) = try resolveLive(target)
        let toggles = AXSemantics.toggleRoles.contains(live.role)
        let before = toggles ? element.string(AXAttr.value) : nil

        // 입력칸·묶음·글자 같은 요소의 AXPress는 앱이 무시하는 경우가 많다. 컨트롤 역할일 때만 AXPress를 쓴다.
        let prefersAXPress = AXSemantics.interactiveRoles.contains(live.role)
        if prefersAXPress, element.actionNames().contains(AXSemantics.pressAction) {
            let error = element.perform(AXSemantics.pressAction)
            switch error {
            case .success:
                return toggleResult(element, before: before, target: target, fallback: .unverifiedAccessibility)
            case .actionUnsupported:
                break
            case .invalidUIElement:
                throw AXControlError(.elementStale, "element disappeared before press")
            default:
                // 모달을 여는 버튼 등은 동작은 했는데 응답이 늦거나 실패 코드를 돌려주기도 한다.
                // 다시 누르면 두 번 눌릴 수 있으므로 합성 클릭으로 내려가지 않는다.
                if let before, let after = poll({ element.string(AXAttr.value) }, until: { $0 != nil && $0 != before }),
                   after != before {
                    return .success(.verified, target, note: "AXPress reported \(error.codeName) but the value changed")
                }
                let code: AXControlErrorCode = error == .cannotComplete ? .actionTimeout : .accessibilityError
                throw AXControlError(code, "AXPress reported \(error.codeName); effect unknown, refresh state before retrying")
            }
        }

        guard options.allowSyntheticFallback else {
            throw AXControlError(.actionNotSupported, "element has no AXPress; available: \(element.actionNames().joined(separator: ", "))")
        }
        let center = try clickablePoint(element, live)
        input.click(at: center)
        return toggleResult(element, before: before, target: target, fallback: .unverifiedSynthetic)
    }

    private func toggleResult(_ element: AXElementRef, before: String?, target: UITarget,
                              fallback: ActionOutcome.Verification) -> StepResult {
        guard let before else { return .success(fallback, target) }
        let after = poll({ element.string(AXAttr.value) }, until: { $0 != nil && $0 != before })
        if let after, after != before { return .success(.verified, target) }
        return .success(fallback, target, note: "toggle value did not change on read-back")
    }

    /// 합성 클릭 지점. 프레임 중심의 최상단 요소가 대상(또는 그 자손)인지 확인한다.
    private func clickablePoint(_ element: AXElementRef, _ live: LiveElementState) throws -> CGPoint {
        guard let frame = live.frame?.standardized, frame.width >= 1, frame.height >= 1 else {
            throw AXControlError(.elementNotClickable, "element has no on-screen frame")
        }
        let center = frame.axCenter
        guard let hit = store.hitTest(center), hit.isSelfOrDescendant(of: element) || element.isSelfOrDescendant(of: hit) else {
            throw AXControlError(.elementOccluded, "another element covers the target at its center")
        }
        return center
    }

    // MARK: move

    private func move(_ source: UITarget, _ destination: UITarget) throws -> StepResult {
        let (sourceElement, sourceLive) = try resolveLive(source)
        let (_, destinationLive) = try resolveLive(destination)
        guard options.allowSyntheticFallback else {
            throw AXControlError(.unsupportedCapability, "move requires synthetic drag, which is disabled")
        }
        if InputSynthesizer.isSecureEventInputEnabled() {
            throw AXControlError(.secureInputActive, "secure event input is on")
        }
        let start = try clickablePoint(sourceElement, sourceLive)
        guard let destinationFrame = destinationLive.frame?.standardized, destinationFrame.width >= 1, destinationFrame.height >= 1 else {
            throw AXControlError(.elementNotClickable, "destination has no on-screen frame")
        }
        let end = destinationFrame.axCenter
        let originalFrame = sourceLive.frame

        input.drag(from: start, to: end)

        // 끌어놓은 뒤 원본 요소 위치를 다시 읽는다. 목적지와 겹치는 곳으로 옮겨졌으면 확인된 것으로 본다.
        let moved = poll({ sourceElement.frame() }, until: { frame in
            guard let frame, let originalFrame else { return false }
            return frame != originalFrame && frame.intersects(destinationFrame)
        })
        if let moved, let originalFrame, moved != originalFrame, moved.intersects(destinationFrame) {
            return .success(.verified, source)
        }
        let note = sourceElement.copyAttribute(AXAttr.role).error == .invalidUIElement
            ? "source element was replaced after the drop" : "source position did not confirm the drop"
        return .success(.unverifiedSynthetic, source, note: note)
    }

    // MARK: 재확인

    private func poll<T>(_ read: () -> T, until done: (T) -> Bool) -> T {
        var value = read()
        var attempts = 1
        while !done(value), attempts < max(1, options.verificationAttempts) {
            Thread.sleep(forTimeInterval: options.verificationInterval)
            value = read()
            attempts += 1
        }
        return value
    }
}
