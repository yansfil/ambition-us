import AgentContracts
import Foundation

/// 단어 시각과 에너지(VAD)로 쉼·간투사·말 속도 저하·망설임을 잡는 로컬 검출기.
///
/// - longPause: 음성이 다시 시작될 때 직전 쉼이 `longPauseMin...longPauseMax`이면(에너지),
///   또는 최종 리비전에서 단어 사이 간격이 그 범위면(단어). 둘은 중복 제거한다.
/// - filler: "음/어/에…"는 단독 어절이면 바로, "그/저/이제/뭐…"는 뒤에 쉼이 있거나 길게 끌 때만.
///   전사기가 간투사를 지우는 경우를 위해, 발화 직전·도중의 짧은 음성 구간에 단어가 하나도
///   겹치지 않으면 낮은 신뢰도의 filler로 본다(에너지).
/// - speechRateDrop: 최근 단어 창의 음절 속도가 기준(세션 평균, 발화 앞부분)보다 크게 느리면.
///
/// volatile 리비전의 단어 시각은 결과 구간을 글자 수로 나눈 추정치라(끝이 현재 오디오까지 늘어난다)
/// 시간에 기대는 검출(약한 간투사, 말 속도, 단어 간격 쉼)은 최종 리비전에서만 한다.
/// - hesitation: 짧은 시간 안에 위 신호가 두 개 이상 겹치면.
/// - risingIntonation: 피치 추적이 없어 아직 내지 않는다.
public struct ParalinguisticDetector: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var longPauseMin: Double = 0.6
        /// 이보다 긴 쉼은 대화 턴 경계로 보고 무시한다.
        public var longPauseMax: Double = 4.0
        public var strongFillers: Set<String> = ["음", "으음", "으", "어", "에", "아", "흠", "엄", "어음"]
        /// 지시어·부사와 겹치므로 문맥(뒤 쉼, 길게 끎)이 있어야 간투사로 본다.
        public var weakFillers: Set<String> = ["그", "저", "이제", "뭐", "막", "그니까", "그러니까", "뭐지", "뭐더라"]
        public var weakFillerMinGapAfter: Double = 0.3
        public var weakFillerMinDuration: Double = 0.45
        /// 단어 없는 음성 구간을 간투사로 볼 길이 범위(초).
        public var vocalizationDuration: ClosedRange<Double> = 0.12...0.9
        /// 첫 단어 앞 이 시간 안의 음성 구간까지 본다.
        public var vocalizationLookback: Double = 1.5
        public var rateWindowWords = 4
        public var rateWindowMinDuration: Double = 0.8
        public var rateDropRatio: Double = 0.6
        /// 한국어 대화 평균 음절 속도 사전값(음절/초).
        public var baselinePrior: Double = 5.0
        public var baselineAdaptation: Double = 0.3
        public var hesitationWindow: Double = 3.0
        public init() {}
    }

    public var configuration: Configuration
    public private(set) var baselineRate: Double

    private var recentCues: [ParalinguisticCue] = []
    private var pauseStarts: [MonotonicTime] = []
    private var fillerMarks: [(id: UUID?, start: MonotonicTime)] = []
    private var voicedSegments: [VoiceActivityTracker.VoicedSegment] = []
    private var checkedVocalizations: Set<UInt64> = []
    private var rateDropUtterances: Set<UUID> = []
    private var finalizedUtterances: Set<UUID> = []
    private var lastHesitation: MonotonicTime?

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        self.baselineRate = configuration.baselinePrior
    }

    // MARK: 에너지 이벤트

    public mutating func ingest(_ event: VoiceActivityTracker.Event, utteranceID: UUID?) -> [ParalinguisticCue] {
        var cues: [ParalinguisticCue] = []
        switch event {
        case .voiceStarted(_, _, let pause):
            if let pause, let cue = longPauseCue(start: pause.start, duration: pause.duration, utteranceID: utteranceID) {
                cues.append(cue)
            }
        case .voiceStopped(let segment):
            voicedSegments.append(segment)
            if voicedSegments.count > 64 { voicedSegments.removeFirst(voicedSegments.count - 64) }
        case .endpoint:
            break
        }
        return finish(cues)
    }

    // MARK: 전사 리비전

    public mutating func ingest(_ update: TranscriptUpdate) -> [ParalinguisticCue] {
        var cues: [ParalinguisticCue] = []
        let words = update.words
        let id = update.utteranceID

        // 간투사(단어).
        for (index, word) in words.enumerated() {
            let key = Self.fillerKey(word.word)
            let duration = word.end.seconds(since: word.start)
            var confidence: Double?
            if configuration.strongFillers.contains(key) {
                confidence = duration >= 0.3 ? 0.9 : 0.8
            } else if update.isFinal, configuration.weakFillers.contains(key) {
                let next = index + 1 < words.count ? words[index + 1] : nil
                if let next {
                    let gap = next.start.seconds(since: word.end)
                    let nextIsFiller = configuration.strongFillers.contains(Self.fillerKey(next.word))
                    if gap >= configuration.weakFillerMinGapAfter || duration >= configuration.weakFillerMinDuration
                        || nextIsFiller {
                        confidence = 0.6
                    }
                } else if duration >= configuration.weakFillerMinDuration {
                    confidence = 0.5
                }
            }
            guard let confidence, !hasFiller(id: id, near: word.start) else { continue }
            fillerMarks.append((id, word.start))
            cues.append(ParalinguisticCue(time: word.start, utteranceID: id, kind: .filler,
                                          confidence: min(1, confidence * max(0.5, word.confidence))))
        }

        if update.isFinal, !finalizedUtterances.contains(id) {
            finalizedUtterances.insert(id)
            // 쉼(단어 간격).
            for (previous, next) in zip(words, words.dropFirst()) {
                let gap = next.start.seconds(since: previous.end)
                if let cue = longPauseCue(start: previous.end, duration: gap, utteranceID: id) { cues.append(cue) }
            }
            cues += untranscribedVocalizations(words: words, utteranceID: id)
        }

        if update.isFinal {
            if let cue = speechRateDrop(words: words, utteranceID: id) { cues.append(cue) }
            updateBaseline(words: words)
        }
        pruneHistory()
        return finish(cues)
    }

    // MARK: 세부 검출

    private mutating func longPauseCue(start: MonotonicTime, duration: Double, utteranceID: UUID?) -> ParalinguisticCue? {
        let minimum = configuration.longPauseMin
        guard duration >= minimum, duration <= configuration.longPauseMax else { return nil }
        // 에너지/단어 두 경로가 같은 쉼을 잡을 수 있다.
        if pauseStarts.contains(where: { abs($0.seconds(since: start)) < minimum }) { return nil }
        pauseStarts.append(start)
        if pauseStarts.count > 32 { pauseStarts.removeFirst() }
        let confidence = min(0.95, 0.5 + (duration - minimum) / (2 * minimum))
        return ParalinguisticCue(time: start, utteranceID: utteranceID, kind: .longPause, confidence: confidence)
    }

    private mutating func pruneHistory() {
        if fillerMarks.count > 128 { fillerMarks.removeFirst(fillerMarks.count - 128) }
        if finalizedUtterances.count > 512 { finalizedUtterances.removeAll() }
        if rateDropUtterances.count > 512 { rateDropUtterances.removeAll() }
    }

    private func hasFiller(id: UUID?, near start: MonotonicTime) -> Bool {
        fillerMarks.contains { $0.id == id && abs($0.start.seconds(since: start)) < 0.15 }
    }

    private mutating func untranscribedVocalizations(words: [WordTiming], utteranceID: UUID) -> [ParalinguisticCue] {
        guard let first = words.first, let last = words.last else { return [] }
        let windowStart = first.start.offset(bySeconds: -configuration.vocalizationLookback)
        var cues: [ParalinguisticCue] = []
        for segment in voicedSegments where segment.start >= windowStart && segment.end <= last.end {
            guard !checkedVocalizations.contains(segment.start.nanoseconds) else { continue }
            checkedVocalizations.insert(segment.start.nanoseconds)
            guard configuration.vocalizationDuration.contains(segment.duration) else { continue }
            let overlapsWord = words.contains { $0.start < segment.end && $0.end > segment.start }
            guard !overlapsWord, !hasFiller(id: utteranceID, near: segment.start) else { continue }
            fillerMarks.append((utteranceID, segment.start))
            cues.append(ParalinguisticCue(time: segment.start, utteranceID: utteranceID, kind: .filler, confidence: 0.45))
        }
        if checkedVocalizations.count > 256 { checkedVocalizations.removeAll() }
        return cues
    }

    private mutating func speechRateDrop(words: [WordTiming], utteranceID: UUID) -> ParalinguisticCue? {
        let size = configuration.rateWindowWords
        guard !rateDropUtterances.contains(utteranceID), words.count >= size else { return nil }
        let window = Array(words.suffix(size))
        guard let tailRate = Self.rate(window, minDuration: configuration.rateWindowMinDuration) else { return nil }
        var reference = baselineRate
        if words.count >= 2 * size, let headRate = Self.rate(Array(words.prefix(size)), minDuration: 0.3) {
            reference = (baselineRate + headRate) / 2
        }
        guard reference > 0 else { return nil }
        let ratio = tailRate / reference
        guard ratio < configuration.rateDropRatio else { return nil }
        rateDropUtterances.insert(utteranceID)
        let confidence = min(0.95, 0.5 + (configuration.rateDropRatio - ratio) / configuration.rateDropRatio)
        return ParalinguisticCue(time: window[0].start, utteranceID: utteranceID, kind: .speechRateDrop,
                                 confidence: confidence)
    }

    private mutating func updateBaseline(words: [WordTiming]) {
        guard let rate = Self.rate(words, minDuration: 1.0),
              words.reduce(0, { $0 + Self.syllableCount($1.word) }) >= 4 else { return }
        baselineRate += (rate - baselineRate) * configuration.baselineAdaptation
    }

    /// 새 cue를 기록하고, 망설임 조합이 되면 hesitation을 덧붙인다.
    private mutating func finish(_ cues: [ParalinguisticCue]) -> [ParalinguisticCue] {
        guard !cues.isEmpty else { return cues }
        var output = cues
        for cue in cues {
            recentCues.append(cue)
            let window = configuration.hesitationWindow
            recentCues.removeAll { abs($0.time.seconds(since: cue.time)) > window }
            let fillers = recentCues.filter { $0.kind == .filler }.count
            let kinds = Set(recentCues.map(\.kind))
            let combined = fillers >= 2 || kinds.count >= 2
            if combined, lastHesitation.map({ abs(cue.time.seconds(since: $0)) > window }) ?? true {
                lastHesitation = cue.time
                let strength = Double(recentCues.count)
                output.append(ParalinguisticCue(time: cue.time, utteranceID: cue.utteranceID, kind: .hesitation,
                                                confidence: min(0.9, 0.5 + 0.1 * strength)))
            }
        }
        return output
    }

    // MARK: 텍스트 도우미

    /// 앞뒤 문장부호를 떼고 연속 반복 글자를 하나로 줄인다("음음…" → "음", "어어" → "어").
    public static func fillerKey(_ word: String) -> String {
        let trimmed = word.trimmingCharacters(in: WordSegmenter.trimSet)
        var output = ""
        var last: Character?
        for character in trimmed where character != last {
            output.append(character)
            last = character
        }
        return output
    }

    /// 한글 음절 수. 한글이 아닌 글자는 3글자를 1음절로 친다.
    public static func syllableCount(_ word: String) -> Int {
        var hangul = 0
        var other = 0
        for scalar in word.unicodeScalars {
            if (0xAC00...0xD7A3).contains(scalar.value) {
                hangul += 1
            } else if CharacterSet.alphanumerics.contains(scalar) {
                other += 1
            }
        }
        return hangul + (other + 2) / 3
    }

    /// 창의 음절 속도(음절/초, 단어 사이 쉼 포함).
    static func rate(_ words: [WordTiming], minDuration: Double) -> Double? {
        guard let first = words.first, let last = words.last else { return nil }
        let duration = last.end.seconds(since: first.start)
        guard duration >= minDuration else { return nil }
        let syllables = words.reduce(0) { $0 + syllableCount($1.word) }
        guard syllables > 0 else { return nil }
        return Double(syllables) / duration
    }
}
