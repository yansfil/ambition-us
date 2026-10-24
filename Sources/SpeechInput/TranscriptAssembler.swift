import AgentContracts
import Foundation

/// SpeechTranscriber 결과 하나를 스트림 타임라인으로 옮긴 것.
public struct TranscriberSegment: Sendable, Equatable {
    /// 결과가 덮는 오디오 구간(스트림 초).
    public var range: StreamTimeRange
    public var text: String
    /// AttributedString run별 텍스트·시각·신뢰도.
    public var tokens: [TimedToken]
    /// false면 volatile(다음 결과가 같은 구간을 교체한다).
    public var isFinal: Bool

    public init(range: StreamTimeRange, text: String, tokens: [TimedToken], isFinal: Bool) {
        self.range = range
        self.text = text
        self.tokens = tokens
        self.isFinal = isFinal
    }

    var normalizedText: String { Self.normalize(text) }
    /// 글자·숫자가 하나라도 있어야 텍스트로 본다(문장부호만 있는 결과는 빈 것으로 취급).
    var hasText: Bool { Self.hasLexicalContent(text) }

    static func hasLexicalContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// 글자가 있는 토큰들의 시각(없으면 결과 구간).
    var speechSpans: [StreamTimeRange] {
        let spans = tokens.filter { Self.hasLexicalContent($0.text) }.compactMap(\.range)
        return spans.isEmpty ? [range] : spans
    }
    var hasTimedTokens: Bool { tokens.contains { $0.range != nil } }
    var lastTimedTokenEnd: Double? { tokens.compactMap { $0.range?.end }.max() }

    static func normalize(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `cut`을 기준으로 앞/뒤로 나눈다. 토큰 시각이 있으면 토큰 시작 시각으로 가른다.
    /// volatile 결과의 run은 뒤쪽 무음까지 덮는 거친 구간이라 중앙값을 쓰면 앞말이 뒤로 밀린다.
    func split(at cut: Double, tolerance: Double) -> (before: TranscriberSegment?, after: TranscriberSegment?) {
        if range.end <= cut + tolerance { return (self, nil) }
        if range.start >= cut - tolerance { return (nil, self) }
        guard hasTimedTokens else {
            // 시각이 없으면 더 많이 걸친 쪽으로 보낸다.
            return cut - range.start >= range.end - cut ? (self, nil) : (nil, self)
        }
        var before: [TimedToken] = []
        var after: [TimedToken] = []
        var goesAfter = false
        for token in tokens {
            if let tokenRange = token.range { goesAfter = tokenRange.start >= cut - tolerance }
            if goesAfter { after.append(token) } else { before.append(token) }
        }
        let beforeHasText = Self.hasLexicalContent(before.map(\.text).joined())
        let afterHasText = Self.hasLexicalContent(after.map(\.text).joined())
        if !afterHasText { return (self, nil) }
        if !beforeHasText { return (nil, self) }
        return (
            TranscriberSegment(range: StreamTimeRange(start: range.start, end: cut),
                               text: before.map(\.text).joined(), tokens: before, isFinal: isFinal),
            TranscriberSegment(range: StreamTimeRange(start: cut, end: range.end),
                               text: after.map(\.text).joined(), tokens: after, isFinal: isFinal)
        )
    }

    /// `boundary` 이전 부분을 버린다. 남는 것이 없으면 nil.
    func trimmed(after boundary: Double, tolerance: Double) -> TranscriberSegment? {
        guard boundary > -.infinity else { return self }
        if range.end <= boundary + tolerance { return nil }
        if range.start >= boundary - tolerance { return self }
        let (_, after) = split(at: boundary, tolerance: tolerance)
        return after
    }
}

/// 조립기 출력. 최종 리비전이면 `alignment`로 원격 정렬기 보정을 요청할 수 있다.
public struct AssembledUpdate: Sendable, Equatable {
    public let update: TranscriptUpdate
    public let alignment: AlignmentRequest
}

/// SpeechTranscriber 결과(volatile/final)를 발화 단위 `TranscriptUpdate` 리비전으로 바꾼다.
///
/// - 같은 발화의 리비전은 전체 텍스트를 다시 담는다(교체, append 아님).
/// - `stablePrefix`는 전사기가 확정(final)한 부분이다. 항상 `text`의 접두사다.
/// - 발화 경계는 VAD endpoint(`endpoint(at:now:)`)로 정한다. endpoint 이후 확정 결과가
///   endpoint까지 덮으면 `isFinal: true`로 닫고, 늦으면 `finalizeTimeout` 뒤 강제로 닫는다.
/// - 닫힌 발화가 덮은 구간에 늦게 도착한 결과는 버린다(같은 명령이 두 번 나가지 않게).
public struct TranscriptAssembler: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// 구간 경계 비교 허용 오차(초).
        public var tolerance: Double = 0.08
        /// endpoint까지 확정됐다고 볼 여유(초). endpoint에는 VAD hangover가 포함돼 있다.
        public var completionSlack: Double = 0.4
        /// endpoint 뒤 확정 결과를 기다리는 최대 시간(초).
        public var finalizeTimeout: Double = 1.5
        /// VAD가 끝을 못 잡을 때: 확정 결과만 남은 채 변화가 없으면 닫는다.
        public var idleCloseAfter: Double = 2.0
        /// VAD가 끝을 못 잡을 때: volatile 결과가 이 시간 동안 안 바뀌면 닫는다.
        public var staleVolatileCloseAfter: Double = 4.0
        public var finalConfidence: Double = 0.9
        public var volatileConfidence: Double = 0.6
        public init() {}
    }

    struct Utterance: Sendable {
        let id: UUID
        var revision = 0
        var finalized: [TranscriberSegment] = []
        var volatile: [TranscriberSegment] = []
        var endpoint: Double?
        var endpointAt: Double?
        var lastChangeAt: Double
        var lastText = ""
        var lastStable = ""
        var lastWords: [WordTiming] = []
        var emitted = false

        var finalizedThrough: Double { finalized.map(\.range.end).max() ?? -.infinity }
        var volatileHasText: Bool { volatile.contains { $0.hasText } }
    }

    public var configuration: Configuration
    /// 설정하면 단어 시작을 VAD 음성 시작으로 옮긴다(파이프라인이 갱신).
    public var voiceActivity = VoiceActivityMap()
    private let aligner: TranscriberRunAligner
    private let makeID: @Sendable () -> UUID
    private var current: Utterance?
    private var pendingEndpoint: Double?
    private var closedThrough: Double = -.infinity
    public private(set) var lastClosedUtteranceID: UUID?

    public init(clock: any StreamClock, configuration: Configuration = .init(),
                makeID: @escaping @Sendable () -> UUID = { UUID() }) {
        self.configuration = configuration
        self.aligner = TranscriberRunAligner(clock: clock)
        self.makeID = makeID
    }

    public var currentUtteranceID: UUID? { current?.id }
    /// 열린 발화가 endpoint 뒤 확정을 기다리는 중인지.
    public var isAwaitingFinal: Bool { current?.endpoint != nil }
    /// 열린 발화, 없으면 마지막으로 닫힌 발화.
    public var lastUtteranceID: UUID? { current?.id ?? lastClosedUtteranceID }

    // MARK: 입력

    /// 전사기 결과 하나. `now`는 지금까지 받은 오디오의 스트림 끝(초).
    public mutating func ingest(_ segment: TranscriberSegment, now: Double) -> [AssembledUpdate] {
        guard let segment = segment.trimmed(after: closedThrough, tolerance: configuration.tolerance) else { return [] }
        var out: [AssembledUpdate] = []
        route(segment, now: now, into: &out)
        return out
    }

    /// VAD가 발화 끝을 잡았다. `offset`은 마지막 음성 구간 끝(스트림 초).
    public mutating func endpoint(at offset: Double, now: Double) -> [AssembledUpdate] {
        guard var utterance = current else {
            pendingEndpoint = offset
            return []
        }
        guard utterance.endpoint == nil else {
            // 이미 닫히는 중이면 다음 발화 몫이다.
            pendingEndpoint = offset
            return []
        }
        utterance.endpoint = offset
        utterance.endpointAt = now
        current = utterance
        var out: [AssembledUpdate] = []
        closeIfComplete(into: &out)
        return out
    }

    /// 주기 호출(레벨 샘플마다). 시간 초과로 닫을 발화를 닫는다.
    public mutating func tick(now: Double, voiceActive: Bool) -> [AssembledUpdate] {
        guard let utterance = current else { return [] }
        var out: [AssembledUpdate] = []
        if let endpointAt = utterance.endpointAt {
            if now - endpointAt >= configuration.finalizeTimeout { close(into: &out) }
        } else if !voiceActive {
            let idle = now - utterance.lastChangeAt
            if utterance.volatileHasText {
                if idle >= configuration.staleVolatileCloseAfter { close(into: &out) }
            } else if !utterance.finalized.isEmpty, idle >= configuration.idleCloseAfter {
                close(into: &out)
            }
        }
        return out
    }

    /// 정지 시 열린 발화를 닫는다.
    public mutating func flush() -> [AssembledUpdate] {
        var out: [AssembledUpdate] = []
        if current != nil { close(into: &out) }
        pendingEndpoint = nil
        return out
    }

    // MARK: 내부

    private mutating func route(_ segment: TranscriberSegment, now: Double, into out: inout [AssembledUpdate]) {
        let tolerance = configuration.tolerance
        if var utterance = current {
            guard let endpoint = utterance.endpoint else {
                apply(segment, to: &utterance, now: now)
                current = utterance
                emitIfChanged(into: &out)
                return
            }
            let (before, after) = segment.split(at: endpoint, tolerance: tolerance)
            if let before {
                apply(before, to: &utterance, now: now)
                current = utterance
                // 이번 결과로 끝까지 확정됐으면 최종 리비전 하나만 낸다.
                if !closeIfComplete(into: &out) { emitIfChanged(into: &out) }
            }
            if let after, after.hasText {
                // endpoint 뒤에서 새 말이 시작됐다. 이전 발화는 지금 가진 것으로 닫는다.
                if current != nil { close(into: &out) }
                route(after, now: now, into: &out)
            }
            return
        }

        if let pending = pendingEndpoint {
            pendingEndpoint = nil
            let (before, after) = segment.split(at: pending, tolerance: tolerance)
            if let before, before.hasText {
                open(with: before, now: now)
                current?.endpoint = pending
                current?.endpointAt = now
                if !closeIfComplete(into: &out) { emitIfChanged(into: &out) }
            }
            if let after { route(after, now: now, into: &out) }
            return
        }

        guard segment.hasText else { return }
        open(with: segment, now: now)
        emitIfChanged(into: &out)
    }

    private mutating func open(with segment: TranscriberSegment, now: Double) {
        var utterance = Utterance(id: makeID(), lastChangeAt: now)
        apply(segment, to: &utterance, now: now)
        current = utterance
    }

    private func apply(_ segment: TranscriberSegment, to utterance: inout Utterance, now: Double) {
        let tolerance = configuration.tolerance
        if segment.isFinal {
            utterance.finalized.removeAll {
                $0.range.start >= segment.range.start - tolerance && $0.range.end <= segment.range.end + tolerance
            }
            utterance.finalized.append(segment)
            utterance.finalized.sort { $0.range.start < $1.range.start }
            utterance.volatile = utterance.volatile.compactMap {
                $0.trimmed(after: segment.range.end, tolerance: tolerance)
            }
        } else {
            // 확정된 구간과 겹치는 앞부분은 버린다.
            guard let fresh = segment.trimmed(after: utterance.finalizedThrough, tolerance: tolerance) else { return }
            // 새 volatile 결과는 자기 구간과 그 뒤를 모두 교체한다.
            utterance.volatile = utterance.volatile.compactMap { old in
                old.range.start < fresh.range.start - tolerance
                    ? old.split(at: fresh.range.start, tolerance: tolerance).before : nil
            }
            utterance.volatile.append(fresh)
        }
        utterance.lastChangeAt = now
    }

    @discardableResult
    private mutating func closeIfComplete(into out: inout [AssembledUpdate]) -> Bool {
        guard let utterance = current, let endpoint = utterance.endpoint,
              !utterance.volatileHasText,
              utterance.finalizedThrough >= endpoint - configuration.completionSlack else { return false }
        close(into: &out)
        return true
    }

    private struct Rendering {
        var text: String
        var stable: String
        var hypotheses: [AlignedWord]
        var streamRange: StreamTimeRange
    }

    private func render(_ utterance: Utterance) -> Rendering {
        let finalTexts = utterance.finalized.filter(\.hasText).map(\.normalizedText)
        let volatileTexts = utterance.volatile.filter(\.hasText).map(\.normalizedText)
        let segments = (utterance.finalized + utterance.volatile).sorted { $0.range.start < $1.range.start }
        let raw = segments.flatMap { segment -> [AlignedWord] in
            let tokens = segment.tokens.isEmpty ? [TimedToken(text: segment.text, range: nil)] : segment.tokens
            return WordSegmenter.words(
                from: tokens, fallbackRange: segment.range,
                defaultConfidence: segment.isFinal ? configuration.finalConfidence : configuration.volatileConfidence)
        }
        let hypotheses = voiceActivity.snappingStarts(of: raw)
        let textSegments = segments.filter(\.hasText)
        let lower = hypotheses.first?.range.start ?? textSegments.first?.range.start ?? 0
        let upper = hypotheses.map(\.range.end).max() ?? textSegments.last?.range.end ?? lower
        return Rendering(text: (finalTexts + volatileTexts).joined(separator: " "),
                         stable: finalTexts.joined(separator: " "),
                         hypotheses: hypotheses,
                         streamRange: StreamTimeRange(start: lower, end: upper))
    }

    private mutating func emitIfChanged(into out: inout [AssembledUpdate]) {
        guard var utterance = current else { return }
        let rendering = render(utterance)
        let words = aligner.words(for: rendering.hypotheses)
        // 아직 내보낸 적 없는 빈 발화는 조용히 둔다. 내보낸 뒤 비면(전사기 철회) 빈 리비전을 낸다.
        guard !rendering.text.isEmpty || utterance.emitted else { return }
        if utterance.emitted, rendering.text == utterance.lastText, rendering.stable == utterance.lastStable,
           words == utterance.lastWords {
            return
        }
        utterance.revision += 1
        utterance.emitted = true
        utterance.lastText = rendering.text
        utterance.lastStable = rendering.stable
        utterance.lastWords = words
        current = utterance
        out.append(makeUpdate(utterance, rendering: rendering, words: words, isFinal: false))
    }

    private mutating func close(into out: inout [AssembledUpdate]) {
        guard var utterance = current else { return }
        current = nil
        let rendering = render(utterance)
        let timedEnd = (utterance.finalized + utterance.volatile).compactMap(\.lastTimedTokenEnd).max()
        let rangeEnd = (utterance.finalized + utterance.volatile).map(\.range.end).max() ?? closedThrough
        // 거친 volatile 구간이 다음 말까지 덮을 수 있으므로 endpoint(마지막 음성 끝)로 상한을 둔다.
        let spoken = timedEnd ?? rangeEnd
        let covered = utterance.endpoint.map { min(spoken, $0) } ?? spoken
        closedThrough = max(closedThrough, covered)
        lastClosedUtteranceID = utterance.id
        guard !rendering.text.isEmpty || utterance.emitted else { return }
        let words = aligner.words(for: rendering.hypotheses)
        utterance.revision += 1
        out.append(makeUpdate(utterance, rendering: rendering, words: words, isFinal: true))
    }

    private func makeUpdate(_ utterance: Utterance, rendering: Rendering, words: [WordTiming],
                            isFinal: Bool) -> AssembledUpdate {
        let update = TranscriptUpdate(utteranceID: utterance.id, revision: utterance.revision, text: rendering.text,
                                      stablePrefix: isFinal ? rendering.text : rendering.stable,
                                      words: words, isFinal: isFinal)
        let request = AlignmentRequest(utteranceID: utterance.id, text: rendering.text,
                                       streamRange: rendering.streamRange, hypotheses: rendering.hypotheses)
        return AssembledUpdate(update: update, alignment: request)
    }
}

/// 소비자 쪽 리비전 저장소. 발화별 최신 리비전만 남긴다(교체, append 아님).
public struct TranscriptRevisionStore: Sendable {
    public private(set) var order: [UUID] = []
    private var latestByID: [UUID: TranscriptUpdate] = [:]
    public let capacity: Int

    public init(capacity: Int = 64) { self.capacity = max(1, capacity) }

    /// 새 리비전이면 교체하고 true. 같거나 낮은 리비전(늦게 온 것)은 무시하고 false.
    @discardableResult
    public mutating func apply(_ update: TranscriptUpdate) -> Bool {
        if let existing = latestByID[update.utteranceID] {
            guard update.revision > existing.revision else { return false }
            latestByID[update.utteranceID] = update
            return true
        }
        latestByID[update.utteranceID] = update
        order.append(update.utteranceID)
        if order.count > capacity {
            let dropped = order.removeFirst()
            latestByID[dropped] = nil
        }
        return true
    }

    public func latest(_ utteranceID: UUID) -> TranscriptUpdate? { latestByID[utteranceID] }

    /// 발화 순서대로 최신 리비전.
    public var utterances: [TranscriptUpdate] { order.compactMap { latestByID[$0] } }
}
