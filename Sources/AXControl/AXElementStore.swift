import AgentContracts
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// AXUIElement 보관소. token ↔ 요소 대응을 resolver·snapshot·executor가 공유한다.
/// 공개 API에는 AXUIElement가 나타나지 않는다.
public final class AXElementStore: Sendable {
    let registry: TokenRegistry<AXElementRef>
    /// 읽기 전용 AX 호출(히트 테스트, 트리 순회)을 직렬화하는 큐. 협력 스레드 풀을 막지 않는다.
    let readQueue = DispatchQueue(label: "gaze.axcontrol.read", qos: .userInteractive)
    let excludedPIDs: Set<Int32>
    let enableChromiumAccessibility: Bool
    private let state = LockedState()

    /// - Parameters:
    ///   - excludedPIDs: 결과에서 뺄 프로세스. 기본값은 Gaze 자신(오버레이 창 제외).
    ///   - messagingTimeout: 응답 없는 앱 때문에 멈추지 않도록 전역 AX 메시지 시간 제한(초).
    public init(capacity: Int = 4096, excludedPIDs: Set<Int32> = [ProcessInfo.processInfo.processIdentifier],
                messagingTimeout: Float = 0.5, enableChromiumAccessibility: Bool = true) {
        registry = TokenRegistry(capacity: capacity, prefix: "ax")
        self.excludedPIDs = excludedPIDs
        self.enableChromiumAccessibility = enableChromiumAccessibility
        if messagingTimeout > 0 {
            AXElementRef.systemWide().setMessagingTimeout(messagingTimeout)
        }
    }

    /// 보관 중인 token 수.
    public var tokenCount: Int { registry.count }

    /// 앱 종료·화면 전환 뒤 해당 앱 token을 무효화한다.
    @discardableResult
    public func invalidate(pid: Int32) -> Int { registry.removeAll(pid: pid) }

    public func invalidateAll() { registry.removeAll() }

    /// token이 아직 살아 있는지(레지스트리에 있는지).
    public func contains(token: String) -> Bool { registry.entry(for: token) != nil }

    func onReadQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            readQueue.async { continuation.resume(returning: body()) }
        }
    }

    // MARK: 앱 정보

    func bundleID(for pid: pid_t) -> String? {
        if let cached = state.withLock({ $0.bundleIDs[pid] }) { return cached }
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        state.withLock { $0.bundleIDs[pid] = .some(bundleID) }
        return bundleID
    }

    func appName(for pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
    }

    /// Electron·Chromium 앱이면 접근성 트리를 켠다. pid마다 한 번만 시도한다.
    /// - Returns: 이번 호출에서 새로 켰으면 true(트리가 비동기로 만들어지므로 호출자는 잠시 뒤 다시 읽을 수 있다).
    @discardableResult
    func ensureChromiumAccessibility(pid: pid_t) -> Bool {
        guard enableChromiumAccessibility else { return false }
        let first = state.withLock { s -> Bool in s.chromiumChecked.insert(pid).inserted }
        guard first else { return false }
        let app = NSRunningApplication(processIdentifier: pid)
        let frameworks = app?.bundleURL.map(Self.frameworkNames(in:)) ?? []
        let kind = ChromiumAccessibility.kind(bundleID: app?.bundleIdentifier, frameworkNames: frameworks)
        let appElement = AXElementRef.application(pid)
        for attribute in ChromiumAccessibility.attributesToEnable(for: kind) {
            if appElement.set(attribute, kCFBooleanTrue) == .success { return true }
        }
        return false
    }

    static func frameworkNames(in bundleURL: URL) -> [String] {
        let dir = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        return (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    }

    // MARK: 히트 테스트

    /// 전역 좌표의 가장 깊은 요소. Gaze 자신의 창을 맞히면 창 목록에서 아래 창 주인 앱으로 다시 찾는다.
    func hitTest(_ point: CGPoint) -> AXElementRef? {
        let (hit, error) = AXElementRef.systemWide().elementAtPosition(point)
        if error == .success, let hit, let pid = hit.pid(), !excludedPIDs.contains(pid) {
            return hit
        }
        let candidates = HitTestFallback.candidatePIDs(at: point, windows: Self.onScreenWindows(), excludedPIDs: excludedPIDs)
        for ownerPID in candidates.prefix(6) {
            let (appHit, appError) = AXElementRef.application(ownerPID).elementAtPosition(point)
            if appError == .success, let appHit, let pid = appHit.pid(), !excludedPIDs.contains(pid) {
                return appHit
            }
        }
        return nil
    }

    /// 화면에 있는 창 목록(앞에서 뒤 순서). 화면 기록 권한 없이도 bounds·pid는 읽힌다.
    static func onScreenWindows() -> [HitTestFallback.WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            return HitTestFallback.WindowInfo(ownerPID: pid, layer: layer, bounds: bounds, alpha: alpha)
        }
    }

    // MARK: UITarget 만들기

    /// 요소 속성을 읽어 token을 등록하고 UITarget을 만든다.
    func makeTarget(_ element: AXElementRef, pid: pid_t, observedAt: MonotonicTime, maxTitleLength: Int = 120) -> UITarget {
        let a = element.attributes([AXAttr.role, AXAttr.subrole, AXAttr.title, AXAttr.description, AXAttr.value,
                                    AXAttr.placeholder, AXAttr.help, AXAttr.position, AXAttr.size])
        let role = AXElementRef.stringValue(a[AXAttr.role]) ?? "AXUnknown"
        let subrole = AXElementRef.stringValue(a[AXAttr.subrole])
        var frame: CGRect?
        if let origin = AXElementRef.pointValue(a[AXAttr.position]), let size = AXElementRef.sizeValue(a[AXAttr.size]) {
            frame = CGRect(origin: origin, size: size)
        }
        return makeTarget(element, pid: pid, role: role, subrole: subrole,
                          title: AXElementRef.stringValue(a[AXAttr.title]),
                          description: AXElementRef.stringValue(a[AXAttr.description]),
                          value: AXElementRef.stringValue(a[AXAttr.value]),
                          placeholder: AXElementRef.stringValue(a[AXAttr.placeholder]),
                          help: AXElementRef.stringValue(a[AXAttr.help]),
                          frame: frame, valueSettable: element.isSettable(AXAttr.value),
                          actions: element.actionNames(), observedAt: observedAt, maxTitleLength: maxTitleLength)
    }

    func makeTarget(_ element: AXElementRef, pid: pid_t, role: String, subrole: String?, title: String?,
                    description: String?, value: String?, placeholder: String?, help: String?, frame: CGRect?,
                    valueSettable: Bool, actions: [String], observedAt: MonotonicTime, maxTitleLength: Int = 120) -> UITarget {
        let secure = AXSemantics.isSecure(role: role, subrole: subrole)
        let textual = AXSemantics.textEntryRoles.contains(role) || subrole == AXSemantics.secureSubrole
        let selectedTextSettable = textual && !valueSettable ? element.isSettable(AXAttr.selectedText) : false
        let editable = AXSemantics.isEditable(role: role, subrole: subrole, valueSettable: valueSettable,
                                              selectedTextSettable: selectedTextSettable)
        let label = AXSemantics.label(title: title, description: description, value: value, placeholder: placeholder,
                                      help: help, isSecure: secure, maxLength: maxTitleLength)
        let token = registry.register(element, pid: pid, role: role, frame: frame)
        return UITarget(token: token, pid: pid, appBundleID: bundleID(for: pid), role: role, title: label,
                        frame: frame ?? .zero, isEditable: editable, isSecure: secure, supportedActions: actions,
                        observedAt: observedAt)
    }

    /// token으로 요소를 되찾는다.
    func element(for token: String) -> AXElementRef? { registry.entry(for: token)?.element }
}

private final class LockedState: @unchecked Sendable {
    struct Values {
        var bundleIDs: [pid_t: String?] = [:]
        var chromiumChecked: Set<pid_t> = []
    }

    private let lock = NSLock()
    private var values = Values()

    func withLock<T>(_ body: (inout Values) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&values)
    }
}
