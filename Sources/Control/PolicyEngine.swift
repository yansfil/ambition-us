import AgentContracts
import Foundation

/// 정책 임계값. 시간은 모두 `MonotonicClock` 기준이다.
public struct PolicyConfiguration: Sendable, Equatable {
    /// 이보다 오래전에 관측한 대상은 거부한다.
    public var staleTargetAge: Duration
    /// move를 승인 없이 실행하려면 두 대상 모두 이 안에 관측돼야 한다.
    public var freshTargetAge: Duration
    /// 사용자가 이 시간 안에 바라본 대상만 "시선이 머문 필드"로 본다.
    public var gazeFocusMaxAge: Duration
    /// 대소문자 구분 없이 부분 문자열로 찾는다. 발견되면 승인을 요구한다.
    public var sensitiveKeywords: [String]

    public static let defaultSensitiveKeywords = [
        "send", "delete", "purchase", "submit",
        "보내기", "전송", "삭제", "결제", "구매", "제출",
    ]

    public init(staleTargetAge: Duration = .seconds(10),
                freshTargetAge: Duration = .seconds(3),
                gazeFocusMaxAge: Duration = .seconds(3),
                sensitiveKeywords: [String] = PolicyConfiguration.defaultSensitiveKeywords) {
        self.staleTargetAge = staleTargetAge
        self.freshTargetAge = freshTargetAge
        self.gazeFocusMaxAge = gazeFocusMaxAge
        self.sensitiveKeywords = sensitiveKeywords
    }
}

/// 사용자가 마지막으로 바라본 대상과 그 시각.
public struct GazeFocus: Sendable, Equatable {
    public let target: UITarget
    public let at: MonotonicTime
    public init(target: UITarget, at: MonotonicTime) {
        self.target = target; self.at = at
    }
}

/// 규칙 평가에 필요한 바깥 상태. 규칙 자체는 이 값과 제안만 보고 결정한다.
public struct PolicyContext: Sendable, Equatable {
    public var safetyMode: AgentSafetySwitch.Mode
    public var gazeFocus: GazeFocus?
    /// 이 제안이 받아쓰기 원장이 발급해 아직 대기 중인 편집과 정확히 일치하는지.
    /// `origin == .dictationLedger`인 제안만 의미가 있다.
    public var verifiedDictationEdit: Bool
    public init(safetyMode: AgentSafetySwitch.Mode = .active, gazeFocus: GazeFocus? = nil,
                verifiedDictationEdit: Bool = false) {
        self.safetyMode = safetyMode; self.gazeFocus = gazeFocus; self.verifiedDictationEdit = verifiedDictationEdit
    }
}

/// 받아쓰기 원장이 발급한 편집인지 확인한다. `DictationLedger`가 구현한다.
public protocol DictationEditVerifying: Sendable {
    /// 제안 ID·대상·행동이 원장이 계획하고 아직 커밋·포기하지 않은 편집과 같으면 true.
    func isPendingLedgerEdit(_ proposal: ActionProposal) async -> Bool
}

/// 결정적 정책 규칙. 같은 입력이면 항상 같은 결정을 낸다.
///
/// 평가 순서(먼저 걸리는 규칙이 이긴다):
/// 1. 비상 정지·일시정지 → reject
/// 2. 만료된 제안 → reject
/// 3. 받아쓰기 의도(origin dictationIntent)는 실행 대상이 아님 → reject.
///    원장 편집(origin dictationLedger)인데 원장이 발급한 대기 편집과 다르면 → reject
/// 4. 보안(비밀번호) 필드 → reject
/// 5. 오래된 대상(staleTargetAge 초과) → reject
/// 6. 위험도 high → requireApproval
/// 7. 민감 키워드(보내기·삭제·결제 등) → requireApproval
/// 8. 줄바꿈·탭 등 제어 문자 입력(채팅창에서 전송될 수 있음) → requireApproval
/// 9. 행동별 규칙: move는 low이고 두 대상이 신선할 때만, typeText는 low이고
///    편집 가능하며 시선이 머문 필드일 때만 execute. setValue는 원장이 확인한 교정
///    (에이전트가 넣은 범위 안쪽만 고침)이고 low·편집 가능일 때만 execute. 나머지는 모두 requireApproval.
public enum PolicyRules {
    public static func evaluate(_ proposal: ActionProposal, now: MonotonicTime,
                                context: PolicyContext, configuration: PolicyConfiguration) -> PolicyDecision {
        if let reason = AgentSafetySwitch.blockingReason(for: context.safetyMode) {
            return .reject(reason: reason)
        }
        if now >= proposal.expiresAt {
            return .reject(reason: "Proposal expired")
        }
        switch proposal.origin {
        case .intent:
            break
        case .dictationIntent:
            return .reject(reason: "Dictation intents are applied through the dictation ledger")
        case .dictationLedger:
            guard context.verifiedDictationEdit else {
                return .reject(reason: "Dictation edit was not issued by the dictation ledger")
            }
        }

        let targets = proposal.action.involvedTargets
        if targets.contains(where: \.isSecure) {
            return .reject(reason: "Target is a secure text field")
        }
        let staleLimit = configuration.staleTargetAge.clampedNanoseconds
        if let stale = targets.first(where: { now.elapsed(since: $0.observedAt) > staleLimit }) {
            let ageMs = now.elapsed(since: stale.observedAt) / 1_000_000
            return .reject(reason: "Target is stale (observed \(ageMs) ms ago)")
        }

        if proposal.risk == .high {
            return .requireApproval(reason: "High-risk action")
        }
        if let keyword = sensitiveKeyword(in: proposal, keywords: configuration.sensitiveKeywords) {
            return .requireApproval(reason: "Contains sensitive keyword \"\(keyword)\"")
        }
        if let text = proposal.action.enteredText, containsControlCharacters(text) {
            return .requireApproval(reason: "Text contains a line break or control character")
        }

        let freshLimit = configuration.freshTargetAge.clampedNanoseconds
        switch proposal.action {
        case .move(let source, let destination):
            guard proposal.risk == .low else {
                return .requireApproval(reason: "Move requires confirmation")
            }
            let fresh = [source, destination].allSatisfy { now.elapsed(since: $0.observedAt) <= freshLimit }
            return fresh ? .execute : .requireApproval(reason: "Move targets are not fresh")

        case .typeText(let target, let text):
            if text.isEmpty {
                return .reject(reason: "Nothing to type")
            }
            guard proposal.risk == .low else {
                return .requireApproval(reason: "Typing at \(proposal.risk.rawValue) risk requires confirmation")
            }
            guard target.isEditable else {
                return .requireApproval(reason: "Target is not an editable text field")
            }
            guard isGazed(target, now: now, context: context, configuration: configuration) else {
                return .requireApproval(reason: "Target is not the field the user is looking at")
            }
            return .execute

        case .press:
            // 민감 키워드(보내기·삭제·결제 등)는 위에서 이미 승인으로 걸렀다. 일반 클릭은 입력·이동처럼 바로 실행한다.
            guard proposal.risk == .low else {
                return .requireApproval(reason: "Pressing at \(proposal.risk.rawValue) risk requires confirmation")
            }
            return .execute

        case .setValue(let target, _):
            // 원장 교정은 에이전트가 이 발화로 넣은 범위 안쪽만 바꾼다(원장이 범위를 보장하고, 위에서 발급 여부를 확인했다).
            if proposal.origin == .dictationLedger, proposal.risk == .low, target.isEditable {
                return .execute
            }
            return .requireApproval(reason: "Replacing a field value requires confirmation")
        }
    }

    /// 제안에서 처음 발견된 민감 키워드. 행동 텍스트, 누를·옮길 대상의 제목, 근거 문장을 본다.
    static func sensitiveKeyword(in proposal: ActionProposal, keywords: [String]) -> String? {
        var haystacks = [proposal.rationale]
        switch proposal.action {
        case .typeText(_, let text): haystacks.append(text)
        case .setValue(_, let value): haystacks.append(value)
        case .press(let target): haystacks.append(target.title ?? "")
        case .move(let source, let destination):
            haystacks.append(source.title ?? "")
            haystacks.append(destination.title ?? "")
        }
        let normalized = haystacks.map { $0.precomposedStringWithCanonicalMapping }
        for keyword in keywords {
            let needle = keyword.precomposedStringWithCanonicalMapping
            guard !needle.isEmpty else { continue }
            if normalized.contains(where: { $0.range(of: needle, options: [.caseInsensitive]) != nil }) {
                return keyword
            }
        }
        return nil
    }

    /// 줄바꿈(Return은 많은 앱에서 전송), 탭(포커스 이동) 등 제어 문자.
    static func containsControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
    }

    static func isGazed(_ target: UITarget, now: MonotonicTime, context: PolicyContext,
                        configuration: PolicyConfiguration) -> Bool {
        guard let focus = context.gazeFocus else { return false }
        guard now.elapsed(since: focus.at) <= configuration.gazeFocusMaxAge.clampedNanoseconds else { return false }
        return sameElement(focus.target, target)
    }

    /// 토큰이 같거나, 같은 프로세스·역할·위치(1pt 이내)면 같은 요소로 본다.
    static func sameElement(_ lhs: UITarget, _ rhs: UITarget) -> Bool {
        if lhs.token == rhs.token { return true }
        guard lhs.pid == rhs.pid, lhs.role == rhs.role else { return false }
        return abs(lhs.frame.minX - rhs.frame.minX) <= 1 && abs(lhs.frame.minY - rhs.frame.minY) <= 1
            && abs(lhs.frame.width - rhs.frame.width) <= 1 && abs(lhs.frame.height - rhs.frame.height) <= 1
    }
}

/// `ActionAuthorizing` 구현. 규칙은 `PolicyRules`에 있고, 이 actor는 시선 초점과
/// 공유 안전 스위치 상태만 모아 넘긴다.
public actor PolicyEngine: ActionAuthorizing {
    public nonisolated let configuration: PolicyConfiguration
    public nonisolated let safety: AgentSafetySwitch
    private let dictationVerifier: (any DictationEditVerifying)?
    private var gazeFocus: GazeFocus?

    /// - Parameter dictationVerifier: 받아쓰기 원장. 없으면 원장 편집 제안은 모두 거부된다.
    public init(configuration: PolicyConfiguration = PolicyConfiguration(),
                safety: AgentSafetySwitch = AgentSafetySwitch(),
                dictationVerifier: (any DictationEditVerifying)? = nil) {
        self.configuration = configuration
        self.safety = safety
        self.dictationVerifier = dictationVerifier
    }

    /// 결합 모듈이 시선이 머문 대상을 알려준다. nil이면 초점을 지운다.
    public func updateGazeFocus(_ target: UITarget?, at time: MonotonicTime) {
        gazeFocus = target.map { GazeFocus(target: $0, at: time) }
    }

    public func currentContext() -> PolicyContext {
        PolicyContext(safetyMode: safety.mode, gazeFocus: gazeFocus)
    }

    public func decide(_ proposal: ActionProposal, now: MonotonicTime) async -> PolicyDecision {
        var verified = false
        if proposal.origin == .dictationLedger, let dictationVerifier {
            verified = await dictationVerifier.isPendingLedgerEdit(proposal)
        }
        var context = currentContext()
        context.verifiedDictationEdit = verified
        return PolicyRules.evaluate(proposal, now: now, context: context, configuration: configuration)
    }
}
