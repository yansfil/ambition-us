import AgentContracts
import Foundation
import Synchronization

/// 사용자 승인을 기다리는 제안. 오버레이의 `OverlayState.pendingApproval`에 그대로 쓸 수 있다.
public struct ApprovalRequest: Sendable, Equatable {
    public let proposal: ActionProposal
    public let reason: String
    public let requestedAt: MonotonicTime
    /// 이 시각까지 응답이 없으면 거절로 처리한다(승인 제한 시간과 제안 만료 중 이른 쪽).
    public let deadline: MonotonicTime
    public init(proposal: ActionProposal, reason: String, requestedAt: MonotonicTime, deadline: MonotonicTime) {
        self.proposal = proposal; self.reason = reason; self.requestedAt = requestedAt; self.deadline = deadline
    }
}

/// 제안 → 정책 → (필요하면) 승인 대기 → 실행 → 결과 스트림.
///
/// - 배치는 순서대로 하나씩 처리하고, 배치끼리도 제출 순서대로 직렬화한다.
///   그래서 승인 대기는 언제나 최대 하나다.
/// - 배치 안에서 하나라도 성공하지 못하면(실패·거부·시간 초과) 나머지는 실행하지 않고
///   `cancelled`로 보고한다. 실패 뒤에는 "Not executed: an earlier action failed".
/// - 이미 처리한 제안 ID가 다시 오면 실행하지 않는다.
/// - 정책이 거부한 제안은 `rejected`로 보고한다.
/// - 실행기가 `executionTimeout` 안에 끝내지 않으면 기다림을 끊고 `failed`(효과 알 수 없음)로 보고한다.
/// - `pause()`·`engageKillSwitch()`는 승인 대기와 실행 기다림을 즉시 끊고, 진행 중인 배치의 남은 행동을 취소한다.
public actor ActionCoordinator {
    public static let earlierFailureReason = "Not executed: an earlier action failed"
    public static let earlierRejectionReason = "Not executed: an earlier action was rejected"
    public static let earlierTimeoutReason = "Not executed: an earlier action was not approved in time"

    /// 상태가 바뀔 때마다 하나씩: proposed(승인 대기) → approved → started → succeeded/failed,
    /// 또는 rejected(정책 거부)·cancelled.
    public nonisolated let outcomes: AsyncStream<ActionOutcome>
    /// 승인 요청이 생기면 그 요청, 해소되면 nil.
    public nonisolated let approvalRequests: AsyncStream<ApprovalRequest?>
    public nonisolated let safety: AgentSafetySwitch

    private let outcomeSink: AsyncStream<ActionOutcome>.Continuation
    private let approvalSink: AsyncStream<ApprovalRequest?>.Continuation
    private let policy: any ActionAuthorizing
    private let executor: any ActionExecuting
    private let clock: any MonotonicClock
    private let approvalTimeout: Duration
    private let executionTimeout: Duration

    private enum Resolution: Sendable {
        case approved
        case rejected(String)
        case timedOut
        case halted(String)
    }

    private struct PendingApproval {
        let request: ApprovalRequest
        let continuation: CheckedContinuation<Resolution, Never>
        let timer: Task<Void, Never>
    }

    /// 한 행동의 최종 결과와, 실패했다면 남은 행동에 붙일 사유.
    private struct Step {
        let outcome: ActionOutcome
        let skipRemaining: String?
    }

    /// 실행기 결과를 기다리는 중인 행동. 시간 초과·정지 때 기다림을 끊는다.
    private struct RunningExecution {
        let proposal: ActionProposal
        let gate: ExecutionGate
        let work: Task<Void, Never>
        let timer: Task<Void, Never>
    }

    private var tail: Task<Void, Never>?
    private var pending: PendingApproval?
    private var running: RunningExecution?
    private var haltEpoch = 0
    private var seenProposalIDs: Set<UUID> = []

    /// - Parameters:
    ///   - safety: `PolicyEngine`과 같은 인스턴스를 넘겨야 한 번의 정지로 둘 다 멈춘다.
    ///   - clock: 시선·AX와 같은 단조 시계. 결과 시각과 정책 판단 시각에 쓴다.
    ///   - executionTimeout: 실행기 응답을 기다리는 최대 시간. 넘기면 failed(효과 알 수 없음).
    public init(policy: any ActionAuthorizing, executor: any ActionExecuting, clock: any MonotonicClock,
                safety: AgentSafetySwitch, approvalTimeout: Duration = .seconds(20),
                executionTimeout: Duration = .seconds(8)) {
        self.policy = policy
        self.executor = executor
        self.clock = clock
        self.safety = safety
        self.approvalTimeout = approvalTimeout
        self.executionTimeout = executionTimeout
        (outcomes, outcomeSink) = AsyncStream.makeStream(of: ActionOutcome.self)
        (approvalRequests, approvalSink) = AsyncStream.makeStream(of: ApprovalRequest?.self)
    }

    deinit {
        outcomeSink.finish()
        approvalSink.finish()
    }

    // MARK: 제출

    @discardableResult
    public func submit(_ proposal: ActionProposal) async -> ActionOutcome {
        await submit([proposal])[0]
    }

    /// 배치를 실행하고 제안마다 최종 결과 하나씩을 돌려준다. 앞선 배치가 끝날 때까지 기다린다.
    @discardableResult
    public func submit(_ batch: [ActionProposal]) async -> [ActionOutcome] {
        guard !batch.isEmpty else { return [] }
        let previous = tail
        let task = Task { () -> [ActionOutcome] in
            await previous?.value
            return await self.runBatch(batch)
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    // MARK: 승인

    public var pendingApproval: ApprovalRequest? { pending?.request }

    /// 대기 중인 승인과 ID가 맞으면 승인하고 true.
    @discardableResult
    public func approve(_ proposalID: UUID) -> Bool {
        resolvePending(proposalID, with: .approved)
    }

    @discardableResult
    public func reject(_ proposalID: UUID, reason: String = "Rejected by user") -> Bool {
        resolvePending(proposalID, with: .rejected(reason))
    }

    // MARK: 정지

    public func pause() {
        safety.pause()
        halt(reason: AgentSafetySwitch.blockingReason(for: .paused)!)
    }

    public func resume() {
        safety.resume()
    }

    public func engageKillSwitch() {
        safety.engageKillSwitch()
        halt(reason: AgentSafetySwitch.blockingReason(for: .killed)!)
    }

    public func resetKillSwitch() {
        safety.resetKillSwitch()
    }

    // MARK: 내부

    private func halt(reason: String) {
        haltEpoch += 1
        resolvePending(nil, with: .halted(reason))
        if let running {
            // 실행기 호출 자체는 되돌릴 수 없다. 기다림만 끊고 효과는 알 수 없다고 보고한다.
            running.gate.resolve(failure(running.proposal,
                                         reason: "Execution abandoned: \(reason); the effect is unknown"))
            running.work.cancel()
        }
    }

    private func haltReason(since epoch: Int) -> String? {
        if let reason = safety.blockingReason { return reason }
        if haltEpoch != epoch { return "Halted: the agent was paused or stopped" }
        return nil
    }

    private func runBatch(_ batch: [ActionProposal]) async -> [ActionOutcome] {
        let epoch = haltEpoch
        var results: [ActionOutcome] = []
        var skipReason: String?
        for proposal in batch {
            if let skipReason {
                results.append(emit(proposal, .cancelled, reason: skipReason))
                continue
            }
            let step = await process(proposal, epoch: epoch)
            results.append(step.outcome)
            skipReason = step.skipRemaining
        }
        return results
    }

    private func process(_ proposal: ActionProposal, epoch: Int) async -> Step {
        if let reason = haltReason(since: epoch) {
            return notExecuted(proposal, reason: reason, skip: "Not executed: \(reason)")
        }
        guard seenProposalIDs.insert(proposal.id).inserted else {
            return notExecuted(proposal, reason: "Duplicate proposal ignored", skip: Self.earlierRejectionReason)
        }

        let decision = await policy.decide(proposal, now: clock.now())
        if let reason = haltReason(since: epoch) {
            return notExecuted(proposal, reason: reason, skip: "Not executed: \(reason)")
        }

        switch decision {
        case .execute:
            break
        case .reject(let reason):
            return Step(outcome: emit(proposal, .rejected, reason: "Rejected by policy: \(reason)"),
                        skipRemaining: Self.earlierRejectionReason)
        case .requireApproval(let reason):
            let now = clock.now()
            guard now < proposal.expiresAt else {
                return notExecuted(proposal, reason: "Proposal expired", skip: Self.earlierTimeoutReason)
            }
            // 사용자가 읽고 답할 시간을 준다. 제안 만료(판단 시점의 신선도)는 승인 전까지만 본다.
            let timeout = approvalTimeout
            let request = ApprovalRequest(proposal: proposal, reason: reason, requestedAt: now,
                                          deadline: now.adding(timeout.clampedNanoseconds))
            emit(proposal, .proposed, reason: reason)

            switch await waitForApproval(request, timeout: timeout) {
            case .approved:
                emit(proposal, .approved, reason: nil)
            case .rejected(let reason):
                return notExecuted(proposal, reason: reason, skip: Self.earlierRejectionReason)
            case .timedOut:
                return notExecuted(proposal, reason: "Approval timed out", skip: Self.earlierTimeoutReason)
            case .halted(let reason):
                return notExecuted(proposal, reason: reason, skip: "Not executed: \(reason)")
            }

            if let reason = haltReason(since: epoch) {
                return notExecuted(proposal, reason: reason, skip: "Not executed: \(reason)")
            }
            // 승인 뒤에는 만료를 다시 보지 않는다. 대상이 바뀌었는지는 실행기가 실행 직전에 다시 확인한다.
        }

        emit(proposal, .started, reason: nil)
        let result = await execute(proposal)
        outcomeSink.yield(result)
        return Step(outcome: result, skipRemaining: result.status == .succeeded ? nil : Self.earlierFailureReason)
    }

    /// 실행기 결과, 시간 초과, 정지 중 먼저 오는 것.
    private func execute(_ proposal: ActionProposal) async -> ActionOutcome {
        let gate = ExecutionGate()
        let executor = self.executor
        let timeout = executionTimeout
        let timeoutOutcome = failure(proposal, reason: "Execution timed out after \(Self.describe(timeout)); the effect is unknown")
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<ActionOutcome, Never>) in
            gate.install(continuation)
            let work = Task { gate.resolve(await executor.execute(proposal)) }
            let timer = Task {
                do { try await Task.sleep(for: timeout) } catch { return }
                gate.resolve(timeoutOutcome)
            }
            running = RunningExecution(proposal: proposal, gate: gate, work: work, timer: timer)
        }
        running?.timer.cancel()
        running = nil
        return result
    }

    private func failure(_ proposal: ActionProposal, reason: String) -> ActionOutcome {
        ActionOutcome(proposalID: proposal.id, status: .failed, verification: .none,
                      target: proposal.action.primaryTarget, time: clock.now(), reason: reason)
    }

    private static func describe(_ duration: Duration) -> String {
        let parts = duration.components
        let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        return seconds >= 1 ? String(format: "%.0fs", seconds) : String(format: "%.0fms", seconds * 1000)
    }

    private func waitForApproval(_ request: ApprovalRequest, timeout: Duration) async -> Resolution {
        // 배치가 직렬화돼 있어 여기 올 때 다른 대기는 없어야 한다. 혹시 남아 있으면 정리한다.
        resolvePending(nil, with: .halted("Superseded by a newer approval request"))
        let id = request.proposal.id
        return await withCheckedContinuation { continuation in
            let timer = Task { [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                await self?.resolvePending(id, with: .timedOut)
            }
            pending = PendingApproval(request: request, continuation: continuation, timer: timer)
            approvalSink.yield(request)
        }
    }

    @discardableResult
    private func resolvePending(_ proposalID: UUID?, with resolution: Resolution) -> Bool {
        guard let current = pending else { return false }
        if let proposalID, current.request.proposal.id != proposalID { return false }
        pending = nil
        current.timer.cancel()
        approvalSink.yield(nil)
        current.continuation.resume(returning: resolution)
        return true
    }

    private func notExecuted(_ proposal: ActionProposal, reason: String, skip: String) -> Step {
        Step(outcome: emit(proposal, .cancelled, reason: reason), skipRemaining: skip)
    }

    @discardableResult
    private func emit(_ proposal: ActionProposal, _ status: ActionOutcome.Status, reason: String?) -> ActionOutcome {
        let outcome = ActionOutcome(proposalID: proposal.id, status: status, verification: .none,
                                    target: proposal.action.primaryTarget, time: clock.now(), reason: reason)
        outcomeSink.yield(outcome)
        return outcome
    }
}

/// 실행기 결과·시간 초과·정지 중 처음 도착한 결과로 한 번만 재개한다.
final class ExecutionGate: Sendable {
    private struct State {
        var continuation: CheckedContinuation<ActionOutcome, Never>?
        var early: ActionOutcome?
        var resolved = false
    }

    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<ActionOutcome, Never>) {
        let early = state.withLock { state -> ActionOutcome? in
            if let early = state.early { return early }
            state.continuation = continuation
            return nil
        }
        if let early { continuation.resume(returning: early) }
    }

    func resolve(_ outcome: ActionOutcome) {
        let continuation = state.withLock { state -> CheckedContinuation<ActionOutcome, Never>? in
            guard !state.resolved else { return nil }
            state.resolved = true
            guard let continuation = state.continuation else {
                state.early = outcome
                return nil
            }
            state.continuation = nil
            return continuation
        }
        continuation?.resume(returning: outcome)
    }
}
