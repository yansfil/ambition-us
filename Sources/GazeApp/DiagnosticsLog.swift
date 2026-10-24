import Foundation
import os

/// 실기기 문제를 확인하기 위한 진단 로그. `~/Library/Logs/Gaze/gaze.log`에 남기고 통합 로그에도 보낸다.
/// 전사 텍스트가 들어가므로 로컬 개발용이다. API 키 같은 비밀 값은 기록하지 않는다.
enum DiagnosticsLog {
    private static let logger = Logger(subsystem: "app.gaze", category: "Diagnostics")
    private static let queue = DispatchQueue(label: "gaze.diagnostics.log")
    static let fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Gaze/gaze.log")

    static func write(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(message)\n"
        queue.async {
            let manager = FileManager.default
            try? manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !manager.fileExists(atPath: fileURL.path) { manager.createFile(atPath: fileURL.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }
}
