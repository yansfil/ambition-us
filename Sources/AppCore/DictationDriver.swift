import AgentContracts
import AXControl
import Control
import Foundation

/// 받아쓰기 원장에 필요한 입력란 읽기·캐럿 이동. 실제 구현은 AX(`AXDictationFieldAccess`), 검사에서는 가짜.
public protocol DictationFieldAccessing: Sendable {
    /// 편집 직전·직후 필드 상태. 읽을 수 없으면(보안 필드, 요소 사라짐) nil.
    func snapshot(of target: UITarget) async -> DictationFieldSnapshot?
    /// 캐럿(길이 0 선택)이나 선택 범위를 옮긴다.
    @discardableResult
    func placeSelection(in target: UITarget, at range: DictationTextRange) async -> Bool
}

/// AXControl의 `AXTextFieldAccess`를 원장 타입으로 옮긴다.
public struct AXDictationFieldAccess: DictationFieldAccessing {
    public let access: AXTextFieldAccess
    public init(access: AXTextFieldAccess) { self.access = access }

    public func snapshot(of target: UITarget) async -> DictationFieldSnapshot? {
        guard let state = await access.state(of: target) else { return nil }
        return DictationFieldSnapshot(value: state.value,
                                      selection: DictationTextRange(location: state.selectionLocation,
                                                                    length: state.selectionLength))
    }

    @discardableResult
    public func placeSelection(in target: UITarget, at range: DictationTextRange) async -> Bool {
        await access.setSelection(of: target, location: range.location, length: range.length)
    }
}

/// 받아쓰기 의도(Intelligence의 `origin == .dictationIntent` 제안)를 원장 편집으로 바꿔 실행한다.
///
/// 원장이 받아쓰기 텍스트의 유일한 기준이다. 의도에 담긴 누적 텍스트를 발화의 안정 텍스트로 보고,
/// 필드 상태를 읽어 원장이 계산한 최소 편집(덧붙임 또는 에이전트가 넣은 범위 안쪽 교정)만 제출한다.
///
/// - 발화마다 편집은 하나씩 직렬로 진행한다. 진행 중에 새 revision이 오면 끝난 뒤 최신 것만 다시 계획한다.
/// - 실행이 성공하면 필드를 다시 읽어 원장에 커밋하고(기대와 다르면 원장이 그 발화를 멈춘다),
///   실패·거절·취소면 포기한다.
/// - 교정(setValue)은 실행 뒤 캐럿을 원장이 기대한 위치로 옮겨 다음 덧붙임이 이어지게 한다.
public actor DictationDriver {
    public struct Job: Sendable, Equatable {
        public let target: UITarget
        public let update: TranscriptUpdate
    }

    public enum Event: Sendable, Equatable {
        case submitted(UUID)
        case committed(key: String)
        case abandoned(key: String, reason: String?)
        case noChange(String)
        case stopped(String)
    }

    public nonisolated let ledger: DictationLedger
    private let field: any DictationFieldAccessing
    private let clock: any MonotonicClock
    private let proposalTTL: Double
    private let submit: @Sendable (ActionProposal) async -> ActionOutcome
    private let retainedUtterances: Int

    private var latest: [UUID: Job] = [:]
    private var running: Set<UUID> = []
    private var order: [UUID] = []
    /// 최근 처리 기록(진단용, 최대 200개).
    public private(set) var events: [Event] = []

    /// - Parameters:
    ///   - submit: 원장 편집 제안을 실행 흐름(ActionCoordinator)에 넘기고 최종 결과를 돌려준다.
    ///   - retainedUtterances: 원장 기록을 유지할 발화 수. 판단 모듈의 기록(16개)보다 커야
    ///     늦게 온 revision이 같은 텍스트를 다시 넣지 않는다.
    public init(ledger: DictationLedger, field: any DictationFieldAccessing, clock: any MonotonicClock,
                proposalTTL: Double = 4, retainedUtterances: Int = 64,
                submit: @escaping @Sendable (ActionProposal) async -> ActionOutcome) {
        self.ledger = ledger
        self.field = field
        self.clock = clock
        self.proposalTTL = proposalTTL
        self.retainedUtterances = retainedUtterances
        self.submit = submit
    }

    /// 받아쓰기 의도 제안을 받는다. typeText가 아니거나 의도가 아니면 무시한다.
    public func handle(intent proposal: ActionProposal, utterance: TranscriptUpdate) async {
        guard proposal.origin == .dictationIntent, case .typeText(let target, let text) = proposal.action else { return }
        let projected = TranscriptUpdate(utteranceID: utterance.utteranceID, revision: utterance.revision,
                                         text: text, stablePrefix: text, words: [], isFinal: utterance.isFinal)
        await enqueue(Job(target: target, update: projected))
    }

    public func enqueue(_ job: Job) async {
        let id = job.update.utteranceID
        if let existing = latest[id], existing.update.revision > job.update.revision { return }
        if latest[id] == nil { remember(id) }
        latest[id] = job
        guard running.insert(id).inserted else { return }
        defer { running.remove(id) }
        var planned: Job?
        while let next = latest[id], next != planned {
            planned = next
            await run(next)
        }
    }

    /// 비상 정지 등으로 진행 중인 모든 받아쓰기를 멈춘다.
    public func stopAll(reason: String) async {
        for id in order { await ledger.stop(utteranceID: id, reason: reason) }
    }

    // MARK: 내부

    private func run(_ job: Job) async {
        guard let before = await field.snapshot(of: job.target) else {
            await ledger.stop(utteranceID: job.update.utteranceID, reason: "Field state is unreadable")
            record(.stopped("Field state is unreadable"))
            return
        }
        switch await ledger.plan(for: job.update, target: job.target, snapshot: before) {
        case .noChange(let reason):
            record(.noChange(reason))
        case .stop(let reason):
            record(.stopped(reason))
        case .apply(let delta):
            let expiresAt = clock.now().adding(seconds: proposalTTL)
            // 근거 문장은 승인 말풍선에 그대로 보인다.
            let rationale: String
            switch delta.edit {
            case .insert(let text, _): rationale = "받아쓰기 입력: \(Self.preview(text))"
            case .replace(_, let text): rationale = "받아쓰기 교정: \(Self.preview(text))"
            }
            let proposal = delta.makeProposal(expiresAt: expiresAt, rationale: rationale)
            record(.submitted(proposal.id))
            let outcome = await submit(proposal)
            guard outcome.status == .succeeded else {
                await ledger.abandon(delta.idempotencyKey)
                record(.abandoned(key: delta.idempotencyKey, reason: outcome.reason))
                return
            }
            if case .replace = delta.edit {
                await field.placeSelection(in: delta.target, at: delta.expectedSelection)
            }
            let observed = await field.snapshot(of: delta.target)
            await ledger.commit(delta.idempotencyKey, observed: observed)
            record(.committed(key: delta.idempotencyKey))
        }
    }

    private func record(_ event: Event) {
        events.append(event)
        if events.count > 200 { events.removeFirst(events.count - 200) }
    }

    private static func preview(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 40 ? String(trimmed.prefix(40)) + "…" : "\"\(trimmed)\""
    }

    private func remember(_ id: UUID) {
        order.append(id)
        while order.count > max(1, retainedUtterances) {
            let evicted = order.removeFirst()
            latest[evicted] = nil
            Task { [ledger] in await ledger.forget(utteranceID: evicted) }
        }
    }
}

extension MonotonicTime {
    func adding(seconds: Double) -> MonotonicTime {
        let delta = UInt64(max(0, seconds) * 1_000_000_000)
        let (sum, overflow) = nanoseconds.addingReportingOverflow(delta)
        return MonotonicTime(nanoseconds: overflow ? .max : sum)
    }

    func seconds(since other: MonotonicTime) -> Double {
        nanoseconds >= other.nanoseconds
            ? Double(nanoseconds - other.nanoseconds) / 1e9
            : -Double(other.nanoseconds - nanoseconds) / 1e9
    }
}
