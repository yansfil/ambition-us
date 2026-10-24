import AppCore
import AppKit

/// 메뉴 막대 상태 항목: 상태 표시, 일시정지/재개, 비상 정지, 보정, 권한, 오버레이 데모, 종료.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private weak var delegate: GazeAppDelegate?
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let errorLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private lazy var pauseItem = makeItem("일시정지", #selector(togglePause), key: "p")
    private lazy var killItem = makeItem("비상 정지", #selector(toggleKillSwitch), key: ".")
    private lazy var calibrateItem = makeItem("시선 보정 시작…", #selector(startCalibration), key: "")
    private lazy var permissionsItem = makeItem("권한 설정…", #selector(showPermissions), key: ",")
    private lazy var demoItem = makeItem("오버레이 데모", #selector(toggleDemo), key: "")
    private lazy var quitItem = makeItem("Gaze 종료", #selector(quit), key: "q")

    init(delegate: GazeAppDelegate) {
        self.delegate = delegate
        super.init()
        statusLine.isEnabled = false
        errorLine.isEnabled = false
        menu.autoenablesItems = false
        menu.delegate = self
        menu.items = [statusLine, errorLine, .separator(), pauseItem, killItem, .separator(),
                      calibrateItem, permissionsItem, demoItem, .separator(), quitItem]
        killItem.keyEquivalentModifierMask = [.command, .option]
        item.menu = menu
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    func refresh() {
        guard let delegate else { return }
        let mode = delegate.mode
        let modeText: String
        let symbol: String
        switch mode {
        case .running:
            modeText = "실행 중"; symbol = "eye"
        case .paused:
            modeText = "일시정지됨"; symbol = "eye.slash"
        case .killed:
            modeText = "비상 정지됨"; symbol = "exclamationmark.octagon"
        case .stopped:
            modeText = "시작 전"; symbol = "eye.slash"
        }
        let input = delegate.gazeMode == .mouse ? "마우스 시선" : "카메라 시선"
        statusLine.title = "Gaze — \(modeText) (\(input))"
        let errors = delegate.sourceErrors
        errorLine.title = errors.joined(separator: " · ")
        errorLine.isHidden = errors.isEmpty

        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Gaze \(modeText)")
        item.button?.toolTip = statusLine.title

        pauseItem.title = mode == .paused ? "재개" : (mode == .stopped ? "시작" : "일시정지")
        pauseItem.isEnabled = mode != .killed
        killItem.title = mode == .killed ? "비상 정지 해제" : "비상 정지"
        killItem.isEnabled = mode != .stopped
        calibrateItem.isEnabled = delegate.gazeMode == .camera
        calibrateItem.toolTip = delegate.gazeMode == .mouse ? "마우스 시선 모드에서는 보정이 필요 없습니다" : nil
        demoItem.state = delegate.isDemoRunning ? .on : .off
    }

    private func makeItem(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func togglePause() { delegate?.togglePause() }
    @objc private func toggleKillSwitch() { delegate?.toggleKillSwitch() }
    @objc private func startCalibration() { delegate?.startCalibration() }
    @objc private func showPermissions() { delegate?.showPermissions() }
    @objc private func toggleDemo() { delegate?.toggleDemo() }
    @objc private func quit() { delegate?.quit() }
}
