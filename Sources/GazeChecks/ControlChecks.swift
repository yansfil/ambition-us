import AgentContracts
import Control
import Foundation
import Synchronization

func controlChecks() async {
    await suite("Control/Policy") { policyTableChecks() }
    await suite("Control/PolicyEngine") { await policyEngineChecks() }
    await suite("Control/DictationLedger") { await ledgerChecks() }
    await suite("Control/ActionCoordinator") { await coordinatorChecks() }
    await suite("Control/통합: 경로별 정책·원장 확인") { await originPolicyChecks() }
    await suite("Control/통합: 정책 거부 상태·실행 시간 초과·정지") { await coordinatorIntegrationChecks() }
}

// MARK: - 공용 도우미

/// `check`는 동기 autoclosure라 await를 못 받는다. actor 조회용 비동기 판정.
private func expect(_ condition: @autoclosure () async -> Bool, _ message: String,
                    file: StaticString = #fileID, line: UInt = #line) async {
    let passed = await condition()
    check(passed, message, file: file, line: line)
}

private let second: UInt64 = 1_000_000_000
private let t0 = MonotonicTime(nanoseconds: 1_000 * second)

private func at(_ seconds: Double) -> MonotonicTime {
    MonotonicTime(nanoseconds: t0.nanoseconds + UInt64(seconds * Double(second)))
}

private func uiTarget(_ token: String = "field", title: String? = nil, editable: Bool = true, secure: Bool = false,
                      observedAt: MonotonicTime = t0, x: Double = 10) -> UITarget {
    UITarget(token: token, pid: 42, appBundleID: "com.example.app", role: editable ? "AXTextField" : "AXButton",
             title: title, frame: CGRect(x: x, y: 10, width: 200, height: 24), isEditable: editable,
             isSecure: secure, supportedActions: ["AXPress"], observedAt: observedAt)
}

private func proposal(_ action: AgentAction, risk: RiskLevel = .low, rationale: String = "User dictated text",
                      expiresAt: MonotonicTime = at(30), id: UUID = UUID()) -> ActionProposal {
    ActionProposal(id: id, action: action, basedOnUtterance: UUID(), basedOnRevision: 1,
                   rationale: rationale, risk: risk, expiresAt: expiresAt)
}

private func isApproval(_ decision: PolicyDecision) -> Bool {
    if case .requireApproval = decision { return true }
    return false
}

private func isReject(_ decision: PolicyDecision) -> Bool {
    if case .reject = decision { return true }
    return false
}

private func reason(_ decision: PolicyDecision) -> String {
    switch decision {
    case .execute: return ""
    case .requireApproval(let reason), .reject(let reason): return reason
    }
}

// MARK: - 정책 표

private func policyTableChecks() {
    let config = PolicyConfiguration()
    let field = uiTarget()
    let gazed = PolicyContext(safetyMode: .active, gazeFocus: GazeFocus(target: field, at: t0))

    func decide(_ p: ActionProposal, _ context: PolicyContext = gazed, now: MonotonicTime = at(1)) -> PolicyDecision {
        PolicyRules.evaluate(p, now: now, context: context, configuration: config)
    }

    let safeType = proposal(.typeText(target: field, text: "안녕하세요"))
    check(decide(safeType) == .execute, "low 위험 typeText + 편집 가능 + 시선 필드 → execute")

    // 거부 규칙
    check(decide(proposal(.typeText(target: field, text: "hi"), expiresAt: at(1))) == .reject(reason: "Proposal expired"),
          "만료 시각 == now → reject")
    check(isReject(decide(proposal(.typeText(target: field, text: "hi"), expiresAt: at(0.5)))), "만료된 제안 → reject")
    let secure = uiTarget("pw", secure: true)
    let secureContext = PolicyContext(gazeFocus: GazeFocus(target: secure, at: t0))
    check(decide(proposal(.typeText(target: secure, text: "hunter2")), secureContext)
          == .reject(reason: "Target is a secure text field"), "보안 필드 → reject")
    let old = uiTarget(observedAt: t0)
    check(isReject(decide(proposal(.typeText(target: old, text: "hi")), now: at(10.5))), "10초 넘은 대상 → reject")
    check(reason(decide(proposal(.typeText(target: old, text: "hi")), now: at(10.5))).hasPrefix("Target is stale"),
          "stale 사유 문구")
    check(isReject(decide(proposal(.typeText(target: field, text: ""), risk: .low))), "빈 텍스트 → reject")

    // 우선순위: 거부가 승인 요구보다 앞선다
    check(isReject(decide(proposal(.typeText(target: secure, text: "보내기"), risk: .high), secureContext)),
          "보안 필드 + high + 키워드 → reject가 우선")
    check(isReject(decide(proposal(.press(target: uiTarget("b", editable: false)), risk: .high, expiresAt: at(0)))),
          "만료 + high → reject")

    // 승인 요구 규칙
    check(decide(proposal(.typeText(target: field, text: "hi"), risk: .high)) == .requireApproval(reason: "High-risk action"),
          "high 위험 → requireApproval")
    for word in ["Send it now", "please SUBMIT", "delete this", "purchase two", "메일 보내기", "파일 전송",
                 "사진 삭제", "결제 진행", "구매하기", "과제 제출"] {
        check(isApproval(decide(proposal(.typeText(target: field, text: word)))), "키워드 '\(word)' → requireApproval")
    }
    let decomposed = "결제".decomposedStringWithCanonicalMapping
    check(isApproval(decide(proposal(.typeText(target: field, text: decomposed)))), "NFD로 분해된 한글 키워드도 감지")
    let sendButton = uiTarget("send", title: "보내기", editable: false)
    check(reason(decide(proposal(.press(target: sendButton)))) == "Contains sensitive keyword \"보내기\"",
          "제목이 '보내기'인 버튼 press → 키워드로 승인 요구")
    check(isApproval(decide(proposal(.typeText(target: field, text: "ok"), rationale: "then submit the form"))),
          "근거 문장에 키워드 → requireApproval")
    check(isApproval(decide(proposal(.typeText(target: field, text: "hello\n")))), "줄바꿈 포함 → requireApproval")
    check(isApproval(decide(proposal(.typeText(target: field, text: "a\tb")))), "탭 포함 → requireApproval")
    check(decide(proposal(.typeText(target: field, text: "👨‍👩‍👧 가족"))) == .execute, "ZWJ 이모지는 제어 문자로 보지 않음")
    check(isApproval(decide(proposal(.typeText(target: field, text: "hi"), risk: .medium))), "medium typeText → requireApproval")
    check(isApproval(decide(proposal(.typeText(target: uiTarget("label", editable: false), text: "hi")))),
          "편집 불가 대상 typeText → requireApproval")
    let other = uiTarget("other", x: 400)
    check(reason(decide(proposal(.typeText(target: other, text: "hi")))) == "Target is not the field the user is looking at",
          "시선이 머물지 않은 필드 → requireApproval")
    check(isApproval(decide(proposal(.typeText(target: field, text: "hi")), PolicyContext())), "시선 정보 없음 → requireApproval")
    check(isApproval(decide(proposal(.typeText(target: field, text: "hi")), now: at(3.5))),
          "시선이 3초 넘게 지난 필드 → requireApproval")
    let sameElementNewToken = uiTarget("field-reissued")
    check(decide(proposal(.typeText(target: sameElementNewToken, text: "hi"))) == .execute,
          "토큰이 달라도 같은 pid·역할·위치면 같은 요소")
    check(isApproval(decide(proposal(.press(target: uiTarget("ok", title: "OK", editable: false))))),
          "low press도 기본은 requireApproval")
    check(isApproval(decide(proposal(.setValue(target: field, value: "x")))), "setValue → requireApproval")

    // move
    let src = uiTarget("src", observedAt: at(0.5))
    let dst = uiTarget("dst", observedAt: at(0.5))
    check(decide(proposal(.move(source: src, destination: dst))) == .execute, "low move + 두 대상 신선 → execute")
    let staleish = uiTarget("dst", observedAt: t0)
    check(decide(proposal(.move(source: src, destination: staleish)), now: at(4))
          == .requireApproval(reason: "Move targets are not fresh"), "move 한쪽이 3초 초과(10초 미만) → requireApproval")
    check(isApproval(decide(proposal(.move(source: src, destination: dst), risk: .medium))), "medium move → requireApproval")
    check(isApproval(decide(proposal(.move(source: src, destination: uiTarget("trash", title: "Delete")))) ),
          "move 대상 제목에 키워드 → requireApproval")

    // 안전 스위치
    var paused = gazed; paused.safetyMode = .paused
    var killed = gazed; killed.safetyMode = .killed
    check(decide(safeType, paused) == .reject(reason: "Agent is paused"), "일시정지 → 실행 가능한 제안도 reject")
    check(decide(safeType, killed) == .reject(reason: "Kill switch engaged"), "비상 정지 → reject")
    check(decide(proposal(.typeText(target: field, text: "hi"), expiresAt: at(0)), killed)
          == .reject(reason: "Kill switch engaged"), "비상 정지가 다른 거부보다 우선")
}

private func policyEngineChecks() async {
    let safety = AgentSafetySwitch()
    let engine = PolicyEngine(safety: safety)
    let field = uiTarget()
    let p = proposal(.typeText(target: field, text: "hi"))

    await expect(isApproval(await engine.decide(p, now: at(1))), "시선 초점 전에는 승인 요구")
    await engine.updateGazeFocus(field, at: at(0.5))
    await expect(await engine.decide(p, now: at(1)) == .execute, "시선 초점 갱신 후 execute")
    safety.pause()
    await expect(await engine.decide(p, now: at(1)) == .reject(reason: "Agent is paused"), "공유 스위치 일시정지 반영")
    safety.resume()
    await expect(await engine.decide(p, now: at(1)) == .execute, "resume 후 다시 execute")
    safety.engageKillSwitch()
    safety.resume()
    await expect(await engine.decide(p, now: at(1)) == .reject(reason: "Kill switch engaged"), "비상 정지는 resume으로 안 풀림")
    safety.resetKillSwitch()
    await expect(await engine.decide(p, now: at(1)) == .execute, "resetKillSwitch 후 execute")
    await engine.updateGazeFocus(nil, at: at(1))
    await expect(isApproval(await engine.decide(p, now: at(1))), "시선 초점 해제 후 승인 요구")
}

// MARK: - 받아쓰기 원장

private func update(_ id: UUID, _ revision: Int, stable: String, text: String? = nil, final: Bool = false) -> TranscriptUpdate {
    TranscriptUpdate(utteranceID: id, revision: revision, text: text ?? stable, stablePrefix: stable,
                     words: [], isFinal: final)
}

private func snap(_ value: String, caret: Int) -> DictationFieldSnapshot {
    DictationFieldSnapshot(value: value, selection: DictationTextRange(location: caret, length: 0))
}

private func delta(_ plan: DictationPlan) -> DictationDelta? {
    if case .apply(let delta) = plan { return delta }
    return nil
}

private func isStop(_ plan: DictationPlan) -> Bool {
    if case .stop = plan { return true }
    return false
}

private func isNoChange(_ plan: DictationPlan) -> Bool {
    if case .noChange = plan { return true }
    return false
}

private func ledgerChecks() async {
    let field = uiTarget()

    // 덧붙임: 기존 텍스트 "AB" 사이(캐럿 1)에 넣고, 새 안정 구간만 이어 붙인다.
    do {
        let ledger = DictationLedger()
        let id = UUID()
        let p0 = await ledger.plan(for: update(id, 0, stable: "", text: "안"), target: field, snapshot: snap("AB", caret: 1))
        check(isNoChange(p0), "안정 구간이 비어 있으면 할 일 없음")
        let p1 = await ledger.plan(for: update(id, 1, stable: "안녕", text: "안녕하"), target: field,
                                   snapshot: snap("AB", caret: 1))
        guard let d1 = delta(p1) else { check(false, "첫 안정 구간 → apply"); return }
        check(d1.edit == .insert(text: "안녕", location: 1), "첫 덧붙임은 stablePrefix만 캐럿 위치에")
        check(d1.expectedFieldValue == "A안녕B", "기대 필드 값은 기존 텍스트 보존")
        check(d1.expectedSelection == DictationTextRange(location: 3, length: 0), "기대 캐럿은 넣은 텍스트 끝")
        check(d1.action == .typeText(target: field, text: "안녕"), "덧붙임은 typeText로 변환")
        await expect(await ledger.commit(d1.idempotencyKey), "커밋 성공")

        let p2 = await ledger.plan(for: update(id, 2, stable: "안녕하세요", text: "안녕하세요 반가"), target: field,
                                   snapshot: snap("A안녕B", caret: 3))
        check(delta(p2)?.edit == .insert(text: "하세요", location: 3), "다음 revision은 새로 안정된 부분만 덧붙임")
        if let d2 = delta(p2) { await ledger.commit(d2.idempotencyKey) }

        // 중복 억제
        let again = await ledger.plan(for: update(id, 2, stable: "안녕하세요"), target: field,
                                      snapshot: snap("A안녕하세요B", caret: 6))
        check(isNoChange(again), "같은 revision 재전달 → noChange")
        let older = await ledger.plan(for: update(id, 1, stable: "안녕"), target: field,
                                      snapshot: snap("A안녕하세요B", caret: 6))
        check(isNoChange(older), "더 오래된 revision → noChange")
        if let d2 = delta(p2) {
            await expect(await ledger.commit(d2.idempotencyKey) == false, "같은 키 두 번째 커밋 → false")
            await expect(await ledger.isCommitted(d2.idempotencyKey), "커밋된 키 조회")
        }
        await expect(await ledger.insertedText(for: id) == "안녕하세요", "원장에 넣은 텍스트 기록")

        let fin = await ledger.plan(for: update(id, 3, stable: "안녕하세요", text: "안녕하세요 반가워요", final: true),
                                    target: field, snapshot: snap("A안녕하세요B", caret: 6))
        check(delta(fin)?.edit == .insert(text: " 반가워요", location: 6), "최종 revision은 text 전체를 반영")
        if let d = delta(fin) { await ledger.commit(d.idempotencyKey) }
        await expect(await ledger.state(for: id) == .finalized, "최종 커밋 후 finalized")
        let after = await ledger.plan(for: update(id, 4, stable: "x", final: true), target: field,
                                      snapshot: snap("A안녕하세요 반가워요B", caret: 11))
        check(isNoChange(after), "finalized 뒤 revision → noChange")
    }

    // 진행 중 편집 중복 차단과 같은 키 재계획
    do {
        let ledger = DictationLedger()
        let id = UUID()
        let first = await ledger.plan(for: update(id, 1, stable: "hello"), target: field, snapshot: snap("", caret: 0))
        let inFlight = await ledger.plan(for: update(id, 2, stable: "hello world"), target: field, snapshot: snap("", caret: 0))
        check(isNoChange(inFlight), "편집이 진행 중이면 새 revision은 noChange")
        guard let d = delta(first) else { check(false, "첫 계획 apply"); return }
        await expect(await ledger.abandon(d.idempotencyKey), "실패한 편집 abandon")
        let retry = await ledger.plan(for: update(id, 1, stable: "hello"), target: field, snapshot: snap("", caret: 0))
        check(delta(retry)?.idempotencyKey == d.idempotencyKey, "같은 편집을 다시 계획하면 같은 idempotency key")
        check(delta(retry)?.proposalID == d.proposalID, "같은 키 → 같은 제안 ID(코디네이터 중복 차단과 연동)")
        await expect(await ledger.commit(d.idempotencyKey), "재시도 커밋")
        await expect(await ledger.commit(d.idempotencyKey) == false, "재시도 키 중복 커밋 차단")

        let partial = await ledger.plan(for: update(id, 2, stable: "hello world"), target: field,
                                        snapshot: snap("hello", caret: 5))
        guard let d2 = delta(partial) else { check(false, "두 번째 apply"); return }
        await ledger.abandon(d2.idempotencyKey)
        // 실행기가 일부만 입력하고 실패한 상황: 필드가 편집 전과 다르다 → 멈춤
        let afterPartial = await ledger.plan(for: update(id, 3, stable: "hello world!"), target: field,
                                             snapshot: snap("hello wo", caret: 8))
        check(isStop(afterPartial), "부분 입력 후 필드가 기대와 다르면 stop")
    }

    // 교정: 에이전트가 넣은 범위 안쪽만 바꾼다
    do {
        let ledger = DictationLedger()
        let id = UUID()
        let base = "To: Bob\n"
        let p1 = await ledger.plan(for: update(id, 1, stable: "meet at noon"), target: field,
                                   snapshot: snap(base, caret: 8))
        if let d = delta(p1) { await ledger.commit(d.idempotencyKey) }
        let fixed = await ledger.plan(for: update(id, 2, stable: "meet at nine", text: "meet at nine", final: true),
                                      target: field, snapshot: snap(base + "meet at noon", caret: 20))
        guard let d = delta(fixed) else { check(false, "교정 apply"); return }
        check(d.edit == .replace(range: DictationTextRange(location: 17, length: 3), with: "ine"),
              "달라진 꼬리만 교체(공통 접두 'meet at n' 이후)")
        if case .replace(let range, _) = d.edit {
            check(range.location >= 8 && range.end <= 20, "교정 범위가 에이전트가 넣은 범위 안")
        }
        check(d.expectedFieldValue == base + "meet at nine", "교정 후 기대 값, 앞쪽 사용자 텍스트 보존")
        check(d.action == .setValue(target: field, value: base + "meet at nine"), "교정은 setValue(전체 값)로 변환")
        await ledger.commit(d.idempotencyKey, observed: snap(base + "meet at nine", caret: 20))
        await expect(await ledger.state(for: id) == .finalized, "관측 결과가 기대와 같으면 finalized")
    }

    // 확정 전 안정 구간이 줄면 지우지 않고, 최종에서만 자기 범위 안에서 지운다
    do {
        let ledger = DictationLedger()
        let id = UUID()
        let p1 = await ledger.plan(for: update(id, 1, stable: "가나다"), target: field, snapshot: snap("", caret: 0))
        if let d = delta(p1) { await ledger.commit(d.idempotencyKey) }
        let shrink = await ledger.plan(for: update(id, 2, stable: "가나"), target: field, snapshot: snap("가나다", caret: 3))
        check(isNoChange(shrink), "확정 전 안정 구간 축소 → 지우지 않고 대기")
        let fin = await ledger.plan(for: update(id, 3, stable: "가나", text: "가나", final: true), target: field,
                                    snapshot: snap("가나다", caret: 3))
        check(delta(fin)?.edit == .replace(range: DictationTextRange(location: 2, length: 1), with: ""),
              "최종에서 줄어든 부분은 자기 범위 안에서 삭제")
        let syllable = DictationLedger()
        let sid = UUID()
        if let d = delta(await syllable.plan(for: update(sid, 1, stable: "하"), target: field, snapshot: snap("", caret: 0))) {
            await syllable.commit(d.idempotencyKey)
        }
        let composed = await syllable.plan(for: update(sid, 2, stable: "한국"), target: field, snapshot: snap("하", caret: 1))
        check(delta(composed)?.edit == .replace(range: DictationTextRange(location: 0, length: 1), with: "한국"),
              "음절이 바뀌면(하→한) 그 음절부터 교체")
    }

    // 사용자 입력·선택 변경 → 멈춤
    do {
        let ledger = DictationLedger()
        let id = UUID()
        if let d = delta(await ledger.plan(for: update(id, 1, stable: "hello"), target: field, snapshot: snap("", caret: 0))) {
            await ledger.commit(d.idempotencyKey)
        }
        let typed = await ledger.plan(for: update(id, 2, stable: "hello world"), target: field,
                                      snapshot: snap("hellox", caret: 6))
        check(isStop(typed), "사용자가 타이핑하면 stop")
        let later = await ledger.plan(for: update(id, 3, stable: "hello world again"), target: field,
                                      snapshot: snap("hellox", caret: 6))
        check(isStop(later), "멈춘 발화는 이후에도 계속 stop")

        let moved = DictationLedger()
        let mid = UUID()
        if let d = delta(await moved.plan(for: update(mid, 1, stable: "hello"), target: field, snapshot: snap("", caret: 0))) {
            await moved.commit(d.idempotencyKey)
        }
        let caretMoved = await moved.plan(for: update(mid, 2, stable: "hello world"), target: field,
                                          snapshot: snap("hello", caret: 2))
        check(caretMoved == .stop(reason: "Selection changed outside the agent"), "캐럿이 움직이면 stop")

        let observed = DictationLedger()
        let oid = UUID()
        if let d = delta(await observed.plan(for: update(oid, 1, stable: "hi"), target: field, snapshot: snap("", caret: 0))) {
            await observed.commit(d.idempotencyKey, observed: snap("Hi", caret: 2))
        }
        await expect(isStop(await observed.plan(for: update(oid, 2, stable: "hi there"), target: field, snapshot: snap("Hi", caret: 2))),
              "커밋 시 관측 값이 다르면(자동 교정 등) 이후 stop")
    }

    // 시작 전 거부 조건
    do {
        let ledger = DictationLedger()
        let secure = await ledger.plan(for: update(UUID(), 1, stable: "pw"), target: uiTarget("pw", secure: true),
                                       snapshot: snap("", caret: 0))
        check(isStop(secure), "보안 필드에는 받아쓰기 안 함")
        let selected = await ledger.plan(for: update(UUID(), 1, stable: "x"), target: field,
                                         snapshot: DictationFieldSnapshot(value: "abc", selection: .init(location: 0, length: 2)))
        check(selected == .stop(reason: "Selection is not empty"), "선택 영역이 있으면 덮어쓰지 않고 stop")
        let id = UUID()
        _ = await ledger.plan(for: update(id, 1, stable: ""), target: field, snapshot: snap("abc", caret: 3))
        let reanchored = await ledger.plan(for: update(id, 2, stable: "d"), target: field, snapshot: snap("abc", caret: 0))
        check(delta(reanchored)?.edit == .insert(text: "d", location: 0), "아직 넣은 게 없으면 현재 캐럿으로 기준점 갱신")
        let switched = await ledger.plan(for: update(id, 3, stable: "de"), target: uiTarget("other", x: 500),
                                         snapshot: snap("dabc", caret: 1))
        check(switched == .stop(reason: "Dictation target changed"), "같은 발화의 대상이 바뀌면 stop")
    }
}

// MARK: - 코디네이터

private final class FakeClock: MonotonicClock, Sendable {
    private let value = Mutex<UInt64>(0)
    init(_ time: MonotonicTime) { value.withLock { $0 = time.nanoseconds } }
    func now() -> MonotonicTime { MonotonicTime(nanoseconds: value.withLock { $0 }) }
    func set(_ time: MonotonicTime) { value.withLock { $0 = time.nanoseconds } }
}

private actor FakeExecutor: ActionExecuting {
    private(set) var executed: [UUID] = []
    private let failing: Set<UUID>
    private let clock: FakeClock
    init(clock: FakeClock, failing: Set<UUID> = []) {
        self.clock = clock; self.failing = failing
    }
    func execute(_ proposal: ActionProposal) async -> ActionOutcome {
        executed.append(proposal.id)
        let fail = failing.contains(proposal.id)
        return ActionOutcome(proposalID: proposal.id, status: fail ? .failed : .succeeded,
                             verification: fail ? .none : .verified, target: proposal.action.involvedTargetsForCheck,
                             time: clock.now(), reason: fail ? "Element vanished" : nil)
    }
}

private extension AgentAction {
    var involvedTargetsForCheck: UITarget? {
        switch self {
        case .typeText(let target, _), .press(let target), .setValue(let target, _): return target
        case .move(_, let destination): return destination
        }
    }
}

/// 시간 안에 끝나지 않으면 nil. 스트림 대기가 영원히 멈추지 않게 한다.
private func within<T: Sendable>(_ seconds: Double, _ operation: @escaping @Sendable () async -> T?) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask { try? await Task.sleep(for: .seconds(seconds)); return nil }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

private func nextRequest(_ stream: AsyncStream<ApprovalRequest?>) async -> ApprovalRequest? {
    await within(2) {
        for await request in stream { if let request { return request } }
        return nil
    }
}

private func take(_ count: Int, from stream: AsyncStream<ActionOutcome>) async -> [ActionOutcome] {
    await within(2) {
        var items: [ActionOutcome] = []
        for await item in stream {
            items.append(item)
            if items.count == count { break }
        }
        return items
    } ?? []
}

private struct Harness {
    let clock: FakeClock
    let executor: FakeExecutor
    let coordinator: ActionCoordinator
    let field: UITarget

    init(failing: Set<UUID> = [], approvalTimeout: Duration = .seconds(5),
         ledger: DictationLedger? = nil) async {
        clock = FakeClock(at(1))
        executor = FakeExecutor(clock: clock, failing: failing)
        field = uiTarget()
        let safety = AgentSafetySwitch()
        let engine = PolicyEngine(safety: safety, dictationVerifier: ledger)
        await engine.updateGazeFocus(field, at: at(0.5))
        coordinator = ActionCoordinator(policy: engine, executor: executor, clock: clock, safety: safety,
                                        approvalTimeout: approvalTimeout)
    }

    func typing(_ text: String, risk: RiskLevel = .low, id: UUID = UUID()) -> ActionProposal {
        proposal(.typeText(target: field, text: text), risk: risk, id: id)
    }
}

private func coordinatorChecks() async {
    // 자동 실행
    do {
        let h = await Harness()
        let p = h.typing("hi")
        let result = await h.coordinator.submit(p)
        check(result.status == .succeeded, "정책 execute → 바로 실행·성공")
        await expect(await h.executor.executed == [p.id], "실행기 한 번 호출")
        let streamed = await take(2, from: h.coordinator.outcomes)
        check(streamed.map(\.status) == [.started, .succeeded], "스트림: started → succeeded")
    }

    // 승인 흐름: 승인
    do {
        let h = await Harness()
        let p = h.typing("hi", risk: .high)
        let coordinator = h.coordinator
        let run = Task { await coordinator.submit([p]) }
        let request = await nextRequest(coordinator.approvalRequests)
        check(request?.proposal.id == p.id, "high 위험 → 승인 요청 방출")
        check(request?.reason == "High-risk action", "승인 요청에 정책 사유")
        await expect(await coordinator.pendingApproval?.proposal.id == p.id, "pendingApproval 조회")
        await expect(await h.executor.executed.isEmpty, "승인 전에는 실행하지 않음")
        await expect(await coordinator.approve(UUID()) == false, "다른 ID 승인은 무시")
        await expect(await coordinator.approve(p.id), "승인")
        let results = await run.value
        check(results.map(\.status) == [.succeeded], "승인 후 실행·성공")
        await expect(await h.executor.executed == [p.id], "승인 후 실행기 호출")
        let streamed = await take(4, from: coordinator.outcomes)
        check(streamed.map(\.status) == [.proposed, .approved, .started, .succeeded],
              "스트림: proposed → approved → started → succeeded")
        await expect(await coordinator.pendingApproval == nil, "승인 후 대기 없음")
    }

    // 승인 흐름: 거절
    do {
        let h = await Harness()
        let p = h.typing("결제", risk: .low)
        let coordinator = h.coordinator
        let run = Task { await coordinator.submit([p]) }
        _ = await nextRequest(coordinator.approvalRequests)
        await expect(await coordinator.reject(p.id), "거절")
        let results = await run.value
        check(results.first?.status == .cancelled && results.first?.reason == "Rejected by user", "거절 → cancelled")
        await expect(await h.executor.executed.isEmpty, "거절하면 실행하지 않음")
    }

    // 승인 흐름: 시간 초과
    do {
        let h = await Harness(approvalTimeout: .milliseconds(50))
        let p = h.typing("hi", risk: .high)
        let result = await within(3) { await h.coordinator.submit(p) }
        check(result?.status == .cancelled && result?.reason == "Approval timed out", "응답 없으면 시간 초과 → cancelled")
        await expect(await h.executor.executed.isEmpty, "시간 초과면 실행하지 않음")
    }

    // 배치: 중간 실패 시 나머지 취소
    do {
        let failingID = UUID()
        let h = await Harness(failing: [failingID])
        let batch = [h.typing("one"), h.typing("two", id: failingID), h.typing("three")]
        let results = await h.coordinator.submit(batch)
        check(results.map(\.status) == [.succeeded, .failed, .cancelled], "배치: 성공 → 실패 → 취소")
        check(results.last?.reason == "Not executed: an earlier action failed", "취소 사유 문구")
        await expect(await h.executor.executed == [batch[0].id, failingID], "실패 뒤 행동은 실행기 미호출")
    }

    // 배치: 정책 거부 시 나머지 취소
    do {
        let h = await Harness()
        let expired = proposal(.typeText(target: h.field, text: "late"), expiresAt: at(0.5))
        let results = await h.coordinator.submit([expired, h.typing("after")])
        check(results.first?.reason == "Rejected by policy: Proposal expired", "정책 거부 → cancelled + 사유")
        check(results.last?.status == .cancelled, "거부 뒤 행동도 취소")
        await expect(await h.executor.executed.isEmpty, "거부 배치는 아무것도 실행 안 함")
    }

    // 중복 제안 차단
    do {
        let h = await Harness()
        let p = h.typing("once")
        await h.coordinator.submit(p)
        let second = await h.coordinator.submit(p)
        check(second.status == .cancelled && second.reason == "Duplicate proposal ignored", "같은 제안 ID 재제출 → 무시")
        await expect(await h.executor.executed == [p.id], "실행은 한 번만")
    }

    // 승인 대기 중 비상 정지
    do {
        let h = await Harness()
        let coordinator = h.coordinator
        let first = h.typing("send", risk: .low)
        let queued = h.typing("then this")
        let run = Task { await coordinator.submit([first, queued]) }
        _ = await nextRequest(coordinator.approvalRequests)
        await coordinator.engageKillSwitch()
        let results = await run.value
        check(results.map(\.status) == [.cancelled, .cancelled], "비상 정지 → 대기·남은 행동 모두 취소")
        check(results.first?.reason == "Kill switch engaged", "대기 중 행동 사유")
        await expect(await h.executor.executed.isEmpty, "비상 정지 후 실행 없음")
        let blocked = await coordinator.submit(h.typing("hi"))
        check(blocked.status == .cancelled && blocked.reason == "Kill switch engaged", "정지 상태에서는 새 제안도 거부")
        await coordinator.resume()
        await expect((await coordinator.submit(h.typing("hi"))).status == .cancelled, "resume으로는 비상 정지가 안 풀림")
        await coordinator.resetKillSwitch()
        await expect((await coordinator.submit(h.typing("hi"))).status == .succeeded, "reset 후 정상 실행")
    }

    // 일시정지
    do {
        let h = await Harness()
        await h.coordinator.pause()
        let paused = await h.coordinator.submit(h.typing("hi"))
        check(paused.reason == "Agent is paused", "일시정지 → 거부")
        await h.coordinator.resume()
        await expect((await h.coordinator.submit(h.typing("hi"))).status == .succeeded, "resume 후 실행")
    }

    // 제출 순서 직렬화: 승인 대기 중인 배치 뒤의 배치는 기다린다
    do {
        let h = await Harness()
        let coordinator = h.coordinator
        let gated = h.typing("x", risk: .high)
        let later = h.typing("y")
        let firstRun = Task { await coordinator.submit(gated) }
        _ = await nextRequest(coordinator.approvalRequests)
        let secondRun = Task { await coordinator.submit(later) }
        try? await Task.sleep(for: .milliseconds(50))
        await expect(await h.executor.executed.isEmpty, "앞 배치 승인 전에는 뒤 배치도 실행 안 함")
        await coordinator.approve(gated.id)
        _ = await firstRun.value
        _ = await secondRun.value
        await expect(await h.executor.executed == [gated.id, later.id], "배치는 제출 순서대로 실행")
    }

    // 원장 델타 → 제안 → 코디네이터
    do {
        let ledger = DictationLedger()
        let h = await Harness(ledger: ledger)
        let id = UUID()
        guard let d = delta(await ledger.plan(for: update(id, 1, stable: "안녕"), target: h.field,
                                              snapshot: snap("", caret: 0))) else {
            check(false, "원장 apply"); return
        }
        let p = d.makeProposal(expiresAt: at(10))
        await expect((await h.coordinator.submit(p)).status == .succeeded, "원장 델타 제안 자동 실행")
        let replay = d.makeProposal(expiresAt: at(10))
        await expect((await h.coordinator.submit(replay)).reason == "Duplicate proposal ignored",
              "같은 델타를 다시 제출해도 코디네이터가 차단")
        await expect(await h.executor.executed.count == 1, "받아쓰기 중복 입력 없음")
    }
}

// MARK: - 통합: 제안 경로(origin)와 원장 확인

private func originPolicyChecks() async {
    let config = PolicyConfiguration()
    let field = uiTarget()
    let gazed = PolicyContext(safetyMode: .active, gazeFocus: GazeFocus(target: field, at: t0))
    var verified = gazed
    verified.verifiedDictationEdit = true

    func originProposal(_ action: AgentAction, _ origin: ActionProposal.Origin, risk: RiskLevel = .low) -> ActionProposal {
        ActionProposal(id: UUID(), action: action, basedOnUtterance: UUID(), basedOnRevision: 1, rationale: "Dictation",
                       risk: risk, expiresAt: at(30), origin: origin)
    }
    func decide(_ p: ActionProposal, _ context: PolicyContext) -> PolicyDecision {
        PolicyRules.evaluate(p, now: at(1), context: context, configuration: config)
    }

    let intent = originProposal(.typeText(target: field, text: "안녕하세요"), .dictationIntent)
    check(decide(intent, verified) == .reject(reason: "Dictation intents are applied through the dictation ledger"),
          "받아쓰기 의도는 직접 실행하지 않음(원장 경유)")
    let forged = originProposal(.setValue(target: field, value: "x"), .dictationLedger)
    check(decide(forged, gazed) == .reject(reason: "Dictation edit was not issued by the dictation ledger"),
          "원장이 발급하지 않은 원장 편집 → reject")
    check(decide(forged, verified) == .execute, "원장이 확인한 교정 setValue(low) → execute")
    check(isApproval(decide(originProposal(.setValue(target: field, value: "x"), .dictationLedger, risk: .medium), verified)),
          "원장 교정이라도 low가 아니면 승인 요구")
    check(isApproval(decide(originProposal(.setValue(target: field, value: "결제 완료"), .dictationLedger), verified)),
          "원장 교정이라도 민감 키워드는 승인 요구")
    check(isReject(decide(originProposal(.setValue(target: uiTarget("pw", secure: true), value: "x"), .dictationLedger),
                          verified)), "원장 교정이라도 보안 필드는 reject")
    check(isApproval(decide(originProposal(.setValue(target: field, value: "x"), .intent), verified)),
          "일반 setValue는 여전히 승인 요구")
    var away = verified
    away.gazeFocus = nil
    check(decide(originProposal(.setValue(target: field, value: "x"), .dictationLedger), away) == .execute,
          "에이전트가 넣은 범위 교정은 시선이 떠나도 실행")
    check(isApproval(decide(originProposal(.typeText(target: field, text: "x"), .dictationLedger), away)),
          "원장 덧붙임(typeText)은 시선이 머문 필드여야 자동 실행")

    // PolicyEngine + 원장: 대기 중인 편집만 확인된다.
    let ledger = DictationLedger()
    let engine = PolicyEngine(safety: AgentSafetySwitch(), dictationVerifier: ledger)
    let id = UUID()
    guard let first = delta(await ledger.plan(for: update(id, 1, stable: "세시"), target: field, snapshot: snap("", caret: 0)))
    else { check(false, "원장 apply"); return }
    await engine.updateGazeFocus(field, at: at(0.5))
    let append = first.makeProposal(expiresAt: at(30))
    check(append.origin == .dictationLedger, "원장 제안의 origin")
    await expect(await engine.decide(append, now: at(1)) == .execute, "대기 중인 원장 덧붙임 → execute")
    let tampered = ActionProposal(id: append.id, action: .typeText(target: field, text: "다른 텍스트"),
                                  basedOnUtterance: id, basedOnRevision: 1, rationale: "Dictation", risk: .low,
                                  expiresAt: at(30), origin: .dictationLedger)
    await expect(isReject(await engine.decide(tampered, now: at(1))), "ID가 같아도 내용이 다르면 reject")
    await ledger.commit(first.idempotencyKey, observed: snap("세시", caret: 2))
    await expect(isReject(await engine.decide(append, now: at(1))), "커밋된 편집을 다시 내면 reject")
    guard let fix = delta(await ledger.plan(for: update(id, 2, stable: "세 시", final: true), target: field,
                                            snapshot: snap("세시", caret: 2))) else { check(false, "교정 apply"); return }
    let correction = fix.makeProposal(expiresAt: at(30))
    check(correction.action == .setValue(target: field, value: "세 시"), "교정은 setValue(기대 필드 값)")
    await engine.updateGazeFocus(nil, at: at(1))
    await expect(await engine.decide(correction, now: at(1)) == .execute, "대기 중인 원장 교정 → 시선 없이도 execute")
    await expect(isReject(await PolicyEngine().decide(correction, now: at(1))), "원장 확인기가 없으면 원장 편집 reject")
}

private actor SlowExecutor: ActionExecuting {
    private(set) var calls = 0
    private let delay: Duration
    private let clock: FakeClock
    init(delay: Duration, clock: FakeClock) { self.delay = delay; self.clock = clock }
    func execute(_ proposal: ActionProposal) async -> ActionOutcome {
        calls += 1
        try? await Task.sleep(for: delay)
        return ActionOutcome(proposalID: proposal.id, status: .succeeded, verification: .verified, target: nil,
                             time: clock.now(), reason: nil)
    }
}

private func coordinatorIntegrationChecks() async {
    // 정책 거부는 rejected
    do {
        let h = await Harness()
        let expired = proposal(.typeText(target: h.field, text: "late"), expiresAt: at(0.5))
        let result = await h.coordinator.submit(expired)
        check(result.status == .rejected && result.reason == "Rejected by policy: Proposal expired", "정책 거부 → rejected 상태")
        let streamed = await take(1, from: h.coordinator.outcomes)
        check(streamed.map(\.status) == [.rejected], "스트림에도 rejected")
    }

    // 실행기 시간 초과
    do {
        let clock = FakeClock(at(1))
        let field = uiTarget()
        let safety = AgentSafetySwitch()
        let engine = PolicyEngine(safety: safety)
        await engine.updateGazeFocus(field, at: at(0.5))
        let slow = SlowExecutor(delay: .seconds(5), clock: clock)
        let coordinator = ActionCoordinator(policy: engine, executor: slow, clock: clock, safety: safety,
                                            executionTimeout: .milliseconds(80))
        let started = ContinuousClock.now
        let result = await within(3) { await coordinator.submit(proposal(.typeText(target: field, text: "hi"))) }
        let elapsed = ContinuousClock.now - started
        check(result?.status == .failed && (result?.reason ?? "").hasPrefix("Execution timed out"),
              "실행기가 응답하지 않으면 시간 초과 failed")
        check(elapsed < .seconds(2), "시간 초과는 실행기를 기다리지 않음")
        let next = await within(3) { await coordinator.submit(proposal(.typeText(target: field, text: "again"))) }
        check(next?.status == .failed, "다음 제안도 막히지 않고 처리됨")
    }

    // 실행 중 비상 정지 → 기다림을 끊음
    do {
        let clock = FakeClock(at(1))
        let field = uiTarget()
        let safety = AgentSafetySwitch()
        let engine = PolicyEngine(safety: safety)
        await engine.updateGazeFocus(field, at: at(0.5))
        let slow = SlowExecutor(delay: .seconds(5), clock: clock)
        let coordinator = ActionCoordinator(policy: engine, executor: slow, clock: clock, safety: safety,
                                            executionTimeout: .seconds(30))
        let p = proposal(.typeText(target: field, text: "hi"))
        let queued = proposal(.typeText(target: field, text: "next"))
        let run = Task { await coordinator.submit([p, queued]) }
        var waited = 0
        while await slow.calls == 0, waited < 200 {
            try? await Task.sleep(for: .milliseconds(5))
            waited += 1
        }
        let started = ContinuousClock.now
        await coordinator.engageKillSwitch()
        let results = await within(3) { await run.value } ?? []
        check(ContinuousClock.now - started < .seconds(2), "비상 정지는 실행 기다림을 즉시 끊음")
        check(results.map(\.status) == [.failed, .cancelled], "실행 중 행동은 failed(효과 불명), 남은 행동은 취소")
        check((results.first?.reason ?? "").contains("Kill switch engaged"), "사유에 비상 정지")
        await expect(await slow.calls == 1, "남은 행동은 실행기 미호출")
    }
}
