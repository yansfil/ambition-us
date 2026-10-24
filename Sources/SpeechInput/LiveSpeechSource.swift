import AVFAudio
import AgentContracts
import Foundation
import Speech

/// 마이크 + SpeechAnalyzer 기반 `SpeechSource`.
///
/// 흐름: 오디오 탭(버퍼마다 host time 도장) → 링·레벨 미터·전사기 입력 →
/// 이 액터에서 VAD endpoint·리비전 조립·준언어 검출 → 세 AsyncStream.
/// 스트림은 정지 후에도 열려 있어 `start()`를 다시 부를 수 있다. 각 스트림은 소비자 하나를 가정한다.
public actor LiveSpeechSource: SpeechSource {
    public struct Configuration: Sendable {
        public var locale = Locale(identifier: "ko-KR")
        public var allowAssetDownload = true
        /// 지연을 줄이는 대신 정확도가 조금 떨어진다.
        public var fastResults = true
        /// 인식 편향용 문맥 단어(지시어·조작 동사).
        public var contextualStrings: [String] = LiveSpeechSource.defaultContextualStrings
        public var normalization = LevelNormalization()
        public var vad = VADConfiguration()
        public var levelRateHz: Double = 30
        /// 입력 노드의 presentationLatency만큼 host time을 앞당긴다.
        public var compensateInputLatency = true
        /// VAD가 꺼진 뒤 발화 끝으로 볼 시간(초). 실제 무음은 여기에 hangover(0.3초)가 더해진다.
        public var endpointGap: Double = 0.9
        /// VAD 음성 구간과 겹치지 않는 전사 결과로는 새 발화를 열지 않는다(무음 환각 방지).
        /// 아주 작은 목소리를 놓치면 끄거나 `vad.minOnLevel`을 낮춘다.
        public var requireVoiceEvidence = true
        public var assembler = TranscriptAssembler.Configuration()
        public var paralinguistic = ParalinguisticDetector.Configuration()
        /// 클립 추출용 PCM 보관 시간(초).
        public var audioRetention: Double = 30
        /// 설정하면 최종 리비전 뒤 단어 시각을 보정해 리비전을 하나 더 낸다(같은 텍스트, isFinal true).
        public var refinementAligner: (any WordAligner)?
        public init() {}
    }

    public static let defaultContextualStrings = [
        "이거", "저거", "그거", "이걸", "저걸", "여기", "저기", "거기", "여기로", "저기로", "이쪽", "저쪽",
        "클릭", "눌러", "열어", "닫아", "옮겨", "복사", "붙여넣기", "입력", "선택",
    ]

    public nonisolated let transcripts: AsyncStream<TranscriptUpdate>
    public nonisolated let levels: AsyncStream<AudioLevelSample>
    public nonisolated let paralinguisticCues: AsyncStream<ParalinguisticCue>
    /// 스트림 오프셋 ↔ 실제 시각, 클립 추출. 다른 모듈의 정렬기가 써도 된다.
    public nonisolated let ring: AudioBufferRing
    public let configuration: Configuration

    private let transcriptContinuation: AsyncStream<TranscriptUpdate>.Continuation
    private let levelContinuation: AsyncStream<AudioLevelSample>.Continuation
    private let cueContinuation: AsyncStream<ParalinguisticCue>.Continuation

    private var pipeline: SpeechPipeline
    private var session: Session?
    private var isStarting = false
    private var finalUpdates: [UUID: TranscriptUpdate] = [:]
    public private(set) var lastError: String?
    public private(set) var resolvedLocale: Locale?

    private enum Event: Sendable {
        case levels([MeterReading])
        case segment(TranscriberSegment)
        case transcriberFailed(String)
        case configurationChanged
    }

    private struct Session {
        let capture: MicrophoneCapture
        let tap: TapProcessor
        let transcriber: KoreanTranscriber
        let events: AsyncStream<Event>.Continuation
        let eventTask: Task<Void, Never>
    }

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        let ring = AudioBufferRing(anchorRetention: 120, sampleRetention: configuration.audioRetention)
        self.ring = ring
        (transcripts, transcriptContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (levels, levelContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
        (paralinguisticCues, cueContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
        pipeline = Self.makePipeline(ring: ring, configuration: configuration)
    }

    private static func makePipeline(ring: AudioBufferRing, configuration: Configuration) -> SpeechPipeline {
        SpeechPipeline(clock: ring, assembler: configuration.assembler,
                       tracker: .init(vad: configuration.vad, endpointGap: configuration.endpointGap),
                       paralinguistic: configuration.paralinguistic,
                       requireVoiceEvidence: configuration.requireVoiceEvidence)
    }

    deinit {
        transcriptContinuation.finish()
        levelContinuation.finish()
        cueContinuation.finish()
    }

    // MARK: SpeechSource

    public func start() async throws {
        guard session == nil, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        lastError = nil
        do {
            try await MicrophonePermission.ensureGranted()
        } catch {
            emitUnavailable()
            throw error
        }
        let capture = MicrophoneCapture(compensateInputLatency: configuration.compensateInputLatency)
        guard let naturalFormat = capture.inputFormat else {
            emitUnavailable()
            throw SpeechInputError.noInputDevice
        }
        let transcriber = KoreanTranscriber(options: .init(locale: configuration.locale,
                                                           allowAssetDownload: configuration.allowAssetDownload,
                                                           fastResults: configuration.fastResults,
                                                           contextualStrings: configuration.contextualStrings))
        let (events, eventContinuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        let analyzerFormat: AVAudioFormat
        let inputContinuation: AsyncStream<AnalyzerInput>.Continuation
        do {
            analyzerFormat = try await transcriber.prepare(naturalFormat: naturalFormat)
            resolvedLocale = await transcriber.resolvedLocale
            inputContinuation = try await transcriber.start(
                onSegment: { eventContinuation.yield(.segment($0)) },
                onFailure: { eventContinuation.yield(.transcriberFailed($0)) })
        } catch {
            await transcriber.stop()
            eventContinuation.finish()
            lastError = String(describing: error)
            emitUnavailable()
            throw error
        }

        ring.reset()
        pipeline = Self.makePipeline(ring: ring, configuration: configuration)
        finalUpdates.removeAll()

        let levelContinuation = self.levelContinuation
        let meter = LevelMeter(normalization: configuration.normalization, vad: configuration.vad,
                               emitRateHz: configuration.levelRateHz)
        let tap = TapProcessor(ring: ring, meter: meter, analyzerFormat: analyzerFormat,
                               sinks: TapSinks(level: { levelContinuation.yield($0) },
                                               readings: { eventContinuation.yield(.levels($0)) },
                                               analyzer: inputContinuation))
        do {
            try capture.start(tap: tap, onConfigurationChange: { eventContinuation.yield(.configurationChanged) })
        } catch {
            inputContinuation.finish()
            await transcriber.stop()
            eventContinuation.finish()
            emitUnavailable()
            throw error
        }

        let eventTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event)
            }
        }
        session = Session(capture: capture, tap: tap, transcriber: transcriber, events: eventContinuation,
                          eventTask: eventTask)
    }

    public func stop() async {
        guard let session else { return }
        self.session = nil
        session.capture.stop()
        session.tap.finishAnalyzerInput()
        // 남은 확정 결과가 이벤트로 들어온 뒤 끝낸다.
        await session.transcriber.stop()
        session.events.finish()
        await session.eventTask.value
        emit(pipeline.flush())
        emitUnavailable()
    }

    /// 앱 차원 음소거. 레벨은 muted로, 전사기에는 무음이 들어간다.
    public func setMuted(_ muted: Bool) {
        session?.tap.setMuted(muted)
    }

    // MARK: 이벤트 처리

    private func handle(_ event: Event) {
        switch event {
        case .levels(let readings):
            for reading in readings { emit(pipeline.process(reading)) }
        case .segment(let segment):
            emit(pipeline.ingest(segment, now: ring.streamEnd))
        case .transcriberFailed(let message):
            lastError = message
        case .configurationChanged:
            guard let session else { return }
            do {
                try session.capture.restart()
            } catch {
                lastError = String(describing: error)
                emitUnavailable()
            }
        }
    }

    private func emit(_ output: SpeechPipeline.Output) {
        for assembled in output.updates {
            let update = assembled.update
            transcriptContinuation.yield(update)
            if update.isFinal {
                finalUpdates[update.utteranceID] = update
                // 보정용 캐시. 순서는 상관없이 크기만 제한한다.
                if finalUpdates.count > 32, let evicted = finalUpdates.keys.first(where: { $0 != update.utteranceID }) {
                    finalUpdates[evicted] = nil
                }
                if let aligner = configuration.refinementAligner { refine(assembled.alignment, with: aligner) }
            }
        }
        for cue in output.cues { cueContinuation.yield(cue) }
        if let through = output.finalizeThrough, let transcriber = session?.transcriber {
            Task { await transcriber.finalize(through: through) }
        }
    }

    private func emitUnavailable() {
        levelContinuation.yield(AudioLevelSample(time: HostTime.now(), rms: 0, isVoice: false, micState: .unavailable))
    }

    private func refine(_ request: AlignmentRequest, with aligner: any WordAligner) {
        Task { [weak self] in
            guard let words = try? await aligner.align(request), !words.isEmpty else { return }
            await self?.applyRefinement(utteranceID: request.utteranceID, words: words)
        }
    }

    private func applyRefinement(utteranceID: UUID, words: [WordTiming]) {
        guard let last = finalUpdates[utteranceID], last.words != words else { return }
        let refined = TranscriptUpdate(utteranceID: utteranceID, revision: last.revision + 1, text: last.text,
                                       stablePrefix: last.stablePrefix, words: words, isFinal: true)
        finalUpdates[utteranceID] = refined
        transcriptContinuation.yield(refined)
    }
}
