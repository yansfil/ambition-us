import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// CGEvent 마우스·키보드·스크롤 합성. 의미 동작이 불가능할 때의 대체 경로이며,
/// Claude computer toolset 멤버(left_click, double_click, left_click_drag, scroll, key, type, hold_key,
/// mouse_move, left_mouse_down/up, cursor_position)를 실행하는 데 필요한 기본 동작을 제공한다.
/// 좌표는 모두 전역 AX/Quartz 좌표(좌상단 원점, 포인트)다. 합성 입력은 검증할 수 없으므로
/// 호출자는 결과를 `unverifiedSynthetic`으로 보고해야 한다.
public struct InputSynthesizer: Sendable {
    public enum MouseButton: String, Sendable, Codable, CaseIterable { case left, right, middle }
    public enum ScrollDirection: String, Sendable, Codable, CaseIterable { case up, down, left, right }
    public enum ScrollUnit: Sendable { case line, pixel }

    /// 합성 이벤트 표식(eventSourceUserData). Gaze의 이벤트 탭이 자기 입력을 무시할 때 쓴다.
    public static let eventMarker: Int64 = 0x4741_5A45

    /// 이벤트 사이 간격. 너무 빠르면 일부 앱이 클릭·키를 놓친다.
    public var eventInterval: TimeInterval

    public init(eventInterval: TimeInterval = 0.008) {
        self.eventInterval = eventInterval
    }

    // MARK: 마우스

    public func cursorPosition() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    public func moveMouse(to point: CGPoint) {
        post(mouse: .mouseMoved, at: point, button: .left)
    }

    public func click(at point: CGPoint, button: MouseButton = .left, clickCount: Int = 1, modifiers: KeyModifiers = []) {
        let (down, up, _) = Self.eventTypes(for: button)
        post(mouse: .mouseMoved, at: point, button: button)
        for count in 1...max(1, min(clickCount, 3)) {
            post(mouse: down, at: point, button: button, clickState: count, flags: modifiers.cgFlags)
            post(mouse: up, at: point, button: button, clickState: count, flags: modifiers.cgFlags)
        }
    }

    public func mouseDown(at point: CGPoint, button: MouseButton = .left) {
        post(mouse: Self.eventTypes(for: button).down, at: point, button: button, clickState: 1)
    }

    public func mouseUp(at point: CGPoint, button: MouseButton = .left) {
        post(mouse: Self.eventTypes(for: button).up, at: point, button: button, clickState: 1)
    }

    /// 누른 채 여러 단계로 이동한 뒤 놓는다. 일부 앱은 드래그 시작 임계값을 넘는 중간 이벤트가 있어야 반응한다.
    public func drag(from start: CGPoint, to end: CGPoint, button: MouseButton = .left, steps: Int = 12,
                     holdBeforeMove: TimeInterval = 0.08) {
        let (down, up, dragged) = Self.eventTypes(for: button)
        post(mouse: .mouseMoved, at: start, button: button)
        post(mouse: down, at: start, button: button, clickState: 1)
        Thread.sleep(forTimeInterval: holdBeforeMove)
        let n = max(1, steps)
        for i in 1...n {
            let t = CGFloat(i) / CGFloat(n)
            let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
            post(mouse: dragged, at: p, button: button, clickState: 1)
        }
        Thread.sleep(forTimeInterval: holdBeforeMove)
        post(mouse: up, at: end, button: button, clickState: 1)
    }

    /// Claude scroll 멤버 형식: 방향과 휠 칸 수.
    public func scroll(at point: CGPoint, direction: ScrollDirection, amount: Int, modifiers: KeyModifiers = []) {
        let n = Int32(max(1, amount))
        switch direction {
        case .up: scroll(at: point, deltaX: 0, deltaY: n, unit: .line, modifiers: modifiers)
        case .down: scroll(at: point, deltaX: 0, deltaY: -n, unit: .line, modifiers: modifiers)
        case .left: scroll(at: point, deltaX: n, deltaY: 0, unit: .line, modifiers: modifiers)
        case .right: scroll(at: point, deltaX: -n, deltaY: 0, unit: .line, modifiers: modifiers)
        }
    }

    /// 양수 deltaY는 위로(내용이 아래로 내려옴), 양수 deltaX는 왼쪽으로 스크롤한다.
    public func scroll(at point: CGPoint, deltaX: Int32, deltaY: Int32, unit: ScrollUnit = .line, modifiers: KeyModifiers = []) {
        post(mouse: .mouseMoved, at: point, button: .left)
        guard let event = CGEvent(scrollWheelEvent2Source: source(), units: unit == .line ? .line : .pixel,
                                  wheelCount: 2, wheel1: deltaY, wheel2: deltaX, wheel3: 0) else { return }
        event.location = point
        event.flags = modifiers.cgFlags
        mark(event)
        event.post(tap: .cghidEventTap)
        pause()
    }

    // MARK: 키보드

    /// 문자열을 유니코드 키 이벤트로 입력한다. 줄바꿈·탭은 실제 Return·Tab 키로 보낸다.
    /// - Parameter pid: 주어지면 해당 프로세스에 직접 보낸다(앞 창이 아니어도 동작하는 앱이 많다).
    public func type(_ text: String, pid: pid_t? = nil) {
        for segment in TypingSegment.segments(for: text) {
            switch segment {
            case .key(let combo):
                press(combo, pid: pid)
            case .text(let chunk):
                // CGEvent 하나에 실리는 유니코드 길이는 짧다(약 20 UTF-16). 글자 단위로 잘라 보낸다.
                for piece in Self.unicodePieces(chunk) {
                    let units = Array(piece.utf16)
                    for keyDown in [true, false] {
                        guard let event = CGEvent(keyboardEventSource: source(), virtualKey: 0, keyDown: keyDown) else { continue }
                        units.withUnsafeBufferPointer { buffer in
                            event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                        }
                        send(event, pid: pid)
                    }
                }
            }
        }
    }

    /// 글자(grapheme)를 깨지 않고 UTF-16 기준 `limit` 이하 조각으로 나눈다.
    public static func unicodePieces(_ text: String, limit: Int = 16) -> [String] {
        var pieces: [String] = []
        var current = ""
        var count = 0
        for character in text {
            let length = character.utf16.count
            if count + length > limit, !current.isEmpty {
                pieces.append(current)
                current = ""
                count = 0
            }
            current.append(character)
            count += length
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// 키 조합을 한 번 누른다. 수식 키를 먼저 누르고 마지막에 뗀다.
    public func press(_ combo: KeyCombo, pid: pid_t? = nil) {
        keyDown(combo, pid: pid)
        keyUp(combo, pid: pid)
    }

    /// xdotool/Orca 형식 문자열("cmd+a", "Return", "ctrl+a Delete").
    public func press(keys: String, pid: pid_t? = nil) throws {
        guard let combos = KeyComboParser.parseSequence(keys) else {
            throw AXControlError(.invalidArgument, "unknown key combination '\(keys)'")
        }
        combos.forEach { press($0, pid: pid) }
    }

    /// Claude hold_key 멤버: 일정 시간 누른 채 유지한다.
    public func hold(_ combo: KeyCombo, duration: TimeInterval, pid: pid_t? = nil) {
        keyDown(combo, pid: pid)
        Thread.sleep(forTimeInterval: max(0, min(duration, 10)))
        keyUp(combo, pid: pid)
    }

    /// 다른 앱(비밀번호 입력 중 등)이 보안 입력 모드를 켜면 합성 키 입력이 전달되지 않는다.
    public static func isSecureEventInputEnabled() -> Bool {
        IsSecureEventInputEnabled()
    }

    // MARK: 내부

    private func keyDown(_ combo: KeyCombo, pid: pid_t?) {
        var held: KeyModifiers = []
        for (modifier, code) in Self.modifierOrder where combo.modifiers.contains(modifier) {
            held.insert(modifier)
            postKey(code, down: true, flags: held.cgFlags, pid: pid)
        }
        postKey(combo.keyCode, down: true, flags: combo.modifiers.cgFlags, pid: pid)
    }

    private func keyUp(_ combo: KeyCombo, pid: pid_t?) {
        postKey(combo.keyCode, down: false, flags: combo.modifiers.cgFlags, pid: pid)
        var held = combo.modifiers
        for (modifier, code) in Self.modifierOrder.reversed() where combo.modifiers.contains(modifier) {
            held.remove(modifier)
            postKey(code, down: false, flags: held.cgFlags, pid: pid)
        }
    }

    private static let modifierOrder: [(KeyModifiers, CGKeyCode)] = [
        (.command, 55), (.shift, 56), (.option, 58), (.control, 59), (.function, 63),
    ]

    private func postKey(_ code: CGKeyCode, down: Bool, flags: CGEventFlags, pid: pid_t?) {
        guard let event = CGEvent(keyboardEventSource: source(), virtualKey: code, keyDown: down) else { return }
        event.flags = flags
        send(event, pid: pid)
    }

    private func send(_ event: CGEvent, pid: pid_t?) {
        mark(event)
        if let pid {
            event.postToPid(pid)
        } else {
            event.post(tap: .cghidEventTap)
        }
        pause()
    }

    private func post(mouse type: CGEventType, at point: CGPoint, button: MouseButton, clickState: Int = 0,
                      flags: CGEventFlags = []) {
        guard let event = CGEvent(mouseEventSource: source(), mouseType: type, mouseCursorPosition: point,
                                  mouseButton: Self.cgButton(button)) else { return }
        if clickState > 0 { event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState)) }
        if !flags.isEmpty { event.flags = flags }
        mark(event)
        event.post(tap: .cghidEventTap)
        pause()
    }

    private func source() -> CGEventSource? {
        CGEventSource(stateID: .hidSystemState)
    }

    private func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.eventMarker)
    }

    private func pause() {
        if eventInterval > 0 { Thread.sleep(forTimeInterval: eventInterval) }
    }

    static func cgButton(_ button: MouseButton) -> CGMouseButton {
        switch button {
        case .left: .left
        case .right: .right
        case .middle: .center
        }
    }

    static func eventTypes(for button: MouseButton) -> (down: CGEventType, up: CGEventType, dragged: CGEventType) {
        switch button {
        case .left: (.leftMouseDown, .leftMouseUp, .leftMouseDragged)
        case .right: (.rightMouseDown, .rightMouseUp, .rightMouseDragged)
        case .middle: (.otherMouseDown, .otherMouseUp, .otherMouseDragged)
        }
    }
}
