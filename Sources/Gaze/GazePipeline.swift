import AgentContracts
import CoreGraphics
import Foundation

public struct UncertaintyConfiguration: Sendable, Equatable {
    /// RMS 오차 → 반경 배율. 2차원 등방 가우시안이면 1.5×RMS가 약 89%를 덮는다.
    public var coverageFactor: Double = 1.5
    public var minimumRadius: Double = 20
    public var maximumRadius: Double = 400
    /// 원시 예측과 필터 출력 차이(떨림)의 EMA 계수.
    public var jitterSmoothing: Double = 0.15
    /// 신뢰도가 낮을수록 반경을 키운다: × (1 + k·(1 − confidence)).
    public var lowConfidenceInflation: Double = 1.0
    public init() {}

    func radius(expectedError: Double, jitter: Double, confidence: Double) -> Double {
        let base = (expectedError * expectedError + jitter * jitter).squareRoot() * coverageFactor
        let inflated = base * (1 + lowConfidenceInflation * (1 - clamp(confidence, 0, 1)))
        return clamp(inflated, minimumRadius, maximumRadius)
    }
}

/// 고정(fixation) 중 표시점 안정화. 고정이 확정되면 필터 출력 대신 고정 중심(처음엔 누적 평균,
/// 이후 시간 상수 `timeConstant`의 지수 평균)을 내보내 강조 표시가 떨리지 않게 한다. 사케이드가 오면 바로 필터 출력으로 돌아간다.
public struct FixationStabilization: Sendable, Equatable {
    public var enabled = true
    public var timeConstant = 0.45
    public init() {}
}

public struct GazePipelineConfiguration: Sendable {
    public var filter = OneEuroParameters()
    public var stabilization = FixationStabilization()
    public var fixation = FixationDetector.Configuration()
    public var attention = AttentionCueDetector.Configuration()
    public var headGesture = HeadGestureDetector.Configuration()
    public var uncertainty = UncertaintyConfiguration()
    /// 표본 사이 공백이 이보다 길면 필터·고정 상태를 초기화한다(초).
    public var trackingGapReset: Double = 0.35
    /// 보정 예측이 화면 밖이라 클램프됐을 때 신뢰도 배율.
    public var offscreenConfidence: Double = 0.5
    public init() {}
}

public struct GazePipelineOutput: Sendable, Equatable {
    public var sample: GazeSample?
    public var cues: [NonverbalCue]
    public init(sample: GazeSample? = nil, cues: [NonverbalCue] = []) {
        self.sample = sample; self.cues = cues
    }
}

/// 특징 → 보정 → One Euro → I-VT → 단서. 카메라 없이 돌릴 수 있는 순수 값 타입.
public struct GazePipeline: Sendable {
    public let configuration: GazePipelineConfiguration
    public var calibration: CalibrationStore
    private var filter: OneEuroFilter2D
    private var fixations: FixationDetector
    private var attention: AttentionCueDetector
    private var headGestures: HeadGestureDetector
    private var jitterSquared = 0.0
    private var stabilized: (fixationID: Int, point: SIMD2<Double>)?
    private var lastDisplayID: UInt32?
    private var lastRevision: Int?
    private var lastTime: MonotonicTime?

    public init(configuration: GazePipelineConfiguration = .init(), calibration: CalibrationStore = .init(),
                regionKeyer: GazeRegionKeying? = nil) {
        self.configuration = configuration
        self.calibration = calibration
        filter = OneEuroFilter2D(parameters: configuration.filter)
        fixations = FixationDetector(configuration: configuration.fixation)
        attention = AttentionCueDetector(configuration: configuration.attention, regionKeyer: regionKeyer)
        headGestures = HeadGestureDetector(configuration: configuration.headGesture)
    }

    /// 보정 전 특징을 처리한다. 해당 디스플레이 보정이 없으면 표본 없이 머리 제스처 단서만 낸다.
    public mutating func process(_ features: GazeFeatures) -> GazePipelineOutput {
        var cues: [NonverbalCue] = []
        if let pose = features.headPose, let cue = headGestures.update(pose, confidence: features.confidence, at: features.time) {
            cues.append(cue)
        }
        guard let mapped = calibration.map(features, preferredDisplay: lastDisplayID) else {
            return GazePipelineOutput(cues: cues)
        }
        let confidence = features.confidence * (mapped.wasClamped ? configuration.offscreenConfidence : 1)
        var output = processScreenPoint(mapped.point, displayID: mapped.displayID, time: features.time,
                                        confidence: confidence, calibrationRevision: mapped.revision,
                                        expectedError: mapped.expectedError)
        output.cues.insert(contentsOf: cues, at: 0)
        return output
    }

    /// 이미 화면 좌표인 시선(Beam SDK, 마우스 대체 등)을 처리한다.
    public mutating func processScreenPoint(_ point: CGPoint, displayID: UInt32, time: MonotonicTime, confidence: Double,
                                            calibrationRevision: Int, expectedError: Double,
                                            headPose: HeadPose? = nil) -> GazePipelineOutput {
        var cues: [NonverbalCue] = []
        if let headPose, let cue = headGestures.update(headPose, confidence: confidence, at: time) {
            cues.append(cue)
        }
        if let lastTime, time <= lastTime { return GazePipelineOutput(cues: cues) }
        let gap = lastTime.map { time.seconds(since: $0) } ?? .infinity
        if lastDisplayID != displayID || lastRevision != calibrationRevision || gap > configuration.trackingGapReset {
            cues += resetTracking(at: time)
        }
        let filtered = filter.filter(point, at: time.seconds)
        let deviation = point.distance(to: filtered)
        let alpha = configuration.uncertainty.jitterSmoothing
        jitterSquared = lastTime == nil ? deviation * deviation : alpha * deviation * deviation + (1 - alpha) * jitterSquared
        let radius = configuration.uncertainty.radius(expectedError: expectedError, jitter: jitterSquared.squareRoot(),
                                                      confidence: confidence)
        let fixation = fixations.update(point: filtered, time: time, displayID: displayID, confidence: confidence)
        cues += attention.update(fixation, uncertaintyRadius: radius, now: time)
        let shown = stabilize(filtered, fixation: fixation, dt: gap)
        lastDisplayID = displayID
        lastRevision = calibrationRevision
        lastTime = time
        let sample = GazeSample(time: time, displayID: displayID, point: shown, uncertaintyRadius: radius,
                                confidence: clamp(confidence, 0, 1), calibrationRevision: calibrationRevision,
                                isFixation: fixation.isFixation)
        return GazePipelineOutput(sample: sample, cues: cues)
    }

    /// 얼굴을 못 찾은 프레임. 공백이 `trackingGapReset`를 넘으면 추적을 끊는다(깜빡임은 무시).
    public mutating func noObservation(at time: MonotonicTime) -> GazePipelineOutput {
        guard let lastTime, time.seconds(since: lastTime) > configuration.trackingGapReset else {
            return GazePipelineOutput()
        }
        return trackingLost(at: time)
    }

    /// 추적을 즉시 끊는다(카메라 정지 등). 진행 중 고정을 마무리한다.
    public mutating func trackingLost(at time: MonotonicTime) -> GazePipelineOutput {
        let cues = resetTracking(at: time)
        headGestures.reset()
        lastTime = nil
        lastDisplayID = nil
        lastRevision = nil
        return GazePipelineOutput(cues: cues)
    }

    /// 고정 중이면 고정 중심 쪽으로 안정화한 점, 아니면 필터 출력.
    private mutating func stabilize(_ filtered: CGPoint, fixation: FixationUpdate, dt: Double) -> CGPoint {
        let options = configuration.stabilization
        guard options.enabled, fixation.isFixation, let current = fixation.current else {
            stabilized = nil
            return filtered
        }
        let value = SIMD2<Double>(Double(filtered.x), Double(filtered.y))
        if let previous = stabilized, previous.fixationID == current.id {
            let alpha = clamp(max(dt.isFinite ? dt / max(options.timeConstant, 1e-3) : 1,
                                  1 / Double(max(current.sampleCount, 1))), 0, 1)
            stabilized = (current.id, previous.point + (value - previous.point) * alpha)
        } else {
            stabilized = (current.id, SIMD2(Double(current.centroid.x), Double(current.centroid.y)))
        }
        let point = stabilized!.point
        return CGPoint(x: point.x, y: point.y)
    }

    private mutating func resetTracking(at time: MonotonicTime) -> [NonverbalCue] {
        filter.reset()
        stabilized = nil
        jitterSquared = 0
        let ended = fixations.reset()
        return attention.update(ended, uncertaintyRadius: 0, now: time)
    }
}
