import AgentContracts
import Foundation

/// 선제 제안 규칙: 머뭇거림(망설임·긴 멈춤·간투사) + 같은 대상에 대한 오래 응시/재방문이 함께 있을 때만.
/// 제안은 행동을 담지 않으며 실행 요청으로 승격되지 않는다.
struct SuggestionTrigger: Equatable {
    let target: UITarget
    let confidence: Double
}

enum SuggestionPolicy {
    static let hesitationKinds: Set<ParalinguisticCue.Kind> = [.hesitation, .longPause, .filler]
    static let dwellKinds: Set<NonverbalCue.Kind> = [.prolongedDwell, .revisit]

    static func trigger(in context: AttentionContext, minCueConfidence: Double,
                        coincidenceWindow: Double) -> SuggestionTrigger? {
        let utteranceID = context.utterance.utteranceID
        let hesitations = context.paralinguistic.filter {
            hesitationKinds.contains($0.kind) && $0.confidence >= minCueConfidence
                && ($0.utteranceID == nil || $0.utteranceID == utteranceID)
        }
        guard !hesitations.isEmpty else { return nil }
        let dwells = context.nonverbal
            .filter { dwellKinds.contains($0.kind) && $0.confidence >= minCueConfidence && $0.targetID != nil }
            .sorted { $0.confidence > $1.confidence }
        let candidates = candidateTargets(context)
        for dwell in dwells {
            guard let target = candidates.first(where: { $0.token == dwell.targetID }), !target.isSecure else { continue }
            let nearest = hesitations.min {
                abs($0.time.seconds(since: dwell.time)) < abs($1.time.seconds(since: dwell.time))
            }
            guard let hesitation = nearest, abs(hesitation.time.seconds(since: dwell.time)) <= coincidenceWindow else { continue }
            var confidence = (hesitation.confidence + dwell.confidence) / 2
            if hesitations.count > 1 { confidence += 0.05 }
            if context.nonverbal.contains(where: { $0.targetID == dwell.targetID && $0.kind != dwell.kind && dwellKinds.contains($0.kind) }) {
                confidence += 0.05
            }
            return SuggestionTrigger(target: target, confidence: min(1, confidence))
        }
        return nil
    }

    static func candidateTargets(_ context: AttentionContext) -> [UITarget] {
        var seen = Set<String>()
        var result: [UITarget] = []
        for target in [context.gazedTarget].compactMap({ $0 }) + context.bindings.compactMap(\.target)
        where seen.insert(target.token).inserted {
            result.append(target)
        }
        return result
    }

    static func cooldownKey(for target: UITarget?) -> String {
        "suggest:\(target?.token ?? "none")"
    }

    static let moveStems = ["옮기", "옮겨", "이동"]

    /// 대상 종류와 발화로 짧은 한국어 제안 문구를 고른다.
    static func message(for target: UITarget, utterance: String) -> String {
        let compact = KoreanText.normalize(utterance).filter { !$0.isWhitespace }
        let mentionsMove = moveStems.contains { compact.contains($0) }
        if looksLikeFile(target) { return "이 파일을 옮길 위치를 찾아볼까요?" }
        if mentionsMove && !target.isEditable && !target.isButtonLike { return "이 항목을 옮길 위치를 찾아볼까요?" }
        if isFinderItem(target) && !target.isButtonLike { return "이 폴더에서 찾으시는 걸 찾아볼까요?" }
        if target.isEditable { return "여기에 들어갈 내용을 같이 써볼까요?" }
        if target.role == "AXLink" { return "이 링크 내용을 요약해 드릴까요?" }
        if ["AXMenuItem", "AXMenuButton", "AXPopUpButton", "AXMenuBarItem"].contains(target.role) {
            return "원하시는 메뉴 항목을 찾아드릴까요?"
        }
        if target.isButtonLike { return "이 버튼이 무엇을 하는지 알려드릴까요?" }
        return "이 항목에 대해 도와드릴까요?"
    }

    static func isFinderItem(_ target: UITarget) -> Bool { target.appBundleID == "com.apple.finder" }

    static func looksLikeFile(_ target: UITarget) -> Bool {
        guard !target.isButtonLike, !target.isEditable || isFinderItem(target),
              let title = target.title?.trimmingCharacters(in: .whitespaces),
              let dot = title.lastIndex(of: "."), dot != title.startIndex else { return false }
        let ext = title[title.index(after: dot)...]
        return (1...5).contains(ext.count) && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}

/// 대상별 쿨다운 + 전역 최소 간격.
struct SuggestionLedger {
    let perTargetCooldown: Double
    let globalGap: Double
    private(set) var lastShown: [String: MonotonicTime] = [:]
    private(set) var lastAny: MonotonicTime?

    init(perTargetCooldown: Double, globalGap: Double) {
        self.perTargetCooldown = perTargetCooldown
        self.globalGap = globalGap
    }

    func canShow(_ key: String, now: MonotonicTime) -> Bool {
        if let last = lastShown[key], now.seconds(since: last) < perTargetCooldown { return false }
        if let lastAny, now.seconds(since: lastAny) < globalGap { return false }
        return true
    }

    mutating func record(_ key: String, now: MonotonicTime) {
        lastShown[key] = now
        lastAny = now
        if lastShown.count > 64 {
            lastShown = lastShown.filter { now.seconds(since: $0.value) < perTargetCooldown }
        }
    }
}
