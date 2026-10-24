import AgentContracts
import Foundation

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
/// - `pause()`·`engageKillSwitch()`는 승인 대기를 즉시 끊고, 진행 중인 배치의 남은 행동을 취소한다.
public actor ActionCoordinator {
    public static let earlierFailureReason = "Not executed: an earlier action failed"
    public static let earlierRejectionReason = "Not executed: an earlier action was rejected"
    public static let earlierTimeoutReason = "Not executed: an earlier action was not approved in time"

    /// 상태가 바뀔 때마다 하나씩: proposed(승인 대기) → approved → started → succeeded/failed, 또는 cancelled.
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

    private var tail: Task<Void, Never>?
    private var pending: PendingApproval?
    private var haltEpoch = 0
    private var seenProposalIDs: Set<UUID> = []

    /// - Parameters:
    ///   - safety: `PolicyEngine`과 같은 인스턴스를 넘겨야 한 번의 정지로 둘 다 멈춘다.
    ///   - clock: 시선·AX와 같은 단조 시계. 결과 시각과 정책 판단 시각에 쓴다.
    public init(policy: any ActionAuthorizing, executor: any ActionExecuting, clock: any MonotonicClock,
                safety: AgentSafetySwitch, approvalTimeout: Duration = .seconds(20)) {
        self.policy = policy
        self.executor = executor
        self.clock = clock
        self.safety = safety
        self.approvalTimeout = approvalTimeout
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
            return notExecuted(proposal, reason: "Rejected by policy: \(reason)", skip: Self.earlierRejectionReason)
        case .requireApproval(let reason):
            let now = clock.now()
            guard now < proposal.expiresAt else {
                return notExecuted(proposal, reason: "Proposal expired", skip: Self.earlierTimeoutReason)
            }
            let remaining = Duration.clampedNanoseconds(proposal.expiresAt.elapsed(since: now))
            let timeout = min(approvalTimeout, remaining)
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
            guard clock.now() < proposal.expiresAt else {
                return notExecuted(proposal, reason: "Proposal expired while awaiting approval",
                                   skip: Self.earlierTimeoutReason)
            }
        }

        emit(proposal, .started, reason: nil)
        let result = await executor.execute(proposal)
        outcomeSink.yield(result)
        return Step(outcome: result, skipRemaining: result.status == .succeeded ? nil : Self.earlierFailureReason)
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
