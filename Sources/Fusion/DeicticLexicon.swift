import AgentContracts
import Foundation

/// 지시어가 문장에서 맡는 역할. "이거를 이쪽으로 옮겨줘"에서 이거=source, 이쪽=destination.
public enum DeicticRole: String, Sendable, Codable {
    case source
    case destination
}

/// 지시 대상의 종류.
public enum DeicticKind: String, Sendable, Codable {
    /// 사물: 이거, 저것, 이 파일 …
    case object
    /// 장소·방향: 여기, 이쪽, 이 위 …
    case place
}

/// 전사 단어열에서 찾은 지시어 하나.
public struct DeicticMatch: Sendable, Equatable {
    /// 결합에 쓰는 시간 구간. "이 파일을"처럼 두 단어면 두 단어를 합친 구간과 글자.
    public let word: WordTiming
    /// `TranscriptUpdate.words`에서의 위치.
    public let wordRange: Range<Int>
    /// 조사를 뗀 표제어("이거", "이 파일").
    public let lemma: String
    public let kind: DeicticKind
    public let role: DeicticRole

    public init(word: WordTiming, wordRange: Range<Int>, lemma: String, kind: DeicticKind, role: DeicticRole) {
        self.word = word; self.wordRange = wordRange; self.lemma = lemma; self.kind = kind; self.role = role
    }
}

/// 한국어 지시어 사전. 표제어 + 조사 조합이 정확히 일치할 때만 지시어로 본다("이번", "그리고"는 제외).
public struct DeicticLexicon: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let kind: DeicticKind
        /// 조사가 없을 때의 역할.
        public let defaultRole: DeicticRole
        public init(kind: DeicticKind, defaultRole: DeicticRole) {
            self.kind = kind; self.defaultRole = defaultRole
        }
    }

    public struct Classification: Sendable, Equatable {
        public let lemma: String
        public let kind: DeicticKind
        public let role: DeicticRole
    }

    /// 한 단어 지시어(정규화된 표제어 → 항목). 축약형(이걸, 이게, 이건)도 여기 둔다.
    public var words: [String: Entry]
    /// "이 파일"의 "이"처럼 뒤 명사를 지시어로 만드는 관형사.
    public var determiners: Set<String>
    /// 관형사 뒤에 올 때 지시어가 되는 명사.
    public var nouns: [String: DeicticKind]
    /// 대상(옮길 것) 표지: 을/를/이/가/은/는/에서 …
    public var sourceParticles: Set<String>
    /// 목적지 표지: 으로/로/에/에다 …
    public var destinationParticles: Set<String>

    public init(words: [String: Entry], determiners: Set<String>, nouns: [String: DeicticKind],
                sourceParticles: Set<String>, destinationParticles: Set<String>) {
        self.words = words; self.determiners = determiners; self.nouns = nouns
        self.sourceParticles = sourceParticles; self.destinationParticles = destinationParticles
    }

    public static let korean: DeicticLexicon = {
        var words: [String: Entry] = [:]
        let object = Entry(kind: .object, defaultRole: .source)
        let place = Entry(kind: .place, defaultRole: .destination)
        for w in ["이거", "이것", "요거", "요것", "저거", "저것", "그거", "그것",
                  // 축약형: 이걸(=이것을), 이게(=이것이), 이건(=이것은)
                  "이걸", "요걸", "저걸", "그걸", "이게", "요게", "저게", "그게", "이건", "요건", "저건", "그건",
                  "this", "that", "these", "those"] {
            words[w] = object
        }
        for w in ["여기", "요기", "거기", "저기", "이쪽", "요쪽", "저쪽", "그쪽",
                  "이곳", "저곳", "그곳", "이리", "저리", "here", "there"] {
            words[w] = place
        }
        var nouns: [String: DeicticKind] = [:]
        for n in ["파일", "폴더", "창", "윈도우", "탭", "버튼", "사진", "이미지", "그림", "문서", "항목", "아이템",
                  "텍스트", "글", "글자", "문장", "단어", "문단", "칸", "셀", "줄", "행", "열", "앱", "아이콘",
                  "메일", "이메일", "메시지", "링크", "메뉴", "페이지", "목록", "리스트", "영상", "동영상", "노트",
                  "메모", "슬라이드", "박스", "필드", "입력창", "표", "내용", "부분"] {
            nouns[n] = .object
        }
        for n in ["쪽", "곳", "위치", "자리", "위", "아래", "옆", "안", "밖", "앞", "뒤"] {
            nouns[n] = .place
        }
        return DeicticLexicon(
            words: words,
            determiners: ["이", "그", "저", "요"],
            nouns: nouns,
            sourceParticles: ["을", "를", "이", "가", "은", "는", "도", "만", "의", "랑", "이랑", "하고", "와", "과",
                              "에서", "서", "부터", "에서부터"],
            destinationParticles: ["으로", "로", "에", "에다", "에다가", "에게", "한테", "까지", "으로다가", "로다가"]
        )
    }()

    /// 공백 없는 한 토큰을 분류한다. 지시어가 아니면 nil.
    public func classify(_ token: String) -> Classification? {
        let t = Self.normalize(token)
        guard !t.isEmpty else { return nil }
        var best: Classification?
        var bestLength = 0
        for (lemma, entry) in words where t.hasPrefix(lemma) && lemma.count > bestLength {
            guard let role = role(forSuffix: String(t.dropFirst(lemma.count)), default: entry.defaultRole) else { continue }
            best = Classification(lemma: lemma, kind: entry.kind, role: role)
            bestLength = lemma.count
        }
        return best
    }

    /// 단어열에서 지시어를 순서대로 찾는다. "이" + "파일을"은 하나로 합친다.
    public func matches(in timings: [WordTiming]) -> [DeicticMatch] {
        var result: [DeicticMatch] = []
        var i = 0
        while i < timings.count {
            let tokens = Self.tokens(timings[i].word)
            if tokens.count == 1, determiners.contains(tokens[0]), i + 1 < timings.count {
                let next = Self.tokens(timings[i + 1].word)
                if next.count == 1, let noun = classifyNoun(next[0]) {
                    let a = timings[i], b = timings[i + 1]
                    let merged = WordTiming(word: "\(a.word) \(b.word)", start: min(a.start, b.start),
                                            end: max(a.end, b.end), confidence: min(a.confidence, b.confidence))
                    result.append(DeicticMatch(word: merged, wordRange: i..<(i + 2), lemma: "\(tokens[0]) \(noun.lemma)",
                                               kind: noun.kind, role: noun.role))
                    i += 2
                    continue
                }
            }
            if let found = classifyTokens(tokens) {
                result.append(DeicticMatch(word: timings[i], wordRange: i..<(i + 1), lemma: found.lemma,
                                           kind: found.kind, role: found.role))
            }
            i += 1
        }
        return result
    }

    // MARK: - 내부

    /// 한 WordTiming 안에 공백으로 여러 토큰이 있을 때("이 파일을").
    private func classifyTokens(_ tokens: [String]) -> Classification? {
        for (index, token) in tokens.enumerated() {
            if determiners.contains(token), index + 1 < tokens.count, let noun = classifyNoun(tokens[index + 1]) {
                return Classification(lemma: "\(token) \(noun.lemma)", kind: noun.kind, role: noun.role)
            }
            if let c = classify(token) { return c }
        }
        return nil
    }

    private func classifyNoun(_ token: String) -> Classification? {
        var best: Classification?
        var bestLength = 0
        for (noun, kind) in nouns where token.hasPrefix(noun) && noun.count > bestLength {
            let defaultRole: DeicticRole = kind == .object ? .source : .destination
            guard let role = role(forSuffix: String(token.dropFirst(noun.count)), default: defaultRole) else { continue }
            best = Classification(lemma: noun, kind: kind, role: role)
            bestLength = noun.count
        }
        return best
    }

    private func role(forSuffix suffix: String, default defaultRole: DeicticRole) -> DeicticRole? {
        if suffix.isEmpty { return defaultRole }
        if destinationParticles.contains(suffix) { return .destination }
        if sourceParticles.contains(suffix) { return .source }
        return nil
    }

    static func normalize(_ raw: String) -> String {
        let trimSet = CharacterSet.punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines)
        return raw.precomposedStringWithCanonicalMapping.trimmingCharacters(in: trimSet).lowercased()
    }

    static func tokens(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0.isWhitespace }).map { normalize(String($0)) }.filter { !$0.isEmpty }
    }
}
