import AgentContracts
import CoreGraphics
import CoreVideo
import Foundation

/// 머리 자세(라디안). Vision의 `VNFaceObservation` yaw/pitch/roll을 그대로 담는다.
public struct HeadPose: Sendable, Codable, Equatable {
    public var yaw: Double
    public var pitch: Double
    public var roll: Double
    public init(yaw: Double, pitch: Double, roll: Double) {
        self.yaw = yaw; self.pitch = pitch; self.roll = roll
    }
}

/// 보정(calibration) 입력 특징 벡터.
///
/// - `primary`: 시선 방향의 2차원 대리값. 보정 모델이 2차 항까지 확장한다.
///   랜드마크 추정기는 눈 안 동공 오프셋, L2CS-Net은 시선 yaw/pitch(라디안).
/// - `auxiliary`: 선형 항으로만 쓰는 보조 특징(머리 자세, 얼굴 위치·크기 등).
///   같은 추정기라면 항상 같은 길이여야 한다.
public struct GazeFeatures: Sendable, Codable, Equatable {
    public var time: MonotonicTime
    public var primary: SIMD2<Double>
    public var auxiliary: [Double]
    public var headPose: HeadPose?
    public var confidence: Double

    public init(time: MonotonicTime, primary: SIMD2<Double>, auxiliary: [Double] = [],
                headPose: HeadPose? = nil, confidence: Double = 1) {
        self.time = time; self.primary = primary; self.auxiliary = auxiliary
        self.headPose = headPose; self.confidence = confidence
    }

    /// [primary.x, primary.y] + auxiliary
    public var vector: [Double] { [primary.x, primary.y] + auxiliary }
}

/// 한쪽 눈 측정값. 좌표는 이미지 정규화 좌표(0...1, 좌상단 원점, y 아래로 증가).
public struct EyeMeasurement: Sendable, Equatable {
    public var contour: [CGPoint]
    public var pupil: CGPoint?
    public init(contour: [CGPoint], pupil: CGPoint?) {
        self.contour = contour; self.pupil = pupil
    }
}

/// Vision 결과를 Vision 타입 없이 담은 얼굴 측정값. 추정기 입력이자 테스트 픽스처.
public struct FaceMeasurement: Sendable, Equatable {
    public var time: MonotonicTime
    /// 원본 프레임 크기(픽셀).
    public var imageSize: CGSize
    /// 정규화 좌표(좌상단 원점).
    public var boundingBox: CGRect
    public var headPose: HeadPose?
    public var leftEye: EyeMeasurement?
    public var rightEye: EyeMeasurement?
    public var confidence: Double

    public init(time: MonotonicTime, imageSize: CGSize, boundingBox: CGRect, headPose: HeadPose?,
                leftEye: EyeMeasurement?, rightEye: EyeMeasurement?, confidence: Double) {
        self.time = time; self.imageSize = imageSize; self.boundingBox = boundingBox; self.headPose = headPose
        self.leftEye = leftEye; self.rightEye = rightEye; self.confidence = confidence
    }
}

/// 추정기 입력. 이미지 기반 모델(L2CS-Net)을 위해 원본 픽셀 버퍼를 함께 넘긴다.
/// 비디오 큐에서 동기적으로만 쓰이므로 Sendable일 필요가 없다.
public struct GazeEstimatorInput {
    public let face: FaceMeasurement
    public let pixelBuffer: CVPixelBuffer?
    public init(face: FaceMeasurement, pixelBuffer: CVPixelBuffer?) {
        self.face = face; self.pixelBuffer = pixelBuffer
    }
}

/// 얼굴 측정값 → 보정 전 특징 벡터. 랜드마크 추정기와 CoreML(L2CS-Net) 추정기를 바꿔 끼운다.
/// 추정기를 바꾸면 특징 의미가 달라지므로 기존 보정은 다시 해야 한다.
public protocol GazeEstimator: Sendable {
    /// 보정 모델과 짝을 맞추기 위한 식별자.
    var identifier: String { get }
    /// 눈 감김 등으로 추정할 수 없으면 nil.
    func estimate(_ input: GazeEstimatorInput) throws -> GazeFeatures?
}

/// Vision 랜드마크만으로 만드는 특징 추정기(모델 파일 불필요).
///
/// 특징 배치
/// - primary: 양쪽 눈 평균 동공 오프셋 (눈꼬리 축 기준 dx, 수직 dy; 눈 너비로 정규화)
/// - auxiliary: [head yaw, head pitch, 얼굴 중심 x, 얼굴 중심 y, 얼굴 너비] (머리 자세 없으면 0)
public struct LandmarkGazeEstimator: GazeEstimator {
    public struct Configuration: Sendable, Equatable {
        /// 눈 세로/가로 비가 이보다 작으면 깜빡임으로 보고 버린다.
        public var minimumEyeOpenness: Double = 0.12
        /// 한쪽 눈만 유효할 때 신뢰도 배율.
        public var singleEyeConfidence: Double = 0.7
        public init() {}
    }

    public var configuration: Configuration
    public var identifier: String { "landmarks-v1" }
    public static let auxiliaryCount = 5

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public func estimate(_ input: GazeEstimatorInput) -> GazeFeatures? {
        estimate(face: input.face)
    }

    public func estimate(face: FaceMeasurement) -> GazeFeatures? {
        let eyes = [face.leftEye, face.rightEye].compactMap { eye -> EyeGeometry? in
            guard let eye, let geometry = Self.eyeGeometry(eye, imageSize: face.imageSize) else { return nil }
            return geometry.openness >= configuration.minimumEyeOpenness ? geometry : nil
        }
        guard !eyes.isEmpty else { return nil }
        let offset = eyes.reduce(SIMD2<Double>(0, 0)) { $0 + $1.pupilOffset } / Double(eyes.count)
        let pose = face.headPose
        let auxiliary = [
            pose?.yaw ?? 0,
            pose?.pitch ?? 0,
            Double(face.boundingBox.midX),
            Double(face.boundingBox.midY),
            Double(face.boundingBox.width),
        ]
        let eyeFactor = eyes.count == 2 ? 1 : configuration.singleEyeConfidence
        return GazeFeatures(time: face.time, primary: offset, auxiliary: auxiliary, headPose: pose,
                            confidence: clamp(face.confidence * eyeFactor, 0, 1))
    }

    public struct EyeGeometry: Sendable, Equatable {
        /// 눈꼬리 축(u)과 그 수직축(v)에 투영한 동공 오프셋 / 눈 너비.
        public var pupilOffset: SIMD2<Double>
        /// 눈 높이 / 눈 너비.
        public var openness: Double
        /// 눈 너비(픽셀).
        public var width: Double
    }

    /// 눈 윤곽과 동공으로 눈 좌표계를 만든다. 머리 roll은 눈꼬리 축으로 보정된다.
    public static func eyeGeometry(_ eye: EyeMeasurement, imageSize: CGSize) -> EyeGeometry? {
        guard eye.contour.count >= 4, let pupil = eye.pupil else { return nil }
        let w = Double(imageSize.width), h = Double(imageSize.height)
        let points = eye.contour.map { SIMD2<Double>(Double($0.x) * w, Double($0.y) * h) }
        // 가장 먼 두 점을 눈꼬리로 본다.
        var cornerA = points[0], cornerB = points[1], best = -1.0
        for i in points.indices {
            for j in points.indices where j > i {
                let d = simdLength(points[i] - points[j])
                if d > best { best = d; cornerA = points[i]; cornerB = points[j] }
            }
        }
        guard best > 1e-6 else { return nil }
        if cornerA.x > cornerB.x { swap(&cornerA, &cornerB) }
        let u = (cornerB - cornerA) / best
        let v = SIMD2<Double>(-u.y, u.x) // y-down 좌표에서 아래쪽
        let center = points.reduce(SIMD2<Double>(0, 0), +) / Double(points.count)
        let d = SIMD2<Double>(Double(pupil.x) * w, Double(pupil.y) * h) - center
        let vertical = points.map { simdDot($0 - center, v) }
        let openness = ((vertical.max() ?? 0) - (vertical.min() ?? 0)) / best
        return EyeGeometry(pupilOffset: SIMD2(simdDot(d, u) / best, simdDot(d, v) / best),
                           openness: openness, width: best)
    }
}

@inline(__always) func simdDot(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.x + a.y * b.y }
@inline(__always) func simdLength(_ a: SIMD2<Double>) -> Double { (a.x * a.x + a.y * a.y).squareRoot() }
