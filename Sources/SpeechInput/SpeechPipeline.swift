import AVFAudio
import AgentContracts
import Foundation

/// 레벨 샘플·전사 결과 → endpoint·리비전·준언어 신호. 라이브 소스와 파일 재생이 같이 쓴다.
public struct SpeechPipeline: Sendable {
    public struct Output: Sendable {
        public var updates: [AssembledUpdate] = []
        public var cues: [ParalinguisticCue] = []
        /// 설정되면 전사기에 이 스트림 오프셋까지 확정을 요청한다.
        public var finalizeThrough: Double?
        public init() {}
    }

    public private(set) var assembler: TranscriptAssembler
    public private(set) var tracker: VoiceActivityTracker
    public private(set) var detector: ParalinguisticDetector
    /// true면 VAD 음성 구간과 겹치지 않는 결과로는 새 발화를 열지 않는다(무음 환각 방지).
    public var requireVoiceEvidence: Bool
    /// 음성 구간과 결과 시각을 비교할 때의 여유(초).
    public var voiceEvidencePadding: Double = 0.35
    private var voicedRanges: [StreamTimeRange] = []

    public init(clock: any StreamClock, assembler: TranscriptAssembler.Configuration = .init(),
                tracker: VoiceActivityTracker.Configuration = .init(),
                paralinguistic: ParalinguisticDetector.Configuration = .init(),
                requireVoiceEvidence: Bool = true) {
        self.assembler = TranscriptAssembler(clock: clock, configuration: assembler)
        self.tracker = VoiceActivityTracker(configuration: tracker)
        self.detector = ParalinguisticDetector(configuration: paralinguistic)
        self.requireVoiceEvidence = requireVoiceEvidence
    }

    public mutating func process(_ reading: MeterReading) -> Output {
        var output = Output()
        for event in tracker.ingest(reading) {
            if case .voiceStopped(let segment) = event {
                voicedRanges.append(StreamTimeRange(start: segment.startOffset, end: segment.endOffset))
                if voicedRanges.count > 128 { voicedRanges.removeFirst(voicedRanges.count - 128) }
            }
            output.cues += detector.ingest(event, utteranceID: assembler.lastUtteranceID)
            syncVoiceActivity()
            if case .endpoint(let lastVoiceOffset, _) = event {
                append(assembler.endpoint(at: lastVoiceOffset, now: reading.streamOffset), to: &output)
                output.finalizeThrough = min(lastVoiceOffset + 0.15, reading.streamOffset)
            }
        }
        append(assembler.tick(now: reading.streamOffset, voiceActive: tracker.isVoice), to: &output)
        return output
    }

    public mutating func ingest(_ segment: TranscriberSegment, now: Double) -> Output {
        var output = Output()
        // 진행 중인 발화의 수정은 그대로 받는다. 새 발화를 열 수 있는 결과만 음성 근거를 본다.
        let opensNew = assembler.currentUtteranceID == nil || assembler.isAwaitingFinal
        if requireVoiceEvidence, opensNew, segment.hasText, !hasVoiceEvidence(segment) { return output }
        syncVoiceActivity()
        append(assembler.ingest(segment, now: now), to: &output)
        return output
    }

    private mutating func syncVoiceActivity() {
        assembler.voiceActivity = VoiceActivityMap(ranges: voicedRanges, openStart: tracker.currentVoiceStartOffset)
    }

    func hasVoiceEvidence(_ segment: TranscriberSegment) -> Bool {
        let padding = voiceEvidencePadding
        return segment.speechSpans.contains { span in
            if let start = tracker.currentVoiceStartOffset, span.end + padding >= start { return true }
            return voicedRanges.contains { $0.start - padding < span.end && $0.end + padding > span.start }
        }
    }

    public mutating func flush() -> Output {
        var output = Output()
        append(assembler.flush(), to: &output)
        tracker.reset()
        voicedRanges.removeAll()
        return output
    }

    private mutating func append(_ updates: [AssembledUpdate], to output: inout Output) {
        for assembled in updates {
            output.updates.append(assembled)
            output.cues += detector.ingest(assembled.update)
        }
    }
}

/// 오디오 파일을 라이브와 같은 경로(탭 처리기 → 링·미터·전사기 → 파이프라인)로 흘려 본다.
/// 마이크 없이 SpeechTranscriber 통합을 확인하거나 녹음을 재생할 때 쓴다.
public enum SpeechFileReplay {
    public struct Result: Sendable {
        public var updates: [TranscriptUpdate]
        public var cues: [ParalinguisticCue]
        public var levels: [AudioLevelSample]
        public var segments: [TranscriberSegment]
        public var resolvedLocale: Locale?
        public var hostBase: MonotonicTime
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var levels: [AudioLevelSample] = []
        private var readings: [MeterReading] = []
        private var segments: [TranscriberSegment] = []
        private var allSegments: [TranscriberSegment] = []
        func add(level: AudioLevelSample) { lock.withLock { levels.append(level) } }
        func add(readings new: [MeterReading]) { lock.withLock { readings += new } }
        func add(segment: TranscriberSegment) { lock.withLock { segments.append(segment); allSegments.append(segment) } }
        func drain() -> ([MeterReading], [TranscriberSegment]) {
            lock.withLock {
                defer { readings.removeAll(); segments.removeAll() }
                return (readings, segments)
            }
        }
        func snapshot() -> ([AudioLevelSample], [TranscriberSegment]) { lock.withLock { (levels, allSegments) } }
    }

    /// - Parameters:
    ///   - speed: 1이면 실시간 속도로 넣는다(전사기 지연과 endpoint 타이밍이 라이브와 같아진다).
    ///   - trailingSilence: 끝에 덧붙일 무음(초). endpoint가 잡히게 한다.
    public static func run(fileURL: URL, configuration: LiveSpeechSource.Configuration = .init(),
                           speed: Double = 1, trailingSilence: Double = 2.0) async throws -> Result {
        let file = try AVAudioFile(forReading: fileURL)
        let format = file.processingFormat
        let transcriber = KoreanTranscriber(options: .init(locale: configuration.locale,
                                                           allowAssetDownload: configuration.allowAssetDownload,
                                                           fastResults: configuration.fastResults,
                                                           contextualStrings: configuration.contextualStrings))
        let analyzerFormat = try await transcriber.prepare(naturalFormat: format)
        let locale = await transcriber.resolvedLocale
        let collector = Collector()
        let input = try await transcriber.start(onSegment: { collector.add(segment: $0) }, onFailure: { _ in })
        let ring = AudioBufferRing(sampleRetention: configuration.audioRetention)
        let meter = LevelMeter(normalization: configuration.normalization, vad: configuration.vad,
                               emitRateHz: configuration.levelRateHz)
        let tap = TapProcessor(ring: ring, meter: meter, analyzerFormat: analyzerFormat,
                               sinks: TapSinks(level: { collector.add(level: $0) },
                                               readings: { collector.add(readings: $0) }, analyzer: input))
        var pipeline = SpeechPipeline(clock: ring, assembler: configuration.assembler,
                                      tracker: .init(vad: configuration.vad, endpointGap: configuration.endpointGap),
                                      paralinguistic: configuration.paralinguistic,
                                      requireVoiceEvidence: configuration.requireVoiceEvidence)
        var updates: [TranscriptUpdate] = []
        var cues: [ParalinguisticCue] = []
        func pump() async {
            let (readings, segments) = collector.drain()
            var outputs: [SpeechPipeline.Output] = []
            for segment in segments { outputs.append(pipeline.ingest(segment, now: ring.streamEnd)) }
            for reading in readings { outputs.append(pipeline.process(reading)) }
            for output in outputs {
                updates += output.updates.map(\.update)
                cues += output.cues
                if let through = output.finalizeThrough { await transcriber.finalize(through: through) }
            }
        }

        let chunkFrames = AVAudioFrameCount(max(256, (format.sampleRate * 0.1).rounded()))
        let hostBase = HostTime.now()
        var framesFed: Int64 = 0
        let silenceFrames = Int64(trailingSilence * format.sampleRate)
        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { break }
            if file.framePosition < file.length {
                try file.read(into: buffer, frameCount: chunkFrames)
            } else if framesFed < file.length + silenceFrames {
                buffer.frameLength = chunkFrames
                TapProcessor.silence(buffer)
            } else {
                break
            }
            guard buffer.frameLength > 0 else { break }
            let host = hostBase.offset(bySeconds: Double(framesFed) / format.sampleRate)
            let when = AVAudioTime(hostTime: HostTime.hostTicks(fromNanoseconds: host.nanoseconds))
            tap.process(buffer, when: when)
            framesFed += Int64(buffer.frameLength)
            await pump()
            if speed > 0 {
                try await Task.sleep(for: .seconds(Double(buffer.frameLength) / format.sampleRate / speed))
            }
        }
        tap.finishAnalyzerInput()
        await transcriber.stop()
        await pump()
        let flushed = pipeline.flush()
        updates += flushed.updates.map(\.update)
        cues += flushed.cues
        let (levels, segments) = collector.snapshot()
        return Result(updates: updates, cues: cues, levels: levels, segments: segments, resolvedLocale: locale,
                      hostBase: hostBase)
    }
}
