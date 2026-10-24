import AgentContracts
import Foundation

/// UTF-16 단위 범위. AX의 `AXSelectedTextRange`(CFRange)와 같은 단위다.
public struct DictationTextRange: Sendable, Codable, Equatable, Hashable {
    public var location: Int
    public var length: Int
    public init(location: Int, length: Int) {
        self.location = location; self.length = length
    }
    public var end: Int { location + length }
}

/// 편집 직전에 AX로 읽은 대상 필드 상태.
public struct DictationFieldSnapshot: Sendable, Codable, Equatable {
    public var value: String
    public var selection: DictationTextRange
    public init(value: String, selection: DictationTextRange) {
        self.value = value; self.selection = selection
    }
}

/// 원장이 계산한 최소 편집 하나. 실행 후 `commit` 또는 `abandon`으로 결과를 알려야 한다.
public struct DictationDelta: Sendable, Equatable {
    public enum Edit: Sendable, Equatable {
        /// 캐럿(= 에이전트가 넣은 범위의 끝) 위치에 덧붙인다.
        case insert(text: String, location: Int)
        /// 에이전트가 넣은 범위 안쪽만 고친다. range는 항상 그 범위의 부분집합이다.
        case replace(range: DictationTextRange, with: String)
    }

    /// 같은 편집이면 몇 번 계획해도 같은 키. 실행기·코디네이터가 중복 실행을 막는 데 쓴다.
    public let idempotencyKey: String
    /// idempotencyKey에서 결정적으로 만든 제안 ID. 코디네이터의 중복 제안 차단과 맞물린다.
    public let proposalID: UUID
    public let utteranceID: UUID
    public let revision: Int
    public let target: UITarget
    public let edit: Edit
    /// 편집이 끝난 뒤 에이전트가 이 발화로 넣은 전체 텍스트.
    public let insertedTextAfter: String
    /// 편집이 끝난 뒤 기대하는 필드 전체 값과 선택 범위.
    public let expectedFieldValue: String
    public let expectedSelection: DictationTextRange

    /// 계약 타입으로 옮긴 행동. 덧붙임은 typeText, 교정은 필드 전체 값을 바꾸는 setValue다.
    /// setValue 실행기는 캐럿을 `expectedSelection`에 둬야 다음 덧붙임이 이어진다(아니면 원장이 멈춘다).
    public var action: AgentAction {
        switch edit {
        case .insert(let text, _): return .typeText(target: target, text: text)
        case .replace: return .setValue(target: target, value: expectedFieldValue)
        }
    }

    /// 원장 편집 제안(`origin == .dictationLedger`). 정책 엔진은 원장이 아직 대기 중인 이 편집과 일치할 때만 허용한다.
    public func makeProposal(risk: RiskLevel = .low, expiresAt: MonotonicTime,
                             rationale: String = "Dictation") -> ActionProposal {
        ActionProposal(id: proposalID, action: action, basedOnUtterance: utteranceID, basedOnRevision: revision,
                       rationale: rationale, risk: risk, expiresAt: expiresAt, origin: .dictationLedger)
    }
}

public enum DictationPlan: Sendable, Equatable {
    case apply(DictationDelta)
    /// 할 일이 없다(이미 반영됨, 오래된 revision, 다른 편집이 진행 중 등).
    case noChange(reason: String)
    /// 이 발화의 받아쓰기를 멈췄다. 이후 같은 발화는 계속 stop을 돌려준다.
    case stop(reason: String)
}

public enum DictationSessionState: Sendable, Equatable {
    case active
    case finalized
    case stopped(reason: String)
}

/// 발화별로 에이전트가 어느 대상에 어떤 텍스트를 넣었는지 기록하고,
/// 새 `TranscriptUpdate` revision마다 안전한 최소 편집을 계산한다.
///
/// 규칙
/// - 확정 전에는 `stablePrefix`만, 최종(isFinal)에는 `text` 전체를 넣는다.
/// - 새로 안정된 부분만 덧붙인다.
/// - 이미 넣은 텍스트와 달라지면 에이전트가 넣은 범위 안쪽만 교정한다.
///   확정 전에 안정 구간이 줄어들면 지우지 않고 기다린다.
/// - 처음 편집한 뒤로는 필드 값이나 선택 범위가 기대와 다르면(사용자 입력·클릭) 멈춘다.
/// - 편집은 한 번에 하나만 진행한다. 같은 편집은 같은 idempotency key를 가지며 두 번 커밋되지 않는다.
///
/// 오프셋은 모두 UTF-16 단위, 텍스트는 NFC로 정규화해 비교한다.
public actor DictationLedger: DictationEditVerifying {
    private struct Pending {
        let key: String
        let proposalID: UUID
        let action: AgentAction
        let insertedTextAfter: String
        let expectedFieldValue: String
        let expectedSelection: DictationTextRange
        let isFinal: Bool
    }

    private struct Session {
        let target: UITarget
        var anchor: Int
        var inserted: String = ""
        var expectedFieldValue: String
        var expectedSelection: DictationTextRange
        var editSequence = 0
        /// 한 번이라도 편집을 내보냈는지. 그 뒤로는 기준점을 다시 잡지 않는다.
        var hasAttempted = false
        var lastRevision = Int.min
        var pending: Pending?
        var state: DictationSessionState = .active
    }

    private var sessions: [UUID: Session] = [:]
    private var pendingOwners: [String: UUID] = [:]
    private var committedKeys: Set<String> = []

    public init() {}

    // MARK: 계획

    public func plan(for update: TranscriptUpdate, target: UITarget,
                     snapshot: DictationFieldSnapshot) -> DictationPlan {
        let id = update.utteranceID
        var session = sessions[id] ?? Session(target: target, anchor: snapshot.selection.location,
                                              expectedFieldValue: snapshot.value,
                                              expectedSelection: snapshot.selection)
        let result = advance(&session, update: update, target: target, snapshot: snapshot)
        sessions[id] = session
        return result
    }

    private func advance(_ session: inout Session, update: TranscriptUpdate, target: UITarget,
                         snapshot: DictationFieldSnapshot) -> DictationPlan {
        switch session.state {
        case .stopped(let reason): return .stop(reason: reason)
        case .finalized: return .noChange(reason: "Utterance already finalized")
        case .active: break
        }
        if !PolicyRules.sameElement(session.target, target) || session.target.pid != target.pid {
            return stop(&session, "Dictation target changed")
        }
        if target.isSecure { return stop(&session, "Target is a secure text field") }
        if !target.isEditable { return stop(&session, "Target is not editable") }
        if update.revision < session.lastRevision {
            return .noChange(reason: "Stale revision \(update.revision) (latest \(session.lastRevision))")
        }
        if session.pending != nil {
            return .noChange(reason: "Another edit for this utterance is in flight")
        }

        if session.hasAttempted {
            if snapshot.value != session.expectedFieldValue {
                return stop(&session, "Field changed outside the agent (user edit)")
            }
            if snapshot.selection != session.expectedSelection {
                return stop(&session, "Selection changed outside the agent")
            }
        } else {
            // 아직 아무것도 넣지 않았다면 지킬 것이 없으므로 현재 캐럿을 기준점으로 다시 잡는다.
            if snapshot.selection.length != 0 {
                return stop(&session, "Selection is not empty")
            }
            let fieldLength = snapshot.value.utf16.count
            guard snapshot.selection.location >= 0, snapshot.selection.location <= fieldLength else {
                return stop(&session, "Caret is outside the field")
            }
            session.anchor = snapshot.selection.location
            session.expectedFieldValue = snapshot.value
            session.expectedSelection = snapshot.selection
        }
        session.lastRevision = update.revision

        let desired = (update.isFinal ? update.text : update.stablePrefix).precomposedStringWithCanonicalMapping
        let inserted = session.inserted
        if desired == inserted {
            if update.isFinal { session.state = .finalized }
            return .noChange(reason: "Already up to date")
        }

        let common = zip(inserted, desired).prefix(while: { $0 == $1 }).count
        let insertedUnits = inserted.utf16.count
        let edit: DictationDelta.Edit
        if common == inserted.count {
            edit = .insert(text: String(desired.dropFirst(common)), location: session.anchor + insertedUnits)
        } else {
            if !update.isFinal && common == desired.count {
                return .noChange(reason: "Stable text shrank; waiting for a later revision")
            }
            let keptUnits = String(inserted.prefix(common)).utf16.count
            let range = DictationTextRange(location: session.anchor + keptUnits, length: insertedUnits - keptUnits)
            edit = .replace(range: range, with: String(desired.dropFirst(common)))
        }

        let expectedValue: String
        switch edit {
        case .insert(let text, let location):
            expectedValue = Self.replacing(session.expectedFieldValue, range: .init(location: location, length: 0), with: text)
        case .replace(let range, let text):
            expectedValue = Self.replacing(session.expectedFieldValue, range: range, with: text)
        }
        let expectedSelection = DictationTextRange(location: session.anchor + desired.utf16.count, length: 0)

        let digest = String(stableHash(inserted + "\u{1F}" + desired), radix: 16)
        let key = "dictation/\(update.utteranceID.uuidString)/\(target.token)/\(session.editSequence)/\(digest)"
        let delta = DictationDelta(idempotencyKey: key, proposalID: stableUUID(from: key),
                                   utteranceID: update.utteranceID, revision: update.revision,
                                   target: session.target, edit: edit, insertedTextAfter: desired,
                                   expectedFieldValue: expectedValue, expectedSelection: expectedSelection)
        session.pending = Pending(key: key, proposalID: delta.proposalID, action: delta.action,
                                  insertedTextAfter: desired, expectedFieldValue: expectedValue,
                                  expectedSelection: expectedSelection, isFinal: update.isFinal)
        session.hasAttempted = true
        pendingOwners[key] = update.utteranceID

        return .apply(delta)
    }

    // MARK: 실행 결과

    /// 편집이 실제로 적용됐음을 기록한다. 이미 커밋했거나 모르는 키면 false(중복 무시).
    /// `observed`를 주면 기대 결과와 비교해, 다르면 이 발화를 멈춘다.
    @discardableResult
    public func commit(_ key: String, observed: DictationFieldSnapshot? = nil) -> Bool {
        guard let id = pendingOwners.removeValue(forKey: key),
              var session = sessions[id], let pending = session.pending, pending.key == key else {
            return false
        }
        session.pending = nil
        session.inserted = pending.insertedTextAfter
        session.expectedFieldValue = pending.expectedFieldValue
        session.expectedSelection = pending.expectedSelection
        session.editSequence += 1
        committedKeys.insert(key)
        if pending.isFinal { session.state = .finalized }
        if let observed,
           observed.value != pending.expectedFieldValue || observed.selection != pending.expectedSelection {
            session.state = .stopped(reason: "Field does not match the expected result after the edit")
        }
        sessions[id] = session
        return true
    }

    /// 편집이 실패했거나 실행하지 않았다. 원장 상태는 편집 전 그대로 두고,
    /// 다음 계획에서 필드가 편집 전 상태와 다르면(부분 입력 등) 멈춘다.
    @discardableResult
    public func abandon(_ key: String) -> Bool {
        guard let id = pendingOwners.removeValue(forKey: key),
              var session = sessions[id], session.pending?.key == key else {
            return false
        }
        session.pending = nil
        sessions[id] = session
        return true
    }

    /// 바깥(예: 비상 정지)에서 발화를 멈춘다.
    public func stop(utteranceID: UUID, reason: String) {
        guard var session = sessions[utteranceID] else { return }
        _ = stop(&session, reason)
        sessions[utteranceID] = session
    }

    /// 끝난 발화의 기록을 지운다. 커밋된 키 기록은 중복 차단을 위해 남긴다.
    public func forget(utteranceID: UUID) {
        if let key = sessions[utteranceID]?.pending?.key { pendingOwners[key] = nil }
        sessions[utteranceID] = nil
    }

    // MARK: 정책 확인

    /// 정책 엔진용: 원장이 계획하고 아직 커밋·포기하지 않은 편집과 ID·행동이 같은가.
    public func isPendingLedgerEdit(_ proposal: ActionProposal) -> Bool {
        guard proposal.origin == .dictationLedger, let session = sessions[proposal.basedOnUtterance],
              let pending = session.pending, case .active = session.state else { return false }
        return pending.proposalID == proposal.id && pending.action == proposal.action
    }

    // MARK: 조회

    public func insertedText(for utteranceID: UUID) -> String? { sessions[utteranceID]?.inserted }
    public func state(for utteranceID: UUID) -> DictationSessionState? { sessions[utteranceID]?.state }
    public func targetToken(for utteranceID: UUID) -> String? { sessions[utteranceID]?.target.token }
    public func isCommitted(_ key: String) -> Bool { committedKeys.contains(key) }

    // MARK: 내부

    private func stop(_ session: inout Session, _ reason: String) -> DictationPlan {
        if let key = session.pending?.key { pendingOwners[key] = nil }
        session.pending = nil
        session.state = .stopped(reason: reason)
        return .stop(reason: reason)
    }

    private static func replacing(_ value: String, range: DictationTextRange, with text: String) -> String {
        (value as NSString).replacingCharacters(in: NSRange(location: range.location, length: range.length), with: text)
    }
}
