import AgentContracts
import Foundation

func contractsChecks() async {
    await suite("Contracts") {
        check(RiskLevel.low < RiskLevel.high, "위험도 순서")
        let word = WordTiming(word: "이거", start: .init(nanoseconds: 10), end: .init(nanoseconds: 20), confidence: 0.9)
        let update = TranscriptUpdate(utteranceID: UUID(), revision: 2, text: "이거를", stablePrefix: "이거",
                                      words: [word], isFinal: false)
        let decoded = try JSONDecoder().decode(TranscriptUpdate.self, from: JSONEncoder().encode(update))
        check(decoded == update, "TranscriptUpdate 직렬화 왕복")
    }
}
