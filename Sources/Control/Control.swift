import AgentContracts
import Foundation

// Control 모듈: 실행 전 안전 게이트(PolicyEngine), 받아쓰기 원장(DictationLedger),
// 승인·실행 흐름(ActionCoordinator)을 담는다. 아래는 모듈 내부 공용 도우미다.
// 다른 모듈의 확장과 이름이 겹치지 않도록 모두 internal로 둔다.

extension AgentAction {
    /// 이 행동이 건드리는 모든 UI 대상.
    var involvedTargets: [UITarget] {
        switch self {
        case .typeText(let target, _), .press(let target), .setValue(let target, _):
            return [target]
        case .move(let source, let destination):
            return [source, destination]
        }
    }

    /// 결과(ActionOutcome)에 실을 대표 대상. move는 도착지를 쓴다.
    var primaryTarget: UITarget {
        switch self {
        case .typeText(let target, _), .press(let target), .setValue(let target, _):
            return target
        case .move(_, let destination):
            return destination
        }
    }

    /// 대상 필드에 들어갈 텍스트(typeText·setValue만 해당).
    var enteredText: String? {
        switch self {
        case .typeText(_, let text): return text
        case .setValue(_, let value): return value
        case .press, .move: return nil
        }
    }
}

extension Duration {
    /// 음수는 0, 넘치면 UInt64.max로 자른 나노초.
    var clampedNanoseconds: UInt64 {
        let parts = components
        guard parts.seconds >= 0, parts.attoseconds >= 0 || parts.seconds > 0 else { return 0 }
        let (secondsPart, overflow) = UInt64(parts.seconds).multipliedReportingOverflow(by: 1_000_000_000)
        if overflow { return .max }
        let subsecond = parts.attoseconds > 0 ? UInt64(parts.attoseconds / 1_000_000_000) : 0
        let (total, overflow2) = secondsPart.addingReportingOverflow(subsecond)
        return overflow2 ? .max : total
    }

    static func clampedNanoseconds(_ value: UInt64) -> Duration {
        .nanoseconds(Int64(clamping: value))
    }
}

extension MonotonicTime {
    /// `earlier`부터 지금까지 흐른 나노초. 미래 시각이면 0.
    func elapsed(since earlier: MonotonicTime) -> UInt64 {
        nanoseconds > earlier.nanoseconds ? nanoseconds - earlier.nanoseconds : 0
    }

    func adding(_ nanos: UInt64) -> MonotonicTime {
        let (sum, overflow) = nanoseconds.addingReportingOverflow(nanos)
        return MonotonicTime(nanoseconds: overflow ? .max : sum)
    }
}

/// 프로세스와 무관하게 같은 값을 내는 FNV-1a 64비트 해시(Swift Hasher는 실행마다 달라진다).
func stableHash(_ string: String, seed: UInt64 = 0xcbf2_9ce4_8422_2325) -> UInt64 {
    var hash = seed
    for byte in string.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x0000_0100_0000_01b3
    }
    return hash
}

/// 문자열 키에서 결정적으로 만든 UUID(RFC 9562 version 8 형식).
func stableUUID(from key: String) -> UUID {
    let high = stableHash(key)
    let low = stableHash(key, seed: 0x84222325cbf29ce4)
    var bytes = [UInt8](repeating: 0, count: 16)
    for index in 0..<8 {
        bytes[index] = UInt8(truncatingIfNeeded: high >> (56 - 8 * UInt64(index)))
        bytes[index + 8] = UInt8(truncatingIfNeeded: low >> (56 - 8 * UInt64(index)))
    }
    bytes[6] = (bytes[6] & 0x0F) | 0x80
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                       bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
}
