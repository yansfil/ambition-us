import AppKit
import Synchronization
import SwiftUI

/// 오버레이 창 번호·프로세스 정보. 화면 캡처 필터(ScreenCaptureKit excludingWindows)와
/// AX 적중 검사 제외(AXUIElementCopyElementAtPosition 결과의 pid/창 번호 비교)에 쓴다.
public struct OverlayWindowInfo: Sendable, Equatable {
    public var processIdentifier: Int32
    /// CGWindowID와 같은 값(NSWindow.windowNumber).
    public var windowNumbers: Set<Int>

    public init(processIdentifier: Int32, windowNumbers: Set<Int>) {
        self.processIdentifier = processIdentifier; self.windowNumbers = windowNumbers
    }
}

/// 어느 스레드에서나 읽을 수 있는 오버레이 창 목록. 컨트롤러가 창을 만들거나 없앨 때 갱신한다.
public final class OverlayWindowRegistry: Sendable {
    public let processIdentifier: Int32
    private let numbers = Mutex<Set<Int>>([])
    private let observers = Mutex<[@Sendable (OverlayWindowInfo) -> Void]>([])

    public init(processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.processIdentifier = processIdentifier
    }

    public var snapshot: OverlayWindowInfo {
        OverlayWindowInfo(processIdentifier: processIdentifier, windowNumbers: numbers.withLock { $0 })
    }

    public func contains(windowNumber: Int) -> Bool { numbers.withLock { $0.contains(windowNumber) } }

    /// AX 요소의 pid가 오버레이 프로세스면 적중 검사 결과에서 버려야 한다.
    public func isOverlayProcess(_ pid: Int32) -> Bool { pid == processIdentifier }

    /// 창 목록이 바뀔 때마다 호출된다(캡처 필터 갱신용).
    public func addObserver(_ observer: @escaping @Sendable (OverlayWindowInfo) -> Void) {
        observers.withLock { $0.append(observer) }
    }

    func replace(with newNumbers: Set<Int>) {
        let changed = numbers.withLock { current -> Bool in
            guard current != newNumbers else { return false }
            current = newNumbers
            return true
        }
        guard changed else { return }
        let info = snapshot
        for observer in observers.withLock({ $0 }) { observer(info) }
    }
}

/// 디스플레이 전체를 덮는 클릭 통과 패널.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 말풍선 전용 상호작용 패널. 클릭은 받지만 키 창이 되지 않아 사용자가 쓰던 앱의 키보드 포커스를 뺏지 않는다.
final class BubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 비활성 창에서도 첫 클릭을 바로 버튼에 전달한다.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
enum OverlayPanelFactory {
    static func configureCommon(_ panel: NSPanel, configuration: OverlayConfiguration) {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: configuration.windowLevel)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.isExcludedFromWindowsMenu = true
        panel.animationBehavior = .none
        panel.worksWhenModal = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        // 화면 공유·녹화에서 제외. ScreenCaptureKit은 이 값을 무시할 수 있으므로 창 번호도 함께 공개한다.
        panel.sharingType = configuration.excludeFromScreenCapture ? .none : .readOnly
    }

    static func makeOverlayPanel(frame: CGRect, configuration: OverlayConfiguration) -> OverlayPanel {
        let panel = OverlayPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        configureCommon(panel, configuration: configuration)
        panel.ignoresMouseEvents = true
        panel.setAccessibilityElement(false)
        panel.setAccessibilityHidden(true)
        panel.setFrame(frame, display: false)
        return panel
    }

    static func makeBubblePanel(configuration: OverlayConfiguration) -> BubblePanel {
        let panel = BubblePanel(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configureCommon(panel, configuration: configuration)
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isFloatingPanel = true
        // isFloatingPanel이 레벨을 바꾸므로 그 뒤에, 오버레이 패널보다 한 단계 위로 둔다.
        panel.level = NSWindow.Level(rawValue: configuration.windowLevel + 1)
        return panel
    }
}
