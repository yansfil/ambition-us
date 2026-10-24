import AgentContracts
import AppCore
import Control
import CoreGraphics
import Foundation
import Fusion
import Intelligence
import Overlay
import Synchronization

// 통합 코어 종단 검사. 카메라·마이크·화면·실제 입력은 쓰지 않는다. 모든 소스·실행기·입력란은 가짜다.

@MainActor
func appCoreChecks() async {
    print("[AppCore/방송]")
    await broadcastChecks()
    print("[AppCore/이동: 시선+지시어 → 승인 → 실행]")
    await moveFlowChecks()
    print("[AppCore/받아쓰기: 원장 단일 기준]")
    await dictationFlowChecks()
    print("[AppCore/음성 대답으로 승인]")
    voiceReplyClassifierChecks()
    await voiceApprovalChecks()
    print("[AppCore/비상 정지]")
    await killSwitchChecks()
    print("[AppCore/선제 제안: 머뭇거림 + 응시 단서 → 말풍선]")
    await suggestionFlowChecks()
}

// MARK: - 가짜 구성요소

private let appBase = 500.0

private func at(_ seconds: Double) -> MonotonicTime {
    MonotonicTime(nanoseconds: UInt64(((appBase + seconds) * 1e9).rounded()))
}

private final class AppClock: MonotonicClock, Sendable {
    private let nanos = Mutex<UInt64>(0)
    init(_ seconds: Double) { set(seconds) }
    func now() -> MonotonicTime { MonotonicTime(nanoseconds: nanos.withLock { $0 }) }
    func set(_ seconds: Double) { nanos.withLock { $0 = at(seconds).nanoseconds } }
}

private final class FakeGaze: GazeSource, Sendable {
    let samples: AsyncStream<GazeSample>
    let nonverbalCues: AsyncStream<NonverbalCue>
    let sampleSink: AsyncStream<GazeSample>.Continuation
    let cueSink: AsyncStream<NonverbalCue>.Continuation
    let starts = Mutex(0)
    let stops = Mutex(0)

    init() {
        (samples, sampleSink) = AsyncStream.makeStream(of: GazeSample.self)
        (nonverbalCues, cueSink) = AsyncStream.makeStream(of: NonverbalCue.self)
    }

    func start() async throws { starts.withLock { $0 += 1 } }
    func stop() async { stops.withLock { $0 += 1 } }
}

private final class FakeSpeech: SpeechSource, Sendable {
    let transcripts: AsyncStream<TranscriptUpdate>
    let levels: AsyncStream<AudioLevelSample>
    let paralinguisticCues: AsyncStream<ParalinguisticCue>
    let transcriptSink: AsyncStream<TranscriptUpdate>.Continuation
    let levelSink: AsyncStream<AudioLevelSample>.Continuation
    let cueSink: AsyncStream<ParalinguisticCue>.Continuation
    let stops = Mutex(0)

    init() {
        (transcripts, transcriptSink) = AsyncStream.makeStream(of: TranscriptUpdate.self)
        (levels, levelSink) = AsyncStream.makeStream(of: AudioLevelSample.self)
        (paralinguisticCues, cueSink) = AsyncStream.makeStream(of: ParalinguisticCue.self)
    }

    func start() async throws {}
    func stop() async { stops.withLock { $0 += 1 } }
}

/// 프레임으로 UI 요소를 찾는다. 관측 시각은 호출 시점(신선한 AX 읽기처럼).
private final class FakeScreen: UITargetResolving, Sendable {
    let elements: [UITarget]
    let clock: AppClock
    init(_ elements: [UITarget], clock: AppClock) { self.elements = elements; self.clock = clock }

    func target(at point: CGPoint) async -> UITarget? {
        guard let e = elements.first(where: { $0.frame.contains(point) }) else { return nil }
        return UITarget(token: e.token, pid: e.pid, appBundleID: e.appBundleID, role: e.role, title: e.title,
                        frame: e.frame, isEditable: e.isEditable, isSecure: e.isSecure,
                        supportedActions: e.supportedActions, observedAt: clock.now())
    }

    func focusedTarget() async -> UITarget? { nil }
}

/// 메모리 속 입력란. 원장이 읽는 상태이자 가짜 실행기가 쓰는 대상.
private actor FakeField: DictationFieldAccessing {
    private(set) var value = ""
    private(set) var selection = DictationTextRange(location: 0, length: 0)

    func snapshot(of target: UITarget) async -> DictationFieldSnapshot? {
        DictationFieldSnapshot(value: value, selection: selection)
    }

    func placeSelection(in target: UITarget, at range: DictationTextRange) async -> Bool {
        selection = range
        return true
    }

    /// AXSelectedText 설정처럼 선택 범위를 바꾸고 캐럿을 삽입 끝으로 옮긴다.
    func insert(_ text: String) {
        value = (value as NSString).replacingCharacters(in: NSRange(location: selection.location, length: selection.length),
                                                        with: text)
        selection = DictationTextRange(location: selection.location + text.utf16.count, length: 0)
    }

    /// AXValue 설정처럼 값을 통째로 바꾸고 캐럿은 끝으로 간다.
    func replaceAll(_ text: String) {
        value = text
        selection = DictationTextRange(location: text.utf16.count, length: 0)
    }
}

private actor RecordingExecutor: ActionExecuting {
    private(set) var executed: [ActionProposal] = []
    private let clock: AppClock
    private let field: FakeField?

    init(clock: AppClock, field: FakeField? = nil) {
        self.clock = clock; self.field = field
    }

    func execute(_ proposal: ActionProposal) async -> ActionOutcome {
        executed.append(proposal)
        if let field {
            switch proposal.action {
            case .typeText(_, let text): await field.insert(text)
            case .setValue(_, let value): await field.replaceAll(value)
            case .press, .move: break
            }
        }
        let target: UITarget
        switch proposal.action {
        case .typeText(let t, _), .press(let t), .setValue(let t, _): target = t
        case .move(_, let destination): target = destination
        }
        return ActionOutcome(proposalID: proposal.id, status: .succeeded, verification: .verified, target: target,
                             time: clock.now(), reason: nil)
    }
}

@MainActor
private final class RecordingOverlay: OverlayRendering {
    private(set) var states: [OverlayState] = []
    func render(_ state: OverlayState) { states.append(state) }
}

@MainActor
private struct AppEnv {
    let clock: AppClock
    let gaze = FakeGaze()
    let speech = FakeSpeech()
    let screen: FakeScreen
    let fuser: AttentionFuser
    let ledger = DictationLedger()
    let field = FakeField()
    let executor: RecordingExecutor
    let coordinator: ActionCoordinator
    let overlay = RecordingOverlay()
    let agent: AgentCoordinator
    let outcomes = OutcomeLog()

    init(elements: [UITarget], applyToField: Bool = false) {
        clock = AppClock(0)
        screen = FakeScreen(elements, clock: clock)
        fuser = AttentionFuser(resolver: screen, clock: clock)
        executor = RecordingExecutor(clock: clock, field: applyToField ? field : nil)
        let safety = AgentSafetySwitch()
        let policy = PolicyEngine(configuration: PolicyConfiguration(requireApprovals: true), safety: safety, dictationVerifier: ledger)
        coordinator = ActionCoordinator(policy: policy, executor: executor, clock: clock, safety: safety,
                                        approvalTimeout: .seconds(10), executionTimeout: .seconds(2))
        let intent = IntentEngine(clock: clock, modelClient: nil)
        let services = AgentServices(clock: clock, gaze: gaze, speech: speech, resolver: screen, fusion: fuser,
                                     intent: intent, policy: policy, coordinator: coordinator, ledger: ledger,
                                     field: field)
        var configuration = AgentCoordinator.Configuration()
        configuration.idleReturnDelay = .zero
        agent = AgentCoordinator(services: services, renderer: overlay, configuration: configuration)
        let log = outcomes
        agent.onOutcome = { log.append($0) }
    }

    /// 실시간처럼 100ms 묶음으로 시선 표본을 보내고, 결합 모듈이 받을 때까지 기다린다.
    func feed(_ samples: [GazeSample]) async {
        var sent = await fuser.stats().acceptedSamples
        var index = 0
        while index < samples.count {
            let chunk = samples[index..<min(samples.count, index + 6)]
            index += chunk.count
            if let last = chunk.last { clock.set(Double(last.time.nanoseconds) / 1e9 - appBase + 0.02) }
            for sample in chunk { gaze.sampleSink.yield(sample) }
            sent += chunk.count
            let expected = sent
            _ = await eventually(1) { await fuser.stats().acceptedSamples >= expected }
        }
    }

    func say(_ update: TranscriptUpdate) {
        speech.transcriptSink.yield(update)
    }
}

@MainActor
private final class OutcomeLog {
    private(set) var items: [ActionOutcome] = []
    func append(_ outcome: ActionOutcome) { items.append(outcome) }
}

/// 조건이 참이 될 때까지 기다린다(최대 seconds초).
@MainActor
private func eventually(_ seconds: Double = 3, _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

private func element(_ token: String, _ frame: CGRect, role: String, title: String, editable: Bool = false,
                     bundle: String = "com.apple.finder") -> UITarget {
    UITarget(token: token, pid: 4242, appBundleID: bundle, role: role, title: title, frame: frame,
             isEditable: editable, isSecure: false, supportedActions: ["AXPress"], observedAt: at(0))
}

private let fileA = element("file-A", CGRect(x: 100, y: 100, width: 80, height: 80), role: "AXImage", title: "보고서.pdf")
private let folderB = element("folder-B", CGRect(x: 600, y: 400, width: 120, height: 120), role: "AXImage", title: "Archive")
private let memo = element("memo", CGRect(x: 100, y: 700, width: 400, height: 120), role: "AXTextArea", title: "메모",
                           editable: true, bundle: "com.apple.Notes")

private extension UITarget {
    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
}

/// 60Hz 응시 표본.
private func fixation(at point: CGPoint, from start: Double, to end: Double) -> [GazeSample] {
    var result: [GazeSample] = []
    var i = 0
    while start + Double(i) / 60 < end - 1e-9 {
        let t = start + Double(i) / 60
        let jitter = CGPoint(x: sin(Double(i) * 1.7) * 2, y: cos(Double(i) * 1.3) * 2)
        result.append(GazeSample(time: at(t), displayID: 1, point: CGPoint(x: point.x + jitter.x, y: point.y + jitter.y),
                                 uncertaintyRadius: 30, confidence: 0.9, calibrationRevision: 1, isFixation: true))
        i += 1
    }
    return result
}

private func saccade(from a: CGPoint, to b: CGPoint, from start: Double, to end: Double) -> [GazeSample] {
    let count = max(1, Int(((end - start) * 60).rounded()))
    return (0..<count).map { i in
        let f = Double(i) / Double(count)
        return GazeSample(time: at(start + Double(i) / 60), displayID: 1,
                          point: CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f),
                          uncertaintyRadius: 60, confidence: 0.8, calibrationRevision: 1, isFixation: false)
    }
}

private func word(_ text: String, _ start: Double, _ end: Double) -> WordTiming {
    WordTiming(word: text, start: at(start), end: at(end), confidence: 0.95)
}

private func transcript(_ id: UUID, _ revision: Int, _ words: [WordTiming], text: String? = nil,
                        stable: String? = nil, final: Bool) -> TranscriptUpdate {
    let joined = text ?? words.map(\.word).joined(separator: " ")
    return TranscriptUpdate(utteranceID: id, revision: revision, text: joined, stablePrefix: stable ?? (final ? joined : ""),
                            words: words, isFinal: final)
}

private let testDisplay = Overlay.DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                                  visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875))

// MARK: - 방송

@MainActor
private func broadcastChecks() async {
    let broadcaster = AsyncBroadcaster<Int>()
    let a = broadcaster.subscribe()
    let b = broadcaster.subscribe(bufferingPolicy: .bufferingNewest(2))
    check(broadcaster.subscriberCount == 2, "구독자 둘")
    let (source, sink) = AsyncStream.makeStream(of: Int.self)
    broadcaster.pump(from: source)
    for i in 1...5 { sink.yield(i) }
    sink.finish()
    var gotA: [Int] = []
    for await value in a { gotA.append(value) }
    var gotB: [Int] = []
    for await value in b { gotB.append(value) }
    check(gotA == [1, 2, 3, 4, 5], "버퍼 무제한 구독자는 모든 원소 수신")
    check(gotB.last == 5 && gotB.count <= 5 && !gotB.isEmpty, "최신 우선 구독자도 마지막 원소 수신 (\(gotB))")
    check(broadcaster.subscriberCount == 0, "원천이 끝나면 구독도 끝남")

    let late = AsyncBroadcaster<Int>()
    do {
        let dropped = late.subscribe()
        _ = dropped
    }
    // 버린 스트림의 구독은 종료 콜백으로 빠진다.
    let gone = await eventually(1) { late.subscriberCount == 0 }
    check(gone, "버린 구독은 자동으로 빠짐")
}

// MARK: - 이동

@MainActor
private func moveFlowChecks() async {
    let env = AppEnv(elements: [fileA, folderB, memo])
    await env.agent.start()
    check(env.agent.mode == .running && env.gaze.starts.withLock { $0 } == 1, "코어 시작: 소스 시작")

    let id = UUID()
    // 파일 A를 보며 "이거를"
    await env.feed(fixation(at: fileA.center, from: 0.4, to: 1.32))
    env.say(transcript(id, 1, [word("이거를", 1.0, 1.3)], final: false))
    // 폴더 B로 시선을 옮기며 "이쪽으로 옮겨줘"
    await env.feed(saccade(from: fileA.center, to: folderB.center, from: 1.32, to: 1.36))
    await env.feed(fixation(at: folderB.center, from: 1.36, to: 2.8))
    let words = [word("이거를", 1.0, 1.3), word("이쪽으로", 1.8, 2.2), word("옮겨줘", 2.3, 2.7)]
    let finalUpdate = transcript(id, 2, words, final: true)
    env.clock.set(2.9)
    env.say(finalUpdate)

    let gotApproval = await eventually { env.agent.overlayState.pendingApproval != nil }
    check(gotApproval, "이동 제안 → 정책 requireApproval → 오버레이 승인 대기")
    guard let pending = env.agent.overlayState.pendingApproval else { return }
    if case .move(let source, let destination) = pending.action {
        check(source.token == "file-A" && destination.token == "folder-B", "이동 방향: 출발 A(이거를) → 목적지 B(이쪽으로)")
    } else {
        check(false, "제안이 move가 아님: \(pending.action)")
    }
    check(pending.origin == .intent && pending.basedOnUtterance == id, "일반 의도 제안, 발화 ID 유지")

    let analysis = await env.fuser.analysis(for: finalUpdate)
    check(analysis.context.bindings.map(\.role) == [.source, .destination], "결합 결과에 역할(source/destination)이 실림")

    let union = fileA.frame.union(folderB.frame)
    let regionShown = await eventually {
        env.agent.overlayState.agentRegion == .target(frame: union, label: OverlayStatusLabel.awaitingApproval)
    }
    check(regionShown, "에이전트 영역: 두 대상을 감싸고 '확인 대기'")
    let layout = OverlayLayoutEngine.layout(env.agent.overlayState, displays: [testDisplay], primaryHeight: 900)
    check(layout.bubble?.subject == .approval(pending), "오버레이 레이아웃에 승인 말풍선")
    let rendered = await eventually { env.overlay.states.last?.pendingApproval == pending }
    check(rendered, "렌더러가 승인 말풍선 상태를 받음")
    let notYet = await env.executor.executed.isEmpty
    check(notYet, "승인 전에는 실행하지 않음")
    let proposedSeen = await eventually {
        env.outcomes.items.filter { $0.proposalID == pending.id }.map(\.status) == [.proposed]
    }
    check(proposedSeen, "결과 스트림: proposed")

    await env.agent.respond(to: .approval(pending), accepted: true)
    let executed = await eventually { await env.executor.executed.count == 1 }
    check(executed, "말풍선 수락 → 실행기 호출")
    let idle = await eventually {
        env.agent.overlayState.agentRegion == .idleScreenEdge && env.agent.overlayState.pendingApproval == nil
    }
    check(idle, "실행이 끝나면 유휴 화면 테두리로 돌아가고 말풍선이 닫힘")
    try? await Task.sleep(for: .milliseconds(100))
    let calls = await env.executor.executed
    check(calls.count == 1 && calls.first?.id == pending.id, "실행기는 정확히 한 번")
    let statuses = env.outcomes.items.filter { $0.proposalID == pending.id }.map(\.status)
    check(statuses == [.proposed, .approved, .started, .succeeded], "결과: proposed → approved → started → succeeded (\(statuses))")
    let labels = env.overlay.states.compactMap { state -> String? in
        if case .target(_, let label) = state.agentRegion { return label }
        return nil
    }
    check(labels.contains(OverlayStatusLabel.awaitingApproval) && labels.contains(OverlayStatusLabel.typing),
          "렌더된 라벨에 확인 대기·입력 중")

    // 같은 최종 revision이 다시 와도 새 제안은 없다.
    env.say(finalUpdate)
    try? await Task.sleep(for: .milliseconds(150))
    let afterReplay = await env.executor.executed.count
    check(afterReplay == 1 && env.agent.overlayState.pendingApproval == nil, "같은 revision 재전송 → 중복 제안 없음")
    await env.agent.shutdown()
}

// MARK: - 음성 대답

private func voiceReplyClassifierChecks() {
    for text in ["응.", "네", "해줘", "그래 해줘", "실행", "OK"] {
        check(VoiceReply.classify(text) == .accept, "수락으로 읽음: \(text)")
    }
    for text in ["아니", "아니야.", "취소해", "하지 마"] {
        check(VoiceReply.classify(text) == .reject, "거절로 읽음: \(text)")
    }
    for text in ["안녕하세요 반갑습니다 오늘 회의는 세 시입니다", "이거 저기로 옮겨줘", "어제 보낸 메일"] {
        check(VoiceReply.classify(text) == nil, "대답이 아님: \(text)")
    }
}

@MainActor
private func voiceApprovalChecks() async {
    let env = AppEnv(elements: [fileA, folderB, memo])
    await env.agent.start()
    let id = UUID()
    await env.feed(fixation(at: fileA.center, from: 0.4, to: 1.32))
    await env.feed(saccade(from: fileA.center, to: folderB.center, from: 1.32, to: 1.36))
    await env.feed(fixation(at: folderB.center, from: 1.36, to: 2.8))
    let words = [word("이거를", 1.0, 1.3), word("이쪽으로", 1.8, 2.2), word("옮겨줘", 2.3, 2.7)]
    env.clock.set(2.9)
    env.say(transcript(id, 1, words, final: true))
    let gotApproval = await eventually { env.agent.overlayState.pendingApproval != nil }
    check(gotApproval, "이동 제안 승인 대기")
    guard env.agent.overlayState.pendingApproval != nil else { return }

    // 제안 만료(4초)가 지나도 승인 대기는 유지된다.
    env.clock.set(9.0)
    // 메모 입력칸을 보며 "응."이라고 대답해도 받아쓰기로 새지 않고 승인으로 처리된다.
    await env.feed(fixation(at: memo.center, from: 8.0, to: 9.0))
    let reply = UUID()
    env.say(transcript(reply, 1, [word("응", 8.6, 8.8)], text: "응.", final: false))
    env.say(transcript(reply, 2, [word("응", 8.6, 8.8)], text: "응.", final: true))
    let executed = await eventually { await env.executor.executed.count == 1 }
    check(executed, "음성 \"응\" → 승인 → 실행기 한 번 호출")
    try? await Task.sleep(for: .milliseconds(150))
    let calls = await env.executor.executed
    check(calls.count == 1, "대답이 받아쓰기·명령으로 새지 않음 (실행 \(calls.count)회)")
    if case .move = calls.first?.action {} else { check(false, "실행된 행동이 move가 아님") }
    await env.agent.shutdown()
}

// MARK: - 받아쓰기

@MainActor
private func dictationFlowChecks() async {
    let env = AppEnv(elements: [fileA, folderB, memo], applyToField: true)
    await env.agent.start()
    let id = UUID()

    await env.feed(fixation(at: memo.center, from: 0.0, to: 1.4))
    env.say(transcript(id, 1, [word("안녕하세요.", 0.3, 0.9), word("오늘", 1.0, 1.15), word("회의는", 1.15, 1.35)],
                       stable: "안녕하세요.", final: false))
    let first = await eventually { await env.field.value == "안녕하세요." }
    check(first, "입력란을 보며 말한 안정 문장만 원장이 입력")

    await env.feed(fixation(at: memo.center, from: 1.4, to: 2.5))
    env.say(transcript(id, 2, [word("안녕하세요.", 0.3, 0.9), word("오늘", 1.0, 1.15), word("회의는", 1.15, 1.35),
                               word("세시입니다.", 1.4, 2.0), word("그리고", 2.1, 2.4)],
                       stable: "안녕하세요. 오늘 회의는 세시입니다.", final: false))
    let second = await eventually { await env.field.value == "안녕하세요. 오늘 회의는 세시입니다." }
    check(second, "다음 revision은 새로 안정된 부분만 덧붙임")

    await env.feed(fixation(at: memo.center, from: 2.5, to: 3.0))
    let corrected = transcript(id, 3, [word("안녕하세요.", 0.3, 0.9), word("오늘", 1.0, 1.15), word("회의는", 1.15, 1.35),
                                       word("세", 1.4, 1.6), word("시입니다.", 1.6, 2.0)], final: true)
    env.say(corrected)
    let third = await eventually { await env.field.value == "안녕하세요. 오늘 회의는 세 시입니다." }
    check(third, "최종 revision의 교정(세시→세 시)은 에이전트가 넣은 범위 안에서 교정")

    // 같은 최종 revision 재전송·정렬 보정 revision(같은 텍스트)
    env.say(corrected)
    env.say(TranscriptUpdate(utteranceID: id, revision: 4, text: corrected.text, stablePrefix: corrected.text,
                             words: corrected.words, isFinal: true))
    try? await Task.sleep(for: .milliseconds(250))
    let fieldValue = await env.field.value
    check(fieldValue == "안녕하세요. 오늘 회의는 세 시입니다.", "재전송 뒤에도 텍스트는 한 번만 (\(fieldValue))")

    let executed = await env.executor.executed
    let kinds = executed.map { proposal -> String in
        switch proposal.action {
        case .typeText(_, let text): return "type:\(text)"
        case .setValue: return "set"
        case .press: return "press"
        case .move: return "move"
        }
    }
    check(kinds == ["type:안녕하세요.", "type: 오늘 회의는 세시입니다.", "set"], "실행: 덧붙임 2회 + 교정 1회 (\(kinds))")
    check(executed.allSatisfy { $0.origin == .dictationLedger }, "실행된 편집은 모두 원장이 만든 것(의도 자체는 실행 안 함)")
    check(Set(executed.map(\.id)).count == executed.count, "같은 편집 중복 실행 없음")
    let inserted = await env.ledger.insertedText(for: id)
    check(inserted == "안녕하세요. 오늘 회의는 세 시입니다.", "원장 기록 = 최종 텍스트")
    let ledgerState = await env.ledger.state(for: id)
    check(ledgerState == .finalized, "최종 revision 뒤 원장 세션 확정")
    let selection = await env.field.selection
    check(selection == DictationTextRange(location: fieldValue.utf16.count, length: 0), "교정 뒤 캐럿은 넣은 텍스트 끝")
    let idle = await eventually { env.agent.overlayState.agentRegion == .idleScreenEdge }
    check(idle, "받아쓰기 편집이 끝나면 유휴 테두리")
    let typingShown = env.overlay.states.contains { state in
        if case .target(let frame, let label) = state.agentRegion { return frame == memo.frame && label == OverlayStatusLabel.typing }
        return false
    }
    check(typingShown, "받아쓰기 중 입력란에 '입력 중' 표시")
    await env.agent.shutdown()
}

// MARK: - 비상 정지

@MainActor
private func killSwitchChecks() async {
    let env = AppEnv(elements: [fileA, folderB, memo])
    await env.agent.start()
    let id = UUID()
    await env.feed(fixation(at: fileA.center, from: 0.4, to: 1.32))
    await env.feed(saccade(from: fileA.center, to: folderB.center, from: 1.32, to: 1.36))
    await env.feed(fixation(at: folderB.center, from: 1.36, to: 2.8))
    env.clock.set(2.9)
    env.say(transcript(id, 1, [word("이거를", 1.0, 1.3), word("이쪽으로", 1.8, 2.2), word("옮겨줘", 2.3, 2.7)], final: true))
    let waiting = await eventually { env.agent.overlayState.pendingApproval != nil }
    check(waiting, "승인 대기 중")
    guard let pending = env.agent.overlayState.pendingApproval else { return }

    await env.agent.engageKillSwitch()
    check(env.agent.mode == .killed, "비상 정지 모드")
    check(env.agent.overlayState.pendingApproval == nil && env.agent.overlayState.agentRegion == .idleScreenEdge,
          "비상 정지 → 말풍선 닫고 유휴 테두리")
    check(env.gaze.stops.withLock { $0 } >= 1 && env.speech.stops.withLock { $0 } >= 1, "비상 정지 → 카메라·마이크 정지")
    let cancelled = await eventually {
        env.outcomes.items.contains { $0.proposalID == pending.id && $0.status == .cancelled && $0.reason == "Kill switch engaged" }
    }
    check(cancelled, "대기 중 제안은 Kill switch engaged로 취소")
    await env.agent.respond(to: .approval(pending), accepted: true)
    try? await Task.sleep(for: .milliseconds(100))
    let nothing = await env.executor.executed.isEmpty
    check(nothing, "정지 뒤 늦은 수락도 실행 안 함")

    await env.agent.resetKillSwitch()
    check(env.agent.mode == .running, "재설정 후 다시 실행 모드")
    await env.agent.shutdown()
}

// MARK: - 선제 제안

@MainActor
private func suggestionFlowChecks() async {
    let env = AppEnv(elements: [fileA, folderB, memo])
    await env.agent.start()
    let id = UUID()
    await env.feed(fixation(at: fileA.center, from: 0.0, to: 1.4))
    // 시선 모듈은 내부 영역 키로 dwell을 낸다. Fusion이 응시점을 UI 요소 token으로 바꿔야 판단 모듈이 쓴다.
    env.gaze.cueSink.yield(NonverbalCue(time: at(1.25), kind: .prolongedDwell, targetID: "gaze-region-1@1",
                                        confidence: 0.85, point: fileA.center, displayID: 1))
    env.speech.cueSink.yield(ParalinguisticCue(time: at(0.8), utteranceID: id, kind: .hesitation, confidence: 0.8))
    let resolved = await eventually { await env.fuser.stats().resolvedCueTargets >= 1 }
    check(resolved, "dwell 단서의 응시점 → UITarget token")
    try? await Task.sleep(for: .milliseconds(50))

    env.say(transcript(id, 1, [word("음…", 0.5, 0.7), word("이거를", 1.0, 1.3)], final: false))
    let shown = await eventually { env.agent.overlayState.suggestion != nil }
    check(shown, "머뭇거림 + 같은 대상 응시 → 선제 제안 말풍선")
    guard let suggestion = env.agent.overlayState.suggestion else { return }
    check(suggestion.target?.token == "file-A" && suggestion.message == "이 파일을 옮길 위치를 찾아볼까요?",
          "제안 대상·문구 (\(suggestion.message))")
    let layout = OverlayLayoutEngine.layout(env.agent.overlayState, displays: [testDisplay], primaryHeight: 900)
    check(layout.bubble?.subject == .suggestion(suggestion), "오버레이 레이아웃에 제안 말풍선")

    var responses: [(UUID, Bool)] = []
    env.agent.onSuggestionResponse = { responses.append(($0.id, $1)) }
    await env.agent.respond(to: .suggestion(suggestion), accepted: false)
    check(env.agent.overlayState.suggestion == nil, "거절하면 말풍선 닫힘")
    check(responses.count == 1 && responses.first?.0 == suggestion.id && responses.first?.1 == false, "제안 응답 콜백")
    let executed = await env.executor.executed.isEmpty
    check(executed, "제안은 행동으로 바뀌지 않음(실행기 미호출)")
    await env.agent.shutdown()
}
