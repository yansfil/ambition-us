import AgentContracts
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// 실제 앱의 접근성 트리를 읽어 AppStateSnapshot을 만든다(Orca `get-app-state`에 해당).
public final class AppStateReader: Sendable {
    public let store: AXElementStore
    private let clock: any MonotonicClock
    private let limits: AppStateLimits

    public init(store: AXElementStore = AXElementStore(), clock: any MonotonicClock = AXUptimeClock(),
                limits: AppStateLimits = .init()) {
        self.store = store
        self.clock = clock
        self.limits = limits
    }

    /// pid 앱의 포커스 창(없으면 주 창, 첫 창, 앱 자체)을 읽는다.
    public func snapshot(pid: Int32, limits: AppStateLimits? = nil) async throws -> AppStateSnapshot {
        let limits = limits ?? self.limits
        let result: Result<AppStateSnapshot, AXControlError> = await store.onReadQueue { [self] in
            read(pid: pid, limits: limits)
        }
        return try result.get()
    }

    /// 현재 앞에 있는 앱(키보드 포커스 앱)을 읽는다.
    public func snapshotFocusedApp(limits: AppStateLimits? = nil) async throws -> AppStateSnapshot {
        let pid: Int32? = await store.onReadQueue {
            AXElementRef.systemWide().element(AXAttr.focusedApplication)?.pid()
        }
        guard let pid else { throw AXControlError(.elementNotFound, "no focused application") }
        return try await snapshot(pid: pid, limits: limits)
    }

    private func read(pid: Int32, limits: AppStateLimits) -> Result<AppStateSnapshot, AXControlError> {
        guard AXIsProcessTrusted() else {
            return .failure(AXControlError(.accessibilityPermissionMissing, "grant Accessibility access to read app state"))
        }
        if store.excludedPIDs.contains(pid) {
            return .failure(AXControlError(.ownProcessRejected, "refusing to read Gaze's own windows"))
        }
        if kill(pid, 0) != 0, errno == ESRCH {
            store.invalidate(pid: pid)
            return .failure(AXControlError(.elementNotFound, "no running process with pid \(pid)"))
        }
        if store.ensureChromiumAccessibility(pid: pid) {
            // Chromium 계열은 트리를 비동기로 만든다. 첫 읽기 전에 잠깐 기다린다.
            Thread.sleep(forTimeInterval: 0.15)
        }
        let app = AXElementRef.application(pid)
        let appRole = app.copyAttribute(AXAttr.role).error
        switch appRole {
        case .success: break
        case .cannotComplete:
            return .failure(AXControlError(.actionTimeout, "app \(pid) did not answer accessibility requests"))
        default:
            return .failure(AXControlError(.elementNotFound, "app \(pid) is not accessible (\(appRole.codeName))"))
        }
        let window = app.element(AXAttr.focusedWindow) ?? app.element(AXAttr.mainWindow) ?? app.elements(AXAttr.windows).first
        let root = window ?? app
        let focusedElement = app.element(AXAttr.focusedUIElement)

        let walker = AXTreeWalker<AXElementRef>(
            info: { element in Self.nodeInfo(element) },
            children: { element in element.elements(AXAttr.children) }
        )
        let walked = walker.walk(root: root, limits: limits)
        let now = clock.now()

        var elements: [AppStateElement] = []
        elements.reserveCapacity(walked.nodes.count)
        var focusedIndex: Int?
        for node in walked.nodes {
            let info = node.info
            let target = store.makeTarget(node.handle, pid: pid, role: info.role, subrole: info.subrole, title: info.title,
                                          description: info.descriptionText, value: info.value,
                                          placeholder: info.placeholder, help: nil, frame: info.frame,
                                          valueSettable: info.isValueSettable, actions: info.actions, observedAt: now,
                                          maxTitleLength: limits.maxLabelLength)
            elements.append(AppStateElement(index: node.index, depth: node.depth, target: target))
            if focusedIndex == nil, info.isFocused || (focusedElement.map { $0 == node.handle } ?? false) {
                focusedIndex = node.index
            }
        }

        let appName = store.appName(for: pid)
        let bundleID = store.bundleID(for: pid)
        let windowTitle = window?.string(AXAttr.title)
        let text = AppStateFormatter.treeText(appName: appName, bundleID: bundleID, pid: pid, windowTitle: windowTitle,
                                              nodes: walked.nodes.map { ($0.index, $0.depth, $0.info) },
                                              focusedIndex: focusedIndex, truncation: walked.truncation, limits: limits)
        return .success(AppStateSnapshot(pid: pid, appName: appName, bundleID: bundleID, windowTitle: windowTitle,
                                         windowFrame: window?.frame(), treeText: text, elements: elements,
                                         focusedIndex: focusedIndex, truncation: walked.truncation, capturedAt: now))
    }

    private static let nodeAttributes = [
        AXAttr.role, AXAttr.subrole, AXAttr.roleDescription, AXAttr.title, AXAttr.description, AXAttr.value,
        AXAttr.placeholder, AXAttr.position, AXAttr.size, AXAttr.focused, AXAttr.enabled, AXAttr.hidden,
    ]

    static func nodeInfo(_ element: AXElementRef) -> AXNodeInfo {
        let a = element.attributes(nodeAttributes)
        var frame: CGRect?
        if let origin = AXElementRef.pointValue(a[AXAttr.position]), let size = AXElementRef.sizeValue(a[AXAttr.size]) {
            frame = CGRect(origin: origin, size: size)
        }
        return AXNodeInfo(
            role: AXElementRef.stringValue(a[AXAttr.role]) ?? "AXUnknown",
            subrole: AXElementRef.stringValue(a[AXAttr.subrole]),
            roleDescription: AXElementRef.stringValue(a[AXAttr.roleDescription]),
            title: AXElementRef.stringValue(a[AXAttr.title]),
            descriptionText: AXElementRef.stringValue(a[AXAttr.description]),
            value: AXElementRef.stringValue(a[AXAttr.value]),
            placeholder: AXElementRef.stringValue(a[AXAttr.placeholder]),
            frame: frame,
            isValueSettable: element.isSettable(AXAttr.value),
            isFocused: (a[AXAttr.focused] as? NSNumber)?.boolValue ?? false,
            isEnabled: (a[AXAttr.enabled] as? NSNumber)?.boolValue ?? true,
            isHidden: (a[AXAttr.hidden] as? NSNumber)?.boolValue ?? false,
            actions: element.actionNames()
        )
    }
}
