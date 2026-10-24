import AgentContracts

protocol Timestamped {
    var time: MonotonicTime { get }
}

extension GazeSample: Timestamped {}
extension NonverbalCue: Timestamped {}
extension ParalinguisticCue: Timestamped {}

/// 시각순으로 정렬된 고정 용량 링 버퍼. 가득 차면 가장 오래된 항목을 버린다.
/// 순서가 뒤바뀐 입력은 정렬 위치에 끼워 넣는다(드문 경우라 O(n) 허용).
struct TimeRingBuffer<Element: Timestamped & Sendable>: Sendable {
    let capacity: Int
    private var storage: [Element?]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        storage = Array(repeating: nil, count: self.capacity)
    }

    var isEmpty: Bool { count == 0 }
    var last: Element? { count > 0 ? self[count - 1] : nil }
    var elements: [Element] { (0..<count).map { self[$0] } }

    subscript(index: Int) -> Element { storage[slot(index)]! }

    /// 넣는다. 용량 초과로 가장 오래된 항목을 버렸으면 true.
    @discardableResult
    mutating func insert(_ element: Element) -> Bool {
        var dropped = false
        if count == capacity {
            storage[head] = nil
            head = (head + 1) % capacity
            count -= 1
            dropped = true
        }
        var position = count
        if let last, element.time < last.time {
            position = upperBound(element.time)
        }
        var i = count
        while i > position {
            storage[slot(i)] = storage[slot(i - 1)]
            i -= 1
        }
        storage[slot(position)] = element
        count += 1
        return dropped
    }

    /// `time`보다 이른 항목을 버리고 버린 개수를 돌려준다.
    @discardableResult
    mutating func removeOlder(than time: MonotonicTime) -> Int {
        var removed = 0
        while count > 0, self[0].time < time {
            storage[head] = nil
            head = (head + 1) % capacity
            count -= 1
            removed += 1
        }
        return removed
    }

    mutating func removeAll(where shouldRemove: (Element) -> Bool) {
        let kept = elements.filter { !shouldRemove($0) }
        removeAll()
        for element in kept { insert(element) }
    }

    mutating func removeAll() {
        storage = Array(repeating: nil, count: capacity)
        head = 0
        count = 0
    }

    /// [from, through] 구간 항목(시각순).
    func elements(from lower: MonotonicTime, through upper: MonotonicTime) -> [Element] {
        guard lower <= upper else { return [] }
        var result: [Element] = []
        var i = lowerBound(lower)
        while i < count {
            let element = self[i]
            if element.time > upper { break }
            result.append(element)
            i += 1
        }
        return result
    }

    /// time 이상인 첫 위치.
    func lowerBound(_ time: MonotonicTime) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if self[mid].time < time { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// time 초과인 첫 위치.
    func upperBound(_ time: MonotonicTime) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if self[mid].time <= time { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func slot(_ index: Int) -> Int { (head + index) % capacity }
}
