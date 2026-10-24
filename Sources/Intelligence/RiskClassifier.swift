import AgentContracts
import Foundation

/// 행동·문구 기반 위험도 분류.
/// 보내기/삭제/구매/제출 계열 표현은 high. 제안 위험도는 (행동 기본값, 대상 제목, 명령 문구) 중 최댓값.
public enum RiskClassifier {
    static let koreanHigh: [String] = [
        "보내", "보낼", "보냅", "보낸", "전송", "발송", "송금", "이체",
        "삭제", "지워", "지우", "지운", "제거", "없애", "휴지통", "비워", "비우",
        "구매", "구입", "결제", "주문", "사줘",
        "제출", "탈퇴", "해지", "포맷", "초기화", "영구",
    ]

    static let koreanMedium: [String] = [
        "저장", "덮어", "변경", "수정", "바꿔", "바꾸", "이동", "옮기", "옮겨", "닫기", "닫아",
        "종료", "로그아웃", "설치", "업로드", "공유", "게시", "예약", "초대", "승인", "확인",
    ]

    static let englishHigh: Set<String> = [
        "send", "delete", "remove", "trash", "erase", "purchase", "buy", "pay", "payment", "checkout",
        "order", "submit", "transfer", "wire", "unsubscribe", "format", "reset", "empty", "post", "publish",
    ]

    static let englishMedium: Set<String> = [
        "save", "overwrite", "replace", "move", "close", "quit", "logout", "signout", "install", "upload",
        "share", "rename", "change", "update", "confirm", "approve", "invite", "schedule",
    ]

    /// 자유 문장(발화·UI 제목)의 위험 문구 수준.
    public static func wordingRisk(_ text: String) -> RiskLevel {
        let normalized = text.precomposedStringWithCanonicalMapping
        let compact = normalized.filter { !$0.isWhitespace }
        let tokens = normalized.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) || !$0.isASCII })
            .map(String.init)

        if koreanHigh.contains(where: { compact.contains($0) }) || tokens.contains(where: { matches($0, englishHigh) }) {
            return .high
        }
        if koreanMedium.contains(where: { compact.contains($0) }) || tokens.contains(where: { matches($0, englishMedium) }) {
            return .medium
        }
        return .low
    }

    /// 제안할 행동의 위험도. `commandText`는 사용자가 에이전트에게 지시한 문구(받아쓰기 내용은 제외).
    public static func risk(for action: AgentAction, commandText: String?) -> RiskLevel {
        var level = baseRisk(for: action)
        for target in action.involvedTargets {
            if let title = target.title { level = max(level, wordingRisk(title)) }
        }
        if let commandText { level = max(level, wordingRisk(commandText)) }
        return level
    }

    static func baseRisk(for action: AgentAction) -> RiskLevel {
        switch action {
        case .typeText: return .low
        case .press(let target):
            let title = target.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? .medium : .low
        case .move: return .medium
        case .setValue(_, let value): return value.isEmpty ? .high : .medium
        }
    }

    private static func matches(_ token: String, _ stems: Set<String>) -> Bool {
        if stems.contains(token) { return true }
        for suffix in ["s", "es", "d", "ed", "ing", "ment"] where token.hasSuffix(suffix) {
            if stems.contains(String(token.dropLast(suffix.count))) { return true }
        }
        return false
    }
}
