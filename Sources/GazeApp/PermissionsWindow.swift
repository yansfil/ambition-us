import AVFoundation
import AXControl
import AppCore
import AppKit
import Observation
import Speech
import SwiftUI

/// 온보딩에 보여 줄 macOS 권한.
enum AppPermission: String, CaseIterable, Identifiable, Sendable {
    case camera, microphone, speechRecognition, accessibility, screenRecording

    var id: String { rawValue }

    var title: String {
        switch self {
        case .camera: "카메라"
        case .microphone: "마이크"
        case .speechRecognition: "음성 인식"
        case .accessibility: "손쉬운 사용"
        case .screenRecording: "화면 기록"
        }
    }

    var purpose: String {
        switch self {
        case .camera: "웹캠으로 어디를 보는지 추적합니다. 영상은 저장하거나 전송하지 않습니다."
        case .microphone: "상시 한국어 음성 명령·받아쓰기를 듣습니다."
        case .speechRecognition: "기기 안에서 한국어 음성을 글자로 바꿉니다."
        case .accessibility: "보고 있는 버튼·입력란을 찾고, 승인한 동작(입력·클릭·이동)을 실행합니다."
        case .screenRecording: "애매한 요청을 판단할 때 화면을 참고합니다(Gaze 오버레이는 제외)."
        }
    }

    /// 시스템 설정 > 개인정보 보호 및 보안의 해당 패널.
    var settingsURL: URL {
        let anchor = switch self {
        case .camera: "Privacy_Camera"
        case .microphone: "Privacy_Microphone"
        case .speechRecognition: "Privacy_SpeechRecognition"
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    func isRequired(for mode: GazeInputMode) -> Bool {
        switch self {
        case .camera: mode == .camera
        case .microphone, .speechRecognition, .accessibility: true
        case .screenRecording: false
        }
    }
}

enum PermissionState: Equatable, Sendable {
    case granted, denied, notDetermined

    var label: String {
        switch self {
        case .granted: "허용됨"
        case .denied: "허용 안 됨"
        case .notDetermined: "아직 묻지 않음"
        }
    }

    var color: Color {
        switch self {
        case .granted: .green
        case .denied: .red
        case .notDetermined: .orange
        }
    }
}

/// 권한 상태 조회·요청. 조회는 대화상자를 띄우지 않는다.
@MainActor
@Observable
final class PermissionsModel {
    let gazeMode: GazeInputMode
    private(set) var states: [AppPermission: PermissionState] = [:]

    init(gazeMode: GazeInputMode) {
        self.gazeMode = gazeMode
        refresh()
    }

    var visiblePermissions: [AppPermission] {
        AppPermission.allCases.filter { $0 != .camera || gazeMode == .camera }
    }

    var allRequiredGranted: Bool {
        visiblePermissions.allSatisfy { !$0.isRequired(for: gazeMode) || states[$0] == .granted }
    }

    func refresh() {
        var next: [AppPermission: PermissionState] = [:]
        for permission in AppPermission.allCases { next[permission] = Self.state(of: permission) }
        if next != states { states = next }
    }

    static func requiredGranted(gazeMode: GazeInputMode) -> Bool {
        AppPermission.allCases.allSatisfy { !$0.isRequired(for: gazeMode) || state(of: $0) == .granted }
    }

    static func state(of permission: AppPermission) -> PermissionState {
        switch permission {
        case .camera:
            return state(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone:
            switch AVAudioApplication.shared.recordPermission {
            case .granted: return .granted
            case .undetermined: return .notDetermined
            default: return .denied
            }
        case .speechRecognition:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .accessibility:
            return PermissionStatus.isAccessibilityTrusted() ? .granted : .denied
        case .screenRecording:
            return PermissionStatus.isScreenCaptureAllowed() ? .granted : .denied
        }
    }

    private static func state(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// 시스템 허용 요청(처음 한 번만 대화상자가 뜬다). 이미 거부했으면 설정을 연다.
    func request(_ permission: AppPermission) {
        switch permission {
        case .camera:
            guard states[permission] == .notDetermined else { return openSettings(permission) }
            Task {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                refresh()
            }
        case .microphone:
            guard states[permission] == .notDetermined else { return openSettings(permission) }
            Task {
                _ = await AVAudioApplication.requestRecordPermission()
                refresh()
            }
        case .speechRecognition:
            guard states[permission] == .notDetermined else { return openSettings(permission) }
            Task {
                await Self.requestSpeechAuthorization()
                refresh()
            }
        case .accessibility:
            PermissionStatus.requestAccessibility()
            openSettings(permission)
        case .screenRecording:
            Task {
                await PermissionStatus.registerScreenCaptureRequest()
                refresh()
                if states[permission] != .granted { openSettings(permission) }
            }
        }
    }

    /// TCC는 완료 블록을 백그라운드 큐에서 부른다. MainActor 클래스 안의 클로저는 MainActor로 추론되어
    /// 그 큐에서 실행되면 격리 검사로 앱이 종료되므로, nonisolated 함수에서 continuation으로 받는다.
    private nonisolated static func requestSpeechAuthorization() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in continuation.resume() }
        }
    }

    func openSettings(_ permission: AppPermission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }

    /// 화면 기록 등 프로세스 시작 시에만 반영되는 권한을 위해 같은 인자로 새로 띄우고 종료한다.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = Array(CommandLine.arguments.dropFirst())
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

struct PermissionsView: View {
    @Bindable var model: PermissionsModel
    let onStart: () -> Void
    let onCalibrate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Gaze 시작하기")
                .font(.title2.bold())
            Text("시선과 목소리로 Mac을 다루려면 아래 권한이 필요합니다. 허용한 뒤에도 실행 전에 위험한 동작은 항상 확인을 받습니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(model.visiblePermissions) { permission in
                PermissionRow(permission: permission,
                              state: model.states[permission] ?? .notDetermined,
                              required: permission.isRequired(for: model.gazeMode),
                              onRequest: { model.request(permission) },
                              onOpenSettings: { model.openSettings(permission) })
            }

            Text("화면 기록은 허용한 뒤 앱을 다시 시작해야 반영됩니다. 설정에서 켜져 있는데도 허용 안 됨으로 나오면 예전 빌드의 허용이 남은 것이니, 목록에서 Gaze를 −로 지우고 다시 허용하세요. `swift run`으로 실행하면 권한이 터미널에 붙으니 scripts/bundle.sh로 만든 Gaze.app을 쓰세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if model.gazeMode == .camera {
                    Button("시선 보정 시작…", action: onCalibrate)
                        .disabled(model.states[.camera] != .granted)
                }
                Spacer()
                Button("Gaze 다시 시작") { model.relaunch() }
                Button(model.allRequiredGranted ? "Gaze 시작" : "필수 권한 없이 시작", action: onStart)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

private struct PermissionRow: View {
    let permission: AppPermission
    let state: PermissionState
    let required: Bool
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(state.color)
                .frame(width: 10, height: 10)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(permission.title).font(.headline)
                    Text(required ? "필수" : "선택")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    Text(state.label)
                        .font(.caption)
                        .foregroundStyle(state.color)
                }
                Text(permission.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if state != .granted {
                Button(state == .notDetermined ? "허용 요청" : "허용하기", action: onRequest)
            }
            Button("설정 열기", action: onOpenSettings)
        }
    }
}

/// 권한 안내 창. 열려 있는 동안 1초마다 상태를 다시 읽는다.
@MainActor
final class PermissionsWindowController: NSObject, NSWindowDelegate {
    private let model: PermissionsModel
    private let window: NSWindow
    private var timer: Timer?

    init(gazeMode: GazeInputMode, onStart: @escaping @MainActor () -> Void, onCalibrate: @escaping @MainActor () -> Void) {
        model = PermissionsModel(gazeMode: gazeMode)
        let view = PermissionsView(model: model, onStart: { onStart() }, onCalibrate: { onCalibrate() })
        window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Gaze 권한"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self
    }

    func present() {
        model.refresh()
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refresh() }
        }
    }

    func close() {
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}
