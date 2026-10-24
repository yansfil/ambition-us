import AgentContracts
import CoreGraphics
import Foundation

/// 시선 고정 위치 → 영역 키. 예: Fusion이 AX 캐시로 `UITarget.token`을 돌려주게 주입한다.
/// nil을 돌려주면 내장 근접 군집 키(`gaze-region-<n>@<displayID>`)를 쓴다.
public typealias GazeRegionKeying = @Sendable (_ point: CGPoint, _ displayID: UInt32) -> String?

/// 고정 흐름에서 prolongedDwell·revisit 단서를 만든다.
///
/// - prolongedDwell: 같은 영역에 연속(고정 사이 공백 ≤ `dwellContinuationGap`)으로 `dwellThreshold` 이상 머물면 1회.
/// - revisit: 다른 영역을 거쳐 `revisitWindow` 안에 이전 영역으로 돌아오면 그때마다 1회.
public struct AttentionCueDetector: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var dwellThreshold: Double = 1.2
        public var dwellContinuationGap: Double = 0.3
        public var revisitWindow: Double = 10
        /// 같은 영역으로 볼 최소 반경(포인트). 실제 반경은 불확실성 반경과 비교해 큰 값.
        public var regionRadius: Double = 80
        public var maximumRegions: Int = 32
        public init() {}
    }

    struct Region: Sendable {
        let key: String
        let displayID: UInt32
        var centroid: CGPoint
        var weight: Double
        var lastSeen: MonotonicTime
        var visits: Int
        var revisits: Int
    }

    public var configuration: Configuration
    public var regionKeyer: GazeRegionKeying?
    private var regions: [Region] = []
    private var currentKey: String?
    private var dwellStart: MonotonicTime?
    private var dwellEmitted = false
    private var lastFixationEnd: MonotonicTime?
    private var nextRegionNumber = 1

    public init(configuration: Configuration = .init(), regionKeyer: GazeRegionKeying? = nil) {
        self.configuration = configuration
        self.regionKeyer = regionKeyer
    }

    public mutating func update(_ update: FixationUpdate, uncertaintyRadius: Double, now: MonotonicTime) -> [NonverbalCue] {
        var cues: [NonverbalCue] = []
        if let ended = update.ended {
            touch(currentKey, at: ended.end)
            lastFixationEnd = ended.end
        }
        if let began = update.began {
            let radius = max(configuration.regionRadius, uncertaintyRadius)
            let key = resolveRegion(began.centroid, displayID: began.displayID, radius: radius, at: began.start)
            let continuing = key == currentKey
                && lastFixationEnd.map { began.start.seconds(since: $0) <= configuration.dwellContinuationGap } ?? false
            if !continuing {
                let previousKey = currentKey
                currentKey = key
                dwellStart = began.start
                dwellEmitted = false
                if let index = regions.firstIndex(where: { $0.key == key }) {
                    let region = regions[index]
                    if region.visits > 0, previousKey != nil, previousKey != key,
                       began.start.seconds(since: region.lastSeen) <= configuration.revisitWindow {
                        regions[index].revisits += 1
                        let confidence = began.meanConfidence * min(1, 0.6 + 0.2 * Double(regions[index].revisits))
                        // targetID는 내부 영역 키다. Fusion이 point를 UI 요소 token으로 바꾼다.
                        cues.append(NonverbalCue(time: now, kind: .revisit, targetID: key, confidence: clamp(confidence, 0, 1),
                                                 point: began.centroid, displayID: began.displayID))
                    }
                    regions[index].visits += 1
                }
            }
            touch(key, at: began.end)
        }
        if let current = update.current, let key = currentKey {
            touch(key, at: current.end)
            if !dwellEmitted, let start = dwellStart, current.end.seconds(since: start) >= configuration.dwellThreshold {
                dwellEmitted = true
                cues.append(NonverbalCue(time: now, kind: .prolongedDwell, targetID: key,
                                         confidence: clamp(current.meanConfidence, 0, 1),
                                         point: current.centroid, displayID: current.displayID))
            }
        }
        prune(now: now)
        return cues
    }

    public mutating func reset() {
        regions.removeAll()
        currentKey = nil
        dwellStart = nil
        dwellEmitted = false
        lastFixationEnd = nil
    }

    private mutating func resolveRegion(_ point: CGPoint, displayID: UInt32, radius: Double, at time: MonotonicTime) -> String {
        if let injected = regionKeyer?(point, displayID) {
            if !regions.contains(where: { $0.key == injected }) {
                regions.append(Region(key: injected, displayID: displayID, centroid: point, weight: 1,
                                      lastSeen: time, visits: 0, revisits: 0))
            }
            return injected
        }
        let nearest = regions.indices
            .filter { regions[$0].displayID == displayID }
            .min { regions[$0].centroid.distance(to: point) < regions[$1].centroid.distance(to: point) }
        if let index = nearest, regions[index].centroid.distance(to: point) <= radius {
            // 영역 중심을 천천히 따라가게 한다(가중치 상한으로 표류 방지).
            var region = regions[index]
            let w = min(region.weight, 9)
            region.centroid = CGPoint(x: (region.centroid.x * w + point.x) / (w + 1), y: (region.centroid.y * w + point.y) / (w + 1))
            region.weight = w + 1
            regions[index] = region
            return region.key
        }
        let key = "gaze-region-\(nextRegionNumber)@\(displayID)"
        nextRegionNumber += 1
        regions.append(Region(key: key, displayID: displayID, centroid: point, weight: 1,
                              lastSeen: time, visits: 0, revisits: 0))
        return key
    }

    private mutating func touch(_ key: String?, at time: MonotonicTime) {
        guard let key, let index = regions.firstIndex(where: { $0.key == key }) else { return }
        if time > regions[index].lastSeen { regions[index].lastSeen = time }
    }

    private mutating func prune(now: MonotonicTime) {
        regions.removeAll { $0.key != currentKey && now.seconds(since: $0.lastSeen) > configuration.revisitWindow * 2 }
        if regions.count > configuration.maximumRegions {
            let excess = regions.count - configuration.maximumRegions
            let victims = regions.filter { $0.key != currentKey }.sorted { $0.lastSeen < $1.lastSeen }.prefix(excess).map(\.key)
            regions.removeAll { victims.contains($0.key) }
        }
    }
}

/// 머리 자세 시계열에서 끄덕임(pitch 왕복)·도리질(yaw 왕복)을 찾는다.
///
/// 지그재그 방식으로 임계값 이상 방향 전환(스윙)을 세고, 빠른 스윙이 연속으로 충분하고
/// 주축 진폭이 보조축보다 충분히 크면 단서를 낸다. 낸 뒤에는 기록을 비우고 쿨다운한다.
public struct HeadGestureDetector: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var window: Double = 1.5
        public var swingThresholdDegrees: Double = 5
        public var maximumSwingDuration: Double = 0.45
        public var minimumShakeSwings: Int = 3
        public var minimumNodSwings: Int = 2
        /// 주축 진폭 / 보조축 진폭 최소 비율.
        public var dominanceRatio: Double = 1.6
        public var cooldown: Double = 1.0
        public init() {}
    }

    struct PoseSample: Sendable {
        let time: MonotonicTime
        let yaw: Double
        let pitch: Double
        let confidence: Double
    }

    struct Swing: Sendable, Equatable {
        let amplitude: Double
        let duration: Double
    }

    public var configuration: Configuration
    private var history: [PoseSample] = []
    private var cooldownUntil: MonotonicTime?

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public mutating func reset() {
        history.removeAll()
    }

    public mutating func update(_ pose: HeadPose, confidence: Double, at time: MonotonicTime) -> NonverbalCue? {
        if let until = cooldownUntil, time < until { return nil }
        if let last = history.last, time <= last.time { return nil }
        history.append(PoseSample(time: time, yaw: pose.yaw, pitch: pose.pitch, confidence: confidence))
        history.removeAll { time.seconds(since: $0.time) > configuration.window }
        guard history.count >= 5 else { return nil }

        let threshold = configuration.swingThresholdDegrees * .pi / 180
        let yawValues = history.map { ($0.time, $0.yaw) }
        let pitchValues = history.map { ($0.time, $0.pitch) }
        let yawRange = range(yawValues.map(\.1)), pitchRange = range(pitchValues.map(\.1))
        let yawRun = fastRun(Self.swings(yawValues, threshold: threshold))
        let pitchRun = fastRun(Self.swings(pitchValues, threshold: threshold))

        let kind: NonverbalCue.Kind
        let run: [Swing]
        let required: Int
        if yawRun.count >= configuration.minimumShakeSwings, yawRange >= configuration.dominanceRatio * pitchRange {
            kind = .headShake; run = yawRun; required = configuration.minimumShakeSwings
        } else if pitchRun.count >= configuration.minimumNodSwings, pitchRange >= configuration.dominanceRatio * yawRange {
            kind = .headNod; run = pitchRun; required = configuration.minimumNodSwings
        } else {
            return nil
        }
        let meanAmplitude = run.reduce(0) { $0 + $1.amplitude } / Double(run.count)
        let faceConfidence = history.reduce(0) { $0 + $1.confidence } / Double(history.count)
        let strength = 0.55 + 0.1 * Double(run.count - required) + 0.2 * min(1, (meanAmplitude - threshold) / threshold)
        history.removeAll()
        cooldownUntil = time.adding(seconds: configuration.cooldown)
        return NonverbalCue(time: time, kind: kind, targetID: nil, confidence: clamp(min(0.95, strength) * faceConfidence, 0, 1))
    }

    private func range(_ values: [Double]) -> Double {
        (values.max() ?? 0) - (values.min() ?? 0)
    }

    /// 끝에서부터 이어지는 빠른 스윙 구간(가장 최근 제스처).
    private func fastRun(_ swings: [Swing]) -> [Swing] {
        var run: [Swing] = []
        for swing in swings.reversed() {
            guard swing.duration <= configuration.maximumSwingDuration else { break }
            run.append(swing)
        }
        return run.reversed()
    }

    /// 지그재그 피벗 사이의 스윙들. 마지막 진행 중 극값까지 포함한다.
    /// 스윙 시간은 시작 피벗 근처(진폭의 20% 이내)를 마지막으로 떠난 시점부터 재서, 앞선 정지 구간은 제외한다.
    static func swings(_ values: [(MonotonicTime, Double)], threshold: Double) -> [Swing] {
        guard !values.isEmpty else { return [] }
        var pivots = [0]
        var lowest = 0, highest = 0
        var extreme = 0
        var direction = 0
        for i in values.indices.dropFirst() {
            let v = values[i].1
            switch direction {
            case 0:
                if v < values[lowest].1 { lowest = i }
                if v > values[highest].1 { highest = i }
                if v - values[lowest].1 >= threshold { direction = 1; pivots[0] = lowest; extreme = i }
                else if values[highest].1 - v >= threshold { direction = -1; pivots[0] = highest; extreme = i }
            case 1:
                if v > values[extreme].1 { extreme = i }
                else if values[extreme].1 - v >= threshold { pivots.append(extreme); direction = -1; extreme = i }
            default:
                if v < values[extreme].1 { extreme = i }
                else if v - values[extreme].1 >= threshold { pivots.append(extreme); direction = 1; extreme = i }
            }
        }
        if direction != 0 { pivots.append(extreme) }
        return zip(pivots, pivots.dropFirst()).map { a, b in
            let amplitude = abs(values[b].1 - values[a].1)
            var start = a
            for k in a...b where abs(values[k].1 - values[a].1) <= 0.2 * amplitude { start = k }
            return Swing(amplitude: amplitude, duration: values[b].0.seconds(since: values[start].0))
        }
    }
}
