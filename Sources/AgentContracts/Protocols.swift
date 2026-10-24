import Foundation

/// 시선 소스. 자체 파이프라인(Vision+CoreML)과 Beam SDK 어댑터가 같은 인터페이스를 구현한다.
///
/// 모든 스트림은 소비자 하나를 전제로 한다. 여러 모듈(오버레이·Fusion·정책)이 받아야 하면
/// 앱 코어의 `AsyncBroadcaster`로 나눈다. 스트림은 stop() 뒤에도 열려 있어 다시 start()할 수 있다.
public protocol GazeSource: Sendable {
    var samples: AsyncStream<GazeSample> { get }
    var nonverbalCues: AsyncStream<NonverbalCue> { get }
    func start() async throws
    func stop() async
}

public protocol SpeechSource: Sendable {
    var transcripts: AsyncStream<TranscriptUpdate> { get }
    var levels: AsyncStream<AudioLevelSample> { get }
    var paralinguisticCues: AsyncStream<ParalinguisticCue> { get }
    func start() async throws
    func stop() async
}

public protocol UITargetResolving: Sendable {
    /// 전역 좌표의 UI 요소를 찾는다. 오버레이 창은 결과에서 제외해야 한다.
    func target(at point: CGPoint) async -> UITarget?
    func focusedTarget() async -> UITarget?
}

public protocol AttentionFusing: Sendable {
    func ingest(_ sample: GazeSample) async
    func ingest(_ cue: NonverbalCue) async
    func ingest(_ cue: ParalinguisticCue) async
    func context(for update: TranscriptUpdate) async -> AttentionContext
}

public enum IntentResult: Sendable, Equatable {
    case none
    case proposal(ActionProposal)
    case suggestion(SuggestionCandidate)
}

public protocol IntentProposing: Sendable {
    func evaluate(_ context: AttentionContext) async -> IntentResult
}

public protocol ActionAuthorizing: Sendable {
    func decide(_ proposal: ActionProposal, now: MonotonicTime) async -> PolicyDecision
}

public protocol ActionExecuting: Sendable {
    func execute(_ proposal: ActionProposal) async -> ActionOutcome
}

@MainActor
public protocol OverlayRendering: AnyObject {
    func render(_ state: OverlayState)
}
