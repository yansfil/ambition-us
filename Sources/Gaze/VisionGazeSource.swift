import AgentContracts
@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Vision

public struct VisionGazeConfiguration: Sendable {
    public enum Resolution: Sendable { case vga640x480, hd1280x720 }

    /// 특정 카메라 `AVCaptureDevice.uniqueID`. nil이면 내장 전면 카메라.
    public var cameraUniqueID: String?
    public var resolution: Resolution = .hd1280x720
    /// 어두운 영역 무게중심으로 동공 위치를 다시 잡는다(랜드마크 추정기 정확도 향상).
    public var refinePupils = true
    public var pupil = PupilLocator.Configuration()
    /// 디스플레이 배치 확인 주기(초). 바뀌면 해당 디스플레이 보정을 무효화한다.
    public var displayRefreshInterval: Double = 1.0
    public var pipeline = GazePipelineConfiguration()
    public init() {}
}

/// 내장 웹캠 + Vision 얼굴 랜드마크 기반 시선 소스.
///
/// - 캡처: `AVCaptureSession`, 비디오 큐에서 동기 처리 + `alwaysDiscardsLateVideoFrames`로 최신 프레임만 처리.
/// - 측정: `VNDetectFaceRectanglesRequest`(rev3, yaw/pitch/roll) → `VNDetectFaceLandmarksRequest`(rev3, 동공 포함).
/// - 추정: 주입한 `GazeEstimator`(기본 `LandmarkGazeEstimator`, 이후 `L2CSGazeEstimator`).
/// - 보정 전에는 시선 표본을 내지 않고 머리 제스처 단서만 낸다. `GazeCalibrating`으로 보정한다.
///
/// 앱 번들로 실행할 때는 Info.plist에 `NSCameraUsageDescription`이 있어야 한다.
/// 상태 변경은 세션 큐/비디오 큐에 갇혀 있고, 공유 상태는 `GazeEngine`의 Mutex가 보호한다.
public final class VisionGazeSource: GazeSource, GazeCalibrating, @unchecked Sendable {
    public let engine: GazeEngine
    public let estimator: any GazeEstimator
    public var samples: AsyncStream<GazeSample> { engine.samples }
    public var nonverbalCues: AsyncStream<NonverbalCue> { engine.nonverbalCues }

    private let configuration: VisionGazeConfiguration
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "gaze.capture.session")
    private let videoQueue = DispatchQueue(label: "gaze.capture.video", qos: .userInteractive)
    private let processor: FrameProcessor
    // 세션 큐 전용
    private var delegate: SampleBufferDelegate?
    private var isConfigured = false

    public init(configuration: VisionGazeConfiguration = .init(),
                estimator: any GazeEstimator = LandmarkGazeEstimator(),
                clock: any MonotonicClock = GazeUptimeClock(),
                regionKeyer: GazeRegionKeying? = nil) {
        self.configuration = configuration
        self.estimator = estimator
        engine = GazeEngine(configuration: configuration.pipeline, clock: clock, regionKeyer: regionKeyer)
        processor = FrameProcessor(engine: engine, estimator: estimator, configuration: configuration)
    }

    // MARK: 권한

    public static var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// 권한을 확인하고 필요하면 요청한다.
    public static func ensureCameraAccess() async throws {
        let bundle = Bundle.main
        if bundle.bundleURL.pathExtension == "app",
           bundle.object(forInfoDictionaryKey: "NSCameraUsageDescription") == nil {
            throw GazeSourceError.missingCameraUsageDescription
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw GazeSourceError.cameraPermissionDenied }
        default:
            throw GazeSourceError.cameraPermissionDenied
        }
    }

    // MARK: GazeSource

    public func start() async throws {
        try await Self.ensureCameraAccess()
        engine.updateDisplays(DisplayGeometry.active())
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            sessionQueue.async {
                do {
                    try self.configureIfNeeded()
                    if !self.session.isRunning { self.session.startRunning() }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                if self.session.isRunning { self.session.stopRunning() }
                continuation.resume()
            }
        }
        engine.trackingLost(at: engine.clock.now())
    }

    private func configureIfNeeded() throws {
        guard !isConfigured else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let preset: AVCaptureSession.Preset = configuration.resolution == .hd1280x720 ? .hd1280x720 : .vga640x480
        if session.canSetSessionPreset(preset) { session.sessionPreset = preset }

        guard let device = Self.selectCamera(uniqueID: configuration.cameraUniqueID) else {
            throw GazeSourceError.cameraUnavailable
        }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch {
            throw GazeSourceError.sessionConfigurationFailed(error.localizedDescription)
        }
        guard session.canAddInput(input) else { throw GazeSourceError.sessionConfigurationFailed("입력을 추가할 수 없음") }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        let delegate = SampleBufferDelegate(processor: processor)
        output.setSampleBufferDelegate(delegate, queue: videoQueue)
        guard session.canAddOutput(output) else {
            session.removeInput(input)
            throw GazeSourceError.sessionConfigurationFailed("출력을 추가할 수 없음")
        }
        session.addOutput(output)
        self.delegate = delegate
        isConfigured = true
    }

    /// 지정 ID → 내장 전면 → 내장 아무거나 → 시스템 기본 순.
    public static func selectCamera(uniqueID: String?) -> AVCaptureDevice? {
        if let uniqueID, let device = AVCaptureDevice(uniqueID: uniqueID) { return device }
        let builtIn = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video,
                                                       position: .unspecified).devices
        return builtIn.first { $0.position == .front } ?? builtIn.first ?? AVCaptureDevice.default(for: .video)
    }

    // MARK: GazeCalibrating

    public func availableDisplays() async -> [DisplayGeometry] {
        engine.updateDisplays(DisplayGeometry.active())
        return engine.displays
    }

    public func beginCalibration(displayID: UInt32) async throws {
        engine.updateDisplays(DisplayGeometry.active())
        try engine.beginCalibration(displayID: displayID)
    }

    public func collectCalibrationTarget(at point: CGPoint, duration: Duration) async throws -> Int {
        try engine.beginCalibrationTarget(point)
        do {
            try await Task.sleep(for: duration)
        } catch {
            engine.abortCalibrationTarget()
            throw error
        }
        return try engine.endCalibrationTarget()
    }

    public func finishCalibration(options: CalibrationOptions = .init()) async throws -> CalibrationReport {
        try engine.finishCalibration(options: options)
    }

    public func cancelCalibration() async {
        engine.cancelCalibration()
    }
}

/// 비디오 큐에서만 호출된다.
private final class FrameProcessor: @unchecked Sendable {
    let engine: GazeEngine
    let estimator: any GazeEstimator
    let configuration: VisionGazeConfiguration

    init(engine: GazeEngine, estimator: any GazeEstimator, configuration: VisionGazeConfiguration) {
        self.engine = engine; self.estimator = estimator; self.configuration = configuration
    }

    func process(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = frameTime(sampleBuffer)
        engine.refreshDisplaysIfNeeded(now: time, interval: configuration.displayRefreshInterval)
        guard var face = VisionFaceAnalyzer.measure(pixelBuffer: pixelBuffer, time: time) else {
            engine.noObservation(at: time)
            return
        }
        if configuration.refinePupils {
            face = PupilLocator.refine(face, buffer: pixelBuffer, configuration: configuration.pupil)
        }
        let features = try? estimator.estimate(GazeEstimatorInput(face: face, pixelBuffer: pixelBuffer))
        if let features = features ?? nil {
            engine.ingest(features)
        } else {
            engine.noObservation(at: time)
        }
    }

    /// 엔진 시계 기준 시각. 캡처 PTS(호스트 시계)와 현재 호스트 시각 차이만큼 캡처 지연을 뺀다.
    private func frameTime(_ sampleBuffer: CMSampleBuffer) -> MonotonicTime {
        let now = engine.clock.now()
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        var latency = CMTimeGetSeconds(CMTimeSubtract(hostNow, pts))
        if !latency.isFinite || latency < 0 || latency > 0.5 { latency = 0 }
        return now.adding(seconds: -latency)
    }
}

private final class SampleBufferDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let processor: FrameProcessor

    init(processor: FrameProcessor) {
        self.processor = processor
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        processor.process(sampleBuffer)
    }
}

/// Vision 요청 → `FaceMeasurement`. 가장 큰 얼굴 하나만 쓴다.
public enum VisionFaceAnalyzer {
    public static func measure(pixelBuffer: CVPixelBuffer, time: MonotonicTime,
                               orientation: CGImagePropertyOrientation = .up) -> FaceMeasurement? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
        let rectangles = VNDetectFaceRectanglesRequest()
        rectangles.revision = VNDetectFaceRectanglesRequestRevision3
        do { try handler.perform([rectangles]) } catch { return nil }
        guard let face = rectangles.results?.max(by: { area($0.boundingBox) < area($1.boundingBox) }) else { return nil }

        let landmarksRequest = VNDetectFaceLandmarksRequest()
        landmarksRequest.revision = VNDetectFaceLandmarksRequestRevision3
        landmarksRequest.inputFaceObservations = [face]
        do { try handler.perform([landmarksRequest]) } catch { return nil }
        guard let observed = landmarksRequest.results?.first, let landmarks = observed.landmarks else { return nil }

        let box = observed.boundingBox // 정규화, 좌하단 원점
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            guard let region else { return [] }
            return region.normalizedPoints.map { p in
                CGPoint(x: box.minX + p.x * box.width, y: 1 - (box.minY + p.y * box.height))
            }
        }
        func eye(_ contour: VNFaceLandmarkRegion2D?, _ pupil: VNFaceLandmarkRegion2D?) -> EyeMeasurement? {
            let outline = points(contour)
            guard outline.count >= 4 else { return nil }
            return EyeMeasurement(contour: outline, pupil: points(pupil).first)
        }
        let yaw = (observed.yaw ?? face.yaw)?.doubleValue
        let pitch = (observed.pitch ?? face.pitch)?.doubleValue
        let roll = (observed.roll ?? face.roll)?.doubleValue
        let pose: HeadPose? = (yaw == nil && pitch == nil && roll == nil)
            ? nil : HeadPose(yaw: yaw ?? 0, pitch: pitch ?? 0, roll: roll ?? 0)
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        return FaceMeasurement(
            time: time, imageSize: size,
            boundingBox: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height),
            headPose: pose,
            leftEye: eye(landmarks.leftEye, landmarks.leftPupil),
            rightEye: eye(landmarks.rightEye, landmarks.rightPupil),
            confidence: Double(face.confidence) * Double(landmarks.confidence))
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }
}
