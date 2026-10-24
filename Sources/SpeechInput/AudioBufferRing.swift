import AgentContracts
import Foundation
import Synchronization

/// 스트림 타임라인(캡처 시작 이후 받은 오디오 프레임 누적 길이, 초) 위의 구간.
///
/// 스트림 타임라인은 받은 프레임만 센다. 버퍼가 빠지면 실제 시간과 어긋나므로
/// `MonotonicTime`으로 바꿀 때는 반드시 `AudioBufferRing`을 거친다.
/// SpeechAnalyzer의 CMTime도 같은 타임라인(첫 버퍼 = 0초)을 쓴다.
public struct StreamTimeRange: Sendable, Equatable, Codable {
    public var start: Double
    public var end: Double
    public init(start: Double, end: Double) {
        self.start = start
        self.end = max(start, end)
    }
    public var duration: Double { end - start }
    public func union(_ other: StreamTimeRange) -> StreamTimeRange {
        StreamTimeRange(start: min(start, other.start), end: max(end, other.end))
    }
}

/// 링에서 잘라 낸 모노 PCM 구간. 원격 정렬기 입력으로 쓴다.
public struct AudioClip: Sendable, Equatable {
    /// 클립 첫 샘플의 스트림 오프셋(초). 클립 상대 오프셋 + streamStart = 스트림 오프셋.
    public let streamStart: Double
    public let sampleRate: Double
    public let samples: [Float]

    public init(streamStart: Double, sampleRate: Double, samples: [Float]) {
        self.streamStart = streamStart
        self.sampleRate = sampleRate
        self.samples = samples
    }

    public var duration: Double { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }
    public var streamRange: StreamTimeRange { StreamTimeRange(start: streamStart, end: streamStart + duration) }

    /// 16비트 PCM 모노 WAV.
    public func wavData() -> Data {
        var data = Data()
        let rate = UInt32(max(1, sampleRate.rounded()))
        let byteCount = UInt32(samples.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(rate); append(rate * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        data.reserveCapacity(data.count + samples.count * 2)
        for sample in samples {
            append(Int16((max(-1, min(1, sample)) * Float(Int16.max)).rounded()))
        }
        return data
    }
}

/// 버퍼마다 (스트림 오프셋, 실제 host time)을 기록하는 링.
///
/// 오디오 탭은 버퍼마다 `append`를 호출한다. 단어 시각(스트림 상대, 또는 클립 상대)을
/// 실제 발화 시각(`MonotonicTime`)으로 바꿀 때 이 앵커들을 보간한다.
/// 버퍼가 빠지거나 장치가 바뀌어도 각 버퍼가 자기 host time을 갖고 있으므로 오차가 누적되지 않는다.
public final class AudioBufferRing: Sendable {
    struct Anchor {
        let streamStart: Double
        let duration: Double
        let hostStart: UInt64
        let sampleRate: Double
        var samples: [Float]?
        var streamEnd: Double { streamStart + duration }
        var hostEnd: UInt64 { hostStart &+ UInt64(max(0, duration * 1_000_000_000).rounded()) }
    }

    struct State {
        var anchors: [Anchor] = []
        var head = 0
        var streamEnd: Double = 0
        var sampleHead = 0
    }

    public let anchorRetention: Double
    public let sampleRetention: Double
    private let state = Mutex(State())

    public init(anchorRetention: Double = 120, sampleRetention: Double = 30) {
        self.anchorRetention = anchorRetention
        self.sampleRetention = sampleRetention
    }

    /// 다음 버퍼를 기록하고 그 버퍼에 배정된 스트림 구간을 돌려준다.
    /// - Parameters:
    ///   - hostTime: 버퍼 첫 프레임이 마이크에 들어온 시각.
    ///   - monoSamples: 클립 추출용 모노 샘플. nil이면 시각 매핑만 한다.
    @discardableResult
    public func append(frameCount: Int, sampleRate: Double, hostTime: MonotonicTime,
                       monoSamples: [Float]? = nil) -> StreamTimeRange {
        guard frameCount > 0, sampleRate > 0 else {
            let end = streamEnd
            return StreamTimeRange(start: end, end: end)
        }
        return state.withLock { state in
            let duration = Double(frameCount) / sampleRate
            let anchor = Anchor(streamStart: state.streamEnd, duration: duration, hostStart: hostTime.nanoseconds,
                                sampleRate: sampleRate, samples: sampleRetention > 0 ? monoSamples : nil)
            state.anchors.append(anchor)
            state.streamEnd += duration
            let range = StreamTimeRange(start: anchor.streamStart, end: state.streamEnd)
            Self.trim(&state, anchorRetention: anchorRetention, sampleRetention: sampleRetention)
            return range
        }
    }

    /// 지금까지 받은 오디오의 스트림 끝(초).
    public var streamEnd: Double { state.withLock { $0.streamEnd } }

    /// 기록이 남아 있는 스트림 구간.
    public var retainedRange: StreamTimeRange? {
        state.withLock { state in
            guard state.head < state.anchors.count else { return nil }
            return StreamTimeRange(start: state.anchors[state.head].streamStart, end: state.streamEnd)
        }
    }

    public func reset() {
        state.withLock { $0 = State() }
    }

    /// 스트림 오프셋(초) → 실제 발화 시각. 기록 범위 밖은 가장 가까운 앵커에서 외삽한다.
    public func monotonicTime(atStreamOffset offset: Double) -> MonotonicTime? {
        state.withLock { state in
            let live = state.anchors[state.head...]
            guard let first = live.first, let last = live.last else { return nil }
            let anchor: Anchor
            if offset <= first.streamStart {
                anchor = first
            } else if offset >= last.streamStart {
                anchor = last
            } else {
                // streamStart <= offset 인 마지막 앵커(이진 탐색).
                var low = state.head, high = state.anchors.count - 1
                while low < high {
                    let mid = (low + high + 1) / 2
                    if state.anchors[mid].streamStart <= offset { low = mid } else { high = mid - 1 }
                }
                anchor = state.anchors[low]
            }
            return MonotonicTime(nanoseconds: anchor.hostStart).offset(bySeconds: offset - anchor.streamStart)
        }
    }

    /// 실제 시각 → 스트림 오프셋. 버퍼가 빠진 구간의 시각은 가장 가까운 경계로 붙인다.
    public func streamOffset(at time: MonotonicTime) -> Double? {
        state.withLock { state in
            let live = state.anchors[state.head...]
            guard let first = live.first, let last = live.last else { return nil }
            let target = time.nanoseconds
            if target <= first.hostStart {
                return first.streamStart - Double(first.hostStart - target) / 1_000_000_000
            }
            if target >= last.hostStart {
                return last.streamStart + Double(target - last.hostStart) / 1_000_000_000
            }
            var low = state.head, high = state.anchors.count - 1
            while low < high {
                let mid = (low + high + 1) / 2
                if state.anchors[mid].hostStart <= target { low = mid } else { high = mid - 1 }
            }
            let anchor = state.anchors[low]
            let within = Double(target - anchor.hostStart) / 1_000_000_000
            return anchor.streamStart + min(within, anchor.duration)
        }
    }

    /// 스트림 구간의 모노 PCM을 잘라 낸다. 샘플이 보관된 범위로 잘리고, 표본율이 섞이면 첫 표본율만 쓴다.
    public func clip(_ range: StreamTimeRange) -> AudioClip? {
        state.withLock { state in
            var samples: [Float] = []
            var clipStart: Double?
            var rate: Double?
            for index in state.head..<state.anchors.count {
                let anchor = state.anchors[index]
                guard anchor.streamEnd > range.start, anchor.streamStart < range.end,
                      let chunk = anchor.samples, !chunk.isEmpty else { continue }
                if let rate, abs(rate - anchor.sampleRate) > 0.5 { break }
                // 부동소수 오차로 표본 하나가 밀리지 않게 경계에 여유를 둔다.
                let lower = max(0, Int(((range.start - anchor.streamStart) * anchor.sampleRate + 1e-6).rounded(.down)))
                let upper = min(chunk.count, Int(((range.end - anchor.streamStart) * anchor.sampleRate - 1e-6).rounded(.up)))
                guard lower < upper else { continue }
                if clipStart == nil {
                    clipStart = anchor.streamStart + Double(lower) / anchor.sampleRate
                    rate = anchor.sampleRate
                }
                samples.append(contentsOf: chunk[lower..<upper])
            }
            guard let clipStart, let rate, !samples.isEmpty else { return nil }
            return AudioClip(streamStart: clipStart, sampleRate: rate, samples: samples)
        }
    }

    private static func trim(_ state: inout State, anchorRetention: Double, sampleRetention: Double) {
        let anchorCutoff = state.streamEnd - anchorRetention
        // 마지막 앵커는 외삽 기준이므로 항상 남긴다.
        while state.head < state.anchors.count - 1, state.anchors[state.head].streamEnd < anchorCutoff {
            state.head += 1
        }
        state.sampleHead = max(state.sampleHead, state.head)
        let sampleCutoff = state.streamEnd - sampleRetention
        while state.sampleHead < state.anchors.count, state.anchors[state.sampleHead].streamEnd < sampleCutoff {
            state.anchors[state.sampleHead].samples = nil
            state.sampleHead += 1
        }
        if state.head > 2048 {
            state.anchors.removeFirst(state.head)
            state.sampleHead -= state.head
            state.head = 0
        }
    }
}
