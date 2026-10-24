import AgentContracts
import CoreGraphics
import Foundation
import Synchronization

/// 마우스 커서를 시선 대신 쓰는 소스. 카메라 없이 오버레이·Fusion을 개발·시연할 때 쓴다.
/// 같은 후처리(One Euro, I-VT, dwell/revisit)를 거치므로 하류 동작을 그대로 확인할 수 있다.
public final class MouseGazeSource: GazeSource, Sendable {
    public let engine: GazeEngine
    public var samples: AsyncStream<GazeSample> { engine.samples }
    public var nonverbalCues: AsyncStream<NonverbalCue> { engine.nonverbalCues }
    private let rate: Double
    private let expectedError: Double
    private let queue = DispatchQueue(label: "gaze.mouse", qos: .userInteractive)
    private let timer = Mutex<DispatchSourceTimer?>(nil)

    public init(rate: Double = 60, expectedError: Double = 10, configuration: GazePipelineConfiguration = .init(),
                clock: any MonotonicClock = GazeUptimeClock(), regionKeyer: GazeRegionKeying? = nil) {
        self.rate = rate
        self.expectedError = expectedError
        engine = GazeEngine(configuration: configuration, clock: clock, regionKeyer: regionKeyer)
    }

    public func start() async throws {
        engine.updateDisplays(DisplayGeometry.active())
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: 1 / max(rate, 1))
        source.setEventHandler { [engine, expectedError] in
            let now = engine.clock.now()
            engine.refreshDisplaysIfNeeded(now: now, interval: 1)
            // CGEvent 위치는 전역 좌상단 원점 좌표다.
            guard let location = CGEvent(source: nil)?.location else { return }
            engine.ingestScreenPoint(location, time: now, confidence: 1, calibrationRevision: 1,
                                     expectedError: expectedError)
        }
        let previous = timer.withLock { current -> DispatchSourceTimer? in
            let old = current
            current = source
            return old
        }
        previous?.cancel()
        source.resume()
    }

    public func stop() async {
        timer.withLock { current -> DispatchSourceTimer? in
            let old = current
            current = nil
            return old
        }?.cancel()
        engine.trackingLost(at: engine.clock.now())
    }
}
