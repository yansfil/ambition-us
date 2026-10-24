import AgentContracts
import CoreGraphics
import Foundation

/// 클릭 기반 암묵 재보정 설정.
///
/// 사람은 대개 클릭하기 직전에 클릭할 곳을 본다. 클릭 약 150ms 전 특징(창 [−250ms, −50ms]의 중앙값)과
/// 커서 위치를 가중 보정 표본으로 쌓고, 디바운스해서 다시 적합한다. 시간이 지나며 생기는
/// 머리 자세·앉은 자세 변화(드리프트)를 따라간다.
public struct ImplicitCalibrationConfiguration: Sendable, Equatable {
    /// 클릭 전 특징 창(초): [click − windowStart, click − windowEnd].
    public var windowStart = 0.25
    public var windowEnd = 0.05
    public var minimumFrames = 3
    public var minimumConfidence = 0.3
    /// 창 안 프레임별 예측이 중앙값에서 이만큼(RMS, pt) 넘게 퍼지면 시선이 움직이던 중으로 본다.
    public var maximumPredictionSpread = 80.0
    /// 모델이 쓸 만할 때(기대 오차 < decentModelFraction × 대각선)만, 예측과 클릭 거리가
    /// gateFraction × 대각선을 넘는 쌍을 버린다(클릭하며 다른 곳을 본 경우).
    public var gateFraction = 0.25
    public var decentModelFraction = 0.1
    /// 버퍼 최대 크기와 최신성 가중치(반감기, 초).
    public var capacity = 120
    public var halfLife: Double = 1800
    public var baseWeight = 0.5
    public var minimumWeight = 0.02
    /// 명시 보정 표본도 시간이 지나면(자세가 바뀌었을 수 있으니) 가중치를 줄인다. 하한이 있어 모양은 유지된다.
    public var explicitHalfLife: Double = 3600
    public var explicitMinimumWeight = 0.25
    /// 같은 자리(반경 pt, 시간 초) 반복 클릭은 하나로 합친다(한 위치가 과대 대표되지 않게).
    public var mergeRadius = 40.0
    public var mergeWindow = 8.0
    /// 마지막 클릭 후 이만큼 기다렸다가, 직전 재적합에서 최소 간격이 지나면 다시 적합한다(초).
    public var refitDelay = 2.5
    public var minimumRefitInterval = 15.0
    public init() {}
}

extension ImplicitCalibrationConfiguration {
    /// 명시 보정 표본의 나이별 가중치 배율.
    public func explicitWeight(age: TimeInterval) -> Double {
        max(explicitMinimumWeight, pow(0.5, max(age, 0) / max(explicitHalfLife, 1)))
    }
}

extension CalibrationDataset {
    /// 재적합용 학습 표본: 명시 표본(나이 가중) + 암묵 표본(최신성 가중).
    public func trainingSamples(now: Date, configuration: ImplicitCalibrationConfiguration) -> [CalibrationSample] {
        let factor = configuration.explicitWeight(age: now.timeIntervalSince(createdAt))
        let explicit = factor == 1 ? samples : samples.map { sample in
            var weighted = sample
            weighted.weight *= factor
            return weighted
        }
        return explicit + implicit.samples(now: now, configuration: configuration)
    }
}

public enum ImplicitPairRejection: String, Error, Sendable, Equatable {
    case uncalibrated
    case otherDisplay
    case tooFewFrames
    case unstableGaze
    case wildlyOff
    case calibrating
}

public struct ImplicitCalibrationEntry: Sendable, Codable, Equatable {
    public var id: Int
    public var features: GazeFeatures
    public var target: CGPoint
    public var recordedAt: Date
    /// 기록 당시 모델 예측 오차(pt).
    public var predictionError: Double?
}

/// 최신성 가중 암묵 표본 버퍼(디스플레이 하나).
public struct ImplicitCalibrationBuffer: Sendable, Codable, Equatable {
    public private(set) var entries: [ImplicitCalibrationEntry] = []
    private var nextID = 1

    public init() {}

    public var count: Int { entries.count }

    public mutating func add(features: GazeFeatures, target: CGPoint, at date: Date, predictionError: Double?,
                             configuration: ImplicitCalibrationConfiguration = .init()) {
        if let index = entries.lastIndex(where: {
            $0.target.distance(to: target) <= configuration.mergeRadius
                && date.timeIntervalSince($0.recordedAt) <= configuration.mergeWindow
        }) {
            entries[index].features = features
            entries[index].target = target
            entries[index].recordedAt = date
            entries[index].predictionError = predictionError
        } else {
            entries.append(ImplicitCalibrationEntry(id: nextID, features: features, target: target, recordedAt: date,
                                                    predictionError: predictionError))
            nextID += 1
        }
        if entries.count > configuration.capacity { entries.removeFirst(entries.count - configuration.capacity) }
    }

    public static func weight(age: TimeInterval, configuration: ImplicitCalibrationConfiguration) -> Double {
        configuration.baseWeight * pow(0.5, max(age, 0) / max(configuration.halfLife, 1))
    }

    /// 가중치가 너무 작아진 표본을 버린다.
    public mutating func prune(now: Date, configuration: ImplicitCalibrationConfiguration = .init()) {
        entries.removeAll { Self.weight(age: now.timeIntervalSince($0.recordedAt), configuration: configuration)
            < configuration.minimumWeight }
    }

    /// 학습용 표본(그룹 = 항목 하나, 최신성 가중치).
    public func samples(now: Date, configuration: ImplicitCalibrationConfiguration = .init()) -> [CalibrationSample] {
        entries.compactMap { entry in
            let w = Self.weight(age: now.timeIntervalSince(entry.recordedAt), configuration: configuration)
            guard w >= configuration.minimumWeight else { return nil }
            return CalibrationSample(features: entry.features, target: entry.target, source: .implicit, weight: w,
                                     groupID: entry.id)
        }
    }
}

public enum ImplicitCalibration {
    /// 특징 여러 개 → 성분별 중앙값 하나.
    public static func aggregate(_ features: [GazeFeatures]) -> GazeFeatures? {
        guard let last = features.max(by: { $0.time < $1.time }), let dimension = features.first?.vector.count,
              features.allSatisfy({ $0.vector.count == dimension }) else { return nil }
        let median = CalibrationCollector.median
        let vector = (0..<dimension).map { i in median(features.map { $0.vector[i] }) }
        let poses = features.compactMap(\.headPose)
        let pose = poses.count == features.count
            ? HeadPose(yaw: median(poses.map(\.yaw)), pitch: median(poses.map(\.pitch)), roll: median(poses.map(\.roll)))
            : last.headPose
        let angles = features.compactMap(\.gazeAngles)
        let boxes = features.compactMap(\.faceBox)
        return GazeFeatures(
            time: last.time, primary: SIMD2(vector[0], vector[1]), auxiliary: Array(vector.dropFirst(2)), headPose: pose,
            confidence: median(features.map(\.confidence)),
            gazeAngles: angles.count == features.count
                ? SIMD2(median(angles.map(\.x)), median(angles.map(\.y))) : last.gazeAngles,
            faceBox: boxes.count == features.count
                ? CGRect(x: median(boxes.map { Double($0.minX) }), y: median(boxes.map { Double($0.minY) }),
                         width: median(boxes.map { Double($0.width) }), height: median(boxes.map { Double($0.height) }))
                : last.faceBox)
    }

    /// 클릭 직전 특징과 클릭 위치를 짝짓는다. 성공하면 (대표 특징, 현재 모델 예측 오차).
    public static func pair(click: CGPoint, clickTime: MonotonicTime, history: [GazeFeatures], model: CalibrationModel?,
                            configuration: ImplicitCalibrationConfiguration = .init())
        -> Result<(features: GazeFeatures, predictionError: Double), ImplicitPairRejection> {
        guard let model else { return .failure(.uncalibrated) }
        guard model.display.contains(click) else { return .failure(.otherDisplay) }
        let window = history.filter {
            let age = clickTime.seconds(since: $0.time)
            return age >= configuration.windowEnd && age <= configuration.windowStart
                && $0.confidence >= configuration.minimumConfidence
        }
        guard window.count >= configuration.minimumFrames else { return .failure(.tooFewFrames) }
        let predictions = window.compactMap { model.predict($0) }.filter { $0.x.isFinite && $0.y.isFinite }
        guard predictions.count >= configuration.minimumFrames else { return .failure(.tooFewFrames) }
        let center = CGPoint(x: CalibrationCollector.median(predictions.map { Double($0.x) }),
                             y: CalibrationCollector.median(predictions.map { Double($0.y) }))
        let spread = (predictions.reduce(0) { $0 + pow($1.distance(to: center), 2) } / Double(predictions.count)).squareRoot()
        guard spread <= configuration.maximumPredictionSpread else { return .failure(.unstableGaze) }
        guard let aggregated = aggregate(window), let predicted = model.predict(aggregated) else {
            return .failure(.tooFewFrames)
        }
        let error = model.display.clamp(predicted).distance(to: click)
        let diagonal = Double(hypot(model.display.frame.width, model.display.frame.height))
        if model.expectedRMSE < configuration.decentModelFraction * diagonal, error > configuration.gateFraction * diagonal {
            return .failure(.wildlyOff)
        }
        return .success((aggregated, error))
    }
}
