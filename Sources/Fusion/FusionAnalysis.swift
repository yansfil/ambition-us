import AgentContracts
import CoreGraphics

/// 지시어 결합 결과의 이유. target이 nil이면 왜 nil인지 알려준다.
public enum BindingOutcome: Sendable, Equatable {
    case bound
    /// 창 안에 쓸 만한 시선 샘플이 없다(추적 끊김, 저신뢰 샘플만 있음, 수신 거부된 지난 샘플).
    case noGaze
    /// 샘플은 있지만 안정된 응시가 없다(계속 훑는 중).
    case noStableFixation
    /// 단어가 버퍼 창보다 오래되어 시선 기록이 이미 지워졌다.
    case stale
    /// 단어 시점의 시선이 이전 보정 revision이라 폐기됐다.
    case calibrationChanged
    /// 응시점에서 UI 요소를 찾지 못했다.
    case unresolvedTarget
    /// 신뢰도가 임계값보다 낮다(계산된 값).
    case lowConfidence(Double)
}

/// 지시어 하나에 대한 상세 결합 정보(디버그·오버레이용).
public struct ResolvedDeictic: Sendable, Equatable {
    public let match: DeicticMatch
    /// AttentionContext.bindings에 들어가는 값과 같다.
    public let binding: DeicticBinding
    public let outcome: BindingOutcome
    /// 선택된 응시 중심점(전역 좌표).
    public let point: CGPoint?
    public let uncertaintyRadius: Double?
    /// 창 안에서 사용한 샘플 수.
    public let sampleCount: Int

    public var role: DeicticRole { match.role }
}

public struct FusionAnalysis: Sendable, Equatable {
    public let context: AttentionContext
    /// bindings와 같은 순서(발화 순서).
    public let deictics: [ResolvedDeictic]
    /// gazedTarget을 응시한 시간.
    public let gazedTargetDwell: Duration?
    /// 계산에 사용한 보정 revision.
    public let calibrationRevision: Int?
}

/// 수신·계산 카운터.
public struct FusionStats: Sendable, Equatable {
    public var acceptedSamples = 0
    public var rejectedStaleSamples = 0
    public var rejectedFutureSamples = 0
    public var rejectedCalibrationSamples = 0
    public var rejectedInvalidSamples = 0
    public var droppedOverflowSamples = 0
    public var calibrationResets = 0
    public var rejectedCues = 0
    public var resolverCalls = 0
    public var targetCacheHits = 0
    public var analysesComputed = 0
    public var analysisCacheHits = 0
    public init() {}
}
