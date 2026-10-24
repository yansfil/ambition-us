import AgentContracts
import CoreGraphics

/// 시선 샘플과 그 샘플이 대표하는 지속시간(초).
struct TimedGaze: Sendable {
    let sample: GazeSample
    let dt: Double
}

/// 공간·시간적으로 이어진 응시 샘플 묶음.
struct FixationSegment: Sendable {
    private(set) var members: [TimedGaze] = []
    /// 샘플 지속시간 합(초).
    private(set) var duration: Double = 0
    private var weightSum = 0.0
    private var sumX = 0.0
    private var sumY = 0.0
    private var sumUncertainty = 0.0

    init(_ first: TimedGaze) { append(first) }

    var displayID: UInt32 { members[0].sample.displayID }
    var firstTime: MonotonicTime { members[0].sample.time }
    var lastTime: MonotonicTime { members[members.count - 1].sample.time }
    /// 신뢰도 가중 중심점.
    var centroid: CGPoint { CGPoint(x: sumX / weightSum, y: sumY / weightSum) }
    var uncertaintyRadius: Double { sumUncertainty / weightSum }

    mutating func append(_ g: TimedGaze) {
        let w = max(g.sample.confidence, 1e-6)
        members.append(g)
        duration += g.dt
        weightSum += w
        sumX += w * Double(g.sample.point.x)
        sumY += w * Double(g.sample.point.y)
        sumUncertainty += w * g.sample.uncertaintyRadius
    }
}

/// 지시어 단어 하나의 증거 창. 시각은 단어 시작 기준 상대 초로 다룬다.
struct EvidenceWindow: Sendable {
    let reference: MonotonicTime
    let coreDuration: Double
    let lead: Double
    let lag: Double
    let leadFloor: Double
    let lagFloor: Double

    init(word: WordTiming, configuration c: FusionConfiguration) {
        reference = word.start
        coreDuration = max(0, word.end.seconds(since: word.start))
        lead = max(0, c.lead.fusionSeconds)
        lag = max(0, c.lag.fusionSeconds)
        leadFloor = min(max(c.leadWeightFloor, 0), 1)
        lagFloor = min(max(c.lagWeightFloor, 0), 1)
    }

    var lowerTime: MonotonicTime { reference.receded(byNanoseconds: UInt64(lead * 1e9)) }
    var upperTime: MonotonicTime { reference.advanced(byNanoseconds: UInt64((coreDuration + lag) * 1e9)) }

    /// 창 밖이면 0. 단어 구간 1, lead/lag 구간은 단어에서 멀어질수록 floor까지 선형 감소.
    func weight(at time: MonotonicTime) -> Double {
        let t = time.seconds(since: reference)
        if t >= 0 && t <= coreDuration { return 1 }
        if t < 0 {
            guard lead > 0, t >= -lead else { return 0 }
            return 1 - (1 - leadFloor) * (-t / lead)
        }
        let over = t - coreDuration
        guard lag > 0, over <= lag else { return 0 }
        return 1 - (1 - lagFloor) * (over / lag)
    }

    /// 창 전체를 빈틈없이 덮었을 때의 가중 시간(초).
    var maxWeightedTime: Double {
        coreDuration + lead * (1 + leadFloor) / 2 + lag * (1 + lagFloor) / 2
    }
}

enum FixationAnalyzer {
    /// 정렬된 샘플마다 다음 샘플까지의 시간을 붙인다(maxGap으로 자름).
    static func timed(_ sorted: [GazeSample], maxGap: Double) -> [TimedGaze] {
        guard !sorted.isEmpty else { return [] }
        let nominal = min(maxGap, 1.0 / 30.0)
        var result: [TimedGaze] = []
        result.reserveCapacity(sorted.count)
        for index in sorted.indices {
            let dt: Double
            if index + 1 < sorted.count {
                dt = min(max(0, sorted[index + 1].time.seconds(since: sorted[index].time)), maxGap)
            } else {
                dt = result.last.map { $0.dt > 0 ? $0.dt : nominal } ?? nominal
            }
            result.append(TimedGaze(sample: sorted[index], dt: dt))
        }
        return result
    }

    /// 응시 샘플(isFixation)을 공간 반경·시간 간격·디스플레이 기준으로 나눈다.
    static func segments(_ timed: [TimedGaze], radius: Double, maxGap: Double) -> [FixationSegment] {
        var result: [FixationSegment] = []
        var current: FixationSegment?
        for g in timed {
            guard g.sample.isFixation else {
                if let c = current { result.append(c); current = nil }
                continue
            }
            if var c = current,
               g.sample.displayID == c.displayID,
               g.sample.time.seconds(since: c.lastTime) <= maxGap + 1e-9,
               distance(g.sample.point, c.centroid) <= radius {
                c.append(g)
                current = c
            } else {
                if let c = current { result.append(c) }
                current = FixationSegment(g)
            }
        }
        if let c = current { result.append(c) }
        return result
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(a.x - b.x), dy = Double(a.y - b.y)
        return (dx * dx + dy * dy).squareRoot()
    }
}
