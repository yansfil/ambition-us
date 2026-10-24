import AgentContracts
import Dispatch

// AXControl 모듈 개요
//
// 접근성 트리 우선, 의미 동작(AXPress/AXValue) 우선, 합성 입력(CGEvent)은 대체 경로로만 쓴다.
// Orca computer-use 헬퍼와 Claude computer use의 동작 집합·오류 코드·검증 수준을 따른다.
//
// - AXTargetResolver: 전역 좌표·포커스 → UITarget. AXUIElement는 AXElementStore의 token 뒤에 숨긴다.
// - AppStateReader / AppStateSnapshot: 앱 하나의 압축 색인 트리 텍스트 + 요소 프레임.
// - AXActionExecutor: 실행 직전 token 재해석·pid/role/frame 검증 후 동작, 값을 다시 읽어 검증 수준을 정한다.
// - InputSynthesizer / ScreenCapture: Claude computer toolset 실행기를 위한 CGEvent 입력과 화면 캡처.
// - PermissionStatus: 손쉬운 사용·화면 기록 권한 확인.
//
// 좌표 규약: 별도 표기가 없으면 전역 AX/Quartz 좌표(주 화면 좌상단 원점, 포인트 단위)를 쓴다.
// Apple의 `Accessibility` 프레임워크와 이름이 겹치지 않도록 모듈 이름을 AXControl로 두었고,
// 접근성 API는 ApplicationServices에서 가져온다.

/// Orca computer-use 오류 코드와 이름을 맞춘 실패 분류. `ActionOutcome.reason`은 "code: message" 형식이다.
public enum AXControlErrorCode: String, Sendable, Codable, CaseIterable {
    case accessibilityPermissionMissing = "accessibility_permission_missing"
    case screenRecordingPermissionMissing = "screen_recording_permission_missing"
    /// token을 모르거나 레지스트리에서 밀려났다. 상태를 다시 읽어야 한다.
    case elementNotFound = "element_not_found"
    /// 요소가 사라졌거나 pid/role이 바뀌었다.
    case elementStale = "element_stale"
    /// 제안 시점과 비교해 프레임이 허용 범위 이상 움직였다.
    case elementMoved = "element_moved"
    /// 합성 클릭 지점의 최상단 요소가 대상이 아니다.
    case elementOccluded = "element_occluded"
    case elementNotClickable = "element_not_clickable"
    case actionNotSupported = "action_not_supported"
    case valueNotSettable = "value_not_settable"
    /// 비밀번호 필드에는 입력하지 않는다.
    case secureFieldRejected = "secure_field_rejected"
    /// 시스템 보안 입력 모드가 켜져 있어 합성 키 입력이 막힌다.
    case secureInputActive = "secure_input_active"
    /// Gaze 자신(오버레이 등)에는 동작하지 않는다.
    case ownProcessRejected = "own_process_rejected"
    case windowNotFocused = "window_not_focused"
    case proposalExpired = "proposal_expired"
    /// 값을 다시 읽었더니 기대와 달랐다.
    case verificationFailed = "verification_failed"
    case accessibilityError = "accessibility_error"
    /// 앱이 제때 응답하지 않았다. 효과는 알 수 없다.
    case actionTimeout = "action_timeout"
    case unsupportedCapability = "unsupported_capability"
    case invalidArgument = "invalid_argument"
}

public struct AXControlError: Error, Sendable, Equatable, CustomStringConvertible {
    public let code: AXControlErrorCode
    public let message: String

    public init(_ code: AXControlErrorCode, _ message: String) {
        self.code = code
        self.message = message
    }

    /// `ActionOutcome.reason`에 넣는 문자열.
    public var reason: String { "\(code.rawValue): \(message)" }
    public var description: String { reason }

    /// "code: message" 형식의 reason에서 코드를 되읽는다.
    public static func code(fromReason reason: String?) -> AXControlErrorCode? {
        guard let reason else { return nil }
        let head = reason.split(separator: ":", maxSplits: 1).first.map(String.init) ?? reason
        return AXControlErrorCode(rawValue: head.trimmingCharacters(in: .whitespaces))
    }
}

/// mach 연속 시각(CLOCK_UPTIME_RAW와 같은 기준) 나노초 시계.
/// 제안 만료 비교가 의미 있으려면 통합 시 다른 모듈과 같은 시계를 주입해야 한다.
public struct AXUptimeClock: MonotonicClock {
    public init() {}
    public func now() -> MonotonicTime { MonotonicTime(nanoseconds: DispatchTime.now().uptimeNanoseconds) }
}
