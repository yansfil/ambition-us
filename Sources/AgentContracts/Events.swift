import CoreGraphics
import Foundation

/// 모든 입력·판단 이벤트가 공유하는 단조 증가 시각(나노초).
public struct MonotonicTime: Sendable, Hashable, Comparable, Codable {
    public let nanoseconds: UInt64
    public init(nanoseconds: UInt64) { self.nanoseconds = nanoseconds }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.nanoseconds < rhs.nanoseconds }
}

public protocol MonotonicClock: Sendable {
    func now() -> MonotonicTime
}

// MARK: - 시선

public struct GazeSample: Sendable, Codable, Equatable {
    public let time: MonotonicTime
    public let displayID: UInt32
    /// 전역 화면 좌표(AX와 같은 좌상단 원점, 포인트 단위).
    public let point: CGPoint
    /// 추정 오차 반경(포인트). 하이라이트 크기 계산에 사용한다.
    public let uncertaintyRadius: Double
    public let confidence: Double
    public let calibrationRevision: Int
    public let isFixation: Bool

    public init(time: MonotonicTime, displayID: UInt32, point: CGPoint, uncertaintyRadius: Double,
                confidence: Double, calibrationRevision: Int, isFixation: Bool) {
        self.time = time; self.displayID = displayID; self.point = point
        self.uncertaintyRadius = uncertaintyRadius; self.confidence = confidence
        self.calibrationRevision = calibrationRevision; self.isFixation = isFixation
    }
}

public struct NonverbalCue: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable { case prolongedDwell, revisit, headShake, headNod }
    public let time: MonotonicTime
    public let kind: Kind
    public let targetID: String?
    public let confidence: Double
    public init(time: MonotonicTime, kind: Kind, targetID: String?, confidence: Double) {
        self.time = time; self.kind = kind; self.targetID = targetID; self.confidence = confidence
    }
}

// MARK: - 음성

public struct WordTiming: Sendable, Codable, Equatable {
    public let word: String
    /// 녹음 버퍼 기준 실제 발화 시작·끝(화면 표시 시각이 아님).
    public let start: MonotonicTime
    public let end: MonotonicTime
    public let confidence: Double
    public init(word: String, start: MonotonicTime, end: MonotonicTime, confidence: Double) {
        self.word = word; self.start = start; self.end = end; self.confidence = confidence
    }
}

/// 같은 발화의 revision은 교체한다. append하지 않는다.
public struct TranscriptUpdate: Sendable, Codable, Equatable {
    public let utteranceID: UUID
    public let revision: Int
    public let text: String
    public let stablePrefix: String
    public let words: [WordTiming]
    public let isFinal: Bool
    public init(utteranceID: UUID, revision: Int, text: String, stablePrefix: String,
                words: [WordTiming], isFinal: Bool) {
        self.utteranceID = utteranceID; self.revision = revision; self.text = text
        self.stablePrefix = stablePrefix; self.words = words; self.isFinal = isFinal
    }
}

public struct AudioLevelSample: Sendable, Codable, Equatable {
    public enum MicState: String, Sendable, Codable { case active, muted, unavailable }
    public let time: MonotonicTime
    /// 0...1로 정규화한 RMS.
    public let rms: Double
    public let isVoice: Bool
    public let micState: MicState
    public init(time: MonotonicTime, rms: Double, isVoice: Bool, micState: MicState) {
        self.time = time; self.rms = rms; self.isVoice = isVoice; self.micState = micState
    }
}

public struct ParalinguisticCue: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable { case hesitation, longPause, filler, risingIntonation, speechRateDrop }
    public let time: MonotonicTime
    public let utteranceID: UUID?
    public let kind: Kind
    public let confidence: Double
    public init(time: MonotonicTime, utteranceID: UUID?, kind: Kind, confidence: Double) {
        self.time = time; self.utteranceID = utteranceID; self.kind = kind; self.confidence = confidence
    }
}

// MARK: - 화면 UI

/// AXUIElement 자체는 AXControl 모듈 밖으로 나가지 않는다. token으로만 참조한다.
public struct UITarget: Sendable, Codable, Equatable, Hashable {
    public let token: String
    public let pid: Int32
    public let appBundleID: String?
    public let role: String
    public let title: String?
    public let frame: CGRect
    public let isEditable: Bool
    public let isSecure: Bool
    public let supportedActions: [String]
    public let observedAt: MonotonicTime
    public init(token: String, pid: Int32, appBundleID: String?, role: String, title: String?, frame: CGRect,
                isEditable: Bool, isSecure: Bool, supportedActions: [String], observedAt: MonotonicTime) {
        self.token = token; self.pid = pid; self.appBundleID = appBundleID; self.role = role; self.title = title
        self.frame = frame; self.isEditable = isEditable; self.isSecure = isSecure
        self.supportedActions = supportedActions; self.observedAt = observedAt
    }
}

// MARK: - 결합·판단·실행

public struct DeicticBinding: Sendable, Codable, Equatable {
    public let word: WordTiming
    public let target: UITarget?
    public let confidence: Double
    public init(word: WordTiming, target: UITarget?, confidence: Double) {
        self.word = word; self.target = target; self.confidence = confidence
    }
}

public struct AttentionContext: Sendable, Codable, Equatable {
    public let utterance: TranscriptUpdate
    public let bindings: [DeicticBinding]
    public let gazedTarget: UITarget?
    public let paralinguistic: [ParalinguisticCue]
    public let nonverbal: [NonverbalCue]
    public init(utterance: TranscriptUpdate, bindings: [DeicticBinding], gazedTarget: UITarget?,
                paralinguistic: [ParalinguisticCue], nonverbal: [NonverbalCue]) {
        self.utterance = utterance; self.bindings = bindings; self.gazedTarget = gazedTarget
        self.paralinguistic = paralinguistic; self.nonverbal = nonverbal
    }
}

public enum RiskLevel: String, Sendable, Codable, Comparable {
    case low, medium, high
    public static func < (lhs: Self, rhs: Self) -> Bool {
        let order: [RiskLevel] = [.low, .medium, .high]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

public enum AgentAction: Sendable, Codable, Equatable {
    case typeText(target: UITarget, text: String)
    case press(target: UITarget)
    case move(source: UITarget, destination: UITarget)
    case setValue(target: UITarget, value: String)
}

public struct ActionProposal: Sendable, Codable, Equatable {
    public let id: UUID
    public let action: AgentAction
    public let basedOnUtterance: UUID
    public let basedOnRevision: Int
    public let rationale: String
    public let risk: RiskLevel
    public let expiresAt: MonotonicTime
    public init(id: UUID, action: AgentAction, basedOnUtterance: UUID, basedOnRevision: Int,
                rationale: String, risk: RiskLevel, expiresAt: MonotonicTime) {
        self.id = id; self.action = action; self.basedOnUtterance = basedOnUtterance
        self.basedOnRevision = basedOnRevision; self.rationale = rationale; self.risk = risk; self.expiresAt = expiresAt
    }
}

/// 선제 도움 제안. 실행 요청으로 승격되지 않는다.
public struct SuggestionCandidate: Sendable, Codable, Equatable {
    public let id: UUID
    public let target: UITarget?
    public let message: String
    public let confidence: Double
    public let expiresAt: MonotonicTime
    public let cooldownKey: String
    public init(id: UUID, target: UITarget?, message: String, confidence: Double,
                expiresAt: MonotonicTime, cooldownKey: String) {
        self.id = id; self.target = target; self.message = message; self.confidence = confidence
        self.expiresAt = expiresAt; self.cooldownKey = cooldownKey
    }
}

public enum PolicyDecision: Sendable, Codable, Equatable {
    case execute
    case requireApproval(reason: String)
    case reject(reason: String)
}

public struct ActionOutcome: Sendable, Codable, Equatable {
    public enum Status: String, Sendable, Codable { case proposed, approved, started, succeeded, failed, cancelled }
    public enum Verification: String, Sendable, Codable { case verified, unverifiedAccessibility, unverifiedSynthetic, none }
    public let proposalID: UUID
    public let status: Status
    public let verification: Verification
    public let target: UITarget?
    public let time: MonotonicTime
    public let reason: String?
    public init(proposalID: UUID, status: Status, verification: Verification, target: UITarget?,
                time: MonotonicTime, reason: String?) {
        self.proposalID = proposalID; self.status = status; self.verification = verification
        self.target = target; self.time = time; self.reason = reason
    }
}

// MARK: - 오버레이

public enum AgentRegion: Sendable, Equatable {
    /// 유휴: 화면 전체 테두리.
    case idleScreenEdge
    case target(frame: CGRect, label: String)
}

public struct OverlayState: Sendable, Equatable {
    public var gaze: GazeSample?
    public var audioLevel: AudioLevelSample?
    public var agentRegion: AgentRegion
    public var suggestion: SuggestionCandidate?
    public var pendingApproval: ActionProposal?
    public init(gaze: GazeSample? = nil, audioLevel: AudioLevelSample? = nil, agentRegion: AgentRegion = .idleScreenEdge,
                suggestion: SuggestionCandidate? = nil, pendingApproval: ActionProposal? = nil) {
        self.gaze = gaze; self.audioLevel = audioLevel; self.agentRegion = agentRegion
        self.suggestion = suggestion; self.pendingApproval = pendingApproval
    }
}
