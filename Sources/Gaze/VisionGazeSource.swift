import AgentContracts
@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import CoreML
import CoreVideo
import Foundation
import Synchronization
import Vision

public struct VisionGazeConfiguration: Sendable {
    public enum Resolution: Sendable { case vga640x480, hd1280x720, hd1920x1080 }

    public enum EstimatorMode: Sendable, Equatable {
        /// 시선 CNN이 설치돼 있으면 쓰고, 없으면 랜드마크 추정기로 대체한다.
        case automatic
        /// 항상 랜드마크 추정기.
        case landmarks
        /// 이 경로의 CNN(.mlpackage/.mlmodelc). 실패하면 랜드마크로 대체.
        case model(URL)
    }

    /// 특정 카메라 `AVCaptureDevice.uniqueID`. nil이면 내장 전면 카메라.
    public var cameraUniqueID: String?
    /// 원하는 해상도. 지원하지 않으면 1280×720 → 640×480 순으로 내린다.
    public var resolution: Resolution = .hd1920x1080
    public var frameRate: Double = 30
    public var estimatorMode: EstimatorMode = .automatic
    public var computeUnits: MLComputeUnits = .all
    public var cnn = CNNGazeEstimator.Configuration()
    /// 어두운 영역 무게중심으로 동공 위치를 다시 잡는다(랜드마크 추정기·홍채 보조 특징 정확도 향상).
    public var refinePupils = true
    public var pupil = PupilLocator.Configuration()
    /// 디스플레이 배치 확인 주기(초). 바뀌면 해당 디스플레이 보정을 무효화한다.
    public var displayRefreshInterval: Double = 1.0
    /// 진단 파일 갱신 주기(초). 0이면 쓰지 않는다.
    public var diagnosticsInterval: Double = 30
    public var pipeline = GazePipelineConfiguration()
    public init() {}
}

/// 내장 웹캠 + Vision 얼굴 측정 + 시선 CNN(CoreML) 기반 시선 소스.
///
/// - 캡처: `AVCaptureSession` 1920×1080(대체 1280×720) 30fps, 32BGRA. 비디오 큐에서 동기 처리 +
///   `alwaysDiscardsLateVideoFrames`로 최신 프레임만 처리한다.
/// - 측정: `VNDetectFaceRectanglesRequest`(rev3, yaw/pitch/roll) → `VNDetectFaceLandmarksRequest`(rev3, 동공 포함).
/// - 추정: 시선 CNN(`CNNGazeEstimator`, 모델이 없으면 `LandmarkGazeEstimator`로 대체하고 상태에 표시).
/// - 보정 전에는 시선 표본을 내지 않고 머리 제스처 단서만 낸다. `GazeCalibrating`으로 보정한다.
///
/// 앱 번들로 실행할 때는 Info.plist에 `NSCameraUsageDescription`이 있어야 한다.
public final class VisionGazeSource: GazeSource, GazeCalibrating, @unchecked Sendable {
    public let engine: GazeEngine
    public var samples: AsyncStream<GazeSample> { engine.samples }
    public var nonverbalCues: AsyncStream<NonverbalCue> { engine.nonverbalCues }

    private let configuration: VisionGazeConfiguration
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "gaze.capture.session")
    private let videoQueue = DispatchQueue(label: "gaze.capture.video", qos: .userInteractive)
    private let processor: FrameProcessor
    private let slot: EstimatorHolder
    // 세션 큐 전용
    private var delegate: SampleBufferDelegate?
    private var isConfigured = false

    struct EstimatorSlot: Sendable {
        var estimator: any GazeEstimator
        var status: GazeEstimatorStatus
        var prepared: Bool
        var loaded: GazeModelStore.Loaded?
    }

    /// 소스와 프레임 처리기가 공유하는 추정기 칸.
    final class EstimatorHolder: Sendable {
        private let slot: Mutex<EstimatorSlot>
        init(_ initial: EstimatorSlot) { slot = Mutex(initial) }
        func withLock<R: Sendable>(_ body: (inout EstimatorSlot) -> R) -> R { slot.withLock { body(&$0) } }
    }

    /// - Parameter estimator: nil이면 `configuration.estimatorMode`에 따라 `start()`에서 정한다.
    public init(configuration: VisionGazeConfiguration = .init(),
                estimator: (any GazeEstimator)? = nil,
                clock: any MonotonicClock = GazeUptimeClock(),
                regionKeyer: GazeRegionKeying? = nil) {
        self.configuration = configuration
        engine = GazeEngine(configuration: configuration.pipeline, clock: clock, regionKeyer: regionKeyer)
        let initial: any GazeEstimator = estimator ?? LandmarkGazeEstimator()
        let status: GazeEstimatorStatus = estimator == nil
            ? GazeEstimatorStatus(kind: .pending, identifier: initial.identifier)
            : GazeEstimatorStatus(kind: estimator is CNNGazeEstimator ? .cnn : .landmarks, identifier: initial.identifier)
        slot = EstimatorHolder(EstimatorSlot(estimator: initial, status: status, prepared: estimator != nil, loaded: nil))
        engine.setEstimator(id: initial.identifier, scaleFloors: initial.featureScaleFloors)
        processor = FrameProcessor(engine: engine, configuration: configuration, slot: slot)
    }

    /// 현재 추정기.
    public var estimator: any GazeEstimator { slot.withLock { $0.estimator } }

    public var estimatorStatus: GazeEstimatorStatus {
        var status = slot.withLock { $0.status }
        if let cnn = slot.withLock({ $0.estimator }) as? CNNGazeEstimator {
            status.medianInferenceMilliseconds = cnn.inferenceLatency.median
        }
        return status
    }

    public var headPosition: HeadPositionStatus? { engine.headPosition }
    public var now: MonotonicTime { engine.clock.now() }

    // MARK: 추정기 준비

    /// 시선 CNN을 찾아 컴파일·로드한다(한 번만). 실패하면 랜드마크 추정기로 대체하고 이유를 상태에 남긴다.
    @discardableResult
    public func prepareEstimator() async -> GazeEstimatorStatus {
        if slot.withLock({ $0.prepared }) { return estimatorStatus }
        let mode = configuration.estimatorMode
        var next: EstimatorSlot
        switch mode {
        case .landmarks:
            next = EstimatorSlot(estimator: LandmarkGazeEstimator(),
                                 status: .init(kind: .landmarks, identifier: LandmarkGazeEstimator.identifier,
                                               fallbackReason: "설정에서 랜드마크 추정기를 선택"),
                                 prepared: true, loaded: nil)
        case .automatic, .model:
            let source: URL? = if case .model(let url) = mode { url } else { nil }
            do {
                let loaded = try await GazeModelStore.load(from: source, computeUnits: configuration.computeUnits)
                let cnn = CNNGazeEstimator(loaded: loaded, configuration: configuration.cnn)
                next = EstimatorSlot(estimator: cnn,
                                     status: .init(kind: .cnn, identifier: cnn.identifier,
                                                   modelName: loaded.info.arch + (loaded.info.testTimeFlip ? "+TTA" : "")),
                                     prepared: true, loaded: loaded)
                GazeLog.estimator.info("using CNN gaze estimator \(cnn.identifier, privacy: .public) from \(loaded.sourceURL.path, privacy: .public) (load \(loaded.loadSeconds, format: .fixed(precision: 2))s)")
            } catch {
                let reason: String = switch error {
                case GazeModelError.notInstalled: "모델 미설치(scripts/fetch-gaze-model.sh)"
                default: "\(error)"
                }
                next = EstimatorSlot(estimator: LandmarkGazeEstimator(),
                                     status: .init(kind: .landmarks, identifier: LandmarkGazeEstimator.identifier,
                                                   fallbackReason: reason),
                                     prepared: true, loaded: nil)
                GazeLog.estimator.error("CNN gaze model unavailable, falling back to landmarks-v1: \(String(describing: error), privacy: .public)")
            }
        }
        let estimator = next.estimator
        slot.withLock { $0 = next }
        engine.setEstimator(id: estimator.identifier, scaleFloors: estimator.featureScaleFloors)
        return estimatorStatus
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
        await prepareEstimator()
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
        writeDiagnostics()
    }

    static func preset(for resolution: VisionGazeConfiguration.Resolution) -> AVCaptureSession.Preset {
        switch resolution {
        case .hd1920x1080: .hd1920x1080
        case .hd1280x720: .hd1280x720
        case .vga640x480: .vga640x480
        }
    }

    private func configureIfNeeded() throws {
        guard !isConfigured else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard let device = Self.selectCamera(uniqueID: configuration.cameraUniqueID) else {
            throw GazeSourceError.cameraUnavailable
        }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) } catch {
            throw GazeSourceError.sessionConfigurationFailed(error.localizedDescription)
        }
        guard session.canAddInput(input) else { throw GazeSourceError.sessionConfigurationFailed("입력을 추가할 수 없음") }
        session.addInput(input)

        // 원하는 해상도부터 낮은 쪽으로.
        let ladder: [VisionGazeConfiguration.Resolution] = switch configuration.resolution {
        case .hd1920x1080: [.hd1920x1080, .hd1280x720, .vga640x480]
        case .hd1280x720: [.hd1280x720, .vga640x480]
        case .vga640x480: [.vga640x480]
        }
        if let preset = ladder.map(Self.preset(for:)).first(where: session.canSetSessionPreset) {
            session.sessionPreset = preset
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        // BGRA: Vision·CNN 크롭(Python 기준 구현과 같은 RGB 샘플링)·동공 밝기 모두 이 형식을 직접 읽는다.
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let delegate = SampleBufferDelegate(processor: processor)
        output.setSampleBufferDelegate(delegate, queue: videoQueue)
        guard session.canAddOutput(output) else {
            session.removeInput(input)
            throw GazeSourceError.sessionConfigurationFailed("출력을 추가할 수 없음")
        }
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            // 기하 계산은 반전되지 않은 영상을 전제로 한다.
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        let fps = Self.applyFrameRate(configuration.frameRate, to: device)
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        processor.setCamera(.init(width: Int(dimensions.width), height: Int(dimensions.height), frameRate: fps,
                                  pixelFormat: "32BGRA"))
        GazeLog.camera.info("camera \(device.localizedName, privacy: .public) \(dimensions.width)x\(dimensions.height) @\(fps, format: .fixed(precision: 1))fps preset \(self.session.sessionPreset.rawValue, privacy: .public)")
        self.delegate = delegate
        isConfigured = true
    }

    /// 활성 포맷이 지원하면 프레임률을 고정한다. 실제 적용된 최대 프레임률을 돌려준다.
    private static func applyFrameRate(_ rate: Double, to device: AVCaptureDevice) -> Double {
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        guard let range = ranges.first(where: { $0.minFrameRate <= rate && rate <= $0.maxFrameRate }) else {
            return ranges.map(\.maxFrameRate).max() ?? 0
        }
        do {
            try device.lockForConfiguration()
            let duration = CMTime(value: 1, timescale: CMTimeScale(rate.rounded()))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
            return rate
        } catch {
            return range.maxFrameRate
        }
    }

    /// 지정 ID → 내장 전면 → 내장 아무거나 → 시스템 기본 순.
    public static func selectCamera(uniqueID: String?) -> AVCaptureDevice? {
        if let uniqueID, let device = AVCaptureDevice(uniqueID: uniqueID) { return device }
        let builtIn = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video,
                                                       position: .unspecified).devices
        return builtIn.first { $0.position == .front } ?? builtIn.first ?? AVCaptureDevice.default(for: .video)
    }

    // MARK: 진단

    public func diagnostics() -> GazeDiagnostics {
        processor.diagnostics()
    }

    /// 진단 파일을 백그라운드에서 쓴다.
    public func writeDiagnostics() {
        let snapshot = diagnostics()
        DispatchQueue.global(qos: .utility).async {
            do { try snapshot.write() } catch {
                GazeLog.estimator.error("failed to write diagnostics: \(String(describing: error), privacy: .public)")
            }
        }
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

    public func collectTarget(at point: CGPoint, settle: Duration, collect: Duration,
                              rejectFlagged: Bool) async throws -> CalibrationTargetResult {
        try engine.beginCalibrationTarget(point, settle: settle.seconds)
        do {
            try await Task.sleep(for: settle + collect)
        } catch {
            engine.abortCalibrationTarget()
            throw error
        }
        return try engine.endCalibrationTarget(rejectFlagged: rejectFlagged)
    }

    public func finishCalibration(options: CalibrationOptions = .init()) async throws -> CalibrationReport {
        let report = try engine.finishCalibration(options: options)
        writeDiagnostics()
        return report
    }

    public func beginValidation() async throws {
        try engine.beginValidation()
    }

    public func collectValidationTarget(at point: CGPoint, settle: Duration, collect: Duration,
                                        rejectFlagged: Bool) async throws -> CalibrationTargetResult {
        try engine.beginValidationTarget(point, settle: settle.seconds)
        do {
            try await Task.sleep(for: settle + collect)
        } catch {
            engine.abortCalibrationTarget()
            throw error
        }
        return try engine.endValidationTarget(rejectFlagged: rejectFlagged)
    }

    public func finishValidation() async throws -> CalibrationValidationReport {
        let report = try engine.finishValidation()
        writeDiagnostics()
        return report
    }

    public func acceptValidation() async throws -> CalibrationReport {
        let report = try engine.acceptValidation()
        writeDiagnostics()
        return report
    }

    public func cancelCalibration() async {
        engine.cancelCalibration()
    }
}

extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// 비디오 큐에서만 `process`가 호출된다. 통계는 Mutex로 보호한다.
private final class FrameProcessor: @unchecked Sendable {
    struct Stats: Sendable {
        var vision = LatencyStats()
        var estimator = LatencyStats()
        var frame = LatencyStats()
        var framesProcessed = 0
        var framesWithFace = 0
        var framesWithFeatures = 0
        var camera: GazeDiagnostics.Camera?
        var lastDiagnosticsWrite: MonotonicTime?
    }

    let engine: GazeEngine
    let configuration: VisionGazeConfiguration
    let slot: VisionGazeSource.EstimatorHolder
    private let stats = Mutex(Stats())

    init(engine: GazeEngine, configuration: VisionGazeConfiguration, slot: VisionGazeSource.EstimatorHolder) {
        self.engine = engine; self.configuration = configuration; self.slot = slot
    }

    func setCamera(_ camera: GazeDiagnostics.Camera) {
        stats.withLock { $0.camera = camera }
    }

    func process(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        let time = frameTime(sampleBuffer)
        engine.refreshDisplaysIfNeeded(now: time, interval: configuration.displayRefreshInterval)
        let face = VisionFaceAnalyzer.measure(pixelBuffer: pixelBuffer, time: time)
        let visionDone = DispatchTime.now().uptimeNanoseconds
        var features: GazeFeatures?
        if var face {
            engine.updateHeadPosition(HeadPositionStatus(face: face, intrinsics: configuration.cnn.intrinsics,
                                                         faceWidthCm: configuration.cnn.faceWidthCm))
            if configuration.refinePupils {
                face = PupilLocator.refine(face, buffer: pixelBuffer, configuration: configuration.pupil)
            }
            let estimator = slot.withLock { $0.estimator }
            features = (try? estimator.estimate(GazeEstimatorInput(face: face, pixelBuffer: pixelBuffer))) ?? nil
        }
        if let features {
            engine.ingest(features)
        } else {
            engine.noObservation(at: time)
        }
        let finished = DispatchTime.now().uptimeNanoseconds
        let writeDue = stats.withLock { stats -> Bool in
            stats.framesProcessed += 1
            stats.vision.add(Double(visionDone - started) / 1e6)
            stats.frame.add(Double(finished - started) / 1e6)
            if face != nil {
                stats.framesWithFace += 1
                stats.estimator.add(Double(finished - visionDone) / 1e6)
            }
            if features != nil { stats.framesWithFeatures += 1 }
            let interval = configuration.diagnosticsInterval
            guard interval > 0 else { return false }
            if let last = stats.lastDiagnosticsWrite, time.seconds(since: last) < interval { return false }
            stats.lastDiagnosticsWrite = time
            return stats.framesProcessed > 30
        }
        if writeDue {
            let snapshot = diagnostics()
            DispatchQueue.global(qos: .utility).async { try? snapshot.write() }
            if let median = snapshot.timing.frameMedianMs {
                GazeLog.estimator.info("frame \(median, format: .fixed(precision: 1))ms median (cnn \(snapshot.timing.cnnMedianMs ?? -1, format: .fixed(precision: 1))ms, vision \(snapshot.timing.visionMedianMs ?? -1, format: .fixed(precision: 1))ms), face \(snapshot.timing.framesWithFace)/\(snapshot.timing.framesProcessed)")
            }
        }
    }

    func diagnostics() -> GazeDiagnostics {
        let current = slot.withLock { $0 }
        let s = stats.withLock { $0 }
        let cnn = current.estimator as? CNNGazeEstimator
        let cnnStats = cnn?.inferenceLatency
        let info = current.loaded?.info
        return GazeDiagnostics(
            updatedAt: Date(),
            estimator: .init(kind: current.status.kind.rawValue, identifier: current.estimator.identifier,
                             modelArch: info?.arch, modelSource: info?.source, testTimeFlip: info?.testTimeFlip,
                             cropWidthScale: info?.crop.widthScale, cropHeightScale: info?.crop.heightScale,
                             cropVerticalOffset: info?.crop.verticalOffset,
                             modelPath: current.loaded?.sourceURL.path, compiledPath: current.loaded?.compiledURL.path,
                             loadSeconds: current.loaded?.loadSeconds, fallbackReason: current.status.fallbackReason),
            camera: s.camera,
            timing: .init(framesProcessed: s.framesProcessed, framesWithFace: s.framesWithFace,
                          framesWithFeatures: s.framesWithFeatures, visionMedianMs: s.vision.median,
                          visionP95Ms: s.vision.p95, estimatorMedianMs: s.estimator.median, estimatorP95Ms: s.estimator.p95,
                          cnnMedianMs: cnnStats?.median, cnnP95Ms: cnnStats?.p95, frameMedianMs: s.frame.median,
                          frameP95Ms: s.frame.p95, budgetMs: 1000 / max(configuration.frameRate, 1)),
            calibrations: engine.calibrationModels.map(GazeDiagnostics.Calibration.init),
            implicit: engine.implicitStats)
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
        // 전체 랜드마크 무게중심·RMS 반경(픽셀 좌표에서 계산).
        let all = points(landmarks.allPoints).map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        var center: CGPoint?, radius: Double?
        if all.count >= 10 {
            let cx = all.reduce(0.0) { $0 + Double($1.x) } / Double(all.count)
            let cy = all.reduce(0.0) { $0 + Double($1.y) } / Double(all.count)
            let r = (all.reduce(0.0) { $0 + pow(Double($1.x) - cx, 2) + pow(Double($1.y) - cy, 2) } / Double(all.count)).squareRoot()
            if r > 1 {
                center = CGPoint(x: cx / Double(size.width), y: cy / Double(size.height))
                radius = r
            }
        }
        return FaceMeasurement(
            time: time, imageSize: size,
            boundingBox: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height),
            headPose: pose,
            leftEye: eye(landmarks.leftEye, landmarks.leftPupil),
            rightEye: eye(landmarks.rightEye, landmarks.rightPupil),
            confidence: Double(face.confidence) * Double(landmarks.confidence),
            landmarkCenter: center, landmarkRadius: radius)
    }

    private static func area(_ rect: CGRect) -> CGFloat { rect.width * rect.height }
}
