import AgentContracts
import AppKit
import Gaze
import Observation
import SwiftUI

/// 보정 진행 상태.
@MainActor
@Observable
final class CalibrationSessionModel {
    enum Stage: Equatable { case settling, collecting }

    struct Target: Equatable {
        var index: Int
        var total: Int
        /// 창 안 좌표(좌상단 원점).
        var point: CGPoint
        var stage: Stage
        var validation: Bool
        var attempt: Int
    }

    struct Result: Equatable {
        enum Quality: Equatable { case good, fair, poor }
        var quality: Quality
        var headline: String
        var details: [String]
        /// 검증 점별 (표적, 예측) 창 좌표 — 결과 화면에 오차를 그린다.
        var errors: [(CGPoint, CGPoint)]

        static func == (lhs: Result, rhs: Result) -> Bool {
            lhs.quality == rhs.quality && lhs.headline == rhs.headline && lhs.details == rhs.details
                && lhs.errors.count == rhs.errors.count
        }
    }

    enum Phase: Equatable {
        case intro
        case target(Target)
        case notice(String)
        case fitting(String)
        case result(Result)
        case failed(message: String)
    }

    var phase: Phase = .intro
    /// 실시간 자세 안내(문제가 없으면 nil).
    var guidance: String?
    /// 거울처럼 보이는 얼굴 위치(0…1)와 거리.
    var face: (x: Double, y: Double, distance: Double)?
    var estimatorSummary: String
    let calibrationCount: Int
    let validationCount: Int

    init(calibrationCount: Int, validationCount: Int, estimatorSummary: String) {
        self.calibrationCount = calibrationCount
        self.validationCount = validationCount
        self.estimatorSummary = estimatorSummary
    }
}

struct CalibrationView: View {
    let model: CalibrationSessionModel
    let onStart: () -> Void
    let onAccept: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.9).ignoresSafeArea()
            switch model.phase {
            case .intro:
                panel(title: "시선 보정") {
                    Text("""
                        점 \(model.calibrationCount)개가 차례로 나타납니다. 점이 작아지면 가운데를 끝까지 바라보세요.
                        이어서 확인용 점 \(model.validationCount)개로 정확도를 잽니다.
                        머리는 편하게 고정하고 눈으로만 보세요. Esc를 누르면 취소합니다.
                        """)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    FacePositionView(face: model.face, guidance: model.guidance)
                    Text(model.estimatorSummary).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button("시작", action: onStart).keyboardShortcut(.defaultAction)
                        Button("취소", action: onCancel).keyboardShortcut(.cancelAction)
                    }
                }
            case .target(let target):
                TargetDot(stage: target.stage, validation: target.validation)
                    .position(target.point)
                    .id("\(target.validation)-\(target.index)-\(target.attempt)")
                VStack(spacing: 6) {
                    if let guidance = model.guidance {
                        Label(guidance, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.yellow)
                    }
                    Text("\(target.validation ? "확인" : "보정") \(target.index + 1) / \(target.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 28)
            case .notice(let message):
                Label(message, systemImage: "arrow.counterclockwise")
                    .font(.title3)
                    .foregroundStyle(.yellow)
            case .fitting(let message):
                ProgressView(message)
                    .tint(.white)
                    .foregroundStyle(.white)
            case .result(let result):
                ForEach(Array(result.errors.enumerated()), id: \.offset) { _, pair in
                    ErrorMarker(target: pair.0, predicted: pair.1)
                }
                panel(title: result.headline) {
                    ForEach(result.details, id: \.self) { line in
                        Text(line).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Button("확인", action: onAccept).keyboardShortcut(.defaultAction)
                        Button("다시 보정", action: onStart)
                        Button("취소", action: onCancel).keyboardShortcut(.cancelAction)
                    }
                }
            case .failed(let message):
                panel(title: "보정 실패") {
                    Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    FacePositionView(face: model.face, guidance: model.guidance)
                    HStack(spacing: 12) {
                        Button("다시", action: onStart).keyboardShortcut(.defaultAction)
                        Button("닫기", action: onCancel).keyboardShortcut(.cancelAction)
                    }
                }
            }
        }
    }

    private func panel<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 14) {
            Text(title).font(.title.bold())
            content()
        }
        .padding(28)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .environment(\.colorScheme, .dark)
    }
}

/// 거울처럼 본 얼굴 위치 미니맵 + 안내 문구.
private struct FacePositionView: View {
    let face: (x: Double, y: Double, distance: Double)?
    let guidance: String?

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.35), lineWidth: 1)
                RoundedRectangle(cornerRadius: 4)
                    .stroke(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: 160 * 0.3, height: 90 * 0.43)
                    .offset(y: 90 * (0.435 - 0.5))
                if let face {
                    Circle()
                        .fill(guidance == nil ? Color.green : Color.yellow)
                        .frame(width: 14, height: 14)
                        .position(x: 160 * face.x, y: 90 * face.y)
                }
            }
            .frame(width: 160, height: 90)
            Group {
                if let guidance {
                    Text(guidance).foregroundStyle(.yellow)
                } else if let face {
                    Text("자세 좋음 · 약 \(Int(face.distance.rounded()))cm").foregroundStyle(.green)
                } else {
                    Text("얼굴을 찾는 중…").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }
}

/// 바라볼 점. 나타나면 바깥 고리가 0.5초 동안 줄어들고(정착), 수집하는 동안 진행 고리가 찬다.
private struct TargetDot: View {
    let stage: CalibrationSessionModel.Stage
    let validation: Bool
    @State private var shrunk = false
    @State private var progress = 0.0

    private var tint: Color { validation ? Color(red: 0.45, green: 0.8, blue: 1) : Color(red: 0.72, green: 0.96, blue: 0.42) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.9), lineWidth: 3)
                .frame(width: shrunk ? 18 : 72, height: shrunk ? 18 : 72)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 30, height: 30)
            Circle().fill(.white).frame(width: 6, height: 6)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) { shrunk = true }
        }
        .onChange(of: stage) { _, now in
            if now == .collecting { withAnimation(.linear(duration: 1.2)) { progress = 1 } }
        }
    }
}

/// 검증 결과: 표적(흰 점)과 예측(색 점)을 잇는 선.
private struct ErrorMarker: View {
    let target: CGPoint
    let predicted: CGPoint

    var body: some View {
        ZStack {
            Path { path in
                path.move(to: target)
                path.addLine(to: predicted)
            }
            .stroke(.orange.opacity(0.8), lineWidth: 2)
            Circle().fill(.white).frame(width: 8, height: 8).position(target)
            Circle().fill(.orange).frame(width: 10, height: 10).position(predicted)
        }
    }
}

/// 키 입력(Esc)을 받는 테두리 없는 전체 화면 창.
private final class CalibrationPanel: NSWindow {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// 주 화면에서 16점 보정 + 5점 검증을 진행한다. `GazeCalibrating`(VisionGazeSource)을 쓴다.
///
/// 흐름: beginCalibration → 점마다 collectTarget(정착 0.5초 버림 + 수집 1.2초, 머리가 움직였거나 표본이 부족하면
/// 한 번 다시) → finishCalibration → beginValidation → 검증 점 5개 → finishValidation → 결과(평균 오차 pt·cm)
/// → 확인(검증 점을 학습에 합침) / 다시 보정.
@MainActor
final class CalibrationWindowController: NSObject, NSWindowDelegate {
    private let calibrator: any GazeCalibrating
    private let onCalibrated: () -> Void
    private let onFinish: () -> Void
    private let model: CalibrationSessionModel
    private let window: CalibrationPanel
    private var display: Gaze.DisplayGeometry?
    private var targets: [CGPoint] = []
    private var validationTargets: [CGPoint] = []
    private var task: Task<Void, Never>?
    private var guidanceTask: Task<Void, Never>?
    private var finished = false
    private var awaitingAcceptance = false

    static let settle = Duration.milliseconds(500)
    static let collect = Duration.milliseconds(1200)
    static let validationCollect = Duration.milliseconds(1000)

    /// - Parameters:
    ///   - onCalibrated: 보정 모델이 바뀔 때마다(저장용).
    ///   - onFinish: 창이 닫힐 때 한 번.
    init(calibrator: any GazeCalibrating, onCalibrated: @escaping () -> Void, onFinish: @escaping () -> Void) {
        self.calibrator = calibrator
        self.onCalibrated = onCalibrated
        self.onFinish = onFinish
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let displayID = number?.uint32Value ?? CGMainDisplayID()
        // Gaze 보정 좌표는 전역 좌상단 원점(CGDisplayBounds)이다.
        let display = Gaze.DisplayGeometry(id: displayID, frame: CGDisplayBounds(displayID))
        self.display = display
        targets = CalibrationTargetLayout.serpentine(rows: 4, columns: 4, in: display)
        validationTargets = CalibrationTargetLayout.validation(in: display)
        model = CalibrationSessionModel(calibrationCount: targets.count, validationCount: validationTargets.count,
                                        estimatorSummary: calibrator.estimatorStatus.summary)
        window = CalibrationPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self
        window.onEscape = { [weak self] in self?.close() }
        let view = CalibrationView(model: model,
                                   onStart: { [weak self] in self?.run() },
                                   onAccept: { [weak self] in self?.accept() },
                                   onCancel: { [weak self] in self?.close() })
        window.contentView = NSHostingView(rootView: view)
        window.setFrame(screen.frame, display: true)
    }

    func present() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        startGuidance()
    }

    func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        task = nil
        guidanceTask?.cancel()
        guidanceTask = nil
        guard !finished else { return }
        finished = true
        let calibrator = self.calibrator
        Task { await calibrator.cancelCalibration() }
        onFinish()
    }

    /// 얼굴 위치를 10Hz로 읽어 안내 문구를 갱신한다.
    private func startGuidance() {
        guidanceTask?.cancel()
        let calibrator = self.calibrator
        guidanceTask = Task { [weak self] in
            while !Task.isCancelled {
                let status = calibrator.headPosition
                let issues = HeadPositionGuidance.evaluate(status, now: calibrator.now)
                if let self {
                    self.model.guidance = HeadPositionGuidance.primaryMessage(issues)
                    if let status, !issues.contains(.noFace) {
                        self.model.face = (status.mirroredX, Double(status.faceCenter.y), status.distanceCm)
                    } else {
                        self.model.face = nil
                    }
                    self.model.estimatorSummary = calibrator.estimatorStatus.summary
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func local(_ point: CGPoint) -> CGPoint {
        guard let origin = display?.frame.origin else { return point }
        return CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    }

    /// 표적 하나: 점을 띄우고 정착 후 진행 고리를 채운다. 문제가 있으면 한 번 다시 본다.
    private func collect(_ point: CGPoint, index: Int, total: Int, validation: Bool) async throws {
        let calibrator = self.calibrator
        for attempt in 0..<2 {
            let base = CalibrationSessionModel.Target(index: index, total: total, point: local(point), stage: .settling,
                                                      validation: validation, attempt: attempt)
            model.phase = .target(base)
            let collectDuration = validation ? Self.validationCollect : Self.collect
            async let result = validation
                ? calibrator.collectValidationTarget(at: point, settle: Self.settle, collect: collectDuration,
                                                     rejectFlagged: attempt == 0)
                : calibrator.collectTarget(at: point, settle: Self.settle, collect: collectDuration,
                                           rejectFlagged: attempt == 0)
            try await Task.sleep(for: Self.settle)
            var collecting = base
            collecting.stage = .collecting
            model.phase = .target(collecting)
            let outcome = try await result
            guard let issue = outcome.issue, attempt == 0 else { return }
            model.phase = .notice(issue == .headMoved
                ? "머리가 움직였어요. 같은 점을 한 번 더 볼게요."
                : "눈이 잘 보이지 않았어요. 같은 점을 한 번 더 볼게요.")
            try await Task.sleep(for: .milliseconds(900))
        }
    }

    private func run() {
        guard let display, task == nil else { return }
        let calibrator = self.calibrator
        let targets = self.targets, validationTargets = self.validationTargets
        awaitingAcceptance = false
        task = Task { [weak self] in
            defer { self?.task = nil }
            do {
                try await calibrator.beginCalibration(displayID: display.id)
                for (index, point) in targets.enumerated() {
                    try await self?.collect(point, index: index, total: targets.count, validation: false)
                }
                self?.model.phase = .fitting("보정 모델을 계산하는 중…")
                let report = try await calibrator.finishCalibration(options: CalibrationOptions())
                self?.onCalibrated()
                try await calibrator.beginValidation()
                for (index, point) in validationTargets.enumerated() {
                    try await self?.collect(point, index: index, total: validationTargets.count, validation: true)
                }
                self?.model.phase = .fitting("정확도를 계산하는 중…")
                let validation = try await calibrator.finishValidation()
                self?.onCalibrated()
                guard let self else { return }
                self.awaitingAcceptance = true
                self.model.phase = .result(self.summarize(report, validation))
            } catch is CancellationError {
                await calibrator.cancelCalibration()
            } catch {
                await calibrator.cancelCalibration()
                self?.model.phase = .failed(message: Self.describe(error))
            }
        }
    }

    /// 확인: 검증 점을 학습에 합쳐 다시 적합하고 저장한 뒤 닫는다.
    private func accept() {
        guard awaitingAcceptance, task == nil else { close(); return }
        awaitingAcceptance = false
        let calibrator = self.calibrator
        task = Task { [weak self] in
            defer { self?.task = nil }
            _ = try? await calibrator.acceptValidation()
            self?.onCalibrated()
            self?.close()
        }
    }

    private func summarize(_ report: CalibrationReport, _ validation: CalibrationValidationReport) -> CalibrationSessionModel.Result {
        func cm(_ points: Double, _ value: Double?) -> String {
            value.map { String(format: "%.1fcm (%.0fpt)", $0, points) } ?? String(format: "%.0fpt", points)
        }
        let meanCm = validation.meanErrorCm
        let quality: CalibrationSessionModel.Result.Quality
        switch meanCm ?? validation.meanError / 50 {
        case ..<2.0: quality = .good
        case ..<3.5: quality = .fair
        default: quality = .poor
        }
        let headline = switch quality {
        case .good: "보정 완료 — 정확도 좋음"
        case .fair: "보정 완료 — 정확도 보통"
        case .poor: "정확도가 낮습니다 — 다시 보정을 권장합니다"
        }
        var details = [
            "확인 점 \(validation.points.count)개 평균 오차 \(cm(validation.meanError, meanCm)) · 최대 \(cm(validation.maxError, validation.maxErrorCm))",
            "교차 검증 \(cm(report.crossValidatedRMSE, report.crossValidatedCm)) · 표적 \(report.targetCount)개 · 표본 \(report.sampleCount)개 · 모델 \(report.kind.rawValue)+\(report.auxiliaryTerms.rawValue)",
            calibrator.estimatorStatus.summary,
        ]
        if validation.missingPoints > 0 {
            details.append("얼굴을 찾지 못한 확인 점 \(validation.missingPoints)개")
        }
        if quality == .poor {
            details.append("얼굴을 밝게 비추고, 화면에서 50–70cm 거리에서 머리를 움직이지 말고 다시 해 보세요.")
        }
        details.append("‘확인’을 누르면 확인 점까지 학습에 넣습니다. 사용 중 클릭할 때마다 조금씩 더 맞춰집니다.")
        let errors = validation.points.map { (local($0.target), local($0.predicted)) }
        return .init(quality: quality, headline: headline, details: details, errors: errors)
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case CalibrationError.insufficientTargets(let found, let required):
            return "얼굴이 잘 보이는 표적이 \(found)개뿐입니다(최소 \(required)개). 조명을 밝게 하고 카메라를 정면으로 두세요."
        case CalibrationError.unknownDisplay:
            return "디스플레이 정보를 찾지 못했습니다. 카메라 시선이 실행 중인지 확인하세요."
        case CalibrationError.noModel:
            return "보정 모델이 없어 정확도를 잴 수 없습니다. 다시 보정해 주세요."
        default:
            return "\(error)"
        }
    }
}
