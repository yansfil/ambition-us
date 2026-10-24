import AgentContracts
import AppKit
import SwiftUI

extension DisplayGeometry {
    @MainActor
    init(screen: NSScreen) {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        self.init(id: number?.uint32Value ?? 0, frame: screen.frame, visibleFrame: screen.visibleFrame)
    }
}

/// 디스플레이 한 대의 클릭 통과 패널 + SwiftUI 모델.
@MainActor
final class DisplaySurface {
    let geometry: DisplayGeometry
    let panel: OverlayPanel
    let model: DisplayOverlayModel

    init(geometry: DisplayGeometry, configuration: OverlayConfiguration) {
        self.geometry = geometry
        model = DisplayOverlayModel(bounds: geometry.localBounds, configuration: configuration)
        panel = OverlayPanelFactory.makeOverlayPanel(frame: geometry.frame, configuration: configuration)
        let host = NSHostingView(rootView: DisplayOverlayView(model: model))
        host.sizingOptions = []
        host.frame = CGRect(origin: .zero, size: geometry.frame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }
}

/// 말풍선 전용 상호작용 패널.
@MainActor
final class BubbleSurface {
    let panel: BubblePanel
    let model = BubbleModel()
    /// 숨김 애니메이션 뒤 orderOut이 늦게 도착해 새로 띄운 말풍선을 지우지 않도록 세대를 센다.
    var generation = 0

    init(configuration: OverlayConfiguration) {
        panel = OverlayPanelFactory.makeBubblePanel(configuration: configuration)
        model.useLiquidGlass = configuration.useLiquidGlass
        model.lime = Color(rgb: configuration.limeRGB)
        let host = FirstMouseHostingView(rootView: BubbleRootView(model: model))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }
}

/// 디스플레이별 투명 클릭 통과 오버레이와 말풍선 패널을 관리한다.
///
/// - 시선: Liquid Glass 둥근 사각형 + 우하단 음성 배지.
/// - 에이전트 영역: 라임 테두리 + 안쪽 글로. 유휴면 화면 테두리, 대상이 생기면 그 프레임으로 줄어든다.
/// - 말풍선: 제안·승인 요청 문구와 수락/거절 버튼. 이 패널만 클릭을 받는다.
@MainActor
public final class OverlayController: OverlayRendering {
    public var configuration: OverlayConfiguration {
        didSet { if oldValue != configuration { rebuildAll() } }
    }
    /// 말풍선 수락. 승인 요청이면 실행 승인, 제안이면 제안 수락으로 해석한다.
    public var onAccept: (@MainActor (OverlayBubbleSubject) -> Void)?
    public var onReject: (@MainActor (OverlayBubbleSubject) -> Void)?
    /// 오버레이 창 번호·pid. 화면 캡처 제외 필터와 AX 적중 검사 제외에 쓴다. 어느 스레드에서나 읽을 수 있다.
    public nonisolated let windowRegistry = OverlayWindowRegistry()
    /// nil이면 시스템 설정(손쉬운 사용 > 동작 줄이기)을 따른다.
    public var reduceMotionOverride: Bool? {
        didSet { rerenderIfActive() }
    }
    public private(set) var lastState = OverlayState()
    public private(set) var isVisible = true

    private var surfaces: [DisplaySurface] = []
    private var primaryHeight: CGFloat = 0
    private var bubble: BubbleSurface?
    private var hasRendered = false
    private var regionSettlesAt = ContinuousClock.now
    private var bubbleKey: BubbleScheduling.Key?
    private var bubbleTask: Task<Void, Never>?
    private var dismissedSubjectID: UUID?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    public init(configuration: OverlayConfiguration = .default) {
        self.configuration = configuration
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.surfaces.isEmpty else { return }
                self.rebuildAll()
            }
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rerenderIfActive() }
        }))
    }

    isolated deinit {
        for (center, token) in observers { center.removeObserver(token) }
        bubbleTask?.cancel()
        surfaces.forEach { $0.close() }
        bubble?.panel.close()
    }

    // MARK: 공개 정보

    public var reducesMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// 클릭 통과 오버레이 패널의 창 번호(CGWindowID).
    public var overlayWindowNumbers: [Int] { surfaces.map(\.panel.windowNumber).filter { $0 > 0 } }

    /// 말풍선 패널 창 번호. 아직 만들지 않았으면 nil.
    public var bubbleWindowNumber: Int? { bubble.map(\.panel.windowNumber).flatMap { $0 > 0 ? $0 : nil } }

    public nonisolated var processIdentifier: Int32 { windowRegistry.processIdentifier }

    // MARK: OverlayRendering

    public func render(_ state: OverlayState) {
        lastState = state
        if surfaces.isEmpty { buildSurfaces() }
        guard !surfaces.isEmpty else { return }

        let displays = surfaces.map(\.geometry)
        let layout = OverlayLayoutEngine.layout(state, displays: displays, primaryHeight: primaryHeight,
                                                configuration: configuration)
        let animate = hasRendered && isVisible
        let reduce = reducesMotion
        var regionMoved = false
        for (surface, displayLayout) in zip(surfaces, layout.displays) {
            if apply(displayLayout, to: surface.model, animate: animate, reduceMotion: reduce) { regionMoved = true }
        }
        if regionMoved {
            let settle = reduce ? 0.3 : configuration.regionAnimationDuration
            regionSettlesAt = .now + .milliseconds(Int(settle * 1000))
        }
        hasRendered = true
        updateBubble(layout.bubble, displays: displays, animate: animate, reduceMotion: reduce)
    }

    // MARK: 표시 제어

    public func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if visible {
            surfaces.forEach { $0.panel.orderFrontRegardless() }
            hasRendered = false
            render(lastState)
        } else {
            surfaces.forEach { $0.panel.orderOut(nil) }
            cancelBubble()
            bubbleKey = nil
            hideBubble(animate: false)
        }
        refreshRegistry()
    }

    /// 모든 창을 닫는다. 다시 render하면 새로 만든다.
    public func tearDown() {
        cancelBubble()
        bubbleKey = nil
        surfaces.forEach { $0.close() }
        surfaces = []
        bubble?.panel.orderOut(nil)
        bubble?.panel.close()
        bubble = nil
        hasRendered = false
        refreshRegistry()
    }

    /// 화면 구성이 바뀐 것을 알 때 직접 부를 수도 있다.
    public func rebuildAll() {
        tearDown()
        render(lastState)
    }

    /// 이미 창을 띄운 뒤에만 다시 그린다(설정 변경 알림이 창을 처음 만들지 않도록).
    private func rerenderIfActive() {
        guard !surfaces.isEmpty else { return }
        render(lastState)
    }

    // MARK: 디스플레이 패널

    private func buildSurfaces() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        primaryHeight = (screens.first { $0.frame.origin == .zero } ?? screens[0]).frame.height
        surfaces = screens.map { DisplaySurface(geometry: DisplayGeometry(screen: $0), configuration: configuration) }
        if isVisible { surfaces.forEach { $0.panel.orderFrontRegardless() } }
        hasRendered = false
        refreshRegistry()
    }

    private func refreshRegistry() {
        var numbers = Set(overlayWindowNumbers)
        if let number = bubbleWindowNumber { numbers.insert(number) }
        windowRegistry.replace(with: numbers)
    }

    /// 레이아웃 하나를 모델에 반영한다. 에이전트 영역이 새 위치로 움직이기 시작했으면 true.
    private func apply(_ layout: DisplayOverlayLayout, to model: DisplayOverlayModel, animate: Bool, reduceMotion: Bool) -> Bool {
        if model.reduceMotion != reduceMotion { model.reduceMotion = reduceMotion }

        // 시선 유리 + 배지
        if let gaze = layout.gaze {
            let wasShowing = model.gaze != nil && model.gazeOpacity > 0
            if !animate {
                withoutAnimation {
                    model.gaze = gaze; model.badge = layout.badge; model.gazeOpacity = gaze.opacity
                }
            } else if !wasShowing {
                // 사라졌던 자리에서 날아오지 않고 새 자리에서 페이드 인.
                withoutAnimation { model.gaze = gaze; model.badge = layout.badge }
                withAnimation(.easeOut(duration: 0.25)) { model.gazeOpacity = gaze.opacity }
            } else if reduceMotion {
                let old = model.gaze.map { CGPoint(x: $0.rect.midX, y: $0.rect.midY) } ?? .zero
                let new = CGPoint(x: gaze.rect.midX, y: gaze.rect.midY)
                if OverlayGeometry.isGazeJump(from: old, to: new) {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        model.gazeGeneration += 1
                        model.gaze = gaze; model.badge = layout.badge; model.gazeOpacity = gaze.opacity
                    }
                } else {
                    withoutAnimation { model.gaze = gaze; model.badge = layout.badge }
                    if model.gazeOpacity != gaze.opacity {
                        withAnimation(.easeInOut(duration: 0.2)) { model.gazeOpacity = gaze.opacity }
                    }
                }
            } else {
                withAnimation(.smooth(duration: 0.18)) {
                    model.gaze = gaze; model.badge = layout.badge; model.gazeOpacity = gaze.opacity
                }
            }
        } else if model.gazeOpacity > 0 {
            if animate {
                withAnimation(.easeOut(duration: 0.35)) { model.gazeOpacity = 0 }
            } else {
                withoutAnimation { model.gazeOpacity = 0 }
            }
        }

        // 에이전트 영역
        let old = model.region
        let new = layout.region
        guard old != new else { return false }
        let moved = old.rect != new.rect || old.isIdleEdge != new.isIdleEdge
        if !animate {
            withoutAnimation { model.region = new }
        } else if reduceMotion && moved {
            // 모션 감소: 이동·축소 대신 이전 위치에서 사라지고 새 위치에서 나타난다.
            withAnimation(.easeInOut(duration: 0.3)) {
                model.regionGeneration += 1
                model.region = new
            }
        } else {
            withAnimation(.spring(duration: configuration.regionAnimationDuration, bounce: 0.1)) { model.region = new }
        }
        return animate && moved && new.isVisible
    }

    private func withoutAnimation(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }

    // MARK: 말풍선

    private func updateBubble(_ request: BubbleRequest?, displays: [DisplayGeometry], animate: Bool, reduceMotion: Bool) {
        let remaining = (regionSettlesAt - .now).components
        let wait = max(0, Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18)
        let decision = BubbleScheduling.decide(current: bubbleKey, isShown: bubble?.model.isShown ?? false,
                                               request: request, dismissedSubjectID: dismissedSubjectID,
                                               secondsUntilRegionSettles: animate ? wait : 0)
        switch decision {
        case .keep:
            return
        case .hide:
            cancelBubble()
            bubbleKey = nil
            hideBubble(animate: animate)
        case .updateInPlace:
            guard let request else { return }
            bubbleKey = BubbleScheduling.Key(request)
            showBubble(request, displays: displays, reduceMotion: reduceMotion, animateIn: false)
        case .show(let delay):
            guard let request else { return }
            cancelBubble()
            bubbleKey = BubbleScheduling.Key(request)
            if bubble?.model.isShown == true { hideBubble(animate: animate) }
            if delay <= 0.01 {
                showBubble(request, displays: displays, reduceMotion: reduceMotion, animateIn: animate)
            } else {
                bubbleTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                    guard !Task.isCancelled, let self else { return }
                    self.showBubble(request, displays: self.surfaces.map(\.geometry),
                                    reduceMotion: self.reducesMotion, animateIn: true)
                }
            }
        }
    }

    private func cancelBubble() {
        bubbleTask?.cancel()
        bubbleTask = nil
    }

    private func bubbleSurface() -> BubbleSurface {
        if let bubble { return bubble }
        let surface = BubbleSurface(configuration: configuration)
        bubble = surface
        refreshRegistry()
        return surface
    }

    private func showBubble(_ request: BubbleRequest, displays: [DisplayGeometry], reduceMotion: Bool, animateIn: Bool) {
        guard isVisible, displays.indices.contains(request.displayIndex) else { return }
        let surface = bubbleSurface()
        let model = surface.model
        let subject = request.subject
        let accept = subject.isApproval ? configuration.approvalAcceptTitle : configuration.suggestionAcceptTitle
        let reject = subject.isApproval ? configuration.approvalRejectTitle : configuration.suggestionRejectTitle
        let size = measureBubble(message: subject.message, accept: accept, reject: reject)
        let visible = displays[request.displayIndex].topLeftVisibleFrame(primaryHeight: primaryHeight)
        let placement = OverlayGeometry.placeBubble(size: size, anchor: request.anchor, visibleFrame: visible)
        let frame = OverlayGeometry.topLeftToCocoa(placement.containerFrame, primaryHeight: primaryHeight)

        let wasOnScreen = surface.panel.isVisible && model.isShown
        surface.generation += 1
        withoutAnimation {
            model.subject = subject
            model.message = subject.message
            model.acceptTitle = accept
            model.rejectTitle = reject
            model.placement = placement
            model.reduceMotion = reduceMotion
            model.onAccept = { [weak self] in self?.resolveBubble(accepted: true) }
            model.onReject = { [weak self] in self?.resolveBubble(accepted: false) }
            if !wasOnScreen { model.isShown = false }
        }
        surface.panel.setFrame(frame, display: true)
        surface.panel.orderFrontRegardless()
        refreshRegistry()

        guard !wasOnScreen else { return }
        if animateIn {
            // 패널이 첫 프레임을 그린 뒤에 나타나기 애니메이션을 건다.
            let generation = surface.generation
            Task { @MainActor [weak surface] in
                guard let surface, surface.generation == generation else { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.25)) {
                    surface.model.isShown = true
                }
            }
        } else {
            withoutAnimation { model.isShown = true }
        }
    }

    private func hideBubble(animate: Bool) {
        guard let surface = bubble, surface.model.isShown || surface.panel.isVisible else { return }
        surface.generation += 1
        let generation = surface.generation
        if animate {
            withAnimation(.easeIn(duration: 0.15)) { surface.model.isShown = false }
            Task { @MainActor [weak surface] in
                try? await Task.sleep(for: .milliseconds(180))
                guard let surface, surface.generation == generation else { return }
                surface.panel.orderOut(nil)
            }
        } else {
            withoutAnimation { surface.model.isShown = false }
            surface.panel.orderOut(nil)
        }
    }

    private func resolveBubble(accepted: Bool) {
        guard let subject = bubble?.model.subject else { return }
        dismissedSubjectID = subject.id
        cancelBubble()
        bubbleKey = nil
        hideBubble(animate: true)
        if accepted { onAccept?(subject) } else { onReject?(subject) }
    }

    /// 말풍선 몸체 크기(꼬리 제외). 최대 폭 안에서 줄바꿈한 결과를 SwiftUI로 잰다.
    private func measureBubble(message: String, accept: String, reject: String) -> CGSize {
        let content = BubbleContent(message: message, acceptTitle: accept, rejectTitle: reject,
                                    lime: Color(rgb: configuration.limeRGB), width: nil)
        let controller = NSHostingController(rootView: content)
        let fit = controller.sizeThatFits(in: CGSize(width: configuration.bubbleMaxWidth, height: 4000))
        return CGSize(width: min(configuration.bubbleMaxWidth, ceil(fit.width) + 1), height: ceil(fit.height))
    }
}
