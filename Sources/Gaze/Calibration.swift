import AgentContracts
import CoreGraphics
import Foundation

/// 보정 표본: 사용자가 `target`(전역 좌표)을 보고 있을 때 측정한 특징.
public struct CalibrationSample: Sendable, Codable, Equatable {
    public enum Source: String, Sendable, Codable {
        /// 보정 점(같은 위치의 표본이 한 그룹).
        case target
        /// 검증 점(검증 후 학습에 합칠 수 있다).
        case validation
        /// 클릭으로 얻은 암묵 보정 표본(표본 하나가 한 그룹).
        case implicit
    }

    public var features: GazeFeatures
    public var target: CGPoint
    public var source: Source
    /// 그룹 가중치 배율. 보정 점은 1, 암묵 표본은 최신성 가중치.
    public var weight: Double
    /// 암묵 표본 그룹 식별자. nil이면 표적 위치로 묶는다.
    public var groupID: Int?

    public init(features: GazeFeatures, target: CGPoint, source: Source = .target, weight: Double = 1,
                groupID: Int? = nil) {
        self.features = features; self.target = target; self.source = source; self.weight = weight
        self.groupID = groupID
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        features = try c.decode(GazeFeatures.self, forKey: .features)
        target = try c.decode(CGPoint.self, forKey: .target)
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .target
        weight = try c.decodeIfPresent(Double.self, forKey: .weight) ?? 1
        groupID = try c.decodeIfPresent(Int.self, forKey: .groupID)
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
    /// 모델이 다른 시선 추정기의 특징으로 학습됐다.
    case estimatorMismatch(String)
    /// 검증할 보정 모델이 없다.
    case noModel
}

public struct CalibrationOptions: Sendable, Equatable {
    /// 지정하면 그 차수만 후보로 쓴다(nil이면 교차검증으로 고른다).
    public var kind: CalibrationModel.Kind?
    /// 후보 구조를 직접 지정(nil이면 자동).
    public var structures: [CalibrationModel.Structure]?
    /// 그룹(표적) 하나씩 빼는 교차검증으로 고르는 릿지 계수 후보.
    public var lambdas: [Double] = [1e-4, 3e-4, 1e-3, 3e-3, 1e-2, 3e-2, 1e-1, 3e-1, 1]
    public var minimumTargets: Int = 5
    public var minimumSamplesPerTarget: Int = 3
    /// 모델에 기록할 추정기 ID.
    public var estimatorID: String = LandmarkGazeEstimator.identifier
    /// 특징별 표준화 최소 척도(`GazeEstimator.featureScaleFloors`).
    public var scaleFloors: [Double] = []
    /// auxiliary 앞쪽 몇 개가 머리 자세인지(구조 후보 `head`).
    public var headAuxiliaryCount: Int = 2
    /// 교차검증 오차가 최선의 (1 + tol)배 이내면 항이 적은 구조를 고른다.
    public var parsimonyTolerance: Double = 0.03
    /// 절편 외 항 수 ≤ 그룹 수 − margin 인 구조만 후보로 쓴다(과적합 방지).
    public var groupMargin: Int = 3
    /// 보조 항 릿지 계수 하한. 보정 중 거의 변하지 않은 보조 특징은 교차검증으로 λ를 가릴 수 없으므로,
    /// 우연한 상관으로 큰 가중치를 얻어 나중에 예측이 튀지 않게 최소 수축을 건다.
    public var auxiliaryLambdaFloor: Double = 0.05

    public init(kind: CalibrationModel.Kind? = nil) { self.kind = kind }
}

/// 디스플레이 하나에 대한 특징 → 화면 좌표 회귀 모델.
///
/// 특징을 z-점수(척도 하한 포함)로 표준화한 뒤 primary 2차원은 1차 또는 2차 다항식(1, x, y[, x², y², xy]),
/// auxiliary는 선형 항(없음 / 머리 자세 / 전부)으로 확장하고 그룹 가중 릿지 회귀를 푼다.
/// 구조와 릿지 계수는 그룹(표적) 단위 교차검증으로 고르며, 비슷하면 항이 적은 쪽을 고른다.
/// 오차는 그룹 단위 교차검증 잔차(+ 검증 단계 오차)로 추정해 불확실성 반경에 쓴다.
public struct CalibrationModel: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable { case linear, quadratic }
    public enum AuxiliaryTerms: String, Sendable, Codable { case none, head, all }

    public struct Structure: Sendable, Codable, Equatable, Hashable {
        public var kind: Kind
        public var auxiliary: AuxiliaryTerms
        public init(kind: Kind, auxiliary: AuxiliaryTerms) { self.kind = kind; self.auxiliary = auxiliary }

        func columns(auxiliaryCount: Int, headCount: Int) -> [Int] {
            var columns = kind == .linear ? [0, 1, 2] : [0, 1, 2, 3, 4, 5]
            switch auxiliary {
            case .none: break
            case .head: columns += (0..<min(headCount, auxiliaryCount)).map { 6 + $0 }
            case .all: columns += (0..<auxiliaryCount).map { 6 + $0 }
            }
            return columns
        }
    }

    /// 표적 위치(디스플레이 로컬 좌표)별 교차검증 RMS 오차.
    public struct ResidualAnchor: Sendable, Codable, Equatable {
        public let point: CGPoint
        public let rmse: Double
    }

    /// 후보 구조별 교차검증 결과(진단용).
    public struct StructureScore: Sendable, Codable, Equatable {
        public let structure: Structure
        public let lambda: Double
        public let crossValidatedRMSE: Double
    }

    /// 검증 단계(보정에 쓰지 않은 새 점) 결과 요약.
    public struct ValidationSummary: Sendable, Codable, Equatable {
        public var meanError: Double
        public var rmse: Double
        public var maxError: Double
        public var meanErrorCm: Double?
        public var pointCount: Int
        public init(meanError: Double, rmse: Double, maxError: Double, meanErrorCm: Double?, pointCount: Int) {
            self.meanError = meanError; self.rmse = rmse; self.maxError = maxError; self.meanErrorCm = meanErrorCm
            self.pointCount = pointCount
        }
    }

    public let display: DisplayGeometry
    public internal(set) var revision: Int
    public let estimatorID: String
    public let kind: Kind
    public let auxiliaryTerms: AuxiliaryTerms
    public let headAuxiliaryCount: Int
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
    /// 보정·검증 점(그룹) 수.
    public let targetCount: Int
    public let sampleCount: Int
    /// 학습에 쓴 암묵(클릭) 표본 수.
    public let implicitCount: Int
    public internal(set) var validation: ValidationSummary?
    public let structureScores: [StructureScore]

    public var structure: Structure { Structure(kind: kind, auxiliary: auxiliaryTerms) }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        display = try c.decode(DisplayGeometry.self, forKey: .display)
        revision = try c.decode(Int.self, forKey: .revision)
        estimatorID = try c.decodeIfPresent(String.self, forKey: .estimatorID) ?? LandmarkGazeEstimator.identifier
        kind = try c.decode(Kind.self, forKey: .kind)
        // 예전 모델은 보조 특징을 모두 선형 항으로 썼다.
        auxiliaryTerms = try c.decodeIfPresent(AuxiliaryTerms.self, forKey: .auxiliaryTerms) ?? .all
        headAuxiliaryCount = try c.decodeIfPresent(Int.self, forKey: .headAuxiliaryCount) ?? 2
        lambda = try c.decode(Double.self, forKey: .lambda)
        featureDimension = try c.decode(Int.self, forKey: .featureDimension)
        featureMean = try c.decode([Double].self, forKey: .featureMean)
        featureScale = try c.decode([Double].self, forKey: .featureScale)
        weightsX = try c.decode([Double].self, forKey: .weightsX)
        weightsY = try c.decode([Double].self, forKey: .weightsY)
        crossValidatedRMSE = try c.decode(Double.self, forKey: .crossValidatedRMSE)
        trainingRMSE = try c.decode(Double.self, forKey: .trainingRMSE)
        residualAnchors = try c.decode([ResidualAnchor].self, forKey: .residualAnchors)
        targetCount = try c.decode(Int.self, forKey: .targetCount)
        sampleCount = try c.decode(Int.self, forKey: .sampleCount)
        implicitCount = try c.decodeIfPresent(Int.self, forKey: .implicitCount) ?? 0
        validation = try c.decodeIfPresent(ValidationSummary.self, forKey: .validation)
        structureScores = try c.decodeIfPresent([StructureScore].self, forKey: .structureScores) ?? []
    }

    init(display: DisplayGeometry, revision: Int, estimatorID: String, kind: Kind, auxiliaryTerms: AuxiliaryTerms,
         headAuxiliaryCount: Int, lambda: Double, featureDimension: Int, featureMean: [Double], featureScale: [Double],
         weightsX: [Double], weightsY: [Double], crossValidatedRMSE: Double, trainingRMSE: Double,
         residualAnchors: [ResidualAnchor], targetCount: Int, sampleCount: Int, implicitCount: Int,
         validation: ValidationSummary?, structureScores: [StructureScore]) {
        self.display = display; self.revision = revision; self.estimatorID = estimatorID; self.kind = kind
        self.auxiliaryTerms = auxiliaryTerms; self.headAuxiliaryCount = headAuxiliaryCount; self.lambda = lambda
        self.featureDimension = featureDimension; self.featureMean = featureMean; self.featureScale = featureScale
        self.weightsX = weightsX; self.weightsY = weightsY; self.crossValidatedRMSE = crossValidatedRMSE
        self.trainingRMSE = trainingRMSE; self.residualAnchors = residualAnchors; self.targetCount = targetCount
        self.sampleCount = sampleCount; self.implicitCount = implicitCount; self.validation = validation
        self.structureScores = structureScores
    }

    /// 검증 결과를 붙인 사본.
    public func withValidation(_ summary: ValidationSummary?) -> CalibrationModel {
        var copy = self
        copy.validation = summary
        return copy
    }

    // MARK: 예측

    /// 디스플레이 로컬 좌표(디스플레이 좌상단 원점) 예측. 특징 차원이 다르면 nil.
    public func predictLocal(_ features: GazeFeatures) -> CGPoint? {
        let raw = features.vector
        guard raw.count == featureDimension else { return nil }
        let phi = Self.expand(standardize(raw), structure: structure, headCount: headAuxiliaryCount)
        guard phi.count == weightsX.count else { return nil }
        return CGPoint(x: RidgeRegression.dot(weightsX, phi), y: RidgeRegression.dot(weightsY, phi))
    }

    /// 전역 좌표 예측(클램프하지 않음).
    public func predict(_ features: GazeFeatures) -> CGPoint? {
        predictLocal(features).map { CGPoint(x: $0.x + display.frame.minX, y: $0.y + display.frame.minY) }
    }

    /// 대표 오차(포인트): 교차검증과 검증 단계 RMS 중 큰 값.
    public var expectedRMSE: Double { max(crossValidatedRMSE, validation?.rmse ?? 0) }

    /// 로컬 좌표 근처 표적들의 교차검증 오차를 역거리 가중으로 보간한다. 검증 오차가 더 크면 그 값을 쓴다.
    public func expectedError(atLocal point: CGPoint) -> Double {
        let floor = validation?.rmse ?? 0
        guard !residualAnchors.isEmpty else { return max(crossValidatedRMSE, floor) }
        let diagonal = Double(hypot(display.frame.width, display.frame.height))
        let softening = max(1, diagonal * 0.1)
        var weighted = 0.0, total = 0.0
        for anchor in residualAnchors {
            let d = anchor.point.distance(to: point)
            let w = 1 / (d * d + softening * softening)
            weighted += w * anchor.rmse * anchor.rmse
            total += w
        }
        return max((weighted / total).squareRoot(), floor)
    }

    func standardize(_ raw: [Double]) -> [Double] {
        (0..<raw.count).map { (raw[$0] - featureMean[$0]) / featureScale[$0] }
    }

    static func expand(_ z: [Double], structure: Structure, headCount: Int) -> [Double] {
        let x = z[0], y = z[1]
        var phi = structure.kind == .linear ? [1, x, y] : [1, x, y, x * x, y * y, x * y]
        let auxiliary = z.dropFirst(2)
        switch structure.auxiliary {
        case .none: break
        case .head: phi += auxiliary.prefix(headCount)
        case .all: phi += auxiliary
        }
        return phi
    }

    /// 2차 + 보조 전부를 담은 전체 확장(열 인덱스는 `Structure.columns`).
    static func fullExpansion(_ z: [Double]) -> [Double] {
        let x = z[0], y = z[1]
        return [1, x, y, x * x, y * y, x * y] + z.dropFirst(2)
    }

    static func termCount(_ structure: Structure, auxiliaryCount: Int, headCount: Int) -> Int {
        structure.columns(auxiliaryCount: auxiliaryCount, headCount: headCount).count
    }

    // MARK: 적합

    struct TargetKey: Hashable { let x: Double; let y: Double }

    /// 그룹별 충분 통계(가중 정규방정식 조각).
    struct GroupStats {
        var gram: [Double]
        var bx: [Double]
        var by: [Double]
        var yy = 0.0
        var weight = 0.0
        var sampleCount = 0
        var isAnchor = false
        var anchorPoint = CGPoint.zero

        init(dimension p: Int) {
            gram = [Double](repeating: 0, count: p * p)
            bx = [Double](repeating: 0, count: p)
            by = [Double](repeating: 0, count: p)
        }

        mutating func add(_ phi: [Double], target: SIMD2<Double>, weight w: Double) {
            let p = phi.count
            for i in 0..<p {
                let wi = w * phi[i]
                bx[i] += wi * target.x
                by[i] += wi * target.y
                for j in i..<p { gram[i * p + j] += wi * phi[j] }
            }
            yy += w * (target.x * target.x + target.y * target.y)
            weight += w
            sampleCount += 1
        }

        mutating func symmetrize(_ p: Int) {
            for i in 0..<p { for j in 0..<i { gram[i * p + j] = gram[j * p + i] } }
        }
    }

    /// 열 부분집합에 대한 릿지 해. gram/b는 전체 확장 차원(p) 기준.
    static func solve(gram: [Double], bx: [Double], by: [Double], p: Int, columns: [Int], lambda: Double,
                      auxiliaryLambda: Double = 0, trainWeight: Double) -> (x: [Double], y: [Double])? {
        let k = columns.count
        var a = [Double](repeating: 0, count: k * k)
        for (r, i) in columns.enumerated() {
            for (c, j) in columns.enumerated() { a[r * k + c] = gram[i * p + j] }
            // 열 0은 절편, 1–5는 primary(1차·2차), 6 이상은 보조 항.
            if r > 0 { a[r * k + r] += (i >= 6 ? max(lambda, auxiliaryLambda) : lambda) * trainWeight }
        }
        guard let solved = LinearAlgebra.choleskySolve(a, n: k, rhs: [columns.map { bx[$0] }, columns.map { by[$0] }])
        else { return nil }
        return (solved[0], solved[1])
    }

    /// 그룹 하나의 가중 제곱오차 합(충분 통계로 계산).
    static func groupSSE(_ g: GroupStats, p: Int, columns: [Int], solution: (x: [Double], y: [Double])) -> Double {
        var sse = g.yy
        for (r, i) in columns.enumerated() {
            sse -= 2 * (solution.x[r] * g.bx[i] + solution.y[r] * g.by[i])
            for (c, j) in columns.enumerated() {
                let gij = g.gram[i * p + j]
                sse += gij * (solution.x[r] * solution.x[c] + solution.y[r] * solution.y[c])
            }
        }
        return max(sse, 0)
    }

    public static func fit(samples: [CalibrationSample], display: DisplayGeometry, revision: Int = 0,
                           options: CalibrationOptions = .init()) throws -> CalibrationModel {
        guard let dimension = samples.first?.features.vector.count, dimension >= 2 else {
            throw CalibrationError.insufficientTargets(found: 0, required: options.minimumTargets)
        }
        guard samples.allSatisfy({ $0.features.vector.count == dimension }) else {
            throw CalibrationError.inconsistentFeatureDimensions
        }
        // 그룹: 보정·검증 점은 위치별(최소 표본 수 이상), 암묵 표본은 하나씩.
        var explicitGroups: [TargetKey: [CalibrationSample]] = [:]
        var implicitGroups: [[CalibrationSample]] = []
        for sample in samples where sample.weight > 0 && sample.weight.isFinite {
            if sample.source == .implicit {
                implicitGroups.append([sample])
            } else {
                explicitGroups[TargetKey(x: Double(sample.target.x), y: Double(sample.target.y)), default: []].append(sample)
            }
        }
        let keys = explicitGroups.filter { $0.value.count >= options.minimumSamplesPerTarget }.keys
            .sorted { ($0.y, $0.x) < ($1.y, $1.x) }
        guard keys.count >= options.minimumTargets else {
            throw CalibrationError.insufficientTargets(found: keys.count, required: options.minimumTargets)
        }
        let groups: [[CalibrationSample]] = keys.map { explicitGroups[$0]! } + implicitGroups
        let origin = SIMD2<Double>(Double(display.frame.minX), Double(display.frame.minY))
        let auxiliaryCount = dimension - 2
        let headCount = min(options.headAuxiliaryCount, auxiliaryCount)

        // 표준화(표본 단순 평균·표준편차, 척도 하한 적용).
        let all = groups.flatMap { $0 }
        let n = Double(all.count)
        var mean = [Double](repeating: 0, count: dimension), scale = [Double](repeating: 1, count: dimension)
        for i in 0..<dimension {
            let column = all.map { $0.features.vector[i] }
            let m = column.reduce(0, +) / n
            let variance = column.reduce(0) { $0 + ($1 - m) * ($1 - m) } / n
            mean[i] = m
            let floor = i < options.scaleFloors.count ? options.scaleFloors[i] : 0
            if floor > 0 {
                scale[i] = max(variance.squareRoot(), floor)
            } else {
                scale[i] = variance > 1e-18 ? variance.squareRoot() : 1
            }
        }

        // 그룹 가중치: 보정 점은 표본 가중치 평균(보통 1), 암묵 표본은 그 가중치. 그룹 안에서는 균등 분배.
        // 표적 좌표는 가중 평균을 빼서 수치 오차를 줄인다(절편에 되돌린다).
        let groupWeights = groups.map { g in g.reduce(0) { $0 + $1.weight } / Double(g.count) }
        let totalWeight = groupWeights.reduce(0, +)
        var center = SIMD2<Double>(0, 0)
        for (g, group) in groups.enumerated() {
            for sample in group {
                center += (SIMD2(Double(sample.target.x), Double(sample.target.y)) - origin) * (groupWeights[g] / Double(group.count))
            }
        }
        center /= max(totalWeight, 1e-12)

        let p = 6 + auxiliaryCount
        var stats: [GroupStats] = []
        for (g, group) in groups.enumerated() {
            var s = GroupStats(dimension: p)
            let w = groupWeights[g] / Double(group.count)
            for sample in group {
                let raw = sample.features.vector
                let z = (0..<dimension).map { (raw[$0] - mean[$0]) / scale[$0] }
                let target = SIMD2(Double(sample.target.x), Double(sample.target.y)) - origin - center
                s.add(fullExpansion(z), target: target, weight: w)
            }
            s.symmetrize(p)
            if g < keys.count {
                s.isAnchor = true
                s.anchorPoint = CGPoint(x: keys[g].x - origin.x, y: keys[g].y - origin.y)
            }
            stats.append(s)
        }
        var total = GroupStats(dimension: p)
        for s in stats {
            for i in 0..<(p * p) { total.gram[i] += s.gram[i] }
            for i in 0..<p { total.bx[i] += s.bx[i]; total.by[i] += s.by[i] }
            total.yy += s.yy
            total.weight += s.weight
        }

        // 후보 구조.
        let groupCount = stats.count
        var candidates: [Structure]
        if let explicit = options.structures {
            candidates = explicit
        } else {
            let kinds: [Kind] = options.kind.map { [$0] } ?? [.linear, .quadratic]
            var auxiliaryOptions: [AuxiliaryTerms] = [.none]
            if auxiliaryCount > 0 { auxiliaryOptions += headCount > 0 && headCount < auxiliaryCount ? [.head, .all] : [.all] }
            candidates = kinds.flatMap { k in auxiliaryOptions.map { Structure(kind: k, auxiliary: $0) } }
        }
        let allowed = candidates.filter {
            termCount($0, auxiliaryCount: auxiliaryCount, headCount: headCount) - 1 <= groupCount - options.groupMargin
        }
        if !allowed.isEmpty { candidates = allowed } else {
            candidates = [candidates.min { termCount($0, auxiliaryCount: auxiliaryCount, headCount: headCount)
                < termCount($1, auxiliaryCount: auxiliaryCount, headCount: headCount) }
                ?? Structure(kind: .linear, auxiliary: .none)]
        }

        /// 그룹 하나씩 빼고 학습·예측한 그룹별 가중 제곱오차 합.
        func crossValidate(_ columns: [Int], _ lambda: Double) -> [Double]? {
            var sse: [Double] = []
            sse.reserveCapacity(groupCount)
            var gram = total.gram, bx = total.bx, by = total.by
            for s in stats {
                for i in 0..<(p * p) { gram[i] = total.gram[i] - s.gram[i] }
                for i in 0..<p { bx[i] = total.bx[i] - s.bx[i]; by[i] = total.by[i] - s.by[i] }
                guard let solution = solve(gram: gram, bx: bx, by: by, p: p, columns: columns, lambda: lambda,
                                           auxiliaryLambda: options.auxiliaryLambdaFloor,
                                           trainWeight: total.weight - s.weight) else { return nil }
                sse.append(groupSSE(s, p: p, columns: columns, solution: solution))
            }
            return sse
        }

        var scores: [StructureScore] = []
        var best: (structure: Structure, lambda: Double, perGroup: [Double]?, score: Double)?
        var perStructure: [(Structure, Double, [Double]?, Double)] = []
        if groupCount >= 4 {
            for structure in candidates {
                let columns = structure.columns(auxiliaryCount: auxiliaryCount, headCount: headCount)
                var chosen: (Double, [Double], Double)?
                for lambda in options.lambdas {
                    guard let sse = crossValidate(columns, lambda) else { continue }
                    let score = (sse.reduce(0, +) / max(total.weight, 1e-12)).squareRoot()
                    if chosen == nil || score < chosen!.2 { chosen = (lambda, sse, score) }
                }
                if let chosen {
                    perStructure.append((structure, chosen.0, chosen.1, chosen.2))
                    scores.append(StructureScore(structure: structure, lambda: chosen.0, crossValidatedRMSE: chosen.2))
                }
            }
            if let bestScore = perStructure.map(\.3).min() {
                // 최선의 (1 + tol)배 이내에서 항이 가장 적은 구조.
                let limit = bestScore * (1 + options.parsimonyTolerance)
                let simplest = perStructure.filter { $0.3 <= limit }.min {
                    let a = termCount($0.0, auxiliaryCount: auxiliaryCount, headCount: headCount)
                    let b = termCount($1.0, auxiliaryCount: auxiliaryCount, headCount: headCount)
                    return a == b ? $0.3 < $1.3 : a < b
                }
                if let simplest { best = (simplest.0, simplest.1, simplest.2, simplest.3) }
            }
        }
        let structure = best?.structure ?? candidates.last!
        let lambda = best?.lambda ?? (options.lambdas.first ?? 1e-2)
        let columns = structure.columns(auxiliaryCount: auxiliaryCount, headCount: headCount)
        guard let solution = solve(gram: total.gram, bx: total.bx, by: total.by, p: p, columns: columns,
                                   lambda: lambda, auxiliaryLambda: options.auxiliaryLambdaFloor,
                                   trainWeight: total.weight) else {
            throw CalibrationError.singularSystem
        }

        let trainingPerGroup = stats.map { (groupSSE($0, p: p, columns: columns, solution: solution) / max($0.weight, 1e-12)).squareRoot() }
        let trainingRMSE = (zip(trainingPerGroup, stats).reduce(0) { $0 + $1.0 * $1.0 * $1.1.weight }
            / max(total.weight, 1e-12)).squareRoot()
        let cvPerGroup = best?.perGroup.map { sse in zip(sse, stats).map { ($0 / max($1.weight, 1e-12)).squareRoot() } }
        let cvRMSE = best?.score ?? trainingRMSE * 2
        var anchors: [ResidualAnchor] = []
        for (g, s) in stats.enumerated() where s.isAnchor {
            let cv = cvPerGroup?[g] ?? trainingPerGroup[g] * 2
            anchors.append(ResidualAnchor(point: s.anchorPoint, rmse: max(cv, trainingPerGroup[g])))
        }
        // 중심화한 표적을 절편으로 되돌린다.
        var weightsX = solution.x, weightsY = solution.y
        weightsX[0] += center.x
        weightsY[0] += center.y
        return CalibrationModel(
            display: display, revision: revision, estimatorID: options.estimatorID, kind: structure.kind,
            auxiliaryTerms: structure.auxiliary, headAuxiliaryCount: headCount, lambda: lambda,
            featureDimension: dimension, featureMean: mean, featureScale: scale, weightsX: weightsX, weightsY: weightsY,
            crossValidatedRMSE: max(cvRMSE, trainingRMSE), trainingRMSE: trainingRMSE, residualAnchors: anchors,
            targetCount: keys.count, sampleCount: all.count, implicitCount: implicitGroups.count, validation: nil,
            structureScores: scores)
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
/// 암묵 재보정(`refine`)은 좌표계가 크게 바뀌지 않으므로 리비전을 유지한다(하류 버퍼를 비우지 않는다).
public struct CalibrationStore: Sendable {
    public private(set) var revision: Int = 0
    public private(set) var models: [UInt32: CalibrationModel] = [:]
    public private(set) var displays: [DisplayGeometry] = []
    /// 설정하면 다른 추정기로 학습된 모델은 설치하지 않는다.
    public private(set) var estimatorID: String?
    /// 두 디스플레이 모두 예측을 포함할 때 직전 디스플레이를 유지하는 여유(정규화 거리).
    public var displayMargin: Double = 0.05

    public init(displays: [DisplayGeometry] = []) {
        self.displays = displays
    }

    public func model(for displayID: UInt32) -> CalibrationModel? { models[displayID] }

    /// 추정기를 바꾼다. 다른 추정기 모델은 무효화하고 그 디스플레이 ID를 돌려준다.
    @discardableResult
    public mutating func setEstimator(_ id: String?) -> [UInt32] {
        estimatorID = id
        guard let id else { return [] }
        let stale = models.values.filter { $0.estimatorID != id }.map(\.display.id).sorted()
        for display in stale { invalidate(displayID: display) }
        return stale
    }

    /// 모델을 새 리비전으로 설치한다. 모델이 현재 디스플레이 배치·추정기와 맞지 않으면 거부한다.
    @discardableResult
    public mutating func install(_ model: CalibrationModel) throws -> CalibrationModel {
        try validate(model)
        revision += 1
        var installed = model
        installed.revision = revision
        models[model.display.id] = installed
        return installed
    }

    /// 같은 디스플레이 모델을 리비전 유지로 교체한다(암묵 재보정·검증 결과 첨부). 기존 모델이 없으면 설치.
    @discardableResult
    public mutating func refine(_ model: CalibrationModel) throws -> CalibrationModel {
        try validate(model)
        guard let current = models[model.display.id] else { return try install(model) }
        var refined = model
        refined.revision = current.revision
        models[model.display.id] = refined
        return refined
    }

    private func validate(_ model: CalibrationModel) throws {
        if !displays.isEmpty, !displays.contains(model.display) {
            throw CalibrationError.displayMismatch(model.display.id)
        }
        if let estimatorID, model.estimatorID != estimatorID {
            throw CalibrationError.estimatorMismatch(model.estimatorID)
        }
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

/// 표적 하나의 수집 결과.
public struct CalibrationTargetResult: Sendable, Equatable {
    public enum Issue: String, Sendable, Equatable {
        /// 얼굴·눈이 잘 안 보여 채택 표본이 부족하다.
        case insufficientSamples
        /// 표적을 보는 동안 머리가 많이 움직였다.
        case headMoved
    }

    public var target: CGPoint
    /// 정착 구간 뒤 받은 표본 수.
    public var collected: Int
    /// 신뢰도·이상치 제거 뒤 남은 표본 수.
    public var accepted: Int
    /// 얼굴 중심 이동(얼굴 폭 비율, 90백분위).
    public var headTranslation: Double
    /// 머리 회전 변화(라디안, 90백분위).
    public var headRotation: Double
    public var issue: Issue?
    /// 표본을 학습 데이터에 넣었는지(문제가 있는 첫 시도는 버리고 다시 볼 수 있다).
    public var committed: Bool

    public init(target: CGPoint, collected: Int, accepted: Int, headTranslation: Double, headRotation: Double,
                issue: Issue?, committed: Bool) {
        self.target = target; self.collected = collected; self.accepted = accepted
        self.headTranslation = headTranslation; self.headRotation = headRotation; self.issue = issue
        self.committed = committed
    }
}

/// 보정 표적별 특징 수집기. 표적이 나타난 직후(사케이드 지연)는 버리고, 표적별 이상치를 제거하고,
/// 머리 움직임을 잰다.
public struct CalibrationCollector: Sendable {
    public let display: DisplayGeometry
    /// 표적 표시 후 이 시간 동안의 표본은 버린다(초). `beginTarget(_:at:settle:)`로 표적마다 바꿀 수 있다.
    public var settleDuration: Double = 0.35
    /// primary 특징의 축별 중앙값·MAD로 정규화한 거리가 이보다 크면 버린다(σ 단위).
    public var outlierThreshold: Double = 3.5
    public var minimumConfidence: Double = 0.2
    /// 채택 표본이 이보다 적으면 `insufficientSamples`.
    public var minimumAcceptedSamples: Int = 6
    /// 얼굴 중심 이동 한계(얼굴 폭 비율, 약 2cm).
    public var maximumHeadTranslation: Double = 0.15
    /// 머리 회전 변화 한계(라디안, 약 5°).
    public var maximumHeadRotation: Double = 0.09
    /// 이 수집기가 만드는 표본 종류(보정 / 검증).
    public var source: CalibrationSample.Source = .target
    public private(set) var samples: [CalibrationSample] = []
    public private(set) var targetCount = 0
    public private(set) var results: [CalibrationTargetResult] = []

    private var activeTarget: CGPoint?
    private var activeSince: MonotonicTime?
    private var activeSettle: Double?
    private var pending: [GazeFeatures] = []
    private var collected = 0

    public init(display: DisplayGeometry, source: CalibrationSample.Source = .target) {
        self.display = display
        self.source = source
    }

    public var isCollecting: Bool { activeTarget != nil }

    public mutating func beginTarget(_ target: CGPoint, at time: MonotonicTime, settle: Double? = nil) {
        activeTarget = target
        activeSince = time
        activeSettle = settle
        pending.removeAll()
        collected = 0
    }

    public mutating func add(_ features: GazeFeatures) {
        guard activeTarget != nil, let since = activeSince,
              features.time.seconds(since: since) >= (activeSettle ?? settleDuration) else { return }
        collected += 1
        guard features.confidence >= minimumConfidence else { return }
        pending.append(features)
    }

    /// 현재 표적을 마무리하고 채택된 표본 수를 돌려준다(문제가 있어도 저장).
    @discardableResult
    public mutating func endTarget() -> Int {
        endTargetDetailed(rejectFlagged: false)?.accepted ?? 0
    }

    /// 현재 표적을 마무리한다. `rejectFlagged`이면 문제가 있는 표적은 저장하지 않는다(다시 보기용).
    public mutating func endTargetDetailed(rejectFlagged: Bool) -> CalibrationTargetResult? {
        guard let target = activeTarget else { return nil }
        defer { activeTarget = nil; activeSince = nil; activeSettle = nil; pending.removeAll(); collected = 0 }
        let accepted = Self.rejectOutliers(pending, threshold: outlierThreshold)
        let motion = Self.headMotion(accepted)
        var issue: CalibrationTargetResult.Issue?
        if accepted.count < minimumAcceptedSamples {
            issue = .insufficientSamples
        } else if motion.translation > maximumHeadTranslation || motion.rotation > maximumHeadRotation {
            issue = .headMoved
        }
        let commit = !accepted.isEmpty && !(rejectFlagged && issue != nil)
        if commit {
            samples += accepted.map { CalibrationSample(features: $0, target: target, source: source) }
            targetCount += 1
        }
        let result = CalibrationTargetResult(target: target, collected: collected, accepted: accepted.count,
                                             headTranslation: motion.translation, headRotation: motion.rotation,
                                             issue: issue, committed: commit)
        results.append(result)
        return result
    }

    public mutating func abortTarget() {
        activeTarget = nil; activeSince = nil; activeSettle = nil; pending.removeAll(); collected = 0
    }

    public func fit(revision: Int = 0, options: CalibrationOptions = .init()) throws -> CalibrationModel {
        try CalibrationModel.fit(samples: samples, display: display, revision: revision, options: options)
    }

    /// 축별 중앙값·MAD(×1.4826, 하한 있음)로 정규화한 primary 거리가 `threshold`보다 먼 표본을 버린다.
    static func rejectOutliers(_ features: [GazeFeatures], threshold: Double) -> [GazeFeatures] {
        guard features.count >= 4 else { return features }
        let mx = median(features.map(\.primary.x)), my = median(features.map(\.primary.y))
        let sx = 1.4826 * median(features.map { abs($0.primary.x - mx) })
        let sy = 1.4826 * median(features.map { abs($0.primary.y - my) })
        // 한 축의 MAD가 0이면(양자화된 특징) 다른 축 척도의 2%를 하한으로 쓴다.
        let floor = max(max(sx, sy) * 0.02, 1e-9)
        let scaleX = max(sx, floor), scaleY = max(sy, floor)
        return features.filter {
            let dx = ($0.primary.x - mx) / scaleX, dy = ($0.primary.y - my) / scaleY
            return (dx * dx + dy * dy).squareRoot() <= threshold
        }
    }

    /// 표본들의 머리 이동(얼굴 폭 비율)·회전(라디안) 90백분위. 정보가 없으면 0.
    static func headMotion(_ features: [GazeFeatures]) -> (translation: Double, rotation: Double) {
        let boxes = features.compactMap(\.faceBox)
        var translation = 0.0
        if boxes.count >= 3 {
            let cx = median(boxes.map { Double($0.midX) }), cy = median(boxes.map { Double($0.midY) })
            let width = max(median(boxes.map { Double($0.width) }), 1e-6)
            translation = percentile(boxes.map { hypot(Double($0.midX) - cx, Double($0.midY) - cy) / width }, 0.9)
        }
        let poses = features.compactMap(\.headPose)
        var rotation = 0.0
        if poses.count >= 3 {
            let yaw = median(poses.map(\.yaw)), pitch = median(poses.map(\.pitch))
            rotation = percentile(poses.map { hypot($0.yaw - yaw, $0.pitch - pitch) }, 0.9)
        }
        return (translation, rotation)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[clamp(Int((Double(sorted.count - 1) * p).rounded()), 0, sorted.count - 1)]
    }
}

/// 검증 단계 결과. 보정에 쓰지 않은 새 점을 보고 있을 때의 예측 오차.
public struct CalibrationValidationReport: Sendable, Equatable, Codable {
    public struct Point: Sendable, Equatable, Codable {
        public let target: CGPoint
        public let predicted: CGPoint
        public let error: Double
        public let sampleCount: Int
    }

    public let displayID: UInt32
    public let points: [Point]
    public let meanError: Double
    public let medianError: Double
    public let rmse: Double
    public let maxError: Double
    /// 디스플레이 물리 크기로 구한 cm당 포인트(모르면 nil).
    public let pointsPerCentimeter: Double?
    /// 측정 표본이 없어 빠진 점 수.
    public let missingPoints: Int

    public var meanErrorCm: Double? { pointsPerCentimeter.map { meanError / $0 } }
    public var rmseCm: Double? { pointsPerCentimeter.map { rmse / $0 } }
    public var maxErrorCm: Double? { pointsPerCentimeter.map { maxError / $0 } }

    public var summary: CalibrationModel.ValidationSummary {
        .init(meanError: meanError, rmse: rmse, maxError: maxError, meanErrorCm: meanErrorCm, pointCount: points.count)
    }
}

public enum CalibrationValidation {
    /// 표적별 예측의 축별 중앙값(디스플레이 안으로 클램프)과 표적의 거리로 오차를 잰다.
    public static func evaluate(model: CalibrationModel, targets: [(target: CGPoint, features: [GazeFeatures])],
                                pointsPerCentimeter: Double?) -> CalibrationValidationReport {
        var points: [CalibrationValidationReport.Point] = []
        var missing = 0
        for entry in targets {
            let predictions = entry.features.compactMap { model.predict($0) }.filter { $0.x.isFinite && $0.y.isFinite }
                .map { model.display.clamp($0) }
            guard !predictions.isEmpty else { missing += 1; continue }
            let predicted = CGPoint(x: CalibrationCollector.median(predictions.map { Double($0.x) }),
                                    y: CalibrationCollector.median(predictions.map { Double($0.y) }))
            points.append(.init(target: entry.target, predicted: predicted, error: predicted.distance(to: entry.target),
                                sampleCount: predictions.count))
        }
        let errors = points.map(\.error)
        let count = Double(max(errors.count, 1))
        return CalibrationValidationReport(
            displayID: model.display.id, points: points,
            meanError: errors.reduce(0, +) / count,
            medianError: CalibrationCollector.median(errors),
            rmse: (errors.reduce(0) { $0 + $1 * $1 } / count).squareRoot(),
            maxError: errors.max() ?? 0,
            pointsPerCentimeter: pointsPerCentimeter, missingPoints: missing)
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

    /// 행마다 방향을 바꾸는(지그재그) 순서. 큰 시선 이동을 줄인다.
    public static func serpentine(rows: Int, columns: Int, in display: DisplayGeometry,
                                  insetFraction: Double = 0.08) -> [CGPoint] {
        let points = grid(rows: rows, columns: columns, in: display, insetFraction: insetFraction)
        var ordered: [CGPoint] = []
        for r in 0..<max(rows, 1) {
            let row = Array(points[(r * columns)..<((r + 1) * columns)])
            ordered += r.isMultiple(of: 2) ? row : row.reversed()
        }
        return ordered
    }

    /// 검증용 5점: 보정 격자와 겹치지 않는 위치(디스플레이 비율).
    public static func validation(in display: DisplayGeometry) -> [CGPoint] {
        let fractions: [(Double, Double)] = [(0.25, 0.28), (0.76, 0.3), (0.5, 0.55), (0.3, 0.8), (0.72, 0.78)]
        return fractions.map { fx, fy in
            CGPoint(x: display.frame.minX + display.frame.width * fx, y: display.frame.minY + display.frame.height * fy)
        }
    }
}
