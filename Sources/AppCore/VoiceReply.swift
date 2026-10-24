import Foundation

/// 승인 대기·제안 중에 들린 짧은 대답을 수락/거절로 읽는다.
/// 대기 중인 질문이 있을 때만 쓰므로, 받아쓰기나 명령으로 흘러가지 않게 막는 역할도 한다.
public enum VoiceReply: Sendable, Equatable {
    case accept
    case reject

    static let acceptPhrases: Set<String> = [
        "응", "어", "엉", "웅", "네", "예", "넹", "넵", "그래", "그래요", "좋아", "좋아요", "좋아해", "해", "해줘", "해 줘",
        "해주세요", "해 주세요", "그렇게 해", "그렇게 해줘", "실행", "실행해", "실행해줘", "확인", "오케이", "오키", "ok", "okay",
        "yes", "yep", "고", "ㅇㅇ", "맞아", "맞아요", "부탁해", "진행", "진행해", "진행해줘", "눌러", "눌러줘", "옮겨", "옮겨줘",
    ]
    static let rejectPhrases: Set<String> = [
        "아니", "아니야", "아니요", "아뇨", "아냐", "아니오", "싫어", "하지마", "하지 마", "하지 마요", "취소", "취소해", "취소해줘",
        "그만", "멈춰", "됐어", "됐어요", "no", "nope", "stop", "cancel", "놔둬", "놔 둬", "안 돼", "안돼",
    ]

    /// 문장부호·공백을 정리한 뒤 짧은 대답 사전과 맞춰 본다. 긴 문장은 대답으로 보지 않는다.
    public static func classify(_ text: String) -> VoiceReply? {
        let normalized = normalize(text)
        guard !normalized.isEmpty, normalized.count <= 12 else { return nil }
        if rejectPhrases.contains(normalized) || rejectPhrases.contains(where: { normalized.hasPrefix($0 + " ") }) {
            return .reject
        }
        if acceptPhrases.contains(normalized) || acceptPhrases.contains(where: { normalized.hasPrefix($0 + " ") }) {
            return .accept
        }
        return nil
    }

    static func normalize(_ text: String) -> String {
        let stripped = text.lowercased().unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }
        return String(String.UnicodeScalarView(stripped))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
