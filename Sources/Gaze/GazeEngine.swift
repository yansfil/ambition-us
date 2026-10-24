import AgentContracts
import CoreGraphics
import Foundation
import Synchronization

public struct CalibrationReport: Sendable, Equatable {
    public let displayID: UInt32
    public let revision: Int
    public let kind: CalibrationModel.Kind
    public let lambda: Double
    public let crossValidatedRMSE: Double
    public let trainingRMSE: Double
    public let targetCount: Int
    public let sampleCount: Int

    init(_ model: CalibrationModel) {
        displayID = model.display.id; revision = model.revision; kind = model.kind; lambda = model.lambda
        crossValidatedRMSE = model.crossValidatedRMSE; trainingRMSE = model.trainingRMSE
        targetCount = model.targetCount; sampleCount = model.sampleCount
    }
}

/// 보정 UI(오버레이/통합 담당)가 쓰는 인터페이스.
///
/// 흐름: `beginCalibration` → 표적마다 화면에 점을 띄우고 `collectCalibrationTarget` → `finishCalibration`.
public protocol GazeCalibrating: Sendable {
    func availableDisplays() async -> [DisplayGeometry]
    func beginCalibration(displayID: UInt32) async throws
    /// 표적을 보는 동안 특징을 모은다(앞쪽 정착 시간은 버림). 채택된 표본 수를 돌려준다.
    func collectCalibrationTarget(at point: CGPoint, duration: Duration) async throws -> Int
    func finishCalibration(options: CalibrationOptions) async throws -> CalibrationReport
    func cancelCalibration() async
}

/// 모든 시선 소스가 공유하는 스레드 안전 처리기. 파이프라인 상태를 Mutex로 보호하고 결과를 스트림으로 내보낸다.
///
/// `AsyncStream`은 소비자 하나를 전제로 한다. 표본 스트림은 최신값 위주로 버퍼링한다.
public final class GazeEngine: Sendable {
    struct State: Sendable {
        var pipeline: GazePipeline
        var collector: CalibrationCollector?
        var latestFeatures: GazeFeatures?
        var lastDisplayRefresh: MonotonicTime?
    }

    public let samples: AsyncStream<GazeSample>
    public let nonverbalCues: AsyncStream<NonverbalCue>
    public let clock: any MonotonicClock
    private let sampleContinuation: AsyncStream<GazeSample>.Continuation
    private let cueContinuation: AsyncStream<NonverbalCue>.Continuation
    private let state: Mutex<State>

    public init(configuration: GazePipelineConfiguration = .init(), clock: any MonotonicClock = GazeUptimeClock(),
                regionKeyer: GazeRegionKeying? = nil, sampleBufferLimit: Int = 8, cueBufferLimit: Int = 256) {
        self.clock = clock
        (samples, sampleContinuation) = AsyncStream.makeStream(of: GazeSample.self,
                                                               bufferingPolicy: .bufferingNewest(sampleBufferLimit))
        (nonverbalCues, cueContinuation) = AsyncStream.makeStream(of: NonverbalCue.self,
                                                                  bufferingPolicy: .bufferingNewest(cueBufferLimit))
        state = Mutex(State(pipeline: GazePipeline(configuration: configuration, regionKeyer: regionKeyer)))
    }

    deinit {
        sampleContinuation.finish()
        cueContinuation.finish()
    }

    /// 스트림을 끝낸다. 이후 입력은 무시된다.
    public func finish() {
        sampleContinuation.finish()
        cueContinuation.finish()
    }

    // MARK: 입력

    public func ingest(_ features: GazeFeatures) {
        let output = state.withLock { state -> GazePipelineOutput in
            state.latestFeatures = features
            state.collector?.add(features)
            return state.pipeline.process(features)
        }
        emit(output)
    }

    /// 화면 좌표 입력(Beam/마우스). displayID가 nil이면 알려진 디스플레이 배치에서 찾는다.
    public func ingestScreenPoint(_ point: CGPoint, displayID: UInt32? = nil, time: MonotonicTime, confidence: Double,
                                  calibrationRevision: Int, expectedError: Double, headPose: HeadPose? = nil) {
        let output = state.withLock { state -> GazePipelineOutput in
            let display = displayID ?? DisplayGeometry.display(for: point, in: state.pipeline.calibration.displays)?.id ?? 0
            return state.pipeline.processScreenPoint(point, displayID: display, time: time, confidence: confidence,
                                                     calibrationRevision: calibrationRevision,
                                                     expectedError: expectedError, headPose: headPose)
        }
        emit(output)
    }

    public func noObservation(at time: MonotonicTime) {
        emit(state.withLock { $0.pipeline.noObservation(at: time) })
    }

    public func trackingLost(at time: MonotonicTime) {
        emit(state.withLock { $0.pipeline.trackingLost(at: time) })
    }

    private func emit(_ output: GazePipelineOutput) {
        for cue in output.cues { cueContinuation.yield(cue) }
        if let sample = output.sample { sampleContinuation.yield(sample) }
    }

    // MARK: 디스플레이

    public var displays: [DisplayGeometry] { state.withLock { $0.pipeline.calibration.displays } }

    /// 디스플레이 배치를 갱신하고 무효화된 보정의 디스플레이 ID를 돌려준다.
    @discardableResult
    public func updateDisplays(_ displays: [DisplayGeometry]) -> [UInt32] {
        state.withLock { state in
            let invalidated = state.pipeline.calibration.updateDisplays(displays)
            if let collector = state.collector, !displays.contains(collector.display) { state.collector = nil }
            return invalidated
        }
    }

    /// `interval`초마다 한 번만 `provider`로 디스플레이 배치를 갱신한다(프레임 루프에서 호출).
    public func refreshDisplaysIfNeeded(now: MonotonicTime, interval: Double,
                                        provider: () -> [DisplayGeometry] = DisplayGeometry.active) {
        let due = state.withLock { state -> Bool in
            if let last = state.lastDisplayRefresh, now.seconds(since: last) < interval { return false }
            state.lastDisplayRefresh = now
            return true
        }
        if due { updateDisplays(provider()) }
    }

    // MARK: 보정

    public var latestFeatures: GazeFeatures? { state.withLock { $0.latestFeatures } }
    public var calibrationRevision: Int { state.withLock { $0.pipeline.calibration.revision } }
    public var calibrationModels: [CalibrationModel] {
        state.withLock { Array($0.pipeline.calibration.models.values).sorted { $0.display.id < $1.display.id } }
    }
    public var isCalibrating: Bool { state.withLock { $0.collector != nil } }

    public func beginCalibration(on display: DisplayGeometry) {
        state.withLock { $0.collector = CalibrationCollector(display: display) }
    }

    public func beginCalibration(displayID: UInt32) throws {
        try state.withLock { state in
            guard let display = state.pipeline.calibration.displays.first(where: { $0.id == displayID }) else {
                throw CalibrationError.unknownDisplay(displayID)
            }
            state.collector = CalibrationCollector(display: display)
        }
    }

    public func beginCalibrationTarget(_ point: CGPoint) throws {
        let now = clock.now()
        try state.withLock { state in
            guard state.collector != nil else { throw CalibrationError.noActiveSession }
            state.collector?.beginTarget(point, at: now)
        }
    }

    @discardableResult
    public func endCalibrationTarget() throws -> Int {
        try state.withLock { state in
            guard state.collector != nil else { throw CalibrationError.noActiveSession }
            return state.collector!.endTarget()
        }
    }

    public func abortCalibrationTarget() {
        state.withLock { $0.collector?.abortTarget() }
    }

    /// 수집한 표본으로 모델을 적합해 설치한다. 실패해도 수집 세션은 유지된다(표적 추가 후 재시도 가능).
    public func finishCalibration(options: CalibrationOptions = .init()) throws -> CalibrationReport {
        let report = try state.withLock { state -> CalibrationReport in
            guard let collector = state.collector else { throw CalibrationError.noActiveSession }
            let model = try state.pipeline.calibration.fit(samples: collector.samples, display: collector.display,
                                                           options: options)
            state.collector = nil
            return CalibrationReport(model)
        }
        return report
    }

    public func cancelCalibration() {
        state.withLock { $0.collector = nil }
    }

    /// 저장해 둔 모델 복원 등. 현재 디스플레이 배치와 맞지 않으면 `displayMismatch`.
    @discardableResult
    public func install(_ model: CalibrationModel) throws -> CalibrationModel {
        try state.withLock { try $0.pipeline.calibration.install(model) }
    }

    public func clearCalibration(displayID: UInt32) {
        state.withLock { _ = $0.pipeline.calibration.invalidate(displayID: displayID) }
    }
}
