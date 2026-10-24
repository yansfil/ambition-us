import Synchronization

/// 정책 엔진과 코디네이터가 함께 참조하는 비상 정지·일시정지 스위치.
///
/// - `paused`: 사용자가 잠시 멈춘 상태. `resume()`으로 풀린다.
/// - `killed`: 비상 정지. `resume()`으로는 풀리지 않고 `resetKillSwitch()`로만 풀린다.
/// 두 상태 모두 모든 행동을 거부한다. 진행 중인 승인 대기까지 즉시 끊으려면
/// 스위치를 직접 건드리지 말고 `ActionCoordinator`의 같은 이름 메서드를 쓴다.
public final class AgentSafetySwitch: Sendable {
    public enum Mode: String, Sendable, Codable, Equatable {
        case active, paused, killed
    }

    private let state = Mutex<Mode>(.active)

    public init() {}

    public var mode: Mode { state.withLock { $0 } }

    /// 행동을 막아야 하면 그 이유, 아니면 nil.
    public var blockingReason: String? { Self.blockingReason(for: mode) }

    public func pause() {
        state.withLock { if $0 == .active { $0 = .paused } }
    }

    public func resume() {
        state.withLock { if $0 == .paused { $0 = .active } }
    }

    public func engageKillSwitch() {
        state.withLock { $0 = .killed }
    }

    public func resetKillSwitch() {
        state.withLock { if $0 == .killed { $0 = .active } }
    }

    static func blockingReason(for mode: Mode) -> String? {
        switch mode {
        case .active: return nil
        case .paused: return "Agent is paused"
        case .killed: return "Kill switch engaged"
        }
    }
}
