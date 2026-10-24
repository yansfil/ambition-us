import AgentContracts
import Foundation

// MARK: - 시각 변환

/// 스트림 오프셋(초) → 실제 발화 시각. `AudioBufferRing`이 구현한다.
public protocol StreamClock: Sendable {
    func monotonicTime(atStreamOffset offset: Double) -> MonotonicTime?
}

extension AudioBufferRing: StreamClock {}

// MARK: - 단어 가설

/// 전사기 결과의 run 하나. 시각은 스트림 타임라인(초)이다.
public struct TimedToken: Sendable, Equatable {
    public var text: String
    public var range: StreamTimeRange?
    public var confidence: Double?
    public init(text: String, range: StreamTimeRange?, confidence: Double? = nil) {
        self.text = text
        self.range = range
        self.confidence = confidence
    }
}

/// 스트림 타임라인 위의 단어(어절) 하나.
public struct AlignedWord: Sendable, Equatable {
    public var word: String
    public var range: StreamTimeRange
    public var confidence: Double
    /// run 시각이 없어 글자 수 비례로 나누거나 보간한 값이면 true.
    public var isEstimated: Bool
    public init(word: String, range: StreamTimeRange, confidence: Double, isEstimated: Bool) {
        self.word = word
        self.range = range
        self.confidence = confidence
        self.isEstimated = isEstimated
    }
}

/// run(토큰) 열을 공백 기준 단어(한국어 어절)로 묶는다.
///
/// - run 하나에 단어가 여러 개면 run 구간을 글자 수 비례로 나눈다.
/// - 단어 하나가 run 여러 개에 걸치면(예: "저기" + "로") 구간을 합친다.
/// - 시각이 없는 단어는 앞뒤 단어(없으면 `fallbackRange`) 사이를 글자 수 비례로 보간한다.
/// - 앞뒤 문장부호는 떼고, 문장부호만 있는 토큰은 버린다.
public enum WordSegmenter {
    public static func words(from tokens: [TimedToken], fallbackRange: StreamTimeRange,
                             defaultConfidence: Double) -> [AlignedWord] {
        struct Draft {
            var text = ""
            var range: StreamTimeRange?
            var confidenceSum = 0.0
            var confidenceCount = 0
            var estimated = false
        }
        var drafts: [Draft] = []
        var current: Draft?
        func flush() {
            if let draft = current, !draft.text.isEmpty { drafts.append(draft) }
            current = nil
        }

        for token in tokens {
            let (pieces, trailingBreak) = split(token.text)
            let total = pieces.reduce(0) { $0 + $1.text.count }
            var consumed = 0
            for piece in pieces {
                if piece.leadingBreak { flush() }
                var draft = current ?? Draft()
                if let range = token.range, total > 0 {
                    let lower = range.start + range.duration * Double(consumed) / Double(total)
                    consumed += piece.text.count
                    let upper = range.start + range.duration * Double(consumed) / Double(total)
                    let sub = StreamTimeRange(start: lower, end: upper)
                    draft.range = draft.range.map { $0.union(sub) } ?? sub
                }
                draft.text += piece.text
                if let confidence = token.confidence {
                    draft.confidenceSum += confidence
                    draft.confidenceCount += 1
                }
                if pieces.count > 1 { draft.estimated = true }
                current = draft
            }
            if trailingBreak { flush() }
        }
        flush()

        // 시각이 빠진 단어 보간.
        var index = 0
        while index < drafts.count {
            guard drafts[index].range == nil else { index += 1; continue }
            var end = index
            while end < drafts.count, drafts[end].range == nil { end += 1 }
            let lower = index > 0 ? drafts[index - 1].range!.end : fallbackRange.start
            let upper = end < drafts.count ? drafts[end].range!.start : fallbackRange.end
            let span = max(0, upper - lower)
            let chars = drafts[index..<end].reduce(0) { $0 + max(1, $1.text.count) }
            var consumed = 0
            for position in index..<end {
                let start = lower + span * Double(consumed) / Double(chars)
                consumed += max(1, drafts[position].text.count)
                drafts[position].range = StreamTimeRange(start: start, end: lower + span * Double(consumed) / Double(chars))
                drafts[position].estimated = true
            }
            index = end
        }

        return drafts.compactMap { draft in
            let word = draft.text.trimmingCharacters(in: trimSet)
            guard !word.isEmpty, let range = draft.range else { return nil }
            var confidence = draft.confidenceCount > 0
                ? draft.confidenceSum / Double(draft.confidenceCount) : defaultConfidence
            if draft.estimated { confidence *= 0.8 }
            return AlignedWord(word: word, range: range, confidence: min(1, max(0, confidence)),
                               isEstimated: draft.estimated)
        }
    }

    static let trimSet = CharacterSet.punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines)

    /// 토큰 텍스트를 공백 없는 조각으로 나눈다. leadingBreak는 조각 앞에 공백이 있었는지.
    private static func split(_ text: String) -> (pieces: [(text: String, leadingBreak: Bool)], trailingBreak: Bool) {
        var pieces: [(text: String, leadingBreak: Bool)] = []
        var buffer = ""
        var bufferLeadingBreak = false
        var pendingBreak = false
        for character in text {
            if character.isWhitespace {
                if !buffer.isEmpty {
                    pieces.append((buffer, bufferLeadingBreak))
                    buffer = ""
                }
                pendingBreak = true
            } else {
                if buffer.isEmpty {
                    bufferLeadingBreak = pendingBreak
                    pendingBreak = false
                }
                buffer.append(character)
            }
        }
        if !buffer.isEmpty { pieces.append((buffer, bufferLeadingBreak)) }
        // 공백으로 끝났으면(공백만 있는 토큰 포함) 다음 토큰은 새 단어다.
        return (pieces, pendingBreak)
    }
}

// MARK: - 음성 구간 보정

/// VAD 음성 구간(스트림 초). 단어 시작을 실제 소리 시작으로 옮기는 데 쓴다.
///
/// SpeechTranscriber의 최종 run 구간은 서로 맞닿게 나와 앞쪽 무음까지 덮는다
/// (예: 1초 쉰 뒤 "저기로"의 run이 쉼 시작부터 잡힌다). 끝 시각은 정확하므로 시작만 옮긴다.
public struct VoiceActivityMap: Sendable, Equatable {
    public var ranges: [StreamTimeRange]
    /// 진행 중인 음성 구간의 시작.
    public var openStart: Double?

    public init(ranges: [StreamTimeRange] = [], openStart: Double? = nil) {
        self.ranges = ranges
        self.openStart = openStart
    }

    /// 단어 구간이 무음으로 시작하면 시작을 겹치는 첫 음성 구간의 시작으로 옮긴다.
    /// 겹치는 음성 구간이 없으면(작은 목소리를 VAD가 놓친 경우) 그대로 둔다.
    public func snappingStarts(of words: [AlignedWord], minimumShift: Double = 0.1,
                               minimumDuration: Double = 0.05) -> [AlignedWord] {
        var voiced = ranges
        if let openStart { voiced.append(StreamTimeRange(start: openStart, end: .greatestFiniteMagnitude)) }
        guard !voiced.isEmpty else { return words }
        return words.map { word in
            let onset = voiced.filter { $0.start < word.range.end && $0.end > word.range.start }.map(\.start).min()
            guard let onset, onset > word.range.start + minimumShift,
                  onset < word.range.end - minimumDuration else { return word }
            var snapped = word
            snapped.range = StreamTimeRange(start: onset, end: word.range.end)
            return snapped
        }
    }
}

// MARK: - 정렬기

/// 정렬 요청. 전사기가 준 단어 가설(스트림 시각)과 발화가 차지하는 스트림 구간을 담는다.
public struct AlignmentRequest: Sendable, Equatable {
    public var utteranceID: UUID
    public var text: String
    public var streamRange: StreamTimeRange
    public var hypotheses: [AlignedWord]
    public init(utteranceID: UUID, text: String, streamRange: StreamTimeRange, hypotheses: [AlignedWord]) {
        self.utteranceID = utteranceID
        self.text = text
        self.streamRange = streamRange
        self.hypotheses = hypotheses
    }
}

/// 단어별 실제 발화 시각을 만든다. 결과 시각은 녹음 버퍼의 host time 기준이다(화면 표시 시각이 아님).
public protocol WordAligner: Sendable {
    func align(_ request: AlignmentRequest) async throws -> [WordTiming]
}

/// SpeechTranscriber run의 `audioTimeRange`를 그대로 쓰는 로컬 정렬기.
public struct TranscriberRunAligner: WordAligner {
    public let clock: any StreamClock
    public init(clock: any StreamClock) { self.clock = clock }

    public func align(_ request: AlignmentRequest) async throws -> [WordTiming] {
        words(for: request.hypotheses)
    }

    /// 동기 버전. 리비전마다 호출하는 조립기 경로에서 쓴다.
    public func words(for hypotheses: [AlignedWord]) -> [WordTiming] {
        hypotheses.compactMap { word in
            guard let start = clock.monotonicTime(atStreamOffset: word.range.start),
                  let end = clock.monotonicTime(atStreamOffset: word.range.end) else { return nil }
            return WordTiming(word: word.word, start: start, end: max(start, end), confidence: word.confidence)
        }
    }
}

/// 원격 정렬기가 돌려주는 클립 상대 단어 오프셋(초).
public struct ClipWordOffset: Sendable, Equatable, Codable {
    public var word: String
    public var start: Double
    public var end: Double
    public var confidence: Double?
    public init(word: String, start: Double, end: Double, confidence: Double? = nil) {
        self.word = word
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

public struct RemoteAlignmentInput: Sendable {
    public var clip: AudioClip
    public var transcript: String
    /// BCP-47, 예: "ko-KR".
    public var languageCode: String
    public init(clip: AudioClip, transcript: String, languageCode: String) {
        self.clip = clip
        self.transcript = transcript
        self.languageCode = languageCode
    }
}

public enum RemoteAlignmentError: Error, Equatable, Sendable {
    case missingCredentials
    case audioUnavailable
    case notImplemented(String)
    case invalidResponse(String)
}

/// 오디오 클립 + 전사문 → 클립 상대 단어 오프셋. Gemini 등 원격 모델 어댑터가 구현한다.
public protocol RemoteAlignmentService: Sendable {
    func wordOffsets(for input: RemoteAlignmentInput) async throws -> [ClipWordOffset]
}

/// 링에서 발화 구간 클립을 잘라 원격 서비스에 보내고, 클립 상대 오프셋을 실제 시각으로 옮긴다.
public struct RemoteWordAligner: WordAligner {
    public let service: any RemoteAlignmentService
    public let ring: AudioBufferRing
    public var padding: Double
    public var languageCode: String

    public init(service: any RemoteAlignmentService, ring: AudioBufferRing,
                padding: Double = 0.25, languageCode: String = "ko-KR") {
        self.service = service
        self.ring = ring
        self.padding = padding
        self.languageCode = languageCode
    }

    public func align(_ request: AlignmentRequest) async throws -> [WordTiming] {
        let padded = StreamTimeRange(start: max(0, request.streamRange.start - padding),
                                     end: request.streamRange.end + padding)
        guard let clip = ring.clip(padded) else { throw RemoteAlignmentError.audioUnavailable }
        let offsets = try await service.wordOffsets(
            for: RemoteAlignmentInput(clip: clip, transcript: request.text, languageCode: languageCode))
        return Self.map(offsets, clipStreamStart: clip.streamStart, clipDuration: clip.duration, clock: ring)
    }

    /// 클립 상대 오프셋 → 스트림 오프셋(+ clipStreamStart) → 실제 시각.
    public static func map(_ offsets: [ClipWordOffset], clipStreamStart: Double, clipDuration: Double,
                           clock: any StreamClock) -> [WordTiming] {
        offsets.compactMap { offset in
            let word = offset.word.trimmingCharacters(in: WordSegmenter.trimSet)
            guard !word.isEmpty, offset.start.isFinite, offset.end.isFinite else { return nil }
            let limit = clipDuration > 0 ? clipDuration : .infinity
            let relativeStart = min(max(0, offset.start), limit)
            let relativeEnd = min(max(relativeStart, offset.end), limit)
            guard let start = clock.monotonicTime(atStreamOffset: clipStreamStart + relativeStart),
                  let end = clock.monotonicTime(atStreamOffset: clipStreamStart + relativeEnd) else { return nil }
            return WordTiming(word: word, start: start, end: max(start, end),
                              confidence: min(1, max(0, offset.confidence ?? 0.8)))
        }
    }
}

/// 주 정렬기가 실패하거나 빈 결과면 보조 정렬기를 쓴다.
public struct FallbackWordAligner: WordAligner {
    public let primary: any WordAligner
    public let fallback: any WordAligner
    public init(primary: any WordAligner, fallback: any WordAligner) {
        self.primary = primary
        self.fallback = fallback
    }

    public func align(_ request: AlignmentRequest) async throws -> [WordTiming] {
        if let words = try? await primary.align(request), !words.isEmpty { return words }
        return try await fallback.align(request)
    }
}

// MARK: - Gemini 스텁

/// gemini-3.5-transcribe 단어 오프셋 어댑터 자리. 네트워크 호출은 아직 구현하지 않았다.
///
/// 응답은 `{"words":[{"word":"이거","start":0.42,"end":0.71,"confidence":0.93}]}` 형태(초 단위 숫자,
/// 또는 "0.420s" 문자열)를 가정하고 `parseWordOffsets`로 해석한다. API 키는 저장하지 않고
/// 호출 시점에 `apiKeyProvider`로만 읽으며, `description`에도 넣지 않는다.
public struct GeminiTranscribeAlignmentService: RemoteAlignmentService, CustomStringConvertible {
    public static let defaultModel = "gemini-3.5-transcribe"
    public var model: String
    private let apiKeyProvider: @Sendable () -> String?

    public init(model: String = GeminiTranscribeAlignmentService.defaultModel,
                apiKeyProvider: @escaping @Sendable () -> String?) {
        self.model = model
        self.apiKeyProvider = apiKeyProvider
    }

    public var description: String { "GeminiTranscribeAlignmentService(model: \(model))" }

    public func wordOffsets(for input: RemoteAlignmentInput) async throws -> [ClipWordOffset] {
        guard let key = apiKeyProvider(), !key.isEmpty else { throw RemoteAlignmentError.missingCredentials }
        // TODO: input.clip.wavData() + input.transcript를 \(model)에 보내 단어 오프셋을 받는다.
        throw RemoteAlignmentError.notImplemented("\(model) 단어 오프셋 호출은 스텁이다")
    }

    /// 가정한 응답 JSON을 클립 상대 오프셋으로 바꾼다. 키 이름은 word/text, start/startOffset/start_time,
    /// end/endOffset/end_time을 받는다.
    public static func parseWordOffsets(_ data: Data) throws -> [ClipWordOffset] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw RemoteAlignmentError.invalidResponse("JSON이 아니다")
        }
        let list: [Any]
        if let object = root as? [String: Any], let words = object["words"] as? [Any] {
            list = words
        } else if let array = root as? [Any] {
            list = array
        } else {
            throw RemoteAlignmentError.invalidResponse("words 배열이 없다")
        }
        return try list.map { element in
            guard let item = element as? [String: Any],
                  let word = (item["word"] ?? item["text"]) as? String,
                  let start = seconds(item["start"] ?? item["startOffset"] ?? item["start_time"]),
                  let end = seconds(item["end"] ?? item["endOffset"] ?? item["end_time"]) else {
                throw RemoteAlignmentError.invalidResponse("단어 항목 형식 오류")
            }
            return ClipWordOffset(word: word, start: start, end: max(start, end),
                                  confidence: (item["confidence"] as? NSNumber)?.doubleValue)
        }
    }

    private static func seconds(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            return Double(trimmed.hasSuffix("s") ? String(trimmed.dropLast()) : trimmed)
        }
        return nil
    }
}
