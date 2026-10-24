import Foundation
import Synchronization

/// `AsyncStream`은 소비자 하나만 전제로 한다. 한 원천 스트림을 여러 구독자에게 나눠 준다.
///
/// - 구독자마다 자기 버퍼 정책을 고른다(예: 오버레이는 최신 1개, 결합 모듈은 넉넉히).
/// - 구독자가 스트림을 버리면(종료) 자동으로 빠진다.
/// - `pump(from:)`로 원천을 끝까지 읽어 나눈다. 원천이 끝나면 모든 구독 스트림도 끝난다.
///   원천 요소를 놓치지 않으려면 펌프를 시작하기 전에 구독해야 한다.
public final class AsyncBroadcaster<Element: Sendable>: Sendable {
    private struct State {
        var subscribers: [UUID: AsyncStream<Element>.Continuation] = [:]
        var finished = false
    }

    private let state = Mutex(State())

    public init() {}

    public var subscriberCount: Int { state.withLock { $0.subscribers.count } }

    public func subscribe(bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy = .unbounded)
        -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: bufferingPolicy)
        let id = UUID()
        let accepted = state.withLock { state -> Bool in
            guard !state.finished else { return false }
            state.subscribers[id] = continuation
            return true
        }
        guard accepted else {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            _ = self?.state.withLock { $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    public func yield(_ element: Element) {
        let targets = state.withLock { Array($0.subscribers.values) }
        for continuation in targets { continuation.yield(element) }
    }

    public func finish() {
        let targets = state.withLock { state -> [AsyncStream<Element>.Continuation] in
            state.finished = true
            defer { state.subscribers.removeAll() }
            return Array(state.subscribers.values)
        }
        for continuation in targets { continuation.finish() }
    }

    /// 원천 스트림을 읽어 모든 구독자에게 나눈다. 반환한 작업을 취소하면 나누기를 멈춘다(구독은 열어 둔다).
    @discardableResult
    public func pump(from source: AsyncStream<Element>) -> Task<Void, Never> {
        Task.detached { [self] in
            for await element in source {
                if Task.isCancelled { return }
                yield(element)
            }
            if !Task.isCancelled { finish() }
        }
    }
}
