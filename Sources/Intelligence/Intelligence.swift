import AgentContracts
import Foundation

// Intelligence 모듈: 발화(TranscriptUpdate) + 시선 결합(AttentionContext) + 준언어 단서를 보고
// "실행 제안(ActionProposal) / 선제 도움 제안(SuggestionCandidate) / 아무것도 안 함"을 결정한다.
//
// - 진입점: `IntentEngine` (IntentProposing 구현)
// - 로컬 빠른 경로: 네트워크 없이 규칙으로 받아쓰기·명령·선제 제안을 결정 (`LocalIntentResolver`, `SuggestionPolicy`)
// - 애매한 경우에만 Claude Messages API 호출 (`ClaudeIntentClient`)
// - 위험도 분류: `RiskClassifier`
// - API 키 로딩: `APIKeyProvider` (환경 변수 → 키체인 → GAZE_ENV_FILE)

/// 부팅 이후 경과 시간 기반 단조 시계. 앱 전체가 같은 시계를 쓰도록 주입하는 것을 권장한다.
public struct UptimeMonotonicClock: MonotonicClock {
    public init() {}
    public func now() -> MonotonicTime {
        MonotonicTime(nanoseconds: DispatchTime.now().uptimeNanoseconds)
    }
}

extension MonotonicTime {
    func adding(seconds: Double) -> MonotonicTime {
        let delta = UInt64(max(0, seconds) * 1_000_000_000)
        let (sum, overflow) = nanoseconds.addingReportingOverflow(delta)
        return MonotonicTime(nanoseconds: overflow ? UInt64.max : sum)
    }

    /// self - other (초). self가 더 이르면 음수.
    func seconds(since other: MonotonicTime) -> Double {
        if nanoseconds >= other.nanoseconds {
            return Double(nanoseconds - other.nanoseconds) / 1_000_000_000
        }
        return -Double(other.nanoseconds - nanoseconds) / 1_000_000_000
    }
}

extension AgentAction {
    var involvedTargets: [UITarget] {
        switch self {
        case .typeText(let target, _), .press(let target), .setValue(let target, _): return [target]
        case .move(let source, let destination): return [source, destination]
        }
    }
}

extension UITarget {
    static let buttonLikeRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXMenuButton", "AXPopUpButton", "AXLink", "AXCheckBox",
        "AXRadioButton", "AXMenuBarItem", "AXDisclosureTriangle", "AXTab", "AXToolbarButton",
    ]

    var isButtonLike: Bool { Self.buttonLikeRoles.contains(role) }

    /// 시선 입력·받아쓰기·값 설정이 허용되는 필드인가.
    var acceptsText: Bool { isEditable && !isSecure }
}
