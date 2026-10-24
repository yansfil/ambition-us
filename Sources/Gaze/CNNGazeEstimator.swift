import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import Synchronization

/// 외형 기반 시선 CNN(yakhyo/gaze-estimation, Gaze360 학습, L2CS-Net 계열) CoreML 추정기.
///
/// 프레임 처리
/// 1. 정렬(랜드마크 무게중심·반경, 없으면 Vision 상자) → One Euro 떨림 억제(`AlignmentFilter`)
///    → RetinaFace형 직사각형 크롭(모델 메타데이터의 배율·세로 이동)
/// 2. `FaceCropSampler`로 448×448 BGRA 버퍼(Python `crop_resize`와 같은 쌍선형 규칙)
/// 3. CoreML: 입력 "image"(ImageType, 0…1 스케일), 그래프 안에서 ImageNet 정규화·빈 기댓값(+좌우 반전 TTA)
///    → "gaze" = [yaw, pitch, yaw 분포 폭, pitch 분포 폭] 라디안
/// 4. 기하: 눈 위치(랜드마크 눈 중심 + 얼굴 폭으로 거리) + 시선 각도 → 화면 평면 교점(cm)
///
/// 특징 배치
/// - primary: 화면 평면 교점(cm, 사용자 시점 x 오른쪽·y 아래, 원점 카메라). 머리가 움직여도 기하적으로 보정된다.
/// - auxiliary: [머리 yaw, 머리 pitch, 얼굴 중심 x, 얼굴 중심 y, 얼굴 폭, 홍채 오프셋 x, 홍채 오프셋 y]
///
/// 비디오 큐에서만 `estimate`를 호출한다(크롭 안정기·버퍼 풀 상태). 통계는 Mutex로 읽는다.
public final class CNNGazeEstimator: GazeEstimator, @unchecked Sendable {
    public struct Configuration: Sendable, Equatable {
        /// nil이면 모델 메타데이터의 크롭 규칙을 쓴다.
        public var crop: FaceCropConfiguration?
        public var alignment = AlignmentFilter.Configuration()
        public var intrinsics = CameraIntrinsics()
        /// Vision 얼굴 상자 폭의 실제 크기 근사(cm). 거리 추정에만 쓰이며 전체 배율은 보정이 흡수한다.
        /// Vision 상자 폭 ≈ 동공 간 거리 × 2.6(표본 16장 중앙값), 성인 동공 간 거리 ≈ 6.3cm.
        public var faceWidthCm = 16.0
        /// 양쪽 눈 모두 이보다 덜 뜨면 깜빡임으로 보고 추론하지 않는다(CNN이 아래 시선으로 오인한다).
        public var minimumEyeOpenness = 0.08
        /// 빈 분포 폭(도, yaw·pitch 평균)이 이 이하면 신뢰도 1, `spreadAtMinimumConfidence`에서 최소.
        /// Gaze360 90빈 분포는 꼬리가 길어 정면 얼굴에서도 폭이 50–65°다(표본 이미지 실측).
        public var spreadAtFullConfidence = 75.0
        public var spreadAtMinimumConfidence = 120.0
        public var minimumSpreadConfidence = 0.3
        public init() {}
    }

    public struct Detail {
        public let features: GazeFeatures?
        public let angles: GazeAngles
        public let cropRect: CGRect
        public let crop: CVPixelBuffer
        public let inferenceMilliseconds: Double
    }

    public let info: GazeModelInfo
    public let configuration: Configuration
    public var identifier: String { info.estimatorID }
    /// [교점 x cm, 교점 y cm, yaw, pitch, 얼굴 x, 얼굴 y, 얼굴 폭, 홍채 x, 홍채 y]
    public var featureScaleFloors: [Double] { Self.defaultFeatureScaleFloors }
    public static let defaultFeatureScaleFloors: [Double] = [0.5, 0.5, 0.05, 0.05, 0.03, 0.03, 0.02, 0.02, 0.02]
    public static let auxiliaryCount = 7

    private let model: MLModel
    private let cropConfiguration: FaceCropConfiguration
    private var alignmentFilter: AlignmentFilter
    private var pool: CVPixelBufferPool?
    private let latency = Mutex(LatencyStats())

    public init(model: MLModel, info: GazeModelInfo, configuration: Configuration = .init()) {
        self.model = model
        self.info = info
        self.configuration = configuration
        cropConfiguration = configuration.crop ?? info.crop
        alignmentFilter = AlignmentFilter(configuration: configuration.alignment)
    }

    public convenience init(loaded: GazeModelStore.Loaded, configuration: Configuration = .init()) {
        self.init(model: loaded.model, info: loaded.info, configuration: configuration)
    }

    public var inferenceLatency: LatencyStats { latency.withLock { $0 } }

    public func resetTracking() { alignmentFilter.reset() }

    public func estimate(_ input: GazeEstimatorInput) throws -> GazeFeatures? {
        try estimateDetailed(input)?.features
    }

    /// 크롭·각도까지 돌려준다(도구·진단용). 깜빡임이거나 크롭을 만들 수 없으면 nil.
    public func estimateDetailed(_ input: GazeEstimatorInput, stabilize: Bool = true) throws -> Detail? {
        guard let buffer = input.pixelBuffer else { return nil }
        let face = input.face
        if Self.eyesClosed(face, minimumOpenness: configuration.minimumEyeOpenness) { return nil }
        let raw = FaceCropGeometry.alignment(face: face)
        let aligned = stabilize ? alignmentFilter.update(raw, at: Double(face.time.nanoseconds) / 1e9) : raw
        let rect = FaceCropGeometry.cropRect(alignment: aligned, configuration: cropConfiguration)
        guard let crop = makeCropBuffer(), FaceCropSampler.sample(pixelBuffer: buffer, crop: rect, into: crop) else {
            return nil
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let angles = try predict(crop: crop)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        latency.withLock { $0.add(elapsed) }
        let features = Self.features(face: face, angles: angles, configuration: configuration)
        return Detail(features: features, angles: angles, cropRect: rect, crop: crop, inferenceMilliseconds: elapsed)
    }

    /// 448×448 BGRA 크롭 → 각도.
    public func predict(crop: CVPixelBuffer) throws -> GazeAngles {
        let provider = try MLDictionaryFeatureProvider(dictionary: [info.inputName: MLFeatureValue(pixelBuffer: crop)])
        let output = try model.prediction(from: provider)
        switch info.outputKind {
        case .continuous:
            guard let array = output.featureValue(for: "gaze")?.multiArrayValue, array.count >= 2 else {
                throw GazeModelError.invalidModel("출력 'gaze'가 없습니다")
            }
            let values = (0..<min(array.count, 4)).map { array[$0].doubleValue }
            return GazeAngles(yaw: values[0], pitch: values[1], yawSpread: values.count > 2 ? values[2] : 0,
                              pitchSpread: values.count > 3 ? values[3] : 0)
        case .logits:
            func logits(_ name: String) -> [Double]? {
                guard let array = output.featureValue(for: name)?.multiArrayValue else { return nil }
                return (0..<array.count).map { array[$0].doubleValue }
            }
            guard let yawLogits = logits("yaw"), let pitchLogits = logits("pitch"),
                  let yaw = GazeBinDecoder.decode(logits: yawLogits, binWidthDegrees: info.binWidthDegrees,
                                                  angleOffsetDegrees: info.angleOffsetDegrees),
                  let pitch = GazeBinDecoder.decode(logits: pitchLogits, binWidthDegrees: info.binWidthDegrees,
                                                    angleOffsetDegrees: info.angleOffsetDegrees)
            else { throw GazeModelError.invalidModel("출력 'yaw'/'pitch' 로짓이 없습니다") }
            return GazeAngles(yaw: yaw.mean, pitch: pitch.mean, yawSpread: yaw.spread, pitchSpread: pitch.spread)
        }
    }

    private func makeCropBuffer() -> CVPixelBuffer? {
        let n = cropConfiguration.outputSize
        if pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: n,
                kCVPixelBufferHeightKey as String: n,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
                                    attributes as CFDictionary, &created)
            pool = created
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    // MARK: 순수 계산

    /// 윤곽이 있는 눈이 모두 `minimumOpenness`보다 감겼으면 true. 눈 윤곽이 없으면 판단하지 않는다(false).
    public static func eyesClosed(_ face: FaceMeasurement, minimumOpenness: Double) -> Bool {
        let geometries = [face.leftEye, face.rightEye].compactMap { eye in
            eye.flatMap { LandmarkGazeEstimator.eyeGeometry($0, imageSize: face.imageSize) }
        }
        guard !geometries.isEmpty else { return false }
        return geometries.allSatisfy { $0.openness < minimumOpenness }
    }

    /// 빈 분포 폭 → 신뢰도 배율.
    public static func spreadConfidence(_ angles: GazeAngles, configuration: Configuration) -> Double {
        let spread = (angles.yawSpread + angles.pitchSpread) / 2 * 180 / .pi
        guard spread > configuration.spreadAtFullConfidence else { return 1 }
        let span = max(configuration.spreadAtMinimumConfidence - configuration.spreadAtFullConfidence, 1e-6)
        let t = (spread - configuration.spreadAtFullConfidence) / span
        return clamp(1 - t * (1 - configuration.minimumSpreadConfidence), configuration.minimumSpreadConfidence, 1)
    }

    /// 눈 중심(픽셀). 랜드마크 눈 윤곽 중심의 평균, 없으면 얼굴 상자 위쪽 40% 지점.
    public static func eyeCenterPixel(_ face: FaceMeasurement) -> CGPoint {
        let w = face.imageSize.width, h = face.imageSize.height
        let centers = [face.leftEye, face.rightEye].compactMap { eye -> CGPoint? in
            guard let contour = eye?.contour, !contour.isEmpty else { return nil }
            let x = contour.reduce(0.0) { $0 + Double($1.x) } / Double(contour.count)
            let y = contour.reduce(0.0) { $0 + Double($1.y) } / Double(contour.count)
            return CGPoint(x: x * w, y: y * h)
        }
        if centers.isEmpty {
            let box = face.boundingBox
            return CGPoint(x: box.midX * w, y: (box.minY + box.height * 0.4) * h)
        }
        let x = centers.reduce(0.0) { $0 + Double($1.x) } / Double(centers.count)
        let y = centers.reduce(0.0) { $0 + Double($1.y) } / Double(centers.count)
        return CGPoint(x: x, y: y)
    }

    /// 얼굴 측정값 + CNN 각도 → 보정 특징. 시선이 화면 평면을 향하지 않으면 nil.
    public static func features(face: FaceMeasurement, angles: GazeAngles,
                                configuration: Configuration = .init()) -> GazeFeatures? {
        let box = face.boundingBox
        let eyePixel = eyeCenterPixel(face)
        let faceWidthPixels = Double(box.width * face.imageSize.width)
        let eye = GazeGeometry.eyePosition(pixel: eyePixel, faceWidthPixels: faceWidthPixels, imageSize: face.imageSize,
                                           intrinsics: configuration.intrinsics, faceWidthCm: configuration.faceWidthCm)
        guard let plane = GazeGeometry.screenPlaneIntersection(eye: eye, yaw: angles.yaw, pitch: angles.pitch),
              plane.x.isFinite, plane.y.isFinite else { return nil }
        let open = [face.leftEye, face.rightEye].compactMap { eye -> LandmarkGazeEstimator.EyeGeometry? in
            guard let eye, let geometry = LandmarkGazeEstimator.eyeGeometry(eye, imageSize: face.imageSize) else { return nil }
            return geometry.openness >= configuration.minimumEyeOpenness ? geometry : nil
        }
        let iris = open.isEmpty ? SIMD2<Double>(0, 0)
            : open.reduce(SIMD2<Double>(0, 0)) { $0 + $1.pupilOffset } / Double(open.count)
        let pose = face.headPose
        let auxiliary = [
            pose?.yaw ?? 0, pose?.pitch ?? 0,
            Double(box.midX), Double(box.midY), Double(box.width),
            iris.x, iris.y,
        ]
        let eyeFactor = open.count == 1 ? 0.85 : 1
        let confidence = clamp(face.confidence * spreadConfidence(angles, configuration: configuration) * eyeFactor, 0, 1)
        return GazeFeatures(time: face.time, primary: plane, auxiliary: auxiliary, headPose: pose,
                            confidence: confidence, gazeAngles: SIMD2(angles.yaw, angles.pitch), faceBox: box)
    }
}

/// 예전 이름 호환(L2CS-Net 빈 디코딩). 새 코드는 `GazeBinDecoder`를 쓴다.
public enum L2CSGazeEstimator {
    public struct ModelSpec: Sendable, Equatable {
        public var binCount = 90
        public var binWidthDegrees = 4.0
        public var angleOffsetDegrees = -180.0
        public init() {}
    }

    /// 빈 로짓 → 기댓값 각도(라디안). 빈 개수가 다르면 nil.
    public static func decodeAngle(logits: [Double], spec: ModelSpec = .init()) -> Double? {
        guard logits.count == spec.binCount else { return nil }
        return GazeBinDecoder.decode(logits: logits, binWidthDegrees: spec.binWidthDegrees,
                                     angleOffsetDegrees: spec.angleOffsetDegrees)?.mean
    }
}
