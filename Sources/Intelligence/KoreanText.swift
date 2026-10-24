import Foundation

/// 에이전트 명령 동사 분류.
enum CommandKind: String, Sendable {
    case move      // 옮겨줘, 이동해줘
    case insert    // 넣어줘: 대상이 둘이면 이동, 하나면 입력
    case press     // 눌러줘, 클릭해줘, 선택해줘
    case open      // 열어줘, 실행해줘
    case type      // 입력해줘, 써줘, 적어줘
    case clear     // 지워줘, 삭제해줘
    case send      // 보내줘, 전송해줘, 제출해줘
    case purchase  // 구매해줘, 결제해줘
    case close     // 닫아줘, 꺼줘
    case save      // 저장해줘
    case replace   // 바꿔줘, 변경해줘
    case other     // 복사·찾기·요약 등: 로컬로 행동을 만들 수 없음 → 애매
}

struct CommandMatch: Sendable, Equatable {
    let kind: CommandKind
    /// 분석한 문자열 기준 Character 오프셋. 동사 어간 시작.
    let lowerOffset: Int
    /// 어미 끝(안정 구간 비교용).
    let verbEnd: Int
    /// 어미 뒤 공백·문장부호까지 포함한 끝(처리 완료 구간).
    let upperOffset: Int
}

struct TextToken: Sendable, Equatable {
    let raw: String
    /// 앞뒤 문장부호를 뗀 형태(분류용).
    let stripped: String
    let start: Int
    let end: Int
}

/// 한국어 발화 분석 규칙. 모두 순수 함수이며 네트워크를 쓰지 않는다.
enum KoreanText {
    static func normalize(_ text: String) -> String { text.precomposedStringWithCanonicalMapping }

    // MARK: - 명령 동사

    struct Stem: Sendable {
        let text: [Character]
        let kind: CommandKind
        let endings: [[Character]]
    }

    /// 요청·명령 어미. 긴 것부터 맞춘다.
    static let imperativeEndings: [String] = [
        "주시겠어요", "주실래요", "주세요", "주겠니", "줄래요", "줄래", "줘요", "줘봐", "줘", "주라",
        "봐줄래", "봐줘", "봐요", "봐", "놓아줘", "놔줘", "놔", "둬줘", "둬", "라",
    ]

    /// "-하세요/-하십시오/-하자" 형태(…해 어간에서 파생).
    static let politeHaEndings: [String] = ["십시오", "세요", "자"]

    static let stemTable: [(String, CommandKind)] = [
        ("옮겨", .move), ("이동해", .move), ("이동시켜", .move),
        ("넣어", .insert),
        ("눌러", .press), ("클릭해", .press), ("탭해", .press), ("선택해", .press), ("체크해", .press), ("골라", .press),
        ("열어", .open), ("실행해", .open), ("켜", .open),
        ("입력해", .type), ("써", .type), ("적어", .type), ("타이핑해", .type), ("작성해", .type),
        ("지워", .clear), ("삭제해", .clear), ("없애", .clear), ("비워", .clear),
        ("보내", .send), ("전송해", .send), ("제출해", .send), ("발송해", .send),
        ("구매해", .purchase), ("결제해", .purchase), ("주문해", .purchase), ("사", .purchase),
        ("닫아", .close), ("꺼", .close), ("종료해", .close),
        ("저장해", .save),
        ("바꿔", .replace), ("변경해", .replace), ("고쳐", .replace), ("수정해", .replace),
        ("복사해", .other), ("붙여넣어", .other), ("붙여", .other), ("찾아", .other), ("스크롤해", .other),
        ("내려", .other), ("올려", .other), ("보여", .other), ("알려", .other), ("정리해", .other), ("요약해", .other),
    ]

    static let stems: [Stem] = {
        let endings = imperativeEndings.sorted { $0.count > $1.count }.map { Array($0) }
        let haEndings = politeHaEndings.sorted { $0.count > $1.count }.map { Array($0) }
        var result: [Stem] = []
        for (stem, kind) in stemTable {
            result.append(Stem(text: Array(stem), kind: kind, endings: endings))
            if stem.hasSuffix("해"), stem.count > 1 {
                result.append(Stem(text: Array(stem.dropLast()) + ["하"], kind: kind, endings: haEndings))
            }
        }
        return result
    }()

    static let englishVerbs: [String: CommandKind] = [
        "click": .press, "press": .press, "tap": .press, "select": .press,
        "open": .open, "launch": .open,
        "move": .move, "drag": .move,
        "type": .type, "write": .type, "enter": .type,
        "delete": .clear, "clear": .clear, "erase": .clear, "remove": .clear,
        "send": .send, "submit": .send,
        "buy": .purchase, "purchase": .purchase, "pay": .purchase,
        "close": .close, "save": .save,
        "change": .replace, "replace": .replace, "rename": .replace,
    ]

    static let englishLeadIns: Set<String> = ["hey", "gaze", "please", "ok", "okay", "now", "can", "could", "would", "you", "and"]

    static func isBoundary(_ c: Character) -> Bool { c.isWhitespace || c.isPunctuation || c.isSymbol }
    static func isTerminalMark(_ c: Character) -> Bool { c.isPunctuation || c.isSymbol }

    /// 첫 번째(가장 앞) 명령 동사를 찾는다. 맨 어간 명령형("열어.")은 최종 발화에서만 인정한다.
    static func findCommand(in text: String, isFinal: Bool) -> CommandMatch? {
        let chars = Array(text)
        var compact: [Character] = []
        var map: [Int] = []
        for (index, c) in chars.enumerated() where !c.isWhitespace {
            compact.append(c)
            map.append(index)
        }
        var best: CommandMatch?
        for stem in stems {
            let s = stem.text
            guard s.count <= compact.count else { continue }
            var i = 0
            while i + s.count <= compact.count {
                let start = i
                i += 1
                guard compact[start..<(start + s.count)].elementsEqual(s) else { continue }
                let origStart = map[start]
                guard origStart == 0 || isBoundary(chars[origStart - 1]) else { continue }
                let afterStem = start + s.count
                var endCompact: Int?
                for ending in stem.endings {
                    let stop = afterStem + ending.count
                    guard stop <= compact.count, compact[afterStem..<stop].elementsEqual(ending) else { continue }
                    let lastOrig = map[stop - 1]
                    if lastOrig + 1 >= chars.count || isBoundary(chars[lastOrig + 1]) {
                        endCompact = stop
                        break
                    }
                }
                if endCompact == nil, isFinal, compact[afterStem...].allSatisfy(isTerminalMark) {
                    endCompact = afterStem
                }
                guard let end = endCompact else { continue }
                let verbEnd = map[end - 1] + 1
                var upper = verbEnd
                while upper < chars.count, chars[upper].isWhitespace || isTerminalMark(chars[upper]) { upper += 1 }
                let match = CommandMatch(kind: stem.kind, lowerOffset: origStart, verbEnd: verbEnd, upperOffset: upper)
                if let current = best {
                    if origStart < current.lowerOffset || (origStart == current.lowerOffset && upper > current.upperOffset) {
                        best = match
                    }
                } else {
                    best = match
                }
            }
        }
        return best ?? findEnglishCommand(in: chars, isFinal: isFinal)
    }

    /// 영어는 동사가 앞에 오므로 최종 발화에서 첫 단어만 본다("click this", "move this there").
    private static func findEnglishCommand(in chars: [Character], isFinal: Bool) -> CommandMatch? {
        guard isFinal else { return nil }
        var index = 0
        while index < chars.count {
            while index < chars.count, !(chars[index].isASCII && chars[index].isLetter) { index += 1 }
            let start = index
            while index < chars.count, chars[index].isASCII, chars[index].isLetter { index += 1 }
            guard start < index else { break }
            let word = String(chars[start..<index]).lowercased()
            if englishLeadIns.contains(word) { continue }
            guard let kind = englishVerbs[word] else { return nil }
            return CommandMatch(kind: kind, lowerOffset: start, verbEnd: chars.count, upperOffset: chars.count)
        }
        return nil
    }

    // MARK: - 화자 의도 단서

    static let agentAddresses = ["헤이게이즈", "게이즈", "heygaze", "okgaze", "gaze", "에이전트야", "비서야"]

    /// 발화가 에이전트를 부르며 시작하는가("게이즈야, …").
    static func hasAgentAddress(_ text: String) -> Bool {
        let compact = String(text.lowercased().filter { !$0.isWhitespace && !isTerminalMark($0) })
        return agentAddresses.contains { compact.hasPrefix($0) }
    }

    static let requestTails = [
        "주시겠어요", "주실래요", "주세요", "주겠니", "줄래요", "줄래", "줘요", "줘", "할까요", "할까", "해봐",
        "부탁해요", "부탁해", "부탁드려요", "부탁드립니다",
    ]

    /// UI 동사는 아니지만 누군가에게 부탁하는 어미로 끝나는가. 입력 내용인지 에이전트 요청인지 애매하다.
    static func hasRequestEnding(_ text: String) -> Bool {
        var compact = Array(text.filter { !$0.isWhitespace })
        while let last = compact.last, isTerminalMark(last) { compact.removeLast() }
        let joined = String(compact)
        return requestTails.contains { joined.hasSuffix($0) }
    }

    static let deicticPrefixes = [
        "이거", "이것", "이걸", "이게", "저거", "저것", "저걸", "저게", "그거", "그것", "그걸", "그게",
        "여기", "저기", "거기", "이쪽", "저쪽", "그쪽", "이곳", "저곳", "그곳",
    ]
    static let determiners: Set<String> = ["이", "저", "그"]
    static let locationPrefixes = ["여기", "거기", "저기", "이곳", "그곳", "저곳", "이쪽", "그쪽", "저쪽"]

    static func hasDeictic(_ text: String) -> Bool {
        tokens(text).contains { token in
            determiners.contains(token.stripped) || deicticPrefixes.contains { token.stripped.hasPrefix($0) }
        }
    }

    static func isDeicticLocation(_ token: String) -> Bool {
        locationPrefixes.contains { token.hasPrefix($0) }
    }

    // MARK: - 문장 경계

    static let sentenceTerminators: Set<Character> = [".", "?", "!", "。", "？", "！", "…"]

    /// 완결된 마지막 문장의 끝 오프셋(종결 부호 다음). 없으면 nil. "3.5" 같은 소수점은 경계가 아니다.
    static func lastSentenceBoundary(in text: String) -> Int? {
        let chars = Array(text)
        var result: Int?
        for (index, c) in chars.enumerated() where sentenceTerminators.contains(c) {
            let next = index + 1
            if next >= chars.count || chars[next].isWhitespace { result = next }
        }
        return result
    }

    static func hasContent(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    // MARK: - 토큰·조사

    static func tokens(_ text: String) -> [TextToken] {
        let chars = Array(text)
        var result: [TextToken] = []
        var index = 0
        while index < chars.count {
            while index < chars.count, chars[index].isWhitespace { index += 1 }
            let start = index
            while index < chars.count, !chars[index].isWhitespace { index += 1 }
            guard start < index else { break }
            let raw = String(chars[start..<index])
            let stripped = String(raw.drop(while: isTerminalMark).reversed().drop(while: isTerminalMark).reversed())
            result.append(TextToken(raw: raw, stripped: stripped, start: start, end: index))
        }
        return result
    }

    static func hasBatchim(_ c: Character) -> Bool {
        guard c.unicodeScalars.count == 1, let scalar = c.unicodeScalars.first,
              (0xAC00...0xD7A3).contains(scalar.value) else { return false }
        return (scalar.value - 0xAC00) % 28 != 0
    }

    /// 받침 유무에 맞는 조사를 뗀다. (예: 회의록이라고 → 회의록, 안녕하세요라고 → 안녕하세요)
    static func stripParticle(_ word: String, afterConsonant: String, afterVowel: String) -> String? {
        let chars = Array(word)
        if word.hasSuffix(afterConsonant), chars.count > afterConsonant.count,
           hasBatchim(chars[chars.count - afterConsonant.count - 1]) {
            return String(chars.dropLast(afterConsonant.count))
        }
        if word.hasSuffix(afterVowel), chars.count > afterVowel.count {
            let before = chars[chars.count - afterVowel.count - 1]
            // 을/를처럼 받침에 따라 갈리는 조사는 받침 없는 경우만 모음형을 뗀다.
            if afterVowel == "를", hasBatchim(before) { return nil }
            return String(chars.dropLast(afterVowel.count))
        }
        return nil
    }

    static func stripObjectParticle(_ word: String) -> String {
        stripParticle(word, afterConsonant: "을", afterVowel: "를") ?? word
    }

    static let destinationSuffixes = ["로", "에다가", "에다", "에", "한테", "에게"]

    /// 목적지 조사(…로, …에, …에다)가 붙은 어절인가. "…에서"(출발점)는 제외된다.
    static func isDestinationMarked(_ token: String) -> Bool {
        guard token.count >= 2 else { return false }
        return destinationSuffixes.contains { token.hasSuffix($0) }
    }

    /// 결합 단어들이 몇 번째 토큰에 있는지 앞에서부터 순서대로 찾는다.
    static func locate(words: [String], in tokens: [TextToken]) -> [Int?] {
        var cursor = 0
        return words.map { word in
            let w = normalize(word).filter { !$0.isWhitespace && !isTerminalMark($0) }
            guard !w.isEmpty, cursor < tokens.count else { return nil }
            let window = tokens[cursor...]
            let found = window.firstIndex(where: { $0.stripped == w })
                ?? window.firstIndex(where: { $0.stripped.hasPrefix(w) })
            if let found { cursor = found + 1 }
            return found
        }
    }

    // MARK: - 입력 내용 추출

    static let quotePairs: [Character: [Character]] = [
        "\"": ["\""], "'": ["'"], "“": ["”", "\""], "‘": ["’", "'"], "「": ["」"], "『": ["』"],
    ]

    static func quotedContent(in text: String) -> String? {
        let chars = Array(text)
        for (index, c) in chars.enumerated() {
            guard let closers = quotePairs[c], index + 1 < chars.count else { continue }
            if let close = chars[(index + 1)...].firstIndex(where: { closers.contains($0) }) {
                let content = String(chars[(index + 1)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty { return content }
            }
        }
        return nil
    }

    /// 위치를 가리키는 어절(여기에, 이 칸에, 결합 단어)을 지운다.
    private static func removeLocationTokens(_ tokens: [TextToken], bindingWords: Set<String>,
                                             dropFirstLocative: Bool) -> [TextToken] {
        var result: [TextToken] = []
        var skipNext = false
        var removedLocation = false
        for token in tokens {
            if skipNext {
                skipNext = false
                removedLocation = true
                continue
            }
            let s = token.stripped
            if determiners.contains(s) && (bindingWords.contains(s) || bindingWords.isEmpty) {
                skipNext = true
                continue
            }
            if isDeicticLocation(s) || bindingWords.contains(where: { !$0.isEmpty && s.hasPrefix($0) }) {
                removedLocation = true
                continue
            }
            result.append(token)
        }
        if dropFirstLocative, !removedLocation,
           let index = result.firstIndex(where: { token in
               token.stripped.count >= 2 && ["에", "에다", "에다가"].contains { token.stripped.hasSuffix($0) }
           }) {
            result.remove(at: index)
        }
        return result
    }

    /// "여기에 '회의록' 입력해줘", "회의록이라고 써줘", "검색창에 날씨 입력해줘"에서 입력할 내용을 뽑는다.
    static func extractTypedContent(beforeVerb prefix: String, bindingWords: [String]) -> String? {
        if let quoted = quotedContent(in: prefix) { return quoted }
        let words = Set(bindingWords.map { normalize($0).filter { !$0.isWhitespace && !isTerminalMark($0) } })
        var all = tokens(prefix)
        if let raGo = all.lastIndex(where: { $0.stripped.hasSuffix("라고") }) {
            all = Array(all[...raGo])
            let last = all[raGo]
            guard let stripped = stripParticle(last.stripped, afterConsonant: "이라고", afterVowel: "라고") else { return nil }
            all[raGo] = TextToken(raw: stripped, stripped: stripped, start: last.start, end: last.end)
            let kept = removeLocationTokens(all, bindingWords: words, dropFirstLocative: false)
            return joined(kept)
        }
        var kept = removeLocationTokens(all, bindingWords: words, dropFirstLocative: true)
        guard let last = kept.last else { return nil }
        let stripped = stripObjectParticle(last.stripped)
        if stripped != last.stripped {
            kept[kept.count - 1] = TextToken(raw: stripped, stripped: stripped, start: last.start, end: last.end)
        }
        return joined(kept)
    }

    /// "제목을 주간 회의록으로 바꿔줘" → "주간 회의록".
    static func extractReplacementValue(beforeVerb prefix: String, bindingWords: [String]) -> String? {
        if let quoted = quotedContent(in: prefix) { return quoted }
        let words = Set(bindingWords.map { normalize($0).filter { !$0.isWhitespace && !isTerminalMark($0) } })
        let all = tokens(prefix)
        guard let index = all.lastIndex(where: { $0.stripped.hasSuffix("로") && $0.stripped.count >= 2 }),
              let value = stripParticle(all[index].stripped, afterConsonant: "으로", afterVowel: "로"),
              !value.isEmpty else { return nil }
        var parts = [value]
        var cursor = index - 1
        let stopSuffixes = ["을", "를", "은", "는", "가", "에", "의"]
        while cursor >= 0 {
            let s = all[cursor].stripped
            if determiners.contains(s) || deicticPrefixes.contains(where: { s.hasPrefix($0) }) || words.contains(s)
                || stopSuffixes.contains(where: { s.hasSuffix($0) }) {
                break
            }
            parts.insert(all[cursor].raw, at: 0)
            cursor -= 1
        }
        return parts.joined(separator: " ")
    }

    private static func joined(_ tokens: [TextToken]) -> String? {
        let text = tokens.map(\.raw).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return hasContent(text) ? text : nil
    }

    /// 모델이 제안한 입력 텍스트가 실제 발화에서 왔는지 비교하기 위한 정규화(공백·문장부호 제거, 소문자).
    static func comparable(_ text: String) -> String {
        String(normalize(text).lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
