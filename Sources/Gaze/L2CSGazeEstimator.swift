import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import Vision

/// L2CS-Net(Abdelrahman et al., 2022) CoreML 모델용 추정기 자리. 아직 모델 파일이 없어 실기기 검증은 안 됐다.
///
/// 기대하는 모델 형태(coremltools 변환 시 맞춘다)
/// - 입력: 얼굴 크롭 RGB 이미지 448×448. ImageNet 정규화(mean/std)는 `ImageType(scale:bias:)`로 모델 안에 넣는다.
///   크롭·리사이즈는 `VNCoreMLRequest`의 `regionOfInterest` + `.scaleFill`이 처리한다.
/// - 출력: yaw/pitch 각각 90개 빈 로짓(4° 간격, −180°부터). 각도 = Σ softmax(logits)ᵢ·i·4 − 180.
///
/// 특징 배치: primary = (gaze yaw, gaze pitch) 라디안, auxiliary = [얼굴 중심 x, 얼굴 중심 y, 얼굴 너비].
/// 카메라 기준 시선 각도이므로 화면 매핑은 같은 `CalibrationModel`이 학습한다.
public final class L2CSGazeEstimator: GazeEstimator, @unchecked Sendable {
    public struct ModelSpec: Sendable, Equatable {
        public var yawOutputName = "yaw"
        public var pitchOutputName = "pitch"
        public var binCount = 90
        public var binWidthDegrees = 4.0
        public var angleOffsetDegrees = -180.0
        /// 얼굴 상자를 이만큼 키워서 크롭한다.
        public var cropScale = 1.2
        public init() {}
    }

    public let spec: ModelSpec
    public var identifier: String { "l2cs-net" }
    private let model: VNCoreMLModel

    public init(model: MLModel, spec: ModelSpec = .init()) throws {
        self.model = try VNCoreMLModel(for: model)
        self.spec = spec
    }

    /// .mlmodel/.mlpackage는 컴파일 후 로드하고, .mlmodelc는 바로 로드한다.
    public static func load(from url: URL, spec: ModelSpec = .init(),
                            computeUnits: MLComputeUnits = .all) async throws -> L2CSGazeEstimator {
        let compiled = url.pathExtension == "mlmodelc" ? url : try await MLModel.compileModel(at: url)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        return try L2CSGazeEstimator(model: MLModel(contentsOf: compiled, configuration: configuration), spec: spec)
    }

    public func estimate(_ input: GazeEstimatorInput) throws -> GazeFeatures? {
        guard let pixelBuffer = input.pixelBuffer else { return nil }
        let face = input.face
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFill
        request.regionOfInterest = Self.visionRegion(for: face.boundingBox, scale: spec.cropScale)
        try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:]).perform([request])
        let outputs = (request.results as? [VNCoreMLFeatureValueObservation]) ?? []
        func logits(_ name: String) -> [Double]? {
            guard let array = outputs.first(where: { $0.featureName == name })?.featureValue.multiArrayValue else { return nil }
            return (0..<array.count).map { array[$0].doubleValue }
        }
        guard let yawLogits = logits(spec.yawOutputName), let pitchLogits = logits(spec.pitchOutputName),
              let yaw = Self.decodeAngle(logits: yawLogits, spec: spec),
              let pitch = Self.decodeAngle(logits: pitchLogits, spec: spec) else { return nil }
        return GazeFeatures(
            time: face.time, primary: SIMD2(yaw, pitch),
            auxiliary: [Double(face.boundingBox.midX), Double(face.boundingBox.midY), Double(face.boundingBox.width)],
            headPose: face.headPose, confidence: face.confidence)
    }

    /// 빈 로짓 → 기댓값 각도(라디안).
    public static func decodeAngle(logits: [Double], spec: ModelSpec = .init()) -> Double? {
        guard logits.count == spec.binCount, let peak = logits.max(), peak.isFinite else { return nil }
        let exps = logits.map { Foundation.exp($0 - peak) }
        let total = exps.reduce(0, +)
        let expectedBin = exps.enumerated().reduce(0.0) { $0 + Double($1.offset) * $1.element } / total
        let degrees = expectedBin * spec.binWidthDegrees + spec.angleOffsetDegrees
        return degrees * .pi / 180
    }

    /// 좌상단 원점 정규화 상자 → Vision ROI(좌하단 원점), 확대 후 [0,1]로 자른다.
    static func visionRegion(for box: CGRect, scale: Double) -> CGRect {
        let expanded = box.insetBy(dx: -box.width * (scale - 1) / 2, dy: -box.height * (scale - 1) / 2)
        let flipped = CGRect(x: expanded.minX, y: 1 - expanded.maxY, width: expanded.width, height: expanded.height)
        return flipped.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}
