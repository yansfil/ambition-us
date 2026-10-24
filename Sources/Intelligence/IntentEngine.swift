import AgentContracts
import Foundation

public struct IntentEngineConfiguration: Sendable, Equatable {
    /// 실행 제안 유효 시간(초). 시선 맥락이 금방 바뀌므로 짧게 둔다.
    public var proposalTTL: Double = 4
    /// 선제 제안 표시 유효 시간(초).
    public var suggestionTTL: Double = 8
    /// 같은 대상에 대한 선제 제안 재표시 금지 시간(초).
    public var suggestionCooldown: Double = 30
    /// 어떤 대상이든 선제 제안 사이 최소 간격(초).
    public var suggestionGlobalGap: Double = 8
    public var minBindingConfidence: Double = 0.5
    public var minCueConfidence: Double = 0.5
    /// 머뭇거림과 응시 단서가 이 시간(초) 안에 함께 있어야 선제 제안.
    public var cueCoincidenceWindow: Double = 4
    public var minModelProposalConfidence: Double = 0.6
    public var minModelSuggestionConfidence: Double = 0.5
    public var maxSuggestionLength: Int = 60
    /// false면 애매해도 모델을 부르지 않는다.
    public var consultModel: Bool = true

    public init() {}
}

/// IntentProposing 구현.
///
/// 순서: 오래된 revision 무시 → 로컬 빠른 경로(명령·받아쓰기) → 선제 제안(머뭇거림 + 응시) → 애매하면 모델.
/// - 같은 발화의 새 revision이 오면 진행 중인 모델 호출을 취소하고, 늦게 도착한 결과는 버린다.
/// - 받아쓰기는 실행 제안이 아니라 **받아쓰기 의도**다: `origin == .dictationIntent`이고 typeText의 text는
///   이 발화에서 받아쓰기로 정한 **누적** 텍스트다(완결된 안정 문장만). 실제 삽입·교정량은 받아쓰기 원장이
///   이미 넣은 텍스트와 비교해 계산한다. 이미 받아쓴 구간이 전사 교정으로 바뀌면 받아쓰기 시작점부터 다시 계산해
///   교정된 누적 텍스트를 낸다.
/// - 선제 제안은 행동을 담지 않으며 실행 제안으로 바뀌지 않는다.
public actor IntentEngine: IntentProposing {
    private struct UtteranceState {
        var latestRevision: Int
        var consumed: String = ""
        var dictationTarget: String?
        /// 받아쓰기를 시작하기 전까지 처리한 발화 앞부분. nil이면 아직 받아쓰기 안 함.
        var dictationPrefix: String?
        /// 이 발화에서 받아쓰기로 정한 누적 텍스트.
        var dictated: String = ""
        var lastAction: AgentAction?
        var touched: UInt64
    }

    private struct InFlightCall {
        let id: UUID
        let revision: Int
        let task: Task<ModelDecision, Never>
    }

    private let configuration: IntentEngineConfiguration
    private let clock: any MonotonicClock
    private let modelClient: (any IntentModelClient)?
    private var utterances: [UUID: UtteranceState] = [:]
    private var touchCounter: UInt64 = 0
    private var ledger: SuggestionLedger
    private var inFlight: [UUID: InFlightCall] = [:]

    public init(configuration: IntentEngineConfiguration = .init(),
                clock: any MonotonicClock = UptimeMonotonicClock(),
                modelClient: (any IntentModelClient)? = ClaudeIntentClient()) {
        self.configuration = configuration
        self.clock = clock
        self.modelClient = modelClient
        self.ledger = SuggestionLedger(perTargetCooldown: configuration.suggestionCooldown,
                                       globalGap: configuration.suggestionGlobalGap)
    }

    public func evaluate(_ context: AttentionContext) async -> IntentResult {
        let update = context.utterance
        let utteranceID = update.utteranceID
        guard acceptRevision(update) else { return .none }
        // 새 revision: 이전 revision에 대한 모델 호출은 더 이상 의미가 없다.
        inFlight.removeValue(forKey: utteranceID)?.task.cancel()

        let now = clock.now()
        guard var state = utterances[utteranceID] else { return .none }
        let resolver = LocalIntentResolver(minBindingConfidence: configuration.minBindingConfidence)
        var local = resolver.resolve(context, consumed: state.consumed, dictationTarget: state.dictationTarget)
        var restartedDictation = false
        if case .blocked = local, let prefix = state.dictationPrefix,
           !KoreanText.normalize(update.text).hasPrefix(state.consumed),
           KoreanText.normalize(update.text).hasPrefix(prefix) {
            // 받아쓴 구간 안에서 전사가 고쳐졌다. 받아쓰기 시작점부터 다시 계산하면 원장이 교정 편집을 만든다.
            let redo = resolver.resolve(context, consumed: prefix, dictationTarget: state.dictationTarget)
            if case .dictation = redo {
                local = redo
                restartedDictation = true
            }
        }

        switch local {
        case .action(let action, let rationale, let consumed, let commandText):
            state.consumed = consumed
            defer { utterances[utteranceID] = state }
            guard state.lastAction != action else { return .none }
            state.lastAction = action
            return .proposal(makeProposal(action, update: update, rationale: rationale,
                                          risk: RiskClassifier.risk(for: action, commandText: commandText), now: now))
        case .dictation(let target, let text, let consumed):
            if state.dictationPrefix == nil { state.dictationPrefix = state.consumed }
            state.dictated = restartedDictation ? text : state.dictated + text
            state.consumed = consumed
            state.dictationTarget = target.token
            utterances[utteranceID] = state
            let action = AgentAction.typeText(target: target, text: state.dictated)
            return .proposal(makeProposal(action, update: update, rationale: "시선이 머문 입력란에 받아쓰기(안정 구간)",
                                          risk: RiskClassifier.risk(for: action, commandText: nil), now: now,
                                          origin: .dictationIntent))
        case .blocked:
            return .none
        case .wait, .nothing, .ambiguous:
            break
        }

        if let suggestion = localSuggestion(context, dictationTarget: state.dictationTarget, now: now) {
            return .suggestion(suggestion)
        }

        guard case .ambiguous(let reason, let pending, let consumedIfActed) = local,
              configuration.consultModel, let modelClient else { return .none }
        return await consult(modelClient, context: context, reason: reason, pending: pending,
                             alreadyHandled: state.consumed, consumedIfActed: consumedIfActed)
    }

    // MARK: - revision 관리

    private func acceptRevision(_ update: TranscriptUpdate) -> Bool {
        touchCounter &+= 1
        if var state = utterances[update.utteranceID] {
            guard update.revision >= state.latestRevision else { return false }
            state.latestRevision = update.revision
            state.touched = touchCounter
            utterances[update.utteranceID] = state
            return true
        }
        utterances[update.utteranceID] = UtteranceState(latestRevision: update.revision, touched: touchCounter)
        if utterances.count > 16, let oldest = utterances.min(by: { $0.value.touched < $1.value.touched })?.key {
            utterances.removeValue(forKey: oldest)
            inFlight.removeValue(forKey: oldest)?.task.cancel()
        }
        return true
    }

    private func makeProposal(_ action: AgentAction, update: TranscriptUpdate, rationale: String,
                              risk: RiskLevel, now: MonotonicTime,
                              origin: ActionProposal.Origin = .intent) -> ActionProposal {
        ActionProposal(id: UUID(), action: action, basedOnUtterance: update.utteranceID,
                       basedOnRevision: update.revision, rationale: rationale, risk: risk,
                       expiresAt: now.adding(seconds: configuration.proposalTTL), origin: origin)
    }

    // MARK: - 선제 제안

    private func localSuggestion(_ context: AttentionContext, dictationTarget: String?,
                                 now: MonotonicTime) -> SuggestionCandidate? {
        guard let trigger = SuggestionPolicy.trigger(in: context, minCueConfidence: configuration.minCueConfidence,
                                                     coincidenceWindow: configuration.cueCoincidenceWindow)
        else { return nil }
        // 받아쓰기 중 잠깐 멈춘 것은 도움 요청이 아니다.
        if dictationTarget == trigger.target.token { return nil }
        let key = SuggestionPolicy.cooldownKey(for: trigger.target)
        guard ledger.canShow(key, now: now) else { return nil }
        ledger.record(key, now: now)
        return SuggestionCandidate(id: UUID(), target: trigger.target,
                                   message: SuggestionPolicy.message(for: trigger.target, utterance: context.utterance.text),
                                   confidence: trigger.confidence,
                                   expiresAt: now.adding(seconds: configuration.suggestionTTL), cooldownKey: key)
    }

    // MARK: - 모델

    private func consult(_ client: any IntentModelClient, context: AttentionContext, reason: AmbiguityReason,
                         pending: String, alreadyHandled: String, consumedIfActed: String) async -> IntentResult {
        let update = context.utterance
        let (request, table) = Self.buildModelRequest(context: context, reason: reason, pending: pending,
                                                      alreadyHandled: alreadyHandled)
        let callID = UUID()
        let task = Task { await client.infer(request) }
        inFlight[update.utteranceID] = InFlightCall(id: callID, revision: update.revision, task: task)
        let decision = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if inFlight[update.utteranceID]?.id == callID { inFlight.removeValue(forKey: update.utteranceID) }

        // 기다리는 동안 새 revision이 왔거나 다른 경로가 같은 구간을 처리했으면 버린다.
        guard !task.isCancelled, !Task.isCancelled,
              var state = utterances[update.utteranceID],
              state.latestRevision == update.revision, state.consumed == alreadyHandled else { return .none }
        let now = clock.now()

        switch decision {
        case .none:
            return .none
        case .proposal(let spec, let message, let confidence, let modelRisk):
            guard confidence >= configuration.minModelProposalConfidence,
                  let action = Self.resolveModelAction(spec, table: table, pending: pending) else { return .none }
            guard state.lastAction != action else { return .none }
            state.consumed = consumedIfActed
            state.lastAction = action
            if case .typeText(let target, _) = action { state.dictationTarget = target.token }
            utterances[update.utteranceID] = state
            // 모델이 낮게 매겨도 로컬 분류보다 낮출 수 없다.
            let risk = max(modelRisk, RiskClassifier.risk(for: action, commandText: pending))
            let rationale = Self.clean(message, limit: 120) ?? "모델 판단"
            return .proposal(makeProposal(action, update: update, rationale: rationale, risk: risk, now: now))
        case .suggestion(let anchorID, let message, let confidence):
            guard confidence >= configuration.minModelSuggestionConfidence,
                  let text = Self.clean(message, limit: configuration.maxSuggestionLength) else { return .none }
            let anchor = anchorID.flatMap { table[$0] }.flatMap { $0.isSecure ? nil : $0 }
            let key = SuggestionPolicy.cooldownKey(for: anchor ?? context.gazedTarget)
            guard ledger.canShow(key, now: now) else { return .none }
            ledger.record(key, now: now)
            return .suggestion(SuggestionCandidate(id: UUID(), target: anchor, message: text, confidence: confidence,
                                                   expiresAt: now.adding(seconds: configuration.suggestionTTL),
                                                   cooldownKey: key))
        }
    }

    /// 모델에 보낼 요청과, 요약 id → 실제 UITarget 표.
    static func buildModelRequest(context: AttentionContext, reason: AmbiguityReason, pending: String,
                                  alreadyHandled: String) -> (IntentModelRequest, [String: UITarget]) {
        var ordered: [UITarget] = []
        var seen = Set<String>()
        for target in [context.gazedTarget].compactMap({ $0 }) + context.bindings.compactMap(\.target)
        where seen.insert(target.token).inserted {
            ordered.append(target)
        }
        ordered = Array(ordered.prefix(6))
        var table: [String: UITarget] = [:]
        let dwellTokens = Set(context.nonverbal.filter { SuggestionPolicy.dwellKinds.contains($0.kind) }.compactMap(\.targetID))
        let summaries = ordered.enumerated().map { index, target -> TargetSummary in
            let id = "t\(index)"
            table[id] = target
            let references = context.bindings.filter { $0.target?.token == target.token }.map(\.word.word)
            return TargetSummary(id: id, role: target.role, title: target.title, frame: target.frame,
                                 isEditable: target.isEditable, isSecure: target.isSecure,
                                 isGazed: target.token == context.gazedTarget?.token,
                                 spokenReferences: references, hasDwell: dwellTokens.contains(target.token))
        }
        var paralinguistic: [ParalinguisticCue.Kind] = []
        for cue in context.paralinguistic where !paralinguistic.contains(cue.kind) { paralinguistic.append(cue.kind) }
        var nonverbal: [NonverbalCue.Kind] = []
        for cue in context.nonverbal where !nonverbal.contains(cue.kind) { nonverbal.append(cue.kind) }
        let request = IntentModelRequest(utterance: pending, alreadyHandled: alreadyHandled,
                                         isFinal: context.utterance.isFinal, reason: reason, targets: summaries,
                                         paralinguistic: paralinguistic, nonverbal: nonverbal)
        return (request, table)
    }

    /// 모델 행동을 실제 대상에 연결하고 안전 규칙을 다시 적용한다.
    /// 입력·값 설정 텍스트는 발화에 실제로 있는 내용이어야 한다(화면 텍스트 주입으로 임의 입력 방지).
    static func resolveModelAction(_ spec: ModelActionSpec, table: [String: UITarget], pending: String) -> AgentAction? {
        guard let target = table[spec.targetID] else { return nil }
        let spoken = KoreanText.comparable(pending)
        func fromUtterance(_ text: String) -> Bool {
            let candidate = KoreanText.comparable(text)
            return !candidate.isEmpty && spoken.contains(candidate)
        }
        switch spec.kind {
        case .typeText:
            guard target.acceptsText, let text = spec.text, fromUtterance(text) else { return nil }
            return .typeText(target: target, text: text)
        case .setValue:
            guard target.acceptsText, let text = spec.text else { return nil }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !fromUtterance(text) { return nil }
            return .setValue(target: target, value: text)
        case .press:
            return .press(target: target)
        case .move:
            guard let destinationID = spec.destinationID, let destination = table[destinationID],
                  destination.token != target.token else { return nil }
            return .move(source: target, destination: destination)
        }
    }

    static func clean(_ text: String, limit: Int) -> String? {
        let collapsed = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed.count > limit ? String(collapsed.prefix(limit)) : collapsed
    }
}
