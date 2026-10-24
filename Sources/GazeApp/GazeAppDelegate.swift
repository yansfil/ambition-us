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
        agent?.overlay.tearDown()
    }

    // MARK: 메뉴 동작

    var mode: AgentCoordinator.Mode { agent?.coordinator.mode ?? .stopped }
    var sourceErrors: [String] { agent?.coordinator.sourceErrors ?? [] }
    var canCalibrate: Bool { agent?.calibrator != nil && mode == .running }
    var isDemoRunning: Bool { demo != nil }
    var gazeMode: GazeInputMode { options.gazeMode }

    func startAgent() {
        guard let agent, agent.coordinator.mode == .stopped else { return }
        Task {
            await agent.coordinator.start()
            refreshMenu()
            guard options.gazeMode == .camera else { return }
            // 소스가 디스플레이 배치를 읽은 뒤에 저장해 둔 보정을 복원한다. 없으면 보정부터 한다.
            let restored = CalibrationPersistence.restore(into: agent.gazeEngine)
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
            onCalibrated: { CalibrationPersistence.save(engine.calibrationModels) },
            onFinish: { [weak self] in
                self?.agent?.overlay.setVisible(true)
                self?.calibrationWindow = nil
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

/// 보정 모델을 ~/Library/Application Support/Gaze/calibration.json에 저장·복원한다.
/// 디스플레이 배치가 바뀌었으면 복원하지 않는다(시선 엔진이 거부).
enum CalibrationPersistence {
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Gaze/calibration.json")
    }

    static func save(_ models: [CalibrationModel]) {
        guard !models.isEmpty, let data = try? JSONEncoder().encode(models) else { return }
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// 설치한 모델 수.
    @discardableResult
    static func restore(into engine: GazeEngine) -> Int {
        guard let data = try? Data(contentsOf: fileURL),
              let models = try? JSONDecoder().decode([CalibrationModel].self, from: data) else { return 0 }
        var installed = 0
        for model in models where (try? engine.install(model)) != nil { installed += 1 }
        return installed
    }
}
