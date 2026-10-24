import AgentContracts
import CoreGraphics
import Foundation

/// 보정 표본: 사용자가 `target`(전역 좌표)을 보고 있을 때 측정한 특징.
public struct CalibrationSample: Sendable, Codable, Equatable {
    public var features: GazeFeatures
    public var target: CGPoint
    public init(features: GazeFeatures, target: CGPoint) {
        self.features = features; self.target = target
    }
}

public enum CalibrationError: Error, Sendable, Equatable {
    case insufficientTargets(found: Int, required: Int)
    case inconsistentFeatureDimensions
    case singularSystem
    case noActiveSession
    case noActiveTarget
    case unknownDisplay(UInt32)
    /// 모델이 만들어진 디스플레이 배치가 현재와 다르다.
    case displayMismatch(UInt32)
}

public struct CalibrationOptions: Sendable, Equatable {
    /// nil이면 표적 수로 결정(6개 이상이면 2차, 아니면 1차).
    public var kind: CalibrationModel.Kind?
    /// 표적 하나씩 빼는 교차검증으로 고르는 릿지 계수 후보.
    public var lambdas: [Double] = [1e-4, 1e-3, 1e-2, 3e-2, 1e-1, 3e-1, 1]
    public var minimumTargets: Int = 5
    public var minimumSamplesPerTarget: Int = 3
    public init(kind: CalibrationModel.Kind? = nil) { self.kind = kind }
}

/// 디스플레이 하나에 대한 특징 → 화면 좌표 회귀 모델.
///
/// 특징을 z-점수로 표준화한 뒤 primary 2차원은 2차 다항식(1, x, y, x², y², xy),
/// auxiliary는 선형 항으로 확장하고, 표적별 동일 가중 릿지 회귀를 푼다.
/// 오차는 표적 하나씩 빼는 교차검증 잔차로 추정해 불확실성 반경에 쓴다.
public struct CalibrationModel: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable { case linear, quadratic }

    /// 표적 위치(디스플레이 로컬 좌표)별 교차검증 RMS 오차.
    public struct ResidualAnchor: Sendable, Codable, Equatable {
        public let point: CGPoint
        public let rmse: Double
    }

    public let display: DisplayGeometry
    public internal(set) var revision: Int
    public let kind: Kind
    public let lambda: Double
    public let featureDimension: Int
    let featureMean: [Double]
    let featureScale: [Double]
    let weightsX: [Double]
    let weightsY: [Double]
    /// 교차검증 RMS 오차(포인트). 표적이 너무 적으면 학습 오차의 2배.
    public let crossValidatedRMSE: Double
    public let trainingRMSE: Double
    public let residualAnchors: [ResidualAnchor]
    public let targetCount: Int
    public let sampleCount: Int

    // MARK: 예측

    /// 디스플레이 로컬 좌표(디스플레이 좌상단 원점) 예측. 특징 차원이 다르면 nil.
    public func predictLocal(_ features: GazeFeatures) -> CGPoint? {
        let raw = features.vector
        guard raw.count == featureDimension else { return nil }
        let phi = Self.expand(standardize(raw), kind: kind)
        return CGPoint(x: RidgeRegression.dot(weightsX, phi), y: RidgeRegression.dot(weightsY, phi))
    }

    /// 전역 좌표 예측(클램프하지 않음).
    public func predict(_ features: GazeFeatures) -> CGPoint? {
        predictLocal(features).map { CGPoint(x: $0.x + display.frame.minX, y: $0.y + display.frame.minY) }
    }

    /// 로컬 좌표 근처 표적들의 교차검증 오차를 역거리 가중으로 보간한다.
    public func expectedError(atLocal point: CGPoint) -> Double {
        guard !residualAnchors.isEmpty else { return crossValidatedRMSE }
        let diagonal = Double(hypot(display.frame.width, display.frame.height))
        let softening = max(1, diagonal * 0.1)
        var weighted = 0.0, total = 0.0
        for anchor in residualAnchors {
            let d = anchor.point.distance(to: point)
            let w = 1 / (d * d + softening * softening)
            weighted += w * anchor.rmse * anchor.rmse
            total += w
        }
        return (weighted / total).squareRoot()
    }

    func standardize(_ raw: [Double]) -> [Double] {
        (0..<raw.count).map { (raw[$0] - featureMean[$0]) / featureScale[$0] }
    }

    static func expand(_ z: [Double], kind: Kind) -> [Double] {
        switch kind {
        case .linear:
            return [1] + z
        case .quadratic:
            let x = z[0], y = z[1]
            return [1, x, y, x * x, y * y, x * y] + z.dropFirst(2)
        }
    }

    static func penalizedMask(featureDimension: Int, kind: Kind) -> [Bool] {
        let terms = kind == .linear ? featureDimension + 1 : featureDimension + 4
        return [false] + Array(repeating: true, count: terms - 1)
    }

    // MARK: 적합

    struct TargetKey: Hashable { let x: Double; let y: Double }

    public static func fit(samples: [CalibrationSample], display: DisplayGeometry, revision: Int = 0,
                           options: CalibrationOptions = .init()) throws -> CalibrationModel {
        guard let dimension = samples.first?.features.vector.count, dimension >= 2 else {
            throw CalibrationError.insufficientTargets(found: 0, required: options.minimumTargets)
        }
        guard samples.allSatisfy({ $0.features.vector.count == dimension }) else {
            throw CalibrationError.inconsistentFeatureDimensions
        }
        let grouped = Dictionary(grouping: samples) { TargetKey(x: Double($0.target.x), y: Double($0.target.y)) }
            .filter { $0.value.count >= options.minimumSamplesPerTarget }
        let keys = grouped.keys.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        guard keys.count >= options.minimumTargets else {
            throw CalibrationError.insufficientTargets(found: keys.count, required: options.minimumTargets)
        }
        let kind = options.kind ?? (keys.count >= 6 ? .quadratic : .linear)
        let origin = SIMD2<Double>(Double(display.frame.minX), Double(display.frame.minY))

        // 표적 순서대로 평탄화하고 표적별 동일 가중치를 준다.
        var raws: [[Double]] = [], targets: [SIMD2<Double>] = [], weights: [Double] = [], groupIndex: [Int] = []
        for (g, key) in keys.enumerated() {
            let group = grouped[key]!
            for sample in group {
                raws.append(sample.features.vector)
                targets.append(SIMD2(key.x, key.y) - origin)
                weights.append(1 / Double(group.count))
                groupIndex.append(g)
            }
        }
        let n = Double(raws.count)
        var mean = [Double](repeating: 0, count: dimension), scale = [Double](repeating: 1, count: dimension)
        for i in 0..<dimension {
            let column = raws.map { $0[i] }
            let m = column.reduce(0, +) / n
            let variance = column.reduce(0) { $0 + ($1 - m) * ($1 - m) } / n
            mean[i] = m
            scale[i] = variance > 1e-18 ? variance.squareRoot() : 1
        }
        let design = raws.map { raw in expand((0..<dimension).map { (raw[$0] - mean[$0]) / scale[$0] }, kind: kind) }
        let penalized = penalizedMask(featureDimension: dimension, kind: kind)

        func predict(_ solution: RidgeRegression.Solution, _ phi: [Double]) -> SIMD2<Double> {
            SIMD2(RidgeRegression.dot(solution.x, phi), RidgeRegression.dot(solution.y, phi))
        }

        /// 표적 하나씩 빼고 학습·예측한 표적별 RMS 오차.
        func crossValidate(_ lambda: Double) -> [Double]? {
            var perTarget: [Double] = []
            for g in keys.indices {
                let train = design.indices.filter { groupIndex[$0] != g }
                guard let solution = RidgeRegression.fit(design: train.map { design[$0] }, targets: train.map { targets[$0] },
                                                         weights: train.map { weights[$0] }, lambda: lambda,
                                                         penalized: penalized) else { return nil }
                let test = design.indices.filter { groupIndex[$0] == g }
                let squared = test.reduce(0.0) { sum, i in
                    let r = predict(solution, design[i]) - targets[i]
                    return sum + simdDot(r, r)
                }
                perTarget.append((squared / Double(test.count)).squareRoot())
            }
            return perTarget
        }

        var chosenLambda = options.lambdas.first ?? 1e-2
        var cvPerTarget: [Double]?
        if keys.count >= 4 {
            var bestScore = Double.infinity
            for lambda in options.lambdas {
                guard let perTarget = crossValidate(lambda) else { continue }
                let score = perTarget.reduce(0) { $0 + $1 * $1 } / Double(perTarget.count)
                if score < bestScore { bestScore = score; chosenLambda = lambda; cvPerTarget = perTarget }
            }
        }
        guard let solution = RidgeRegression.fit(design: design, targets: targets, weights: weights,
                                                 lambda: chosenLambda, penalized: penalized) else {
            throw CalibrationError.singularSystem
        }
        var trainingPerTarget = [Double](repeating: 0, count: keys.count)
        var counts = [Int](repeating: 0, count: keys.count)
        for i in design.indices {
            let r = predict(solution, design[i]) - targets[i]
            trainingPerTarget[groupIndex[i]] += simdDot(r, r)
            counts[groupIndex[i]] += 1
        }
        trainingPerTarget = zip(trainingPerTarget, counts).map { ($0 / Double($1)).squareRoot() }
        let trainingRMSE = (trainingPerTarget.reduce(0) { $0 + $1 * $1 } / Double(keys.count)).squareRoot()
        let anchorErrors = cvPerTarget ?? trainingPerTarget.map { $0 * 2 }
        let cvRMSE = cvPerTarget.map { ($0.reduce(0) { $0 + $1 * $1 } / Double($0.count)).squareRoot() }
            ?? trainingRMSE * 2
        let anchors = keys.enumerated().map { g, key in
            ResidualAnchor(point: CGPoint(x: key.x - origin.x, y: key.y - origin.y), rmse: max(anchorErrors[g], trainingPerTarget[g]))
        }
        return CalibrationModel(
            display: display, revision: revision, kind: kind, lambda: chosenLambda, featureDimension: dimension,
            featureMean: mean, featureScale: scale, weightsX: solution.x, weightsY: solution.y,
            crossValidatedRMSE: max(cvRMSE, trainingRMSE), trainingRMSE: trainingRMSE,
            residualAnchors: anchors, targetCount: keys.count, sampleCount: raws.count)
    }
}

/// 보정 결과를 디스플레이에 매핑한 시선 점.
public struct MappedGaze: Sendable, Equatable {
    public let displayID: UInt32
    /// 디스플레이 안으로 클램프한 전역 좌표.
    public let point: CGPoint
    /// 그 위치에서 기대되는 보정 오차(포인트).
    public let expectedError: Double
    public let revision: Int
    /// 예측이 디스플레이 밖이라 클램프됐는지.
    public let wasClamped: Bool
}

/// 디스플레이별 보정 모델과 리비전 관리. 디스플레이 배치가 바뀌면 해당 모델을 무효화한다.
///
/// 리비전은 모델 설치·무효화마다 1씩 증가하는 전역 카운터이고,
/// `GazeSample.calibrationRevision`에는 그 표본을 만든 모델의 리비전이 들어간다(미보정 = 0).
public struct CalibrationStore: Sendable {
    public private(set) var revision: Int = 0
    public private(set) var models: [UInt32: CalibrationModel] = [:]
    public private(set) var displays: [DisplayGeometry] = []
    /// 두 디스플레이 모두 예측을 포함할 때 직전 디스플레이를 유지하는 여유(정규화 거리).
    public var displayMargin: Double = 0.05

    public init(displays: [DisplayGeometry] = []) {
        self.displays = displays
    }

    public func model(for displayID: UInt32) -> CalibrationModel? { models[displayID] }

    /// 모델을 새 리비전으로 설치한다. 모델이 현재 디스플레이 배치와 맞지 않으면 거부한다.
    @discardableResult
    public mutating func install(_ model: CalibrationModel) throws -> CalibrationModel {
        if !displays.isEmpty, !displays.contains(model.display) {
            throw CalibrationError.displayMismatch(model.display.id)
        }
        revision += 1
        var installed = model
        installed.revision = revision
        models[model.display.id] = installed
        return installed
    }

    @discardableResult
    public mutating func fit(samples: [CalibrationSample], display: DisplayGeometry,
                             options: CalibrationOptions = .init()) throws -> CalibrationModel {
        try install(CalibrationModel.fit(samples: samples, display: display, revision: revision + 1, options: options))
    }

    @discardableResult
    public mutating func invalidate(displayID: UInt32) -> Bool {
        guard models.removeValue(forKey: displayID) != nil else { return false }
        revision += 1
        return true
    }

    /// 디스플레이 배치를 갱신하고, 사라졌거나 프레임이 바뀐 디스플레이의 모델을 무효화한다.
    @discardableResult
    public mutating func updateDisplays(_ current: [DisplayGeometry]) -> [UInt32] {
        displays = current
        let stale = models.values.filter { !current.contains($0.display) }.map(\.display.id).sorted()
        for id in stale { invalidate(displayID: id) }
        return stale
    }

    /// 모든 모델로 예측해 화면 안에 떨어지는(또는 가장 가까운) 디스플레이를 고른다.
    public func map(_ features: GazeFeatures, preferredDisplay: UInt32? = nil) -> MappedGaze? {
        struct Candidate { let model: CalibrationModel; let local: CGPoint; let outside: Double; let centerDistance: Double }
        let candidates: [Candidate] = models.values.sorted { $0.display.id < $1.display.id }.compactMap { model in
            guard let local = model.predictLocal(features), local.x.isFinite, local.y.isFinite else { return nil }
            let size = model.display.frame.size
            guard size.width > 0, size.height > 0 else { return nil }
            let nx = Double(local.x / size.width), ny = Double(local.y / size.height)
            let outside = max(0, -nx, nx - 1) + max(0, -ny, ny - 1)
            return Candidate(model: model, local: local, outside: outside, centerDistance: hypot(nx - 0.5, ny - 0.5))
        }
        let preferred = candidates.first { $0.model.display.id == preferredDisplay && $0.outside <= displayMargin }
        guard let chosen = preferred ?? candidates.min(by: { ($0.outside, $0.centerDistance) < ($1.outside, $1.centerDistance) })
        else { return nil }
        let size = chosen.model.display.frame.size
        let clampedLocal = CGPoint(x: clamp(chosen.local.x, 0, size.width), y: clamp(chosen.local.y, 0, size.height))
        let origin = chosen.model.display.frame.origin
        return MappedGaze(
            displayID: chosen.model.display.id,
            point: CGPoint(x: clampedLocal.x + origin.x, y: clampedLocal.y + origin.y),
            expectedError: chosen.model.expectedError(atLocal: clampedLocal),
            revision: chosen.model.revision,
            wasClamped: chosen.outside > 1e-9)
    }
}

/// 보정 표적별 특징 수집기. 표적이 나타난 직후(사케이드 지연)는 버리고, 표적별 이상치를 제거한다.
public struct CalibrationCollector: Sendable {
    public let display: DisplayGeometry
    /// 표적 표시 후 이 시간 동안의 표본은 버린다(초).
    public var settleDuration: Double = 0.35
    /// primary 특징 중앙값에서 MAD×이 배수보다 먼 표본은 버린다.
    public var outlierMADMultiplier: Double = 3
    public private(set) var samples: [CalibrationSample] = []
    public private(set) var targetCount = 0

    private var activeTarget: CGPoint?
    private var activeSince: MonotonicTime?
    private var pending: [GazeFeatures] = []

    public init(display: DisplayGeometry) {
        self.display = display
    }

    public var isCollecting: Bool { activeTarget != nil }

    public mutating func beginTarget(_ target: CGPoint, at time: MonotonicTime) {
        activeTarget = target
        activeSince = time
        pending.removeAll()
    }

    public mutating func add(_ features: GazeFeatures) {
        guard activeTarget != nil, let since = activeSince,
              features.time.seconds(since: since) >= settleDuration else { return }
        pending.append(features)
    }

    /// 현재 표적을 마무리하고 채택된 표본 수를 돌려준다.
    @discardableResult
    public mutating func endTarget() -> Int {
        guard let target = activeTarget else { return 0 }
        defer { activeTarget = nil; activeSince = nil; pending.removeAll() }
        let accepted = Self.rejectOutliers(pending, multiplier: outlierMADMultiplier)
        guard !accepted.isEmpty else { return 0 }
        samples += accepted.map { CalibrationSample(features: $0, target: target) }
        targetCount += 1
        return accepted.count
    }

    public mutating func abortTarget() {
        activeTarget = nil; activeSince = nil; pending.removeAll()
    }

    public func fit(revision: Int = 0, options: CalibrationOptions = .init()) throws -> CalibrationModel {
        try CalibrationModel.fit(samples: samples, display: display, revision: revision, options: options)
    }

    static func rejectOutliers(_ features: [GazeFeatures], multiplier: Double) -> [GazeFeatures] {
        guard features.count >= 4 else { return features }
        let median = SIMD2(Self.median(features.map(\.primary.x)), Self.median(features.map(\.primary.y)))
        let distances = features.map { simdLength($0.primary - median) }
        let mad = Self.median(distances)
        let limit = multiplier * max(1.4826 * mad, 1e-9)
        return zip(features, distances).filter { $0.1 <= limit }.map(\.0)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

/// 보정 표적 배치(전역 좌표).
public enum CalibrationTargetLayout {
    public static func grid(rows: Int, columns: Int, in display: DisplayGeometry,
                            insetFraction: Double = 0.08) -> [CGPoint] {
        let frame = display.frame
        let insetX = frame.width * insetFraction, insetY = frame.height * insetFraction
        let usable = frame.insetBy(dx: insetX, dy: insetY)
        var points: [CGPoint] = []
        for r in 0..<max(rows, 1) {
            for c in 0..<max(columns, 1) {
                let fx = columns > 1 ? Double(c) / Double(columns - 1) : 0.5
                let fy = rows > 1 ? Double(r) / Double(rows - 1) : 0.5
                points.append(CGPoint(x: usable.minX + usable.width * fx, y: usable.minY + usable.height * fy))
            }
        }
        return points
    }

    public static func nine(in display: DisplayGeometry) -> [CGPoint] { grid(rows: 3, columns: 3, in: display) }
    public static func sixteen(in display: DisplayGeometry) -> [CGPoint] { grid(rows: 4, columns: 4, in: display) }
}
