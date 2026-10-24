import AgentContracts
import AppKit
import Gaze
import os

/// 전역 왼쪽 클릭을 관찰해 시선 엔진의 암묵 재보정 표본으로 넘긴다.
///
/// 마우스 전역 모니터는 손쉬운 사용 권한이 필요 없다. Gaze 자신이 합성한 클릭(에이전트 실행)은 시선에서 나온
/// 위치라 독립 근거가 아니므로 버린다. Gaze 창(보정 창 등)에 대한 클릭은 전역 모니터로 오지 않는다.
@MainActor
final class ImplicitCalibrationMonitor {
    private let engine: GazeEngine
    private let isEnabled: () -> Bool
    private var monitor: Any?
    private let logger = Logger(subsystem: "app.gaze", category: "implicit")

    init(engine: GazeEngine, isEnabled: @escaping () -> Bool) {
        self.engine = engine
        self.isEnabled = isEnabled
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        guard isEnabled() else { return }
        let location: CGPoint
        if let cgEvent = event.cgEvent {
            if cgEvent.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { return }
            location = cgEvent.location // 전역 좌상단 원점
        } else {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let point = NSEvent.mouseLocation
            location = CGPoint(x: point.x, y: primaryHeight - point.y)
        }
        // 이벤트 발생 후 핸들러까지의 지연만큼 엔진 시각을 당긴다.
        let age = min(max(ProcessInfo.processInfo.systemUptime - event.timestamp, 0), 0.5)
        let now = engine.clock.now()
        let time = MonotonicTime(nanoseconds: now.nanoseconds - min(now.nanoseconds, UInt64(age * 1e9)))
        switch engine.recordImplicitClick(at: location, time: time) {
        case .success(let error):
            logger.debug("implicit sample at (\(location.x, format: .fixed(precision: 0)), \(location.y, format: .fixed(precision: 0))) prediction error \(error, format: .fixed(precision: 0))pt")
        case .failure(let reason):
            logger.debug("implicit click rejected: \(reason.rawValue, privacy: .public)")
        }
    }
}
