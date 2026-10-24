import AgentContracts
import AppKit
import Foundation

/// 수동 확인용 가짜 상태 시나리오. 시간 t(초)만으로 상태가 정해지는 순수 함수라 검사에도 쓴다.
///
/// 20초 주기:
/// - 0–4s   유휴 화면 테두리, 시선이 천천히 돌아다님, 말하는 중
/// - 4–8s   "읽는 중" 문단 영역, 조용함
/// - 8–12s  "입력 중" 입력칸 영역, 말하는 중
/// - 12–16s 오른쪽 위 버튼에 제안 말풍선 "여기다 이걸 올릴까요?", 마이크 음소거
/// - 16–18s 입력칸 실행 승인 요청(확인 대기), 조용함
/// - 18–20s 유휴, 시선 잃음, 마이크 사용 불가
public enum OverlayDemoScript {
    public static let period: Double = 20

    public enum Phase: String, Sendable, CaseIterable {
        case idle, reading, typing, suggestion, approval, lost
    }

    public static func phase(at t: Double) -> Phase {
        let p = t.truncatingRemainder(dividingBy: period)
        switch p {
        case ..<4: return .idle
        case ..<8: return .reading
        case ..<12: return .typing
        case ..<16: return .suggestion
        case ..<18: return .approval
        default: return .lost
        }
    }

    /// 데모 대상 영역(AX 전역 좌표). display는 AX 전역 좌표의 디스플레이 영역.
    public static func readingFrame(in d: CGRect) -> CGRect {
        CGRect(x: d.minX + d.width * 0.1, y: d.minY + d.height * 0.24, width: d.width * 0.38, height: d.height * 0.3)
    }

    public static func inputFrame(in d: CGRect) -> CGRect {
        CGRect(x: d.minX + d.width * 0.3, y: d.minY + d.height * 0.8, width: d.width * 0.4, height: 40)
    }

    public static func uploadButtonFrame(in d: CGRect) -> CGRect {
        CGRect(x: d.maxX - 190, y: d.minY + 52, width: 120, height: 34)
    }

    public static func state(at t: Double, display d: CGRect, displayID: UInt32 = 0) -> OverlayState {
        let phase = phase(at: t)
        let cycle = Int(t / period)
        let time = MonotonicTime(nanoseconds: UInt64(max(t, 0) * 1e9))
        let reading = readingFrame(in: d), input = inputFrame(in: d), upload = uploadButtonFrame(in: d)

        func gaze(around rect: CGRect, radius: Double, speed: Double = 0.7) -> GazeSample {
            let point = CGPoint(x: rect.midX + rect.width * 0.35 * CGFloat(sin(t * speed)),
                                y: rect.midY + rect.height * 0.3 * CGFloat(sin(t * speed * 1.7 + 1)))
            return GazeSample(time: time, displayID: displayID, point: point, uncertaintyRadius: radius,
                              confidence: 0.85, calibrationRevision: 1, isFixation: true)
        }
        func target(_ frame: CGRect, role: String, title: String) -> UITarget {
            UITarget(token: "demo-\(role)", pid: 0, appBundleID: "demo", role: role, title: title, frame: frame,
                     isEditable: role == "AXTextField", isSecure: false, supportedActions: ["AXPress"], observedAt: time)
        }
        func audio(_ state: AudioLevelSample.MicState, speaking: Bool) -> AudioLevelSample {
            let rms = speaking ? 0.12 + 0.1 * abs(sin(t * 5.3)) + 0.05 * abs(sin(t * 13)) : 0.005
            return AudioLevelSample(time: time, rms: rms, isVoice: speaking, micState: state)
        }
        func id(_ n: Int) -> UUID {
            UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", cycle * 10 + n))!
        }

        switch phase {
        case .idle:
            return OverlayState(gaze: gaze(around: d.insetBy(dx: d.width * 0.2, dy: d.height * 0.2), radius: 46, speed: 0.5),
                                audioLevel: audio(.active, speaking: true), agentRegion: .idleScreenEdge)
        case .reading:
            return OverlayState(gaze: gaze(around: reading, radius: 60),
                                audioLevel: audio(.active, speaking: false),
                                agentRegion: .target(frame: reading, label: OverlayStatusLabel.reading))
        case .typing:
            return OverlayState(gaze: gaze(around: input, radius: 40, speed: 1.1),
                                audioLevel: audio(.active, speaking: true),
                                agentRegion: .target(frame: input, label: OverlayStatusLabel.typing))
        case .suggestion:
            let suggestion = SuggestionCandidate(id: id(1), target: target(upload, role: "AXButton", title: "업로드"),
                                                 message: "여기다 이걸 올릴까요?", confidence: 0.8,
                                                 expiresAt: MonotonicTime(nanoseconds: time.nanoseconds + 5_000_000_000),
                                                 cooldownKey: "demo-upload")
            return OverlayState(gaze: gaze(around: upload, radius: 36, speed: 0.4),
                                audioLevel: audio(.muted, speaking: false),
                                agentRegion: .target(frame: upload, label: OverlayStatusLabel.awaitingApproval),
                                suggestion: suggestion)
        case .approval:
            let field = target(input, role: "AXTextField", title: "검색")
            let proposal = ActionProposal(id: id(2), action: .typeText(target: field, text: "오늘 회의록"),
                                          basedOnUtterance: id(3), basedOnRevision: 1,
                                          rationale: "검색창에 '오늘 회의록'을 입력할까요?", risk: .medium,
                                          expiresAt: MonotonicTime(nanoseconds: time.nanoseconds + 5_000_000_000))
            return OverlayState(gaze: gaze(around: input, radius: 40, speed: 0.3),
                                audioLevel: audio(.active, speaking: false),
                                agentRegion: .target(frame: input, label: OverlayStatusLabel.typing),
                                pendingApproval: proposal)
        case .lost:
            return OverlayState(gaze: nil, audioLevel: audio(.unavailable, speaking: false), agentRegion: .idleScreenEdge)
        }
    }
}

/// 가짜 상태를 주기적으로 그리는 데모 실행기.
@MainActor
public final class OverlayDemo {
    public let controller: OverlayController
    private var task: Task<Void, Never>?
    private var startedAt = Date()

    public init(controller: OverlayController = OverlayController()) {
        self.controller = controller
    }

    /// frameRate Hz로 가짜 상태를 render한다.
    public func start(frameRate: Double = 30) {
        stop()
        startedAt = Date()
        let interval = Duration.milliseconds(Int(1000 / max(frameRate, 1)))
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func tick() {
        let screens = NSScreen.screens
        guard let screen = NSScreen.main ?? screens.first else { return }
        let primaryHeight = (screens.first { $0.frame.origin == .zero } ?? screen).frame.height
        let geometry = DisplayGeometry(screen: screen)
        let state = OverlayDemoScript.state(at: Date().timeIntervalSince(startedAt),
                                            display: geometry.topLeftFrame(primaryHeight: primaryHeight),
                                            displayID: geometry.id)
        controller.render(state)
    }

    /// 단독 실행: 메뉴 막대 상주(accessory) 앱으로 데모를 띄운다. 반환하지 않는다.
    /// 예) GazeApp에서 `--overlay-demo` 인자를 받으면 `OverlayDemo.runStandalone()` 호출.
    public static func runStandalone(duration: Double? = nil) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let demo = OverlayDemo()
        demo.controller.onAccept = { print("[OverlayDemo] 수락: \($0.message)") }
        demo.controller.onReject = { print("[OverlayDemo] 거절: \($0.message)") }
        demo.start()
        if let duration {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(Int(duration * 1000)))
                exit(0)
            }
        }
        withExtendedLifetime(demo) { app.run() }
        exit(0)
    }
}
