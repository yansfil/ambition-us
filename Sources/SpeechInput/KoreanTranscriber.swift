import AVFAudio
import CoreMedia
import Foundation
import Speech

/// SpeechAnalyzer + SpeechTranscriber(기본 ko-KR) 래퍼.
///
/// 입력 버퍼의 `bufferStartTime`은 첫 버퍼 = 0초인 스트림 타임라인이다. 따라서 결과의
/// `range`와 run별 `audioTimeRange`는 그대로 `AudioBufferRing`의 스트림 오프셋이 된다.
actor KoreanTranscriber {
    struct Options: Sendable {
        var locale: Locale
        var allowAssetDownload: Bool
        var fastResults: Bool
        var contextualStrings: [String]
    }

    private let options: Options
    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private(set) var resolvedLocale: Locale?
    private(set) var analyzerFormat: AVAudioFormat?

    init(options: Options) {
        self.options = options
    }

    /// 로케일 지원·설치 상태를 확인하고(필요하면 내려받고) 분석기 입력 형식을 정한다.
    func prepare(naturalFormat: AVAudioFormat?) async throws -> AVAudioFormat {
        guard SpeechTranscriber.isAvailable else { throw SpeechInputError.transcriberUnavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: options.locale) else {
            throw SpeechInputError.localeUnsupported(options.locale.identifier)
        }
        var reporting: Set<SpeechTranscriber.ReportingOption> = [.volatileResults]
        if options.fastResults { reporting.insert(.fastResults) }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: reporting,
                                            attributeOptions: [.audioTimeRange, .transcriptionConfidence])
        try await Self.ensureAssets(for: transcriber, locale: locale, allowDownload: options.allowAssetDownload)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber],
                                                                         considering: naturalFormat) else {
            throw SpeechInputError.audioFormatUnavailable
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber],
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        if !options.contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = options.contextualStrings
            try? await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: format)
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.resolvedLocale = locale
        self.analyzerFormat = format
        return format
    }

    /// 결과 수신을 시작하고 입력 continuation을 돌려준다. 오디오 탭이 여기에 버퍼를 넣는다.
    func start(onSegment: @escaping @Sendable (TranscriberSegment) -> Void,
               onFailure: @escaping @Sendable (String) -> Void) async throws -> AsyncStream<AnalyzerInput>.Continuation {
        guard let transcriber, let analyzer else { throw SpeechInputError.transcriberUnavailable }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        resultsTask = Task.detached(priority: .userInitiated) {
            do {
                for try await result in transcriber.results {
                    onSegment(Self.segment(from: result))
                }
            } catch is CancellationError {
            } catch {
                onFailure(String(describing: error))
            }
        }
        try await analyzer.start(inputSequence: stream)
        input = continuation
        return continuation
    }

    /// `offset`(스트림 초)까지의 결과를 확정하게 한다. endpoint 직후 호출한다.
    func finalize(through offset: Double) async {
        guard let analyzer, offset.isFinite, offset > 0 else { return }
        try? await analyzer.finalize(through: CMTime(seconds: offset, preferredTimescale: 1_000_000))
    }

    /// 입력을 닫고 남은 결과를 모두 확정한 뒤 끝낸다.
    func stop() async {
        input?.finish()
        input = nil
        if let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                await analyzer.cancelAndFinishNow()
            }
        }
        if let task = resultsTask {
            // 결과 스트림이 안 끝나면 2초 뒤 끊는다.
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(2))
                task.cancel()
            }
            await task.value
            watchdog.cancel()
        }
        resultsTask = nil
        analyzer = nil
        transcriber = nil
    }

    // MARK: 자산

    static func ensureAssets(for transcriber: SpeechTranscriber, locale: Locale, allowDownload: Bool) async throws {
        let target = locale.identifier(.bcp47)
        let installed = await SpeechTranscriber.installedLocales.contains { $0.identifier(.bcp47) == target }
        if !installed {
            let status = await AssetInventory.status(forModules: [transcriber])
            guard status != .unsupported else { throw SpeechInputError.localeUnsupported(target) }
            guard allowDownload else { throw SpeechInputError.assetsNotInstalled(target) }
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
            } catch {
                throw SpeechInputError.assetInstallFailed(String(describing: error))
            }
            guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
                throw SpeechInputError.assetsNotInstalled(target)
            }
        }
        // 이 로케일 자산을 유지하도록 예약한다(한도를 넘으면 시스템 판단에 맡긴다).
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier(.bcp47) == target }),
           reserved.count < AssetInventory.maximumReservedLocales {
            _ = try? await AssetInventory.reserve(locale: locale)
        }
    }

    /// 설치 상태 조회(UI 표시용).
    static func assetStatus(for locale: Locale) async -> AssetInventory.Status {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return .unsupported }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [])
        return await AssetInventory.status(forModules: [transcriber])
    }

    // MARK: 결과 변환

    static func segment(from result: SpeechTranscriber.Result) -> TranscriberSegment {
        let text = result.text
        var tokens: [TimedToken] = []
        for run in text.runs {
            let piece = String(text[run.range].characters)
            tokens.append(TimedToken(text: piece, range: run.audioTimeRange.flatMap(StreamTimeRange.init(cmTimeRange:)),
                                     confidence: run.transcriptionConfidence))
        }
        let range = StreamTimeRange(cmTimeRange: result.range)
            ?? StreamTimeRange(start: tokens.compactMap { $0.range?.start }.min() ?? 0,
                               end: tokens.compactMap { $0.range?.end }.max() ?? 0)
        return TranscriberSegment(range: range, text: String(text.characters), tokens: tokens, isFinal: result.isFinal)
    }
}

extension StreamTimeRange {
    init?(cmTimeRange range: CMTimeRange) {
        guard range.isValid, range.start.isNumeric, range.duration.isNumeric else { return nil }
        let start = range.start.seconds
        let end = CMTimeRangeGetEnd(range).seconds
        guard start.isFinite, end.isFinite else { return nil }
        self.init(start: start, end: end)
    }
}
