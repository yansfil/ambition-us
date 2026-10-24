import AXControl
import AgentContracts
import Control
import Fusion
import Gaze
import Intelligence
import Overlay
import SpeechInput

/// 시선 입력 방식.
public enum GazeInputMode: String, Sendable {
    /// 내장 웹캠 + Vision. 보정(9점)이 필요하다.
    case camera
    /// 마우스 커서를 시선 대신 쓴다(카메라 없이 개발·시연).
    case mouse
}

/// 실제 앱 구성 결과.
@MainActor
public struct LiveAgent {
    public let coordinator: AgentCoordinator
    public let overlay: OverlayController
    /// 카메라 모드에서만 있다. 9점 보정 창이 쓴다.
    public let calibrator: (any GazeCalibrating)?
    /// 시선 후처리 엔진. 보정 모델 저장·복원에 쓴다.
    public let gazeEngine: GazeEngine
    /// 화면 캡처(오버레이 창 제외). 모델 판단에 화면을 보낼 때 쓴다.
    public let screenCapture: ScreenCapture
    /// 앱 접근성 트리 읽기. resolver·executor와 같은 요소 보관소를 쓴다.
    public let appState: AppStateReader
}

/// 모듈을 실제 구현으로 조립한다.
///
/// 공유 인스턴스: 시계(`UptimeClock`) 하나, AX 요소 보관소 하나(resolver·앱 상태·실행기·입력란 접근),
/// 안전 스위치 하나(정책·코디네이터), 받아쓰기 원장 하나(드라이버·정책 확인).
public enum AgentAssembly {
    @MainActor
    public static func live(gazeMode: GazeInputMode, overlay: OverlayController,
                            configuration: AgentCoordinator.Configuration = .init()) -> LiveAgent {
        let clock = UptimeClock()
        let registry = overlay.windowRegistry
        // 오버레이·말풍선은 Gaze 자신의 프로세스다. 적중 검사·실행 대상에서 뺀다.
        let store = AXElementStore(excludedPIDs: [registry.processIdentifier])
        let resolver = AXTargetResolver(store: store, clock: clock)
        let appState = AppStateReader(store: store, clock: clock)
        let executor = AXActionExecutor(store: store, clock: clock)
        let field = AXDictationFieldAccess(access: AXTextFieldAccess(store: store))
        let screenCapture = ScreenCapture(excludedWindowNumbers: { registry.snapshot.windowNumbers })

        let safety = AgentSafetySwitch()
        let ledger = DictationLedger()
        let policy = PolicyEngine(safety: safety, dictationVerifier: ledger)
        let actions = ActionCoordinator(policy: policy, executor: executor, clock: clock, safety: safety,
                                        executionTimeout: .seconds(8))
        let fusion = AttentionFuser(resolver: resolver, clock: clock)
        let intent = IntentEngine(clock: clock)

        let gaze: any GazeSource
        let calibrator: (any GazeCalibrating)?
        let engine: GazeEngine
        switch gazeMode {
        case .camera:
            let vision = VisionGazeSource(clock: clock)
            gaze = vision
            calibrator = vision
            engine = vision.engine
        case .mouse:
            let mouse = MouseGazeSource(clock: clock)
            gaze = mouse
            calibrator = nil
            engine = mouse.engine
        }
        // 음성 시각은 오디오 host time(mach_absolute_time)에서 오며 `UptimeClock`과 같은 기준이다.
        let speech = LiveSpeechSource()

        let services = AgentServices(clock: clock, gaze: gaze, speech: speech, resolver: resolver, fusion: fusion,
                                     intent: intent, policy: policy, coordinator: actions, ledger: ledger, field: field)
        let coordinator = AgentCoordinator(services: services, renderer: overlay, configuration: configuration)
        overlay.onAccept = { [weak coordinator] subject in coordinator?.handleBubble(subject, accepted: true) }
        overlay.onReject = { [weak coordinator] subject in coordinator?.handleBubble(subject, accepted: false) }
        return LiveAgent(coordinator: coordinator, overlay: overlay, calibrator: calibrator, gazeEngine: engine,
                         screenCapture: screenCapture, appState: appState)
    }
}
