import AgentContracts
import Control
import CoreGraphics
import Foundation
import Overlay

/// 코디네이터가 묶는 모듈들. 실제 앱은 `AgentAssembly.live`가, 검사는 가짜로 채운다.
///
/// 시계(`clock`)·안전 스위치(`policy.safety == coordinator.safety`)·AX 요소 보관소는 하나만 만들어
/// 모든 모듈에 같은 인스턴스를 주입해야 한다.
public struct AgentServices: Sendable {
    public var clock: any MonotonicClock
    public var gaze: any GazeSource
    public var speech: any SpeechSource
    /// 시선 초점(정책의 "보고 있는 필드")을 찾는 데 쓴다. Fusion과 같은 resolver를 넘긴다.
    public var resolver: any UITargetResolving
    public var fusion: any AttentionFusing
    public var intent: any IntentProposing
    public var policy: PolicyEngine
    public var coordinator: ActionCoordinator
    public var ledger: DictationLedger
    public var field: any DictationFieldAccessing

    public init(clock: any MonotonicClock, gaze: any GazeSource, speech: any SpeechSource,
                resolver: any UITargetResolving, fusion: any AttentionFusing, intent: any IntentProposing,
                policy: PolicyEngine, coordinator: ActionCoordinator, ledger: DictationLedger,
                field: any DictationFieldAccessing) {
        self.clock = clock; self.gaze = gaze; self.speech = speech; self.resolver = resolver; self.fusion = fusion
        self.intent = intent; self.policy = policy; self.coordinator = coordinator; self.ledger = ledger
        self.field = field
    }
}

/// 앱 코어. 입력 스트림을 모듈에 나눠 주고, 판단 결과를 실행 흐름과 오버레이에 연결한다.
///
/// - 시선: 방송기로 오버레이(최신 1개)·Fusion(버퍼)·정책 시선 초점(고정 표본만, 간격 제한)에 동시에 보낸다.
/// - 음성: 레벨 → 오버레이 배지, 준언어 단서 → Fusion, 전사 → Fusion 맥락 → IntentEngine.
///   같은 발화의 새 revision이 오면 이전 revision 평가(모델 호출 대기)를 취소하고 순서대로 처리한다.
/// - 결과: 실행 제안 → ActionCoordinator. 받아쓰기 의도 → DictationDriver(원장이 실제 편집 계산) → ActionCoordinator.
///   선제 제안 → 오버레이 말풍선.
/// - 오버레이 에이전트 영역: 제안 대상 프레임으로 옮겨 "읽는 중" → 승인 대기면 "확인 대기" → 실행 중 "입력 중",
///   끝나면 잠시 뒤 유휴 화면 테두리로 돌아간다. 승인 요청은 말풍선으로 띄우고 수락·거절을 코디네이터에 전달한다.
@MainActor
public final class AgentCoordinator {
    public struct Configuration: Sendable {
        /// 행동이 끝난 뒤 유휴 테두리로 돌아가기까지 기다리는 시간(결과를 눈으로 확인할 여유).
        public var idleReturnDelay: Duration = .milliseconds(700)
        /// 정책 시선 초점을 갱신하는 최소 간격(초, 표본 시각 기준). AX 적중 검사 비용을 줄인다.
        public var gazeFocusInterval: Double = 0.15
        /// 원장 편집 제안 유효 시간(초).
        public var dictationProposalTTL: Double = 4
        /// Fusion으로 가는 시선 표본 버퍼(최신 우선).
        public var fusionGazeBuffer: Int = 512
        public init() {}
    }

    public enum Mode: String, Sendable, Equatable {
        case stopped, running, paused, killed
    }

    public let services: AgentServices
    public let configuration: Configuration
    public let dictation: DictationDriver
    public private(set) var overlayState = OverlayState()
    public private(set) var mode: Mode = .stopped
    /// 마지막 소스 시작 오류(권한 없음 등). 메뉴 막대에 보여 준다.
    public private(set) var sourceErrors: [String] = []

    public var onModeChange: (@MainActor (Mode) -> Void)?
    public var onOutcome: (@MainActor (ActionOutcome) -> Void)?
    public var onSuggestionResponse: (@MainActor (SuggestionCandidate, Bool) -> Void)?
    public var onLog: (@MainActor (String) -> Void)?

    private let renderer: (any OverlayRendering)?
    private let gazeBroadcast = AsyncBroadcaster<GazeSample>()
    private let relay: ProposalRelay
    private var pumps: [Task<Void, Never>] = []
    private var evaluations: [UUID: (token: UUID, task: Task<Void, Never>)] = [:]
    private var tracked: [UUID: ActionProposal] = [:]
    private var activeProposalID: UUID?
    private var idleTask: Task<Void, Never>?
    private var suggestionTask: Task<Void, Never>?
    private var renderScheduled = false
    private var pumpsStarted = false

    public init(services: AgentServices, renderer: (any OverlayRendering)?, configuration: Configuration = .init()) {
        self.services = services
        self.renderer = renderer
        self.configuration = configuration
        let relay = ProposalRelay()
        self.relay = relay
        dictation = DictationDriver(ledger: services.ledger, field: services.field, clock: services.clock,
                                    proposalTTL: configuration.dictationProposalTTL,
                                    submit: { proposal in await relay.submit(proposal) })
        relay.owner = self
    }

    // MARK: 수명

    /// 스트림 펌프를 연결하고 시선·음성 소스를 시작한다. 소스 하나가 실패해도 나머지는 계속한다.
    public func start() async {
        guard mode == .stopped else { return }
        startPumps()
        setMode(.running)
        await startSources()
        render()
    }

    /// 앱 종료용. 펌프를 끊으면 원천 스트림도 끝나므로 다시 시작할 수 없다.
    public func shutdown() async {
        cancelEvaluations()
        pumps.forEach { $0.cancel() }
        pumps = []
        await services.gaze.stop()
        await services.speech.stop()
        setMode(.stopped)
    }

    /// 일시정지: 실행을 멈추고(승인 대기 취소) 카메라·마이크를 끈다.
    public func pause() async {
        guard mode == .running else { return }
        setMode(.paused)
        await services.coordinator.pause()
        cancelEvaluations()
        await stopSources()
        clearTransientOverlay()
    }

    public func resume() async {
        guard mode == .paused else { return }
        await services.coordinator.resume()
        setMode(.running)
        await startSources()
    }

    /// 비상 정지: 승인 대기·실행 기다림을 즉시 끊고, 받아쓰기를 멈추고, 카메라·마이크를 끈다.
    /// `resetKillSwitch()`로만 풀린다.
    public func engageKillSwitch() async {
        guard mode != .killed else { return }
        let wasRunning = mode == .running
        setMode(.killed)
        await services.coordinator.engageKillSwitch()
        cancelEvaluations()
        await dictation.stopAll(reason: "Kill switch engaged")
        if wasRunning { await stopSources() }
        clearTransientOverlay()
    }

    public func resetKillSwitch() async {
        guard mode == .killed else { return }
        await services.coordinator.resetKillSwitch()
        await services.coordinator.resume()
        startPumps()
        setMode(.running)
        await startSources()
    }

    // MARK: 말풍선

    /// 오버레이 말풍선 수락·거절. 승인 요청이면 코디네이터에 전달하고, 선제 제안이면 닫는다.
    public func respond(to subject: OverlayBubbleSubject, accepted: Bool) async {
        switch subject {
        case .approval(let proposal):
            if accepted {
                await services.coordinator.approve(proposal.id)
            } else {
                await services.coordinator.reject(proposal.id)
            }
        case .suggestion(let suggestion):
            if overlayState.suggestion?.id == suggestion.id {
                overlayState.suggestion = nil
                render()
            }
            onSuggestionResponse?(suggestion, accepted)
        }
    }

    /// `OverlayController.onAccept/onReject`에 그대로 연결한다.
    public func handleBubble(_ subject: OverlayBubbleSubject, accepted: Bool) {
        Task { await respond(to: subject, accepted: accepted) }
    }

    // MARK: 펌프

    private func startPumps() {
        guard !pumpsStarted else { return }
        pumpsStarted = true
        let s = services
        let interval = configuration.gazeFocusInterval

        // 시선 방송: 구독을 먼저 만든 뒤 펌프를 시작해야 첫 표본을 놓치지 않는다.
        let overlayGaze = gazeBroadcast.subscribe(bufferingPolicy: .bufferingNewest(1))
        let fusionGaze = gazeBroadcast.subscribe(bufferingPolicy: .bufferingNewest(max(1, configuration.fusionGazeBuffer)))
        let focusGaze = gazeBroadcast.subscribe(bufferingPolicy: .bufferingNewest(1))
        pumps.append(gazeBroadcast.pump(from: s.gaze.samples))

        pumps.append(Task { [weak self] in
            for await sample in overlayGaze {
                guard let self else { return }
                self.overlayState.gaze = sample
                self.render()
            }
        })
        pumps.append(Task.detached {
            for await sample in fusionGaze { await s.fusion.ingest(sample) }
        })
        pumps.append(Task.detached {
            var last: MonotonicTime?
            for await sample in focusGaze {
                guard sample.isFixation else { continue }
                if let last, sample.time.seconds(since: last) < interval, sample.time >= last { continue }
                last = sample.time
                let target = await s.resolver.target(at: sample.point)
                await s.policy.updateGazeFocus(target, at: sample.time)
            }
        })
        pumps.append(Task.detached {
            for await cue in s.gaze.nonverbalCues { await s.fusion.ingest(cue) }
        })
        pumps.append(Task.detached {
            for await cue in s.speech.paralinguisticCues { await s.fusion.ingest(cue) }
        })
        pumps.append(Task { [weak self] in
            for await level in s.speech.levels {
                guard let self else { return }
                self.overlayState.audioLevel = level
                self.render()
            }
        })
        pumps.append(Task { [weak self] in
            for await update in s.speech.transcripts {
                guard let self else { return }
                self.handleTranscript(update)
            }
        })
        pumps.append(Task { [weak self] in
            for await outcome in s.coordinator.outcomes {
                guard let self else { return }
                self.handleOutcome(outcome)
            }
        })
        pumps.append(Task { [weak self] in
            for await request in s.coordinator.approvalRequests {
                guard let self else { return }
                self.overlayState.pendingApproval = request?.proposal
                self.render()
            }
        })
    }

    private func startSources() async {
        sourceErrors = []
        do {
            try await services.gaze.start()
            onLog?("시선 소스 시작됨")
        } catch {
            sourceErrors.append("시선: \(error)")
            onLog?("시선 소스 시작 실패: \(error)")
        }
        do {
            try await services.speech.start()
            onLog?("음성 소스 시작됨")
        } catch {
            sourceErrors.append("음성: \(error)")
            onLog?("음성 소스 시작 실패: \(error)")
        }
    }

    private func stopSources() async {
        await services.gaze.stop()
        await services.speech.stop()
    }

    // MARK: 전사 → 판단

    private func handleTranscript(_ update: TranscriptUpdate) {
        let words = update.words.map(\.word).joined(separator: "|")
        onLog?("전사 r\(update.revision)\(update.isFinal ? " final" : "") \"\(update.text)\" stable=\"\(update.stablePrefix)\" words=[\(words)]")
        guard mode == .running else { return }
        let id = update.utteranceID
        let previous = evaluations[id]?.task
        // 이전 revision의 평가는 더 이상 의미가 없다(모델 호출 대기 중이면 끊는다).
        previous?.cancel()
        let token = UUID()
        let s = services
        let task = Task { [weak self] in
            // 같은 발화는 revision 순서대로 판단 모듈에 들어가야 한다.
            await previous?.value
            guard !Task.isCancelled else {
                self?.finishEvaluation(id, token: token)
                return
            }
            let context = await s.fusion.context(for: update)
            if update.isFinal {
                let bindings = context.bindings.map { "\($0.word.word)→\($0.target.map { "\($0.role) \($0.title ?? "")" } ?? "없음")(\($0.role))" }
                let gazed = context.gazedTarget.map { "\($0.role) \($0.title ?? "")" } ?? "없음"
                self?.onLog?("결합 r\(update.revision): 응시 대상=\(gazed) 지시어=\(bindings)")
            }
            guard !Task.isCancelled else {
                self?.finishEvaluation(id, token: token)
                return
            }
            let result = await s.intent.evaluate(context)
            // 판단 모듈이 결과를 냈다면 그 상태도 이미 반영됐다. 취소됐어도 결과는 처리한다.
            self?.handle(result, utterance: update)
            self?.finishEvaluation(id, token: token)
        }
        evaluations[id] = (token, task)
    }

    private func finishEvaluation(_ id: UUID, token: UUID) {
        if evaluations[id]?.token == token { evaluations[id] = nil }
    }

    private func cancelEvaluations() {
        for (_, entry) in evaluations { entry.task.cancel() }
        evaluations.removeAll()
    }

    private func handle(_ result: IntentResult, utterance: TranscriptUpdate) {
        switch result {
        case .none: if utterance.isFinal { onLog?("판단 r\(utterance.revision): 없음") }
        case .suggestion(let suggestion): onLog?("판단 r\(utterance.revision): 제안 \"\(suggestion.message)\"")
        case .proposal(let proposal): onLog?("판단 r\(utterance.revision): 실행 제안 \(proposal.origin) \(proposal.action) 위험도 \(proposal.risk)")
        }
        guard mode == .running else { return }
        switch result {
        case .none:
            return
        case .suggestion(let suggestion):
            show(suggestion)
        case .proposal(let proposal):
            switch proposal.origin {
            case .dictationIntent:
                let driver = dictation
                Task.detached { await driver.handle(intent: proposal, utterance: utterance) }
            case .intent, .dictationLedger:
                Task { _ = await self.submitTracked(proposal) }
            }
        }
    }

    // MARK: 실행 흐름 ↔ 오버레이

    /// 제안을 실행 흐름에 넘기고 오버레이 영역을 대상으로 옮긴다.
    func submitTracked(_ proposal: ActionProposal) async -> ActionOutcome {
        tracked[proposal.id] = proposal
        activate(proposal.id, frame: Self.regionFrame(for: proposal.action), label: OverlayStatusLabel.reading)
        return await services.coordinator.submit(proposal)
    }

    private func handleOutcome(_ outcome: ActionOutcome) {
        onLog?("실행 결과 \(outcome.status) 검증=\(outcome.verification) \(outcome.reason ?? "")")
        onOutcome?(outcome)
        let proposal = tracked[outcome.proposalID]
        let frame = proposal.map { Self.regionFrame(for: $0.action) } ?? outcome.target?.frame
        switch outcome.status {
        case .proposed:
            if let frame { activate(outcome.proposalID, frame: frame, label: OverlayStatusLabel.awaitingApproval) }
        case .approved, .started:
            if let frame { activate(outcome.proposalID, frame: frame, label: OverlayStatusLabel.typing) }
        case .succeeded, .failed, .cancelled, .rejected:
            tracked[outcome.proposalID] = nil
            if activeProposalID == outcome.proposalID {
                activeProposalID = nil
                scheduleIdle()
            }
        }
    }

    private func activate(_ id: UUID, frame: CGRect, label: String) {
        idleTask?.cancel()
        idleTask = nil
        activeProposalID = id
        overlayState.agentRegion = .target(frame: frame, label: label)
        render()
    }

    private func scheduleIdle() {
        idleTask?.cancel()
        if configuration.idleReturnDelay <= .zero {
            overlayState.agentRegion = .idleScreenEdge
            render()
            return
        }
        let delay = configuration.idleReturnDelay
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.activeProposalID == nil else { return }
            self.overlayState.agentRegion = .idleScreenEdge
            self.render()
        }
    }

    private func show(_ suggestion: SuggestionCandidate) {
        overlayState.suggestion = suggestion
        render()
        suggestionTask?.cancel()
        let remaining = suggestion.expiresAt.seconds(since: services.clock.now())
        let id = suggestion.id
        suggestionTask = Task { [weak self] in
            if remaining > 0 { try? await Task.sleep(for: .milliseconds(Int(remaining * 1000))) }
            guard !Task.isCancelled, let self, self.overlayState.suggestion?.id == id else { return }
            self.overlayState.suggestion = nil
            self.render()
        }
    }

    private func clearTransientOverlay() {
        idleTask?.cancel()
        suggestionTask?.cancel()
        activeProposalID = nil
        overlayState.pendingApproval = nil
        overlayState.suggestion = nil
        overlayState.agentRegion = .idleScreenEdge
        render()
    }

    /// 이동은 출발지와 목적지를 함께 감싼다. 나머지는 대상 프레임.
    static func regionFrame(for action: AgentAction) -> CGRect {
        switch action {
        case .move(let source, let destination): return source.frame.union(destination.frame)
        default: return action.primaryTarget.frame
        }
    }

    // MARK: 모드·그리기

    private func setMode(_ newMode: Mode) {
        guard mode != newMode else { return }
        mode = newMode
        onModeChange?(newMode)
    }

    /// 같은 주기에 여러 번 바뀌어도 한 번만 그린다.
    private func render() {
        guard let renderer, !renderScheduled else { return }
        renderScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            renderer.render(self.overlayState)
        }
    }
}

/// DictationDriver(actor)가 원장 편집을 코어의 추적 제출로 보내는 다리. 코어보다 먼저 만들어야 해서 약한 참조를 둔다.
@MainActor
final class ProposalRelay {
    weak var owner: AgentCoordinator?

    func submit(_ proposal: ActionProposal) async -> ActionOutcome {
        guard let owner else {
            return ActionOutcome(proposalID: proposal.id, status: .cancelled, verification: .none,
                                 target: proposal.action.primaryTarget, time: MonotonicTime(nanoseconds: 0),
                                 reason: "Agent core is gone")
        }
        return await owner.submitTracked(proposal)
    }
}
