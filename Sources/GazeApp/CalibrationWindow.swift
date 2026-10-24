import AppKit
import Gaze
import Observation
import SwiftUI

/// 9점 보정 진행 상태.
@MainActor
@Observable
final class CalibrationSessionModel {
    enum Phase: Equatable {
        case intro
        /// index번째 표적(0부터). point는 창 안 좌표(좌상단 원점).
        case target(index: Int, point: CGPoint, collecting: Bool)
        case fitting
        case done(summary: String)
        case failed(message: String)
    }

    var phase: Phase = .intro
    let total: Int

    init(total: Int) { self.total = total }
}

struct CalibrationView: View {
    let model: CalibrationSessionModel
    let onStart: () -> Void
    let onCancel: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.88).ignoresSafeArea()
            switch model.phase {
            case .intro:
                panel(title: "시선 보정",
                      message: "화면에 점 \(model.total)개가 차례로 나타납니다.\n머리는 편하게 두고 눈으로만 각 점의 가운데를 바라보세요.\nEsc를 누르면 취소합니다.") {
                    Button("시작", action: onStart).keyboardShortcut(.defaultAction)
                    Button("취소", action: onCancel).keyboardShortcut(.cancelAction)
                }
            case .target(let index, let point, let collecting):
                TargetDot(collecting: collecting)
                    .position(point)
                    .id(index)
                Text("\(index + 1) / \(model.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 24)
            case .fitting:
                ProgressView("보정 모델을 계산하는 중…")
                    .tint(.white)
                    .foregroundStyle(.white)
            case .done(let summary):
                panel(title: "보정 완료", message: summary) {
                    Button("다시", action: onStart)
                    Button("닫기", action: onClose).keyboardShortcut(.defaultAction)
                }
            case .failed(let message):
                panel(title: "보정 실패", message: message) {
                    Button("다시", action: onStart).keyboardShortcut(.defaultAction)
                    Button("닫기", action: onClose).keyboardShortcut(.cancelAction)
                }
            }
        }
    }

    private func panel<Buttons: View>(title: String, message: String,
                                      @ViewBuilder buttons: () -> Buttons) -> some View {
        VStack(spacing: 14) {
            Text(title).font(.title.bold())
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack(spacing: 12) { buttons() }
        }
        .padding(28)
        .frame(maxWidth: 460)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .environment(\.colorScheme, .dark)
    }
}

/// 바라볼 점. 모으는 동안 바깥 고리가 줄어든다.
private struct TargetDot: View {
    let collecting: Bool
    @State private var shrink = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(red: 0.72, green: 0.96, blue: 0.42), lineWidth: 3)
                .frame(width: shrink ? 14 : 54, height: shrink ? 14 : 54)
            Circle()
                .fill(.white)
                .frame(width: 8, height: 8)
        }
        .onAppear { shrink = false }
        .onChange(of: collecting) { _, now in
            withAnimation(.easeInOut(duration: 1.1)) { shrink = now }
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

/// 주 화면에서 9점 보정을 진행한다. `GazeCalibrating`(VisionGazeSource)을 쓴다.
///
/// 흐름: beginCalibration → 점마다 시선 이동 시간(0.6초) 뒤 collectCalibrationTarget(1.2초) → finishCalibration.
@MainActor
final class CalibrationWindowController: NSObject, NSWindowDelegate {
    private let calibrator: any GazeCalibrating
    private let onCalibrated: () -> Void
    private let onFinish: () -> Void
    private let model: CalibrationSessionModel
    private let window: CalibrationPanel
    private var display: Gaze.DisplayGeometry?
    private var targets: [CGPoint] = []
    private var task: Task<Void, Never>?
    private var finished = false

    /// - Parameters:
    ///   - onCalibrated: 보정이 성공할 때마다(모델 저장용).
    ///   - onFinish: 창이 닫힐 때 한 번.
    init(calibrator: any GazeCalibrating, onCalibrated: @escaping () -> Void, onFinish: @escaping () -> Void) {
        self.calibrator = calibrator
        self.onCalibrated = onCalibrated
        self.onFinish = onFinish
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let displayID = number?.uint32Value ?? CGMainDisplayID()
        // Gaze 보정 좌표는 전역 좌상단 원점(CGDisplayBounds)이다.
        display = Gaze.DisplayGeometry(id: displayID, frame: CGDisplayBounds(displayID))
        targets = display.map { CalibrationTargetLayout.nine(in: $0) } ?? []
        model = CalibrationSessionModel(total: targets.count)
        window = CalibrationPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self
        window.onEscape = { [weak self] in self?.cancel() }
        let view = CalibrationView(model: model,
                                   onStart: { [weak self] in self?.run() },
                                   onCancel: { [weak self] in self?.cancel() },
                                   onClose: { [weak self] in self?.close() })
        window.contentView = NSHostingView(rootView: view)
        window.setFrame(screen.frame, display: true)
    }

    func present() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        task?.cancel()
        task = nil
        guard !finished else { return }
        finished = true
        let calibrator = self.calibrator
        Task { await calibrator.cancelCalibration() }
        onFinish()
    }

    private func cancel() {
        close()
    }

    private func run() {
        guard let display, task == nil else { return }
        let calibrator = self.calibrator
        let targets = self.targets
        let origin = display.frame.origin
        task = Task { [weak self] in
            defer { self?.task = nil }
            do {
                try await calibrator.beginCalibration(displayID: display.id)
                for (index, point) in targets.enumerated() {
                    let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
                    self?.model.phase = .target(index: index, point: local, collecting: false)
                    // 눈이 점으로 옮겨 갈 시간. 수집기도 앞쪽 정착 구간을 버린다.
                    try await Task.sleep(for: .milliseconds(600))
                    self?.model.phase = .target(index: index, point: local, collecting: true)
                    _ = try await calibrator.collectCalibrationTarget(at: point, duration: .milliseconds(1200))
                }
                self?.model.phase = .fitting
                let report = try await calibrator.finishCalibration(options: CalibrationOptions())
                self?.onCalibrated()
                let error = Int(report.crossValidatedRMSE.rounded())
                self?.model.phase = .done(summary: """
                    표적 \(report.targetCount)개, 표본 \(report.sampleCount)개로 보정했습니다.
                    예상 오차(교차 검증): 약 \(error)pt · 모델 \(report.kind.rawValue)
                    """)
            } catch is CancellationError {
                await calibrator.cancelCalibration()
            } catch {
                await calibrator.cancelCalibration()
                self?.model.phase = .failed(message: Self.describe(error))
            }
        }
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case CalibrationError.insufficientTargets(let found, let required):
            return "얼굴이 잘 보이는 표적이 \(found)개뿐입니다(최소 \(required)개). 조명을 밝게 하고 카메라를 정면으로 두세요."
        case CalibrationError.unknownDisplay:
            return "디스플레이 정보를 찾지 못했습니다. 카메라 시선이 실행 중인지 확인하세요."
        default:
            return "\(error)"
        }
    }
}
