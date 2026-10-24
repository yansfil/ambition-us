import Foundation

public struct HTTPResponse: Sendable, Equatable {
    public let status: Int
    public let body: Data
    public init(status: Int, body: Data) {
        self.status = status; self.body = body
    }
}

/// 네트워크 경계. 검사에서는 가짜 전송으로 바꿔 실제 네트워크를 호출하지 않는다.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// URLSession 기반 전송. 요청·응답을 디스크에 캐시하지 않도록 ephemeral 세션을 쓴다.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        // URLSession의 async API는 Task 취소를 존중한다(새 revision이 오면 호출이 취소된다).
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return HTTPResponse(status: http.statusCode, body: data)
    }
}
