import Foundation

nonisolated(unsafe) var failures = 0

func check(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #fileID, line: UInt = #line) {
    if condition() {
        print("  ok   \(message)")
    } else {
        failures += 1
        print("  FAIL \(message) (\(file):\(line))")
    }
}

func suite(_ name: String, _ body: () async throws -> Void) async {
    print("[\(name)]")
    do { try await body() } catch {
        failures += 1
        print("  FAIL threw \(error)")
    }
}
