import AgentContracts
import CoreGraphics
import Foundation
import Fusion
import Synchronization

func fusionChecks() async {
    await suite("Fusion") {
        lexiconChecks()
        await twoDeicticsChecks()
        await lookAheadChecks()
        await revisionChecks()
        await staleChecks()
        await missingGazeChecks()
        await calibrationChecks()
        await lowConfidenceChecks()
        await dictationChecks()
        await outOfOrderChecks()
    }
}

// MARK: - 시나리오

private func lexiconChecks() {
    let lex = DeicticLexicon.korean
    check(lex.classify("이거를")?.role == .source && lex.classify("이거를")?.kind == .object, "이거를 → 사물/source")
    check(lex.classify("이쪽으로")?.role == .destination && lex.classify("이쪽으로")?.kind == .place, "이쪽으로 → 장소/destination")
    check(lex.classify("여기서")?.role == .source, "여기서 → source(출발지)")
    check(lex.classify("여기에")?.role == .destination, "여기에 → destination")
    check(lex.classify("이걸")?.role == .source && lex.classify("이걸로")?.role == .destination, "축약형 이걸/이걸로")
    check(lex.classify("저거,")?.lemma == "저거", "문장부호 제거")
    check(lex.classify("이번") == nil && lex.classify("그리고") == nil && lex.classify("저기요") == nil,
          "이번/그리고/저기요는 지시어 아님")

    let words = [fw("이", 1.0, 1.1), fw("파일을", 1.1, 1.5), fw("저쪽에", 1.7, 2.0), fw("넣어줘", 2.1, 2.5)]
    let matches = lex.matches(in: words)
    check(matches.count == 2, "이 파일을 / 저쪽에 두 개 검출")
    if matches.count == 2 {
        check(matches[0].lemma == "이 파일" && matches[0].wordRange == 0..<2 && matches[0].role == .source,
              "관형사+명사 결합: 이 파일 → source")
        check(matches[0].word.start == ft(1.0) && matches[0].word.end == ft(1.5), "결합 구간 = 두 단어 합")
        check(matches[1].role == .destination && matches[1].kind == .place, "저쪽에 → destination")
    }
}

/// "이거를 이쪽으로 옮겨줘": 단어마다 그 시점의 응시 대상이 결합돼야 한다.
private func twoDeicticsChecks() async {
    let env = FusionEnv()
    var samples = fixation(at: fileA.center, from: 0.4, to: 1.32)
    samples += saccade(from: fileA.center, to: folderB.center, from: 1.32, to: 1.36)
    samples += fixation(at: folderB.center, from: 1.36, to: 2.8)
    await env.feed(samples)
    env.clock.set(2.9)

    let update = fupdate(revision: 1, [fw("이거를", 1.0, 1.3), fw("이쪽으로", 1.8, 2.2), fw("옮겨줘", 2.3, 2.7)])
    let result = await env.fuser.analysis(for: update)
    let bindings = result.context.bindings
    check(bindings.count == 2, "지시어 두 개 → binding 두 개")
    guard bindings.count == 2 else { return }
    check(bindings[0].target?.token == "A", "이거를 → 그 순간 보던 파일 A")
    check(bindings[1].target?.token == "B", "이쪽으로 → 그 순간 보던 폴더 B")
    check(result.deictics.map(\.role) == [.source, .destination], "역할: source, destination")
    check(bindings.allSatisfy { $0.confidence >= 0.35 && $0.confidence <= 1 }, "두 결합 모두 신뢰도 임계 이상")
    check(bindings[0].word.word == "이거를" && bindings[1].word.start == ft(1.8), "binding.word는 실제 발화 타이밍")
    let context = await env.fuser.context(for: update)
    check(context == result.context, "context(for:) == analysis(for:).context")
    let stats = await env.fuser.stats()
    check(stats.targetCacheHits > 0 && stats.resolverCalls == env.resolver.callCount, "좌표별 UITarget 캐시 사용")
}

/// 말하기 직전에 본 대상(lead 창)을 결합한다. lead를 0으로 두면 결합하지 않는다.
private func lookAheadChecks() async {
    var samples = fixation(at: fileA.center, from: 2.70, to: 2.98)
    samples += saccade(from: fileA.center, to: CGPoint(x: 1400, y: 900), from: 2.98, to: 3.40)
    let update = fupdate(revision: 1, [fw("이거", 3.0, 3.3), fw("지워줘", 3.4, 3.8)])

    let env = FusionEnv()
    await env.feed(samples)
    env.clock.set(3.9)
    let withLead = await env.fuser.analysis(for: update)
    check(withLead.context.bindings.first?.target?.token == "A", "단어 직전 300ms 응시(A)를 결합")
    check(withLead.deictics.first?.outcome == .bound, "lead 결합 outcome = bound")

    var noLeadConfig = FusionConfiguration()
    noLeadConfig.lead = .zero
    let noLead = FusionEnv(configuration: noLeadConfig)
    await noLead.feed(samples)
    noLead.clock.set(3.9)
    let withoutLead = await noLead.fuser.analysis(for: update)
    check(withoutLead.context.bindings.first?.target == nil, "lead=0이면 단어 중 훑기만 있어 결합 안 함")
    check(withoutLead.deictics.first?.outcome == .noStableFixation, "lead=0 outcome = noStableFixation")
}

/// revision이 바뀌면 다시 계산하고, 같은 revision은 같은 결과를 돌려준다.
private func revisionChecks() async {
    let env = FusionEnv()
    var samples = fixation(at: fileA.center, from: 10.0, to: 11.0)
    samples += saccade(from: fileA.center, to: folderB.center, from: 11.0, to: 11.1)
    samples += fixation(at: folderB.center, from: 11.1, to: 12.2)
    await env.feed(samples)
    env.clock.set(12.3)

    let id = UUID()
    let rev1 = fupdate(id: id, revision: 1, [fw("이거", 10.4, 10.6), fw("열어줘", 10.7, 11.0)])
    let first = await env.fuser.analysis(for: rev1)
    check(first.context.bindings.first?.target?.token == "A", "rev1: 10.4s의 이거 → A")

    let rev2 = fupdate(id: id, revision: 2, [fw("이거", 11.5, 11.7), fw("열어줘", 11.8, 12.1)])
    let second = await env.fuser.analysis(for: rev2)
    check(second.context.bindings.first?.target?.token == "B", "rev2: 타이밍이 바뀌면 다시 계산 → B")
    check(second.context.utterance.revision == 2 && second.context.bindings.count == 1, "rev2는 교체(append 아님)")

    // 새 샘플이 더 들어와도 같은 (utteranceID, revision)은 같은 결과.
    await env.feed(fixation(at: folderB.center, from: 12.2, to: 12.6))
    env.clock.set(12.7)
    let computedBefore = await env.fuser.stats().analysesComputed
    let callsBefore = env.resolver.callCount
    let again = await env.fuser.analysis(for: rev1)
    let computedAfter = await env.fuser.stats().analysesComputed
    check(again == first, "같은 revision 재요청 → 동일 결과(멱등)")
    check(computedAfter == computedBefore && env.resolver.callCount == callsBefore, "재요청은 재계산·resolver 호출 없음")

    let rev3 = fupdate(id: id, revision: 3, [fw("열어줘", 11.8, 12.1)])
    let third = await env.fuser.analysis(for: rev3)
    check(third.context.bindings.isEmpty, "rev3에서 지시어가 사라지면 binding 없음")
}

/// 수신 시점에 오래된 샘플, 미래 샘플, 버퍼보다 오래된 단어를 거부한다.
private func staleChecks() async {
    let env = FusionEnv()
    let late = fixation(at: fileA.center, from: 19.0, to: 19.5)
    env.clock.set(20.6)
    for sample in late { await env.fuser.ingest(sample) }
    var stats = await env.fuser.stats()
    check(stats.rejectedStaleSamples == late.count && stats.acceptedSamples == 0, "1초 넘게 늦게 온 샘플 전부 거부")
    let result = await env.fuser.analysis(for: fupdate(revision: 1, [fw("이거", 19.1, 19.3)]))
    check(result.context.bindings.first?.target == nil && result.deictics.first?.outcome == .noGaze,
          "거부된 샘플로는 결합하지 않음")

    await env.fuser.ingest(GazeSample(time: ft(23.0), displayID: 1, point: fileA.center, uncertaintyRadius: 20,
                                      confidence: 0.9, calibrationRevision: 1, isFixation: true))
    stats = await env.fuser.stats()
    check(stats.rejectedFutureSamples == 1, "시계보다 2초 이상 미래 샘플 거부")

    let old = FusionEnv()
    await old.feed(fixation(at: fileA.center, from: 30.0, to: 30.6))
    old.clock.set(45.0)
    let stale = await old.fuser.analysis(for: fupdate(revision: 1, [fw("이거", 30.1, 30.3)]))
    check(stale.deictics.first?.outcome == .stale && stale.context.bindings.first?.target == nil,
          "버퍼 창(10초)보다 오래된 단어 → stale")
}

/// 단어 시점에 시선이 없으면 마지막으로 본 대상으로 대체하지 않는다.
private func missingGazeChecks() async {
    let empty = FusionEnv()
    empty.clock.set(53.0)
    let none = await empty.fuser.analysis(for: fupdate(revision: 1, [fw("이거를", 52.0, 52.3), fw("여기로", 52.5, 52.8)]))
    check(none.context.bindings.count == 2, "시선 없어도 지시어마다 binding 자리는 남김")
    check(none.context.bindings.allSatisfy { $0.target == nil && $0.confidence == 0 }, "시선 없음 → target nil, 신뢰도 0")
    check(none.deictics.allSatisfy { $0.outcome == .noGaze } && none.context.gazedTarget == nil, "outcome = noGaze")

    let earlier = FusionEnv()
    await earlier.feed(fixation(at: fileA.center, from: 50.0, to: 51.0))
    earlier.clock.set(53.5)
    let gap = await earlier.fuser.analysis(for: fupdate(revision: 1, [fw("이거", 53.0, 53.3)]))
    check(gap.context.bindings.first?.target == nil, "2초 전 응시(A)로 대체하지 않음")
}

/// 보정 revision이 바뀌면 이전 샘플을 버리고, 늦게 온 이전 revision 샘플도 거부한다.
private func calibrationChecks() async {
    let env = FusionEnv()
    await env.feed(fixation(at: fileA.center, from: 60.0, to: 60.8, revision: 1))
    await env.feed(fixation(at: folderB.center, from: 61.0, to: 61.8, revision: 2))
    env.clock.set(61.9)
    await env.fuser.ingest(GazeSample(time: ft(61.85), displayID: 1, point: fileA.center, uncertaintyRadius: 20,
                                      confidence: 0.9, calibrationRevision: 1, isFixation: true))
    let stats = await env.fuser.stats()
    let revision = await env.fuser.currentCalibrationRevision()
    check(stats.calibrationResets == 1 && revision == 2, "보정 revision 1 → 2 전환")
    check(stats.rejectedCalibrationSamples == 1, "늦게 온 이전 revision 샘플 거부")

    let result = await env.fuser.analysis(for: fupdate(revision: 1, [fw("이거", 60.3, 60.5), fw("저쪽", 61.3, 61.5)]))
    check(result.context.bindings.count == 2, "binding 두 개")
    guard result.context.bindings.count == 2 else { return }
    check(result.context.bindings[0].target == nil && result.deictics[0].outcome == .calibrationChanged,
          "이전 보정 시점의 이거 → 결합 안 함(calibrationChanged)")
    check(result.context.bindings[1].target?.token == "B", "새 보정 시점의 저쪽 → B")
    check(result.calibrationRevision == 2, "분석에 사용한 보정 revision 기록")
}

/// 낮은 신뢰도 샘플과 모호한 응시를 거부한다.
private func lowConfidenceChecks() async {
    let weak = FusionEnv()
    await weak.feed(fixation(at: fileA.center, from: 70.0, to: 70.8, confidence: 0.3))
    weak.clock.set(70.9)
    let weakResult = await weak.fuser.analysis(for: fupdate(revision: 1, [fw("이거", 70.3, 70.5)]))
    check(weakResult.context.bindings.first?.target == nil && weakResult.deictics.first?.outcome == .noGaze,
          "신뢰도 0.3 샘플만 있으면 결합 안 함")

    // A/B를 110ms마다 번갈아 보면 모호하다.
    let flip = FusionEnv()
    var samples: [GazeSample] = []
    for k in 0..<10 {
        let start = 71.6 + Double(k) * 0.11
        samples += fixation(at: k.isMultiple(of: 2) ? fileA.center : folderB.center, from: start, to: start + 0.11)
    }
    await flip.feed(samples)
    flip.clock.set(72.8)
    let flipResult = await flip.fuser.analysis(for: fupdate(revision: 1, [fw("이거", 72.0, 72.4)]))
    let isLow: Bool
    if case .lowConfidence(let value)? = flipResult.deictics.first?.outcome { isLow = value < 0.35 } else { isLow = false }
    check(isLow && flipResult.context.bindings.first?.target == nil, "A/B 번갈아 응시 → lowConfidence로 거부")
}

/// 받아쓰기 대상: 발화 동안 오래 응시한 편집 가능 요소.
private func dictationChecks() async {
    let id = UUID()
    let words = [fw("안녕하세요", 80.0, 80.6), fw("반갑습니다", 80.7, 81.3)]

    let env = FusionEnv()
    await env.feed(fixation(at: textField.center, from: 79.5, to: 81.5))
    env.clock.set(80.25)
    await env.fuser.ingest(ParalinguisticCue(time: ft(80.2), utteranceID: nil, kind: .longPause, confidence: 0.8))
    env.clock.set(80.55)
    await env.fuser.ingest(ParalinguisticCue(time: ft(80.5), utteranceID: id, kind: .hesitation, confidence: 0.8))
    env.clock.set(80.65)
    await env.fuser.ingest(ParalinguisticCue(time: ft(80.6), utteranceID: UUID(), kind: .filler, confidence: 0.8))
    await env.fuser.ingest(ParalinguisticCue(time: ft(75.0), utteranceID: nil, kind: .filler, confidence: 0.8))
    await env.fuser.ingest(NonverbalCue(time: ft(80.3), kind: .prolongedDwell, targetID: "field", confidence: 0.7))
    await env.fuser.ingest(NonverbalCue(time: ft(74.0), kind: .headNod, targetID: nil, confidence: 0.7))
    env.clock.set(81.6)
    let result = await env.fuser.analysis(for: fupdate(id: id, revision: 1, words))
    check(result.context.gazedTarget?.token == "field", "발화 중 응시한 입력 칸 → gazedTarget")
    check((result.gazedTargetDwell ?? .zero) >= .milliseconds(300), "응시 시간 300ms 이상")
    check(result.context.bindings.isEmpty, "지시어 없는 받아쓰기 → binding 없음")
    check(result.context.paralinguistic.map(\.kind) == [.longPause, .hesitation], "준언어 단서: 이 발화 것만")
    check(result.context.nonverbal.map(\.kind) == [.prolongedDwell], "비언어 단서: 발화 구간 것만")

    let button = FusionEnv()
    await button.feed(fixation(at: sendButton.center, from: 79.5, to: 81.5))
    button.clock.set(81.6)
    let onButton = await button.fuser.context(for: fupdate(revision: 1, words))
    check(onButton.gazedTarget == nil, "편집 불가 버튼 응시 → gazedTarget 없음")

    let secure = FusionEnv()
    await secure.feed(fixation(at: passwordField.center, from: 79.5, to: 81.5))
    secure.clock.set(81.6)
    let onPassword = await secure.fuser.context(for: fupdate(revision: 1, words))
    check(onPassword.gazedTarget == nil, "보안 입력 칸은 기본적으로 받아쓰기 대상 아님")
}

/// 순서가 뒤바뀐 샘플도 시각순으로 넣는다.
private func outOfOrderChecks() async {
    let env = FusionEnv()
    let samples = fixation(at: fileA.center, from: 90.0, to: 90.6)
    env.clock.set(90.65)
    for sample in samples.reversed() { await env.fuser.ingest(sample) }
    let result = await env.fuser.analysis(for: fupdate(revision: 1, [fw("이거", 90.2, 90.4)]))
    check(result.context.bindings.first?.target?.token == "A", "역순 수신 샘플로도 결합")
}

// MARK: - 테스트 도구

private final class FusionTestClock: MonotonicClock {
    private let value = Mutex<UInt64>(0)
    func now() -> MonotonicTime { MonotonicTime(nanoseconds: value.withLock { $0 }) }
    func set(_ seconds: Double) { value.withLock { $0 = ft(seconds).nanoseconds } }
}

private final class FusionTestResolver: UITargetResolving {
    let targets: [UITarget]
    private let calls = Mutex(0)
    init(_ targets: [UITarget]) { self.targets = targets }
    var callCount: Int { calls.withLock { $0 } }

    func target(at point: CGPoint) async -> UITarget? {
        calls.withLock { $0 += 1 }
        return targets.filter { $0.frame.contains(point) }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    func focusedTarget() async -> UITarget? { nil }
}

private struct FusionEnv {
    let clock = FusionTestClock()
    let resolver = FusionTestResolver([fileA, folderB, textField, passwordField, sendButton])
    let fuser: AttentionFuser

    init(configuration: FusionConfiguration = FusionConfiguration()) {
        fuser = AttentionFuser(resolver: resolver, clock: clock, configuration: configuration)
    }

    /// 실시간처럼 각 샘플을 20ms 지연으로 넣는다.
    func feed(_ samples: [GazeSample]) async {
        for sample in samples.sorted(by: { $0.time < $1.time }) {
            clock.set(Double(sample.time.nanoseconds) / 1e9 - fusionBase + 0.02)
            await fuser.ingest(sample)
        }
    }
}

/// 모든 시각은 100초 기준 상대값.
private let fusionBase = 100.0

private func ft(_ seconds: Double) -> MonotonicTime {
    MonotonicTime(nanoseconds: UInt64(((fusionBase + seconds) * 1e9).rounded()))
}

private func fw(_ text: String, _ start: Double, _ end: Double) -> WordTiming {
    WordTiming(word: text, start: ft(start), end: ft(end), confidence: 0.95)
}

private func fupdate(id: UUID = UUID(), revision: Int, _ words: [WordTiming]) -> TranscriptUpdate {
    let text = words.map(\.word).joined(separator: " ")
    return TranscriptUpdate(utteranceID: id, revision: revision, text: text, stablePrefix: "", words: words, isFinal: false)
}

private func element(_ token: String, _ frame: CGRect, role: String, editable: Bool = false, secure: Bool = false) -> UITarget {
    UITarget(token: token, pid: 42, appBundleID: "com.example.test", role: role, title: token, frame: frame,
             isEditable: editable, isSecure: secure, supportedActions: ["AXPress"], observedAt: ft(0))
}

private let fileA = element("A", CGRect(x: 100, y: 100, width: 80, height: 80), role: "AXImage")
private let folderB = element("B", CGRect(x: 600, y: 400, width: 120, height: 120), role: "AXImage")
private let textField = element("field", CGRect(x: 100, y: 700, width: 400, height: 40), role: "AXTextField", editable: true)
private let passwordField = element("password", CGRect(x: 100, y: 800, width: 400, height: 40), role: "AXSecureTextField",
                                    editable: true, secure: true)
private let sendButton = element("send", CGRect(x: 900, y: 100, width: 80, height: 30), role: "AXButton")

private extension UITarget {
    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
}

/// 60Hz 응시 샘플(±2pt 결정적 흔들림).
private func fixation(at point: CGPoint, from start: Double, to end: Double, confidence: Double = 0.9,
                      revision: Int = 1) -> [GazeSample] {
    var result: [GazeSample] = []
    var i = 0
    while start + Double(i) / 60 < end - 1e-9 {
        let t = start + Double(i) / 60
        let jitter = CGPoint(x: sin(Double(i) * 1.7) * 2, y: cos(Double(i) * 1.3) * 2)
        result.append(GazeSample(time: ft(t), displayID: 1, point: CGPoint(x: point.x + jitter.x, y: point.y + jitter.y),
                                 uncertaintyRadius: 30, confidence: confidence, calibrationRevision: revision, isFixation: true))
        i += 1
    }
    return result
}

/// 두 점 사이를 지나는 비응시 샘플.
private func saccade(from a: CGPoint, to b: CGPoint, from start: Double, to end: Double) -> [GazeSample] {
    var result: [GazeSample] = []
    let count = max(1, Int(((end - start) * 60).rounded()))
    for i in 0..<count {
        let f = Double(i) / Double(count)
        result.append(GazeSample(time: ft(start + Double(i) / 60), displayID: 1,
                                 point: CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f),
                                 uncertaintyRadius: 60, confidence: 0.8, calibrationRevision: 1, isFixation: false))
    }
    return result
}
