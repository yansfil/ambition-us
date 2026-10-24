import AgentContracts

/// AttentionFuser 조정값. 기본값은 웹캠 기반 30~60Hz 시선 추적을 가정한다.
public struct FusionConfiguration: Sendable, Equatable {
    // MARK: 버퍼

    /// 시선·단서를 보관하는 시간 창. 이보다 오래된 단어는 `stale`로 결합하지 않는다.
    public var bufferWindow: Duration = .seconds(10)
    /// 시선 샘플 최대 개수(240Hz × 10초).
    public var gazeCapacity: Int = 2400
    /// 비언어·준언어 단서 최대 개수(각각).
    public var cueCapacity: Int = 256

    // MARK: 수신 검증

    /// 수신 시점에 이보다 오래된 시선 샘플은 버린다.
    public var maxSampleAge: Duration = .seconds(1)
    /// 시계보다 이만큼 넘게 미래인 샘플은 버린다.
    public var maxFutureSkew: Duration = .milliseconds(500)
    /// 이보다 낮은 신뢰도의 샘플은 결합에 쓰지 않는다.
    public var minSampleConfidence: Double = 0.4

    // MARK: 지시어 창

    /// 단어 시작 전 창. 사람은 말하기 전에 대상을 먼저 본다.
    public var lead: Duration = .milliseconds(300)
    /// 단어 끝 뒤 창.
    public var lag: Duration = .milliseconds(150)
    /// lead 창 맨 앞(start - lead)의 가중치. 단어 시작에서 1까지 선형 증가.
    public var leadWeightFloor: Double = 0.5
    /// lag 창 맨 끝(end + lag)의 가중치. 단어 끝에서 1부터 선형 감소.
    public var lagWeightFloor: Double = 0.3

    // MARK: 응시 분할

    /// 연속 샘플 사이 허용 간격. 넘으면 응시를 끊고, 샘플 지속시간도 이 값으로 자른다.
    public var maxSampleGap: Duration = .milliseconds(100)
    /// 같은 응시로 묶는 중심점 반경(포인트).
    public var fixationRadius: Double = 60
    /// 이보다 짧은 응시는 후보에서 뺀다.
    public var minFixationDuration: Duration = .milliseconds(100)
    /// 이 길이 이상이면 안정성 계수 1.
    public var stableFixationDuration: Duration = .milliseconds(200)

    // MARK: 신뢰도

    /// 가중 창의 이 비율 이상을 응시가 덮으면 커버리지 계수 1.
    public var fullCoverageFraction: Double = 0.3
    /// 최종 결합 신뢰도가 이보다 낮으면 target을 nil로 둔다.
    public var minBindingConfidence: Double = 0.35

    // MARK: 받아쓰기 대상

    /// 첫 단어 전에 입력 칸을 보는 시간까지 포함하는 창.
    public var dictationLead: Duration = .seconds(1)
    /// 편집 가능 요소를 이만큼 이상 응시해야 받아쓰기 대상으로 본다.
    public var minDictationDwell: Duration = .milliseconds(300)
    /// 보안 입력 칸(비밀번호)을 받아쓰기 대상으로 허용할지.
    public var allowSecureDictationTarget: Bool = false
    /// 단어 타이밍이 없는 전사일 때 `now` 기준으로 보는 창.
    public var untimedFallbackWindow: Duration = .seconds(2)

    // MARK: 캐시

    /// 좌표→UITarget 캐시 유효 시간.
    public var targetCacheTTL: Duration = .seconds(3)
    /// 캐시 키 격자 크기(포인트).
    public var targetCacheGrid: Double = 4
    public var targetCacheCapacity: Int = 256
    /// (utteranceID, revision) 결과 캐시 크기.
    public var analysisCacheCapacity: Int = 64

    public init() {}

    /// 응시 길이를 정확히 재기 위해 창 양쪽으로 더 읽는 범위.
    var segmentationMargin: Duration {
        max(stableFixationDuration, minFixationDuration) + maxSampleGap
    }
}
