import AXControl
import AgentContracts
import AppCore
import AppKit
import Gaze
import Overlay

struct LaunchOptions: Sendable {
    var gazeMode: GazeInputMode
}

/// 앱 수명·메뉴 막대·창(권한 안내, 보정)을 관리한다. 실제 판단·실행은 `AgentCoordinator`가 한다.
@MainActor
final class GazeAppDelegate: NSObject, NSApplicationDelegate {
    let options: LaunchOptions
    private var agent: LiveAgent?
    private var statusMenu: StatusMenuController?
    private var permissionsWindow: PermissionsWindowController?
    private var calibrationWindow: CalibrationWindowController?
    private var implicitMonitor: ImplicitCalibrationMonitor?
    private var demo: OverlayDemo?

    init(options: LaunchOptions) {
        self.options = options
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let overlay = OverlayController()
        let agent = AgentAssembly.live(gazeMode: options.gazeMode, overlay: overlay)
        self.agent = agent
        agent.coordinator.onModeChange = { [weak self] _ in self?.refreshMenu() }
        agent.coordinator.onLog = { message in DiagnosticsLog.write(message) }
        DiagnosticsLog.write("시작: 시선 입력 \(options.gazeMode), 권한 \(AppPermission.allCases.map { "\($0)=\(PermissionsModel.state(of: $0))" }.joined(separator: " "))")
        statusMenu = StatusMenuController(delegate: self)
        overlay.render(OverlayState())
        refreshMenu()

        // 화면 기록은 앱이 한 번 요청해야 시스템 설정 목록에 나타난다.
        if PermissionsModel.state(of: .screenRecording) != .granted {
            Task { await PermissionStatus.registerScreenCaptureRequest() }
        }

        if PermissionsModel.requiredGranted(gazeMode: options.gazeMode) {
            startAgent()
        } else {
            showPermissions()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        demo?.stop()
        implicitMonitor?.stop()
        if let agent, options.gazeMode == .camera {
            agent.gazeEngine.flushImplicitRefit()
            CalibrationPersistence.save(agent.gazeEngine)
            (agent.calibrator as? VisionGazeSource)?.diagnostics().writeIgnoringErrors()
        }
        agent?.overlay.tearDown()
    }

    // MARK: 메뉴 동작

    var mode: AgentCoordinator.Mode { agent?.coordinator.mode ?? .stopped }
    var sourceErrors: [String] { agent?.coordinator.sourceErrors ?? [] }
    var canCalibrate: Bool { agent?.calibrator != nil && mode == .running }
    var isDemoRunning: Bool { demo != nil }
    var gazeMode: GazeInputMode { options.gazeMode }

    /// 메뉴에 보여 줄 시선 상태(추정기, 보정 정확도, 클릭 보정 수).
    var gazeStatusLines: [String] {
        guard options.gazeMode == .camera, let agent, let calibrator = agent.calibrator else { return [] }
        var lines = [calibrator.estimatorStatus.summary]
        if let model = agent.gazeEngine.calibrationModels.first {
            let ppcm = model.display.pointsPerCentimeter
            var text: String
            if let validation = model.validation {
                text = validation.meanErrorCm.map { String(format: "보정 정확도: 평균 %.1fcm", $0) }
                    ?? String(format: "보정 정확도: 평균 %.0fpt", validation.meanError)
            } else {
                text = ppcm.map { String(format: "보정 오차(교차 검증): %.1fcm", model.crossValidatedRMSE / $0) }
                    ?? String(format: "보정 오차(교차 검증): %.0fpt", model.crossValidatedRMSE)
            }
            if model.implicitCount > 0 { text += " · 클릭 보정 \(model.implicitCount)회" }
            lines.append(text)
        } else {
            lines.append("보정 필요 — ‘시선 보정 시작…’")
        }
        return lines
    }

    func startAgent() {
        guard let agent, agent.coordinator.mode == .stopped else { return }
        Task {
            await agent.coordinator.start()
            refreshMenu()
            guard options.gazeMode == .camera else { return }
            let engine = agent.gazeEngine
            let vision = agent.calibrator as? VisionGazeSource
            // 보정이 바뀌면(명시 보정·검증·클릭 재적합) 저장하고 진단 파일을 갱신한다.
            engine.setCalibrationObserver { event in
                Task { @MainActor in
                    if case .restored = event { return }
                    CalibrationPersistence.save(engine)
                    vision?.writeDiagnostics()
                }
            }
            // 소스가 추정기·디스플레이 배치를 정한 뒤에 같은 추정기로 만든 보정을 복원한다. 없으면 보정부터 한다.
            let restored = CalibrationPersistence.restore(into: engine)
            if implicitMonitor == nil {
                let monitor = ImplicitCalibrationMonitor(engine: engine) { [weak self] in
                    self?.mode == .running && self?.calibrationWindow == nil
                }
                monitor.start()
                implicitMonitor = monitor
            }
            vision?.writeDiagnostics()
            refreshMenu()
            if restored == 0, calibrationWindow == nil, PermissionsModel.state(of: .camera) == .granted {
                startCalibration()
            }
        }
    }

    func togglePause() {
        guard let coordinator = agent?.coordinator else { return }
        Task {
            switch coordinator.mode {
            case .running: await coordinator.pause()
            case .paused: await coordinator.resume()
            case .stopped: await coordinator.start()
            case .killed: break
            }
            refreshMenu()
        }
    }

    func toggleKillSwitch() {
        guard let coordinator = agent?.coordinator else { return }
        Task {
            if coordinator.mode == .killed {
                await coordinator.resetKillSwitch()
            } else {
                await coordinator.engageKillSwitch()
            }
            refreshMenu()
        }
    }

    func showPermissions() {
        if permissionsWindow == nil {
            permissionsWindow = PermissionsWindowController(
                gazeMode: options.gazeMode,
                onStart: { [weak self] in
                    self?.startAgent()
                    self?.permissionsWindow?.close()
                },
                onCalibrate: { [weak self] in self?.startCalibration() })
        }
        permissionsWindow?.present()
    }

    func startCalibration() {
        guard let agent, let calibrator = agent.calibrator else { return }
        if agent.coordinator.mode != .running {
            startAgent()
        }
        calibrationWindow?.close()
        agent.overlay.setVisible(false)
        let engine = agent.gazeEngine
        let controller = CalibrationWindowController(
            calibrator: calibrator,
            onCalibrated: { [weak self] in
                CalibrationPersistence.save(engine)
                self?.refreshMenu()
            },
            onFinish: { [weak self] in
                self?.agent?.overlay.setVisible(true)
                self?.calibrationWindow = nil
                self?.refreshMenu()
            })
        calibrationWindow = controller
        controller.present()
    }

    func toggleDemo() {
        guard let agent else { return }
        if let demo {
            demo.stop()
            demo.controller.tearDown()
            self.demo = nil
            agent.overlay.setVisible(true)
        } else {
            // 데모는 별도 오버레이로 띄우고, 실제 오버레이는 잠시 숨긴다.
            agent.overlay.setVisible(false)
            let demo = OverlayDemo(controller: OverlayController())
            demo.controller.onAccept = { NSLog("[Gaze demo] 수락: %@", $0.message) }
            demo.controller.onReject = { NSLog("[Gaze demo] 거절: %@", $0.message) }
            demo.start()
            self.demo = demo
        }
        refreshMenu()
    }

    func quit() {
        Task {
            await agent?.coordinator.shutdown()
            NSApp.terminate(nil)
        }
    }

    private func refreshMenu() {
        statusMenu?.refresh()
    }
}

/// 보정을 ~/Library/Application Support/Gaze/calibration-v2.json에 저장·복원한다
/// (추정기 ID, 모델, 보정·검증 표본, 클릭 표본). 예전 calibration.json(landmarks-v1)은 읽기만 하고 지우지 않는다.
/// 디스플레이 배치나 시선 추정기가 바뀌었으면 복원하지 않는다(시선 엔진이 거부).
enum CalibrationPersistence {
    static func save(_ engine: GazeEngine) {
        let archive = engine.exportArchive()
        guard !archive.models.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(archive) else { return }
        let url = GazeStoragePaths.calibrationArchive
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// 설치한 모델 수.
    @discardableResult
    static func restore(into engine: GazeEngine) -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: GazeStoragePaths.calibrationArchive),
           let archive = try? decoder.decode(CalibrationArchive.self, from: data) {
            let installed = engine.importArchive(archive)
            if installed > 0 { return installed }
        }
        // 예전 형식: 모델 배열(추정기 ID가 없으면 landmarks-v1). 현재 추정기와 같을 때만 설치된다.
        guard let data = try? Data(contentsOf: GazeStoragePaths.legacyCalibration),
              let models = try? JSONDecoder().decode([CalibrationModel].self, from: data) else { return 0 }
        var installed = 0
        for model in models where (try? engine.install(model)) != nil { installed += 1 }
        return installed
    }
}

extension GazeDiagnostics {
    func writeIgnoringErrors() { try? write() }
}
