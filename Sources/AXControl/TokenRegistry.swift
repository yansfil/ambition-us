import CoreGraphics
import Foundation

/// 요소 참조를 문자열 token으로 바꿔 보관하는 레지스트리.
/// AXUIElement를 모듈 밖에 내보내지 않기 위한 장치이며, 같은 요소는 같은 token을 받는다.
/// 용량을 넘으면 가장 오래 쓰지 않은 항목부터 내보낸다. 내보낸 token은 `element_not_found`가 된다.
public final class TokenRegistry<Element: Hashable>: @unchecked Sendable {
    public struct Entry {
        public let token: String
        public let element: Element
        public let pid: Int32
        public let role: String
        public let frame: CGRect?
    }

    public let capacity: Int
    private let prefix: String
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var tokenByElement: [Element: String] = [:]
    private var lastUse: [String: UInt64] = [:]
    private var clock: UInt64 = 0
    private var serial: UInt64 = 0

    public init(capacity: Int = 4096, prefix: String = "ax") {
        self.capacity = max(1, capacity)
        self.prefix = prefix
    }

    public var count: Int { lock.withLock { entries.count } }

    /// 요소를 등록하고 token을 돌려준다. 이미 있는 요소면 메타데이터만 갱신하고 같은 token을 준다.
    @discardableResult
    public func register(_ element: Element, pid: Int32, role: String, frame: CGRect?) -> String {
        lock.withLock {
            clock &+= 1
            if let existing = tokenByElement[element] {
                entries[existing] = Entry(token: existing, element: element, pid: pid, role: role, frame: frame)
                lastUse[existing] = clock
                return existing
            }
            serial &+= 1
            let token = "\(prefix)-\(pid)-\(serial)"
            entries[token] = Entry(token: token, element: element, pid: pid, role: role, frame: frame)
            tokenByElement[element] = token
            lastUse[token] = clock
            evictIfNeeded()
            return token
        }
    }

    public func entry(for token: String) -> Entry? {
        lock.withLock {
            guard let entry = entries[token] else { return nil }
            clock &+= 1
            lastUse[token] = clock
            return entry
        }
    }

    public func token(for element: Element) -> String? {
        lock.withLock { tokenByElement[element] }
    }

    public func remove(token: String) {
        lock.withLock { removeLocked(token) }
    }

    /// 앱이 종료됐거나 상태를 새로 읽을 때 해당 pid의 token을 모두 무효화한다.
    @discardableResult
    public func removeAll(pid: Int32) -> Int {
        lock.withLock {
            let tokens = entries.values.filter { $0.pid == pid }.map(\.token)
            tokens.forEach(removeLocked)
            return tokens.count
        }
    }

    public func removeAll() {
        lock.withLock {
            entries.removeAll()
            tokenByElement.removeAll()
            lastUse.removeAll()
        }
    }

    private func removeLocked(_ token: String) {
        guard let entry = entries.removeValue(forKey: token) else { return }
        tokenByElement.removeValue(forKey: entry.element)
        lastUse.removeValue(forKey: token)
    }

    private func evictIfNeeded() {
        guard entries.count > capacity else { return }
        // 매번 한 개씩 지우면 대량 등록 때 정렬 비용이 커지므로 1/8씩 한꺼번에 내보낸다.
        let overflow = entries.count - capacity
        let batch = max(overflow, capacity / 8)
        let victims = lastUse.sorted { $0.value < $1.value }.prefix(batch).map(\.key)
        victims.forEach(removeLocked)
    }
}
