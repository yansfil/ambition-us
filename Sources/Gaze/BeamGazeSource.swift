import AgentContracts
import CoreGraphics
import Foundation

/// Eyeware Beam Eye Tracker SDK 어댑터 자리(SDK 미통합).
///
/// 통합 계획
/// - SDK의 추적 콜백(사용자 상태: 화면 시선점, 머리 자세, 추적 신뢰도)을 받아 `ingest(_:)`로 넘긴다.
/// - Beam은 자체 보정을 하므로 `CalibrationModel`을 거치지 않고 `GazePipeline.processScreenPoint`로
///   One Euro·I-VT·단서 검출만 공유한다. SDK 좌표(통합 화면 픽셀 등)는 이 어댑터에서 전역 포인트로 바꾼다.
/// - SDK 보정이 바뀌면 `calibrationRevision`을 올려서 하류가 표본을 섞지 않게 한다.
///
/// 지금은 `start()`가 `GazeSourceError.sdkUnavailable`을 던지고, `ingest(_:)`는 리플레이·테스트용으로만 쓴다.
public final class BeamGazeSource: GazeSource, Sendable {
    /// SDK 프레임을 옮겨 담을 값.
    public struct Frame: Sendable, Equatable {
        public var time: MonotonicTime
        /// 전역 좌표(좌상단 원점, 포인트).
        public var point: CGPoint
        public var displayID: UInt32?
        public var confidence: Double
        public var headPose: HeadPose?
        public var calibrationRevision: Int
        /// SDK가 오차를 주지 않으면 기본값을 쓴다(포인트).
        public var expectedError: Double

        public init(time: MonotonicTime, point: CGPoint, displayID: UInt32? = nil, confidence: Double,
                    headPose: HeadPose? = nil, calibrationRevision: Int = 1, expectedError: Double = 40) {
            self.time = time; self.point = point; self.displayID = displayID; self.confidence = confidence
            self.headPose = headPose; self.calibrationRevision = calibrationRevision; self.expectedError = expectedError
        }
    }

    public static let isSDKAvailable = false

    public let engine: GazeEngine
    public var samples: AsyncStream<GazeSample> { engine.samples }
    public var nonverbalCues: AsyncStream<NonverbalCue> { engine.nonverbalCues }

    public init(configuration: GazePipelineConfiguration = .init(), clock: any MonotonicClock = GazeUptimeClock(),
                regionKeyer: GazeRegionKeying? = nil) {
        engine = GazeEngine(configuration: configuration, clock: clock, regionKeyer: regionKeyer)
    }

    public func start() async throws {
        throw GazeSourceError.sdkUnavailable("Beam Eye Tracker")
    }

    public func stop() async {
        engine.trackingLost(at: engine.clock.now())
    }

    /// SDK 콜백 진입점(현재는 리플레이·테스트용).
    public func ingest(_ frame: Frame) {
        engine.ingestScreenPoint(frame.point, displayID: frame.displayID, time: frame.time, confidence: frame.confidence,
                                 calibrationRevision: frame.calibrationRevision, expectedError: frame.expectedError,
                                 headPose: frame.headPose)
    }

    /// SDK가 추적을 잃었다고 알릴 때.
    public func trackingLost(at time: MonotonicTime) {
        engine.trackingLost(at: time)
    }
}
