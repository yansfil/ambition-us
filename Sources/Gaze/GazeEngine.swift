import AgentContracts
import CoreGraphics
import Foundation
import Synchronization

public struct CalibrationReport: Sendable, Equatable {
    public let displayID: UInt32
    public let revision: Int
    public let kind: CalibrationModel.Kind
    public let auxiliaryTerms: CalibrationModel.AuxiliaryTerms
    public let lambda: Double
    public let crossValidatedRMSE: Double
    public let trainingRMSE: Double
    public let targetCount: Int
    public let sampleCount: Int
    public let implicitCount: Int
    public let estimatorID: String
    public let validation: CalibrationModel.ValidationSummary?
    /// 디스플레이 cm당 포인트(모르면 nil).
    public let pointsPerCentimeter: Double?

    public init(_ model: CalibrationModel, pointsPerCentimeter: Double? = nil) {
        displayID = model.display.id; revision = model.revision; kind = model.kind
        auxiliaryTerms = model.auxiliaryTerms; lambda = model.lambda
        crossValidatedRMSE = model.crossValidatedRMSE; trainingRMSE = model.trainingRMSE
        targetCount = model.targetCount; sampleCount = model.sampleCount; implicitCount = model.implicitCount
        estimatorID = model.estimatorID; validation = model.validation
        self.pointsPerCentimeter = pointsPerCentimeter
    }

    public var crossValidatedCm: Double? { pointsPerCentimeter.map { crossValidatedRMSE / $0 } }
}

/// 디스플레이 하나의 학습 데이터(명시 보정·검증 표본 + 암묵 표본). 암묵 재적합과 저장에 쓴다.
public struct CalibrationDataset: Sendable, Codable, Equatable {
    public var display: DisplayGeometry
    public var estimatorID: String
    public var samples: [CalibrationSample]
    public var implicit: ImplicitCalibrationBuffer
    public var createdAt: Date

    public init(display: DisplayGeometry, estimatorID: String, samples: [CalibrationSample],
                implicit: ImplicitCalibrationBuffer = .init(), createdAt: Date = Date()) {
        self.display = display; self.estimatorID = estimatorID; self.samples = samples; self.implicit = implicit
        self.createdAt = createdAt
    }
}

/// 보정 저장 파일(calibration-v2.json).
public struct CalibrationArchive: Sendable, Codable, Equatable {
    public var version: Int
    public var estimatorID: String
    public var models: [CalibrationModel]
    public var datasets: [CalibrationDataset]
    public var savedAt: Date

    public init(estimatorID: String, models: [CalibrationModel], datasets: [CalibrationDataset], savedAt: Date = Date()) {
        version = 2; self.estimatorID = estimatorID; self.models = models; self.datasets = datasets; self.savedAt = savedAt
    }
}

/// 보정 상태 변화 알림(저장·진단 갱신용).
public enum CalibrationEvent: Sendable, Equatable {
    case calibrated(CalibrationReport)
    case validated(CalibrationValidationReport)
    /// 검증 점을 합쳐 다시 적합했거나, 클릭 표본으로 암묵 재적합했다(리비전 유지).
    case refined(CalibrationReport)
    case restored(Int)
}

/// 암묵 보정 집계(진단용).
public struct ImplicitCalibrationStats: Sendable, Equatable, Codable {
    public var accepted = 0
    public var rejected: [String: Int] = [:]
    public var refits = 0
    public var lastRefitCVRMSE: Double?
    public var lastRefitAt: Date?
    public init() {}
}

/// 보정 UI(오버레이/통합 담당)가 쓰는 인터페이스.
///
/// 흐름: `beginCalibration` → 표적마다 화면에 점을 띄우고 `collectTarget` → `finishCalibration`
/// → (선택) `beginValidation` → 검증 점마다 `collectValidationTarget` → `finishValidation`
/// → `acceptValidation`(검증 점을 학습에 합침).
public protocol GazeCalibrating: Sendable {
    func availableDisplays() async -> [DisplayGeometry]
    func beginCalibration(displayID: UInt32) async throws
    /// 표적을 보는 동안 특징을 모은다(앞쪽 정착 시간은 버림). 채택된 표본 수를 돌려준다.
    func collectCalibrationTarget(at point: CGPoint, duration: Duration) async throws -> Int
    /// 정착(`settle`, 버림) + 수집(`collect`). `rejectFlagged`이면 머리가 움직였거나 표본이 부족한 표적은
    /// 저장하지 않는다(UI가 같은 점을 다시 보여 준다).
    func collectTarget(at point: CGPoint, settle: Duration, collect: Duration,
                       rejectFlagged: Bool) async throws -> CalibrationTargetResult
    func finishCalibration(options: CalibrationOptions) async throws -> CalibrationReport
    func beginValidation() async throws
    func collectValidationTarget(at point: CGPoint, settle: Duration, collect: Duration,
                                 rejectFlagged: Bool) async throws -> CalibrationTargetResult
    func finishValidation() async throws -> CalibrationValidationReport
    /// 검증 점을 학습에 합쳐 다시 적합한다.
    func acceptValidation() async throws -> CalibrationReport
    func cancelCalibration() async
    /// 현재 시선 추정기 상태(CNN / 랜드마크 대체).
    var estimatorStatus: GazeEstimatorStatus { get }
    /// 최근 얼굴 위치(자세 안내용).
    var headPosition: HeadPositionStatus? { get }
    /// 엔진 시계 기준 현재 시각.
    var now: MonotonicTime { get }
}

/// 시선 추정기 상태(메뉴·보정 창 표시용).
public struct GazeEstimatorStatus: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable { case cnn, landmarks, pending }
    public var kind: Kind
    public var identifier: String
    public var modelName: String?
    /// CNN을 못 쓰는 이유(랜드마크 대체 시).
    public var fallbackReason: String?
    public var medianInferenceMilliseconds: Double?

    public init(kind: Kind, identifier: String, modelName: String? = nil, fallbackReason: String? = nil,
                medianInferenceMilliseconds: Double? = nil) {
        self.kind = kind; self.identifier = identifier; self.modelName = modelName; self.fallbackReason = fallbackReason
        self.medianInferenceMilliseconds = medianInferenceMilliseconds
    }

    public var summary: String {
        switch kind {
        case .cnn:
            let latency = medianInferenceMilliseconds.map { String(format: " · %.1fms", $0) } ?? ""
            return "시선 추정: CNN (\(modelName ?? identifier))\(latency)"
        case .landmarks:
            return "시선 추정: 랜드마크(정확도 낮음)" + (fallbackReason.map { " — \($0)" } ?? "")
        case .pending:
            return "시선 추정: 모델 준비 중…"
        }
    }
}

/// 모든 시선 소스가 공유하는 스레드 안전 처리기. 파이프라인 상태를 Mutex로 보호하고 결과를 스트림으로 내보낸다.
///
/// `AsyncStream`은 소비자 하나를 전제로 한다. 표본 스트림은 최신값 위주로 버퍼링한다.
public final class GazeEngine: Sendable {
    struct PendingRefit: Sendable {
        var displayID: UInt32
        var due: MonotonicTime
    }

    struct State: Sendable {
        var pipeline: GazePipeline
        var collector: CalibrationCollector?
        var validationCollector: CalibrationCollector?
        /// 마지막으로 보정(또는 검증)한 디스플레이.
        var lastCalibratedDisplay: UInt32?
        var pendingValidation: (displayID: UInt32, samples: [CalibrationSample], report: CalibrationValidationReport)?
        var latestFeatures: GazeFeatures?
        /// 최근 특징(클릭 짝짓기용, `historyDuration`초).
        var history: [GazeFeatures] = []
        var lastDisplayRefresh: MonotonicTime?
        var estimatorID: String?
        var scaleFloors: [Double] = []
        var datasets: [UInt32: CalibrationDataset] = [:]
        var implicitStats = ImplicitCalibrationStats()
        var pendingRefit: PendingRefit?
        var lastRefitAt: MonotonicTime?
        var refitInFlight = false
        var headPosition: HeadPositionStatus?
    }

    public let samples: AsyncStream<GazeSample>
    public let nonverbalCues: AsyncStream<NonverbalCue>
    public let clock: any MonotonicClock
    public let implicitConfiguration: ImplicitCalibrationConfiguration
    private let sampleContinuation: AsyncStream<GazeSample>.Continuation
    private let cueContinuation: AsyncStream<NonverbalCue>.Continuation
    private let state: Mutex<State>
    private let observer = Mutex<(@Sendable (CalibrationEvent) -> Void)?>(nil)
    private let refitQueue = DispatchQueue(label: "gaze.calibration.refit", qos: .utility)
    private let historyDuration = 1.5

    public init(configuration: GazePipelineConfiguration = .init(), clock: any MonotonicClock = GazeUptimeClock(),
                regionKeyer: GazeRegionKeying? = nil, sampleBufferLimit: Int = 8, cueBufferLimit: Int = 256,
                implicitConfiguration: ImplicitCalibrationConfiguration = .init()) {
        self.clock = clock
        self.implicitConfiguration = implicitConfiguration
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

    /// 보정 상태가 바뀔 때 호출할 처리기(임의 스레드에서 호출된다).
    public func setCalibrationObserver(_ handler: (@Sendable (CalibrationEvent) -> Void)?) {
        observer.withLock { $0 = handler }
    }

    private func notify(_ event: CalibrationEvent) {
        let handler = observer.withLock { $0 }
        handler?(event)
    }

    // MARK: 입력

    public func ingest(_ features: GazeFeatures) {
        let (output, refit) = state.withLock { state -> (GazePipelineOutput, RefitJob?) in
            state.latestFeatures = features
            state.history.append(features)
            if let first = state.history.first, features.time.seconds(since: first.time) > historyDuration {
                state.history.removeAll { features.time.seconds(since: $0.time) > historyDuration }
            }
            state.collector?.add(features)
            state.validationCollector?.add(features)
            let output = state.pipeline.process(features)
            return (output, takeDueRefit(&state, now: features.time))
        }
        emit(output)
        if let refit { run(refit) }
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

    /// 최근 얼굴 위치(카메라 소스가 프레임마다 갱신).
    public func updateHeadPosition(_ status: HeadPositionStatus?) {
        state.withLock { $0.headPosition = status }
    }

    public var headPosition: HeadPositionStatus? { state.withLock { $0.headPosition } }

    // MARK: 추정기

    /// 시선 추정기를 정한다. 다른 추정기로 학습된 보정·데이터는 무효화한다.
    @discardableResult
    public func setEstimator(id: String, scaleFloors: [Double]) -> [UInt32] {
        state.withLock { state in
            state.estimatorID = id
            state.scaleFloors = scaleFloors
            state.datasets = state.datasets.filter { $0.value.estimatorID == id }
            return state.pipeline.calibration.setEstimator(id)
        }
    }

    public var estimatorID: String? { state.withLock { $0.estimatorID } }

    // MARK: 디스플레이

    public var displays: [DisplayGeometry] { state.withLock { $0.pipeline.calibration.displays } }

    /// 디스플레이 배치를 갱신하고 무효화된 보정의 디스플레이 ID를 돌려준다.
    @discardableResult
    public func updateDisplays(_ displays: [DisplayGeometry]) -> [UInt32] {
        state.withLock { state in
            let invalidated = state.pipeline.calibration.updateDisplays(displays)
            if let collector = state.collector, !displays.contains(collector.display) { state.collector = nil }
            if let collector = state.validationCollector, !displays.contains(collector.display) {
                state.validationCollector = nil
            }
            state.datasets = state.datasets.filter { displays.contains($0.value.display) }
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
    public var isCalibrating: Bool { state.withLock { $0.collector != nil || $0.validationCollector != nil } }
    public var implicitStats: ImplicitCalibrationStats { state.withLock { $0.implicitStats } }

    private func options(_ base: CalibrationOptions, _ state: State) -> CalibrationOptions {
        var options = base
        if let id = state.estimatorID { options.estimatorID = id }
        if options.scaleFloors.isEmpty { options.scaleFloors = state.scaleFloors }
        return options
    }

    public func beginCalibration(on display: DisplayGeometry) {
        state.withLock { $0.collector = CalibrationCollector(display: display); $0.validationCollector = nil }
    }

    public func beginCalibration(displayID: UInt32) throws {
        try state.withLock { state in
            guard let display = state.pipeline.calibration.displays.first(where: { $0.id == displayID }) else {
                throw CalibrationError.unknownDisplay(displayID)
            }
            state.collector = CalibrationCollector(display: display)
            state.validationCollector = nil
            state.pendingValidation = nil
        }
    }

    /// 표적 수집 시작. `settle`(초)을 주면 이 표적의 정착 구간을 바꾼다.
    public func beginCalibrationTarget(_ point: CGPoint, settle: Double? = nil) throws {
        let now = clock.now()
        try state.withLock { state in
            guard state.collector != nil else { throw CalibrationError.noActiveSession }
            state.collector?.beginTarget(point, at: now, settle: settle)
        }
    }

    @discardableResult
    public func endCalibrationTarget() throws -> Int {
        try state.withLock { state in
            guard state.collector != nil else { throw CalibrationError.noActiveSession }
            return state.collector!.endTarget()
        }
    }

    public func endCalibrationTarget(rejectFlagged: Bool) throws -> CalibrationTargetResult {
        try state.withLock { state in
            guard state.collector != nil else { throw CalibrationError.noActiveSession }
            guard let result = state.collector!.endTargetDetailed(rejectFlagged: rejectFlagged) else {
                throw CalibrationError.noActiveTarget
            }
            return result
        }
    }

    public func abortCalibrationTarget() {
        state.withLock { $0.collector?.abortTarget(); $0.validationCollector?.abortTarget() }
    }

    /// 수집한 표본으로 모델을 적합해 설치한다. 실패해도 수집 세션은 유지된다(표적 추가 후 재시도 가능).
    /// 새 명시 보정이므로 그 디스플레이의 암묵 표본은 비운다.
    public func finishCalibration(options: CalibrationOptions = .init()) throws -> CalibrationReport {
        let report = try state.withLock { state -> CalibrationReport in
            guard let collector = state.collector else { throw CalibrationError.noActiveSession }
            let resolved = self.options(options, state)
            let model = try state.pipeline.calibration.fit(samples: collector.samples, display: collector.display,
                                                           options: resolved)
            state.datasets[collector.display.id] = CalibrationDataset(
                display: collector.display, estimatorID: resolved.estimatorID, samples: collector.samples)
            state.lastCalibratedDisplay = collector.display.id
            state.collector = nil
            state.pendingRefit = nil
            return CalibrationReport(model, pointsPerCentimeter: collector.display.pointsPerCentimeter)
        }
        GazeLog.calibration.info("calibrated display \(report.displayID): \(report.targetCount) targets, \(report.sampleCount) samples, \(report.kind.rawValue, privacy: .public)+\(report.auxiliaryTerms.rawValue, privacy: .public) λ=\(report.lambda) CV \(report.crossValidatedRMSE, format: .fixed(precision: 1))pt train \(report.trainingRMSE, format: .fixed(precision: 1))pt")
        notify(.calibrated(report))
        return report
    }

    public func cancelCalibration() {
        state.withLock { $0.collector = nil; $0.validationCollector = nil }
    }

    // MARK: 검증

    /// 최근 보정한(또는 지정한) 디스플레이에서 검증을 시작한다. 그 디스플레이 모델이 있어야 한다.
    public func beginValidation(displayID: UInt32? = nil) throws {
        try state.withLock { state in
            guard let id = displayID ?? state.lastCalibratedDisplay,
                  let model = state.pipeline.calibration.model(for: id) else { throw CalibrationError.noModel }
            state.validationCollector = CalibrationCollector(display: model.display, source: .validation)
            state.pendingValidation = nil
        }
    }

    public func beginValidationTarget(_ point: CGPoint, settle: Double? = nil) throws {
        let now = clock.now()
        try state.withLock { state in
            guard state.validationCollector != nil else { throw CalibrationError.noActiveSession }
            state.validationCollector?.beginTarget(point, at: now, settle: settle)
        }
    }

    public func endValidationTarget(rejectFlagged: Bool) throws -> CalibrationTargetResult {
        try state.withLock { state in
            guard state.validationCollector != nil else { throw CalibrationError.noActiveSession }
            guard let result = state.validationCollector!.endTargetDetailed(rejectFlagged: rejectFlagged) else {
                throw CalibrationError.noActiveTarget
            }
            return result
        }
    }

    /// 검증 점 오차를 계산하고 모델에 요약을 붙인다(리비전 유지). 검증 표본은 `acceptValidation`까지 보관한다.
    public func finishValidation() throws -> CalibrationValidationReport {
        let report = try state.withLock { state -> CalibrationValidationReport in
            guard let collector = state.validationCollector else { throw CalibrationError.noActiveSession }
            guard let model = state.pipeline.calibration.model(for: collector.display.id) else {
                throw CalibrationError.noModel
            }
            typealias Key = CalibrationModel.TargetKey
            var grouped: [Key: [GazeFeatures]] = [:]
            var order: [Key] = []
            for sample in collector.samples {
                let key = Key(x: Double(sample.target.x), y: Double(sample.target.y))
                if grouped[key] == nil { order.append(key) }
                grouped[key, default: []].append(sample.features)
            }
            let report = CalibrationValidation.evaluate(
                model: model, targets: order.map { (CGPoint(x: $0.x, y: $0.y), grouped[$0]!) },
                pointsPerCentimeter: collector.display.pointsPerCentimeter)
            if !report.points.isEmpty {
                try state.pipeline.calibration.refine(model.withValidation(report.summary))
            }
            state.pendingValidation = (collector.display.id, collector.samples, report)
            state.validationCollector = nil
            return report
        }
        GazeLog.calibration.info("validation display \(report.displayID): mean \(report.meanError, format: .fixed(precision: 1))pt (\(report.meanErrorCm ?? -1, format: .fixed(precision: 2))cm) rmse \(report.rmse, format: .fixed(precision: 1))pt max \(report.maxError, format: .fixed(precision: 1))pt over \(report.points.count) points")
        notify(.validated(report))
        return report
    }

    /// 보관한 검증 표본을 학습 데이터에 합쳐 다시 적합한다(검증 요약은 유지, 리비전 유지).
    public func acceptValidation(options: CalibrationOptions = .init()) throws -> CalibrationReport {
        let report = try state.withLock { state -> CalibrationReport in
            guard let pending = state.pendingValidation,
                  var dataset = state.datasets[pending.displayID],
                  let current = state.pipeline.calibration.model(for: pending.displayID) else {
                throw CalibrationError.noModel
            }
            dataset.samples += pending.samples
            let resolved = self.options(options, state)
            let refit = try CalibrationModel.fit(samples: dataset.trainingSamples(now: Date(), configuration: implicitConfiguration),
                                                 display: dataset.display, revision: current.revision, options: resolved)
            let installed = try state.pipeline.calibration.refine(refit.withValidation(current.validation))
            state.datasets[pending.displayID] = dataset
            state.pendingValidation = nil
            return CalibrationReport(installed, pointsPerCentimeter: dataset.display.pointsPerCentimeter)
        }
        notify(.refined(report))
        return report
    }

    // MARK: 암묵 재보정(클릭)

    /// 클릭(전역 좌표, 엔진 시계 시각)을 직전 특징과 짝지어 암묵 보정 표본으로 쌓는다.
    @discardableResult
    public func recordImplicitClick(at point: CGPoint, time: MonotonicTime, date: Date = Date())
        -> Result<Double, ImplicitPairRejection> {
        let configuration = implicitConfiguration
        return state.withLock { state -> Result<Double, ImplicitPairRejection> in
            func reject(_ reason: ImplicitPairRejection) -> Result<Double, ImplicitPairRejection> {
                state.implicitStats.rejected[reason.rawValue, default: 0] += 1
                return .failure(reason)
            }
            guard state.collector == nil, state.validationCollector == nil else { return reject(.calibrating) }
            let calibration = state.pipeline.calibration
            guard let display = DisplayGeometry.display(for: point, in: calibration.displays),
                  display.contains(point) else { return reject(.otherDisplay) }
            guard let model = calibration.model(for: display.id), state.datasets[display.id] != nil else {
                return reject(.uncalibrated)
            }
            switch ImplicitCalibration.pair(click: point, clickTime: time, history: state.history, model: model,
                                            configuration: configuration) {
            case .failure(let reason):
                return reject(reason)
            case .success(let paired):
                state.datasets[display.id]!.implicit.add(features: paired.features, target: point, at: date,
                                                         predictionError: paired.predictionError,
                                                         configuration: configuration)
                state.implicitStats.accepted += 1
                var due = time.adding(seconds: configuration.refitDelay)
                if let last = state.lastRefitAt {
                    let earliest = last.adding(seconds: configuration.minimumRefitInterval)
                    if earliest > due { due = earliest }
                }
                state.pendingRefit = PendingRefit(displayID: display.id, due: due)
                return .success(paired.predictionError)
            }
        }
    }

    struct RefitJob: Sendable {
        var displayID: UInt32
        var baseRevision: Int
        var samples: [CalibrationSample]
        var display: DisplayGeometry
        var options: CalibrationOptions
        var validation: CalibrationModel.ValidationSummary?
    }

    /// 예약된 암묵 재적합이 때가 되면 작업을 꺼낸다(잠금 안에서 호출).
    private func takeDueRefit(_ state: inout State, now: MonotonicTime) -> RefitJob? {
        guard let pending = state.pendingRefit, now >= pending.due, !state.refitInFlight,
              state.collector == nil, state.validationCollector == nil else { return nil }
        state.pendingRefit = nil
        guard var dataset = state.datasets[pending.displayID],
              let model = state.pipeline.calibration.model(for: pending.displayID) else { return nil }
        let date = Date()
        dataset.implicit.prune(now: date, configuration: implicitConfiguration)
        state.datasets[pending.displayID] = dataset
        state.refitInFlight = true
        state.lastRefitAt = now
        return RefitJob(displayID: pending.displayID, baseRevision: model.revision,
                        samples: dataset.trainingSamples(now: date, configuration: implicitConfiguration),
                        display: dataset.display, options: options(.init(), state), validation: model.validation)
    }

    private func run(_ job: RefitJob) {
        refitQueue.async { [self] in
            let model = try? CalibrationModel.fit(samples: job.samples, display: job.display, revision: job.baseRevision,
                                                  options: job.options)
            completeRefit(job, model: model)
        }
    }

    /// 백그라운드 적합 결과를 설치한다. 그사이 명시 보정이 있었으면 버린다.
    private func completeRefit(_ job: RefitJob, model: CalibrationModel?) {
        let report = state.withLock { state -> CalibrationReport? in
            state.refitInFlight = false
            guard let model, let current = state.pipeline.calibration.model(for: job.displayID),
                  current.revision == job.baseRevision, state.collector == nil else { return nil }
            guard let installed = try? state.pipeline.calibration.refine(model.withValidation(job.validation)) else {
                return nil
            }
            state.implicitStats.refits += 1
            state.implicitStats.lastRefitCVRMSE = installed.crossValidatedRMSE
            state.implicitStats.lastRefitAt = Date()
            return CalibrationReport(installed, pointsPerCentimeter: job.display.pointsPerCentimeter)
        }
        if let report {
            GazeLog.calibration.info("implicit refit display \(report.displayID): \(report.implicitCount) clicks + \(report.targetCount) targets, CV \(report.crossValidatedRMSE, format: .fixed(precision: 1))pt")
            notify(.refined(report))
        }
    }

    /// 예약된 암묵 재적합을 지금 실행한다(검사·종료 전 저장용). 백그라운드 큐가 끝날 때까지 기다린다.
    public func flushImplicitRefit() {
        let job = state.withLock { state -> RefitJob? in
            if var pending = state.pendingRefit {
                pending.due = MonotonicTime(nanoseconds: 0)
                state.pendingRefit = pending
            }
            return takeDueRefit(&state, now: clock.now())
        }
        guard let job else { return }
        refitQueue.sync {
            let model = try? CalibrationModel.fit(samples: job.samples, display: job.display, revision: job.baseRevision,
                                                  options: job.options)
            completeRefit(job, model: model)
        }
    }

    // MARK: 저장·복원

    /// 저장해 둔 모델 복원 등. 현재 디스플레이 배치·추정기와 맞지 않으면 오류.
    @discardableResult
    public func install(_ model: CalibrationModel) throws -> CalibrationModel {
        try state.withLock { try $0.pipeline.calibration.install(model) }
    }

    public func clearCalibration(displayID: UInt32) {
        state.withLock {
            _ = $0.pipeline.calibration.invalidate(displayID: displayID)
            $0.datasets[displayID] = nil
        }
    }

    public func exportArchive() -> CalibrationArchive {
        state.withLock { state in
            CalibrationArchive(
                estimatorID: state.estimatorID ?? "",
                models: Array(state.pipeline.calibration.models.values).sorted { $0.display.id < $1.display.id },
                datasets: Array(state.datasets.values).sorted { $0.display.id < $1.display.id })
        }
    }

    /// 보관 파일을 복원한다. 현재 추정기·디스플레이와 맞는 모델만 설치하고 설치 수를 돌려준다.
    @discardableResult
    public func importArchive(_ archive: CalibrationArchive) -> Int {
        let installed = state.withLock { state -> Int in
            var count = 0
            for model in archive.models {
                guard (try? state.pipeline.calibration.install(model)) != nil else { continue }
                count += 1
                if let dataset = archive.datasets.first(where: { $0.display == model.display
                    && $0.estimatorID == model.estimatorID }) {
                    state.datasets[model.display.id] = dataset
                }
                state.lastCalibratedDisplay = model.display.id
            }
            return count
        }
        if installed > 0 { notify(.restored(installed)) }
        return installed
    }

    public var datasets: [CalibrationDataset] {
        state.withLock { Array($0.datasets.values).sorted { $0.display.id < $1.display.id } }
    }
}
