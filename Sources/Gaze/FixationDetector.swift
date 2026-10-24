import AgentContracts
import CoreGraphics
import Foundation

public struct Fixation: Sendable, Equatable {
    public let id: Int
    public let displayID: UInt32
    public let start: MonotonicTime
    /// 마지막으로 포함된 표본 시각.
    public let end: MonotonicTime
    public let centroid: CGPoint
    public let sampleCount: Int
    public let meanConfidence: Double

    public var duration: Double { end.seconds(since: start) }
}

public struct FixationUpdate: Sendable, Equatable {
    /// 이번 표본이 확정된 고정(fixation)에 속하는지.
    public var isFixation = false
    /// 진행 중인 확정 고정(사케이드 의심 구간 포함).
    public var current: Fixation?
    /// 이번 표본에서 확정된 고정.
    public var began: Fixation?
    /// 이번 표본에서 끝난 고정.
    public var ended: Fixation?

    public init(isFixation: Bool = false, current: Fixation? = nil, began: Fixation? = nil, ended: Fixation? = nil) {
        self.isFixation = isFixation; self.current = current; self.began = began; self.ended = ended
    }
}

/// I-VT(속도 임계) 고정 검출기. 웹캠 잡음 대비로, 짧은 속도 스파이크 뒤 같은 자리로 돌아오면 고정을 이어 붙인다.
public struct FixationDetector: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var velocityThresholdDegreesPerSecond: Double = 30
        /// 시각 1°에 해당하는 화면 포인트(약 60cm 거리의 노트북 화면 기준 근사).
        public var pointsPerDegree: Double = 45
        public var minimumDuration: Double = 0.1
        /// 이 시간 이하의 속도 스파이크는 잡음으로 본다.
        public var maximumGap: Double = 0.08
        public var mergeRadiusDegrees: Double = 1.5
        public init() {}
    }

    struct Candidate: Sendable {
        var displayID: UInt32
        var start: MonotonicTime
        var end: MonotonicTime
        var sumX = 0.0, sumY = 0.0, count = 0, confidenceSum = 0.0
        var id: Int?
        var gapStart: MonotonicTime?

        init(point: CGPoint, time: MonotonicTime, displayID: UInt32, confidence: Double) {
            self.displayID = displayID; start = time; end = time
            add(point, time, confidence)
        }

        mutating func add(_ point: CGPoint, _ time: MonotonicTime, _ confidence: Double) {
            sumX += Double(point.x); sumY += Double(point.y); count += 1; confidenceSum += confidence; end = time
        }

        var centroid: CGPoint { CGPoint(x: sumX / Double(count), y: sumY / Double(count)) }

        var fixation: Fixation? {
            id.map { Fixation(id: $0, displayID: displayID, start: start, end: end, centroid: centroid,
                              sampleCount: count, meanConfidence: confidenceSum / Double(count)) }
        }
    }

    public var configuration: Configuration
    private var lastPoint: CGPoint?
    private var lastTime: MonotonicTime?
    private var candidate: Candidate?
    private var nextID = 1

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public mutating func update(point: CGPoint, time: MonotonicTime, displayID: UInt32,
                                confidence: Double = 1) -> FixationUpdate {
        var update = FixationUpdate()
        guard let lp = lastPoint, let lt = lastTime else {
            candidate = Candidate(point: point, time: time, displayID: displayID, confidence: confidence)
            lastPoint = point; lastTime = time
            return status(update)
        }
        let dt = time.seconds(since: lt)
        guard dt > 1e-6 else { return status(update) }
        let speed = lp.distance(to: point) / dt / configuration.pointsPerDegree
        let mergeRadius = configuration.mergeRadiusDegrees * configuration.pointsPerDegree

        if speed <= configuration.velocityThresholdDegreesPerSecond {
            if var c = candidate {
                if let gapStart = c.gapStart {
                    if time.seconds(since: gapStart) <= configuration.maximumGap,
                       point.distance(to: c.centroid) <= mergeRadius {
                        c.gapStart = nil
                        c.add(point, time, confidence)
                        candidate = c
                    } else {
                        update.ended = c.fixation
                        candidate = Candidate(point: point, time: time, displayID: displayID, confidence: confidence)
                    }
                } else {
                    c.add(point, time, confidence)
                    candidate = c
                }
            } else {
                candidate = Candidate(point: point, time: time, displayID: displayID, confidence: confidence)
            }
            if var c = candidate, c.id == nil, c.end.seconds(since: c.start) >= configuration.minimumDuration {
                c.id = nextID
                nextID += 1
                candidate = c
                update.began = c.fixation
            }
        } else if var c = candidate {
            if c.id == nil {
                candidate = nil
            } else if let gapStart = c.gapStart {
                if time.seconds(since: gapStart) > configuration.maximumGap {
                    update.ended = c.fixation
                    candidate = nil
                }
            } else {
                c.gapStart = time
                candidate = c
            }
        }
        lastPoint = point
        lastTime = time
        return status(update)
    }

    /// 추적이 끊겼을 때 호출. 진행 중 고정이 있으면 `ended`로 돌려준다.
    public mutating func reset() -> FixationUpdate {
        let ended = candidate?.fixation
        candidate = nil
        lastPoint = nil
        lastTime = nil
        return FixationUpdate(ended: ended)
    }

    private func status(_ update: FixationUpdate) -> FixationUpdate {
        var update = update
        update.current = candidate?.fixation
        update.isFixation = update.current != nil && candidate?.gapStart == nil
        return update
    }
}
