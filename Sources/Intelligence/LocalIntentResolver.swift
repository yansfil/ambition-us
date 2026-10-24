import AgentContracts
import Foundation

/// 로컬 빠른 경로의 결정(네트워크 없음).
enum LocalDecision: Equatable {
    /// 명령 + 결합된 지시 대상 → 행동 제안. `consumed`는 처리 완료로 표시할 발화 앞부분.
    case action(AgentAction, rationale: String, consumed: String, commandText: String?)
    /// 시선이 머문 입력란에 대한 받아쓰기. `text`는 이번에 새로 입력할 증분.
    case dictation(target: UITarget, text: String, consumed: String)
    /// 로컬로 확정할 수 없음 → (조건이 맞으면) 모델에 묻는다.
    case ambiguous(AmbiguityReason, pending: String, consumedIfActed: String)
    /// 아직 판단하기 이르다(문장·명령이 끝나지 않음). 모델도 부르지 않는다.
    case wait
    /// 에이전트와 무관한 발화.
    case nothing
    /// 안전상 아무것도 하지 않는다(보안 입력란, 처리 구간 변경 등). 모델도 부르지 않는다.
    case blocked(String)
}

struct LocalIntentResolver {
    let minBindingConfidence: Double

    struct ResolvedBinding: Equatable {
        let word: String
        let start: MonotonicTime
        let target: UITarget
    }

    func resolve(_ context: AttentionContext, consumed: String, dictationTarget: String?) -> LocalDecision {
        let update = context.utterance
        let text = KoreanText.normalize(update.text)
        let stable = KoreanText.normalize(update.stablePrefix)
        guard text.hasPrefix(consumed) else { return .blocked("이미 처리한 구간이 바뀜") }
        let pending = String(text.dropFirst(consumed.count))
        guard KoreanText.hasContent(pending) else { return .nothing }
        let pendingStable = stable.hasPrefix(consumed) ? String(stable.dropFirst(consumed.count)) : ""
        let stableIsPrefix = pending.hasPrefix(pendingStable)
        let stableCount = update.isFinal ? pending.count : (stableIsPrefix ? pendingStable.count : 0)
        let resolved = resolvedBindings(context)

        // 1) 에이전트에게 하는 명령. 비최종 발화에서는 동사 어미가 안정 구간 안에 있어야 한다.
        if let command = KoreanText.findCommand(in: pending, isFinal: update.isFinal) {
            guard update.isFinal || command.verbEnd <= stableCount else { return .wait }
            let consumedAfter = consumed + String(Array(pending)[0..<command.upperOffset])
            return resolveCommand(command, pending: pending, context: context, resolved: resolved,
                                  consumedAfter: consumedAfter)
        }
        if KoreanText.hasAgentAddress(pending) {
            return update.isFinal ? .ambiguous(.agentAddressed, pending: pending, consumedIfActed: consumed + pending) : .wait
        }

        // 2) 입력란을 바라보며 하는 말 → 받아쓰기(안정 구간만).
        if let field = context.gazedTarget, field.isEditable {
            if field.isSecure { return .blocked("보안 입력란") }
            if let previous = dictationTarget, previous != field.token { return .blocked("받아쓰기 대상이 바뀜") }
            if resolved.contains(where: { $0.target.token != field.token }) {
                return update.isFinal
                    ? .ambiguous(.deicticReference, pending: pending, consumedIfActed: consumed + pending) : .wait
            }
            if KoreanText.hasRequestEnding(pending) {
                return update.isFinal
                    ? .ambiguous(.uncertainRequest, pending: pending, consumedIfActed: consumed + pending) : .wait
            }
            let raw: String
            if update.isFinal {
                raw = pending
            } else {
                // 한국어는 동사가 끝에 오므로 완결된 문장까지만 입력한다(뒤에 명령 어미가 붙을 수 있음).
                guard stableIsPrefix, let cut = KoreanText.lastSentenceBoundary(in: pendingStable) else { return .wait }
                raw = String(Array(pendingStable)[0..<cut])
            }
            var typed = raw.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            if consumed.isEmpty {
                typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let first = typed.first, first.isWhitespace {
                typed = " " + typed.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard KoreanText.hasContent(typed) else { return .wait }
            return .dictation(target: field, text: typed, consumed: consumed + raw)
        }

        // 3) 다른 대상을 가리키는 말(질문 등).
        if !context.bindings.isEmpty || KoreanText.hasDeictic(pending) {
            return update.isFinal
                ? .ambiguous(.deicticReference, pending: pending, consumedIfActed: consumed + pending) : .wait
        }
        return .nothing
    }

    func resolvedBindings(_ context: AttentionContext) -> [ResolvedBinding] {
        context.bindings
            .compactMap { binding -> ResolvedBinding? in
                guard let target = binding.target, binding.confidence >= minBindingConfidence else { return nil }
                return ResolvedBinding(word: binding.word.word, start: binding.word.start, target: target)
            }
            .sorted { $0.start < $1.start }
    }

    private func distinctTargets(_ resolved: [ResolvedBinding]) -> [UITarget] {
        var seen = Set<String>()
        return resolved.map(\.target).filter { seen.insert($0.token).inserted }
    }

    private func resolveCommand(_ command: CommandMatch, pending: String, context: AttentionContext,
                                resolved: [ResolvedBinding], consumedAfter: String) -> LocalDecision {
        let chars = Array(pending)
        let ambiguous = LocalDecision.ambiguous(.unresolvedCommand, pending: pending, consumedIfActed: consumedAfter)
        let targets = distinctTargets(resolved)
        let prefix = String(chars[0..<command.lowerOffset])
        let commandText = String(chars[0..<command.verbEnd])
        let bindingWords = context.bindings.map(\.word.word)

        /// 지시 대상이 하나면 그것, 지시어가 아예 없으면 시선 대상.
        func single(_ accept: (UITarget) -> Bool = { _ in true }) -> UITarget? {
            if targets.count == 1 { return accept(targets[0]) ? targets[0] : nil }
            if targets.isEmpty, context.bindings.isEmpty, let gazed = context.gazedTarget, accept(gazed) { return gazed }
            return nil
        }

        let kind: CommandKind = command.kind == .insert ? (targets.count >= 2 ? .move : .type) : command.kind
        switch kind {
        case .move:
            guard targets.count == 2 else { return ambiguous }
            let (source, destination) = moveDirection(targets, resolved: resolved, pending: pending, verbOffset: command.lowerOffset)
            return .action(.move(source: source, destination: destination),
                           rationale: "이동 명령과 지시어 두 대상을 결합", consumed: consumedAfter, commandText: commandText)
        case .type:
            guard let target = single({ $0.isEditable }) else { return ambiguous }
            guard !target.isSecure else { return .blocked("보안 입력란에는 입력하지 않음") }
            guard let content = KoreanText.extractTypedContent(beforeVerb: prefix, bindingWords: bindingWords) else {
                return ambiguous
            }
            return .action(.typeText(target: target, text: content), rationale: "입력 명령에서 내용을 추출",
                           consumed: consumedAfter, commandText: commandText.replacingOccurrences(of: content, with: " "))
        case .press, .open:
            guard let target = single() else { return ambiguous }
            return .action(.press(target: target), rationale: "누르기·열기 명령과 지시 대상을 결합",
                           consumed: consumedAfter, commandText: commandText)
        case .send, .purchase, .close, .save:
            guard let target = single({ $0.isButtonLike }) else { return ambiguous }
            return .action(.press(target: target), rationale: "버튼 실행 명령과 지시 대상을 결합",
                           consumed: consumedAfter, commandText: commandText)
        case .clear:
            guard let target = single({ $0.isEditable }) else { return ambiguous }
            guard !target.isSecure else { return .blocked("보안 입력란은 건드리지 않음") }
            return .action(.setValue(target: target, value: ""), rationale: "입력란 지우기 명령",
                           consumed: consumedAfter, commandText: commandText)
        case .replace:
            guard let target = single({ $0.isEditable }) else { return ambiguous }
            guard !target.isSecure else { return .blocked("보안 입력란은 건드리지 않음") }
            guard let value = KoreanText.extractReplacementValue(beforeVerb: prefix, bindingWords: bindingWords) else {
                return ambiguous
            }
            return .action(.setValue(target: target, value: value), rationale: "값 바꾸기 명령에서 새 값을 추출",
                           consumed: consumedAfter, commandText: commandText.replacingOccurrences(of: value, with: " "))
        case .other, .insert:
            return ambiguous
        }
    }

    /// 목적지 조사(…로/…에)가 붙은 쪽을 목적지로, 없으면 말한 순서(먼저=출발, 나중=목적지)로 정한다.
    private func moveDirection(_ targets: [UITarget], resolved: [ResolvedBinding], pending: String,
                               verbOffset: Int) -> (UITarget, UITarget) {
        let tokens = KoreanText.tokens(pending)
        let verbToken = tokens.firstIndex { $0.end > verbOffset } ?? tokens.count
        let positions = KoreanText.locate(words: resolved.map(\.word), in: tokens)
        var destinations = Set<String>()
        for (index, binding) in resolved.enumerated() {
            guard let position = positions[index] else { continue }
            let nextBinding = positions[(index + 1)...].compactMap { $0 }.first ?? tokens.count
            let end = min(nextBinding, position + 2, verbToken)
            guard position < end else { continue }
            if tokens[position..<end].contains(where: { KoreanText.isDestinationMarked($0.stripped) }) {
                destinations.insert(binding.target.token)
            }
        }
        let first = targets[0], second = targets[1]
        if destinations.contains(first.token) && !destinations.contains(second.token) {
            return (second, first)
        }
        return (first, second)
    }
}
