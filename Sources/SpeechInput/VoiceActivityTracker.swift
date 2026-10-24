import AgentContracts
import Foundation

/// 레벨 미터의 VAD 판정을 발화 구간·쉼·endpoint 이벤트로 바꾼다.
///
/// VAD는 attack만큼 늦게 켜지고 hangover만큼 늦게 꺼진다. 이벤트의 시각은 이를 빼서
/// 실제 소리 기준으로 추정한다. endpoint 오프셋은 hangover를 포함한 보수적인 값이다.
public struct VoiceActivityTracker: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// VAD가 꺼진 뒤 이 시간(초)이 지나면 발화 끝(endpoint)으로 본다.
        /// 실제 무음 기준으로는 여기에 VAD hangover가 더해진다(기본 0.9 + 0.3 ≈ 1.2초).
        /// 시선을 옮기며 "이거… 저기로"처럼 쉬는 명령이 쪼개지지 않도록 길게 둔다.
        public var endpointGap: Double = 0.9
        /// `VADConfiguration.attack`/`hangover`와 같게 둔다.
        public var vadAttack: Double = 0.04
        public var vadHangover: Double = 0.30
        public init() {}
        public init(vad: VADConfiguration, endpointGap: Double = 0.9) {
            self.endpointGap = endpointGap
            self.vadAttack = vad.attack
            self.vadHangover = vad.hangover
        }
    }

    public struct VoicedSegment: Sendable, Equatable {
        public let start: MonotonicTime
        public let end: MonotonicTime
        public let startOffset: Double
        public let endOffset: Double
        public var duration: Double { max(0, endOffset - startOffset) }
        public init(start: MonotonicTime, end: MonotonicTime, startOffset: Double, endOffset: Double) {
            self.start = start
            self.end = end
            self.startOffset = startOffset
            self.endOffset = endOffset
        }
    }

    public struct Pause: Sendable, Equatable {
        public let start: MonotonicTime
        public let end: MonotonicTime
        public let duration: Double
        public init(start: MonotonicTime, end: MonotonicTime, duration: Double) {
            self.start = start
            self.end = end
            self.duration = duration
        }
    }

    public enum Event: Sendable, Equatable {
        /// 음성이 시작됐다. 직전 음성 이후의 쉼이 있으면 함께 준다.
        case voiceStarted(offset: Double, time: MonotonicTime, pauseBefore: Pause?)
        case voiceStopped(VoicedSegment)
        /// 발화 끝. `lastVoiceOffset`까지 확정하면 된다.
        case endpoint(lastVoiceOffset: Double, time: MonotonicTime)
    }

    public var configuration: Configuration
    public private(set) var isVoice = false
    private var lastVoice: (offset: Double, time: MonotonicTime)?
    private var segmentStart: (offset: Double, time: MonotonicTime)?
    private var endpointFired = true

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    /// 진행 중인 음성 구간의 시작(스트림 초). 무음이면 nil.
    public var currentVoiceStartOffset: Double? { isVoice ? segmentStart?.offset : nil }

    public mutating func ingest(_ reading: MeterReading) -> [Event] {
        var events: [Event] = []
        let offset = reading.streamOffset
        let time = reading.sample.time
        if reading.sample.isVoice {
            if !isVoice {
                isVoice = true
                let onsetOffset = offset - configuration.vadAttack
                let onsetTime = time.offset(bySeconds: -configuration.vadAttack)
                var pause: Pause?
                if let last = lastVoice {
                    let start = last.time.offset(bySeconds: -configuration.vadHangover)
                    let end = max(start, onsetTime)
                    pause = Pause(start: start, end: end, duration: end.seconds(since: start))
                }
                segmentStart = (onsetOffset, onsetTime)
                endpointFired = false
                events.append(.voiceStarted(offset: onsetOffset, time: onsetTime, pauseBefore: pause))
            }
            lastVoice = (offset, time)
        } else {
            if isVoice {
                isVoice = false
                if let start = segmentStart, let last = lastVoice {
                    let endOffset = max(start.offset, last.offset - configuration.vadHangover)
                    let endTime = max(start.time, last.time.offset(bySeconds: -configuration.vadHangover))
                    events.append(.voiceStopped(VoicedSegment(start: start.time, end: endTime,
                                                              startOffset: start.offset, endOffset: endOffset)))
                }
                segmentStart = nil
            }
            if let last = lastVoice, !endpointFired, offset - last.offset >= configuration.endpointGap {
                endpointFired = true
                events.append(.endpoint(lastVoiceOffset: last.offset, time: last.time))
            }
        }
        return events
    }

    public mutating func reset() {
        isVoice = false
        lastVoice = nil
        segmentStart = nil
        endpointFired = true
    }
}
