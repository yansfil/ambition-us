import Foundation
import Security

/// Anthropic API 키. 문자열 보간·print·dump 어디에도 값이 나오지 않도록 가린다.
public struct APIKey: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// 실제 값은 모듈 내부(HTTP 헤더 설정)에서만 읽는다.
    let value: String

    /// 공백을 제거하고 비어 있거나 내부에 공백/제어 문자가 있으면 nil.
    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        value = trimmed
    }

    public var description: String { "APIKey(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

public enum APIKeySource: String, Sendable, Equatable {
    case environment, keychain, envFile
}

public struct LoadedAPIKey: Sendable, Equatable {
    public let key: APIKey
    public let source: APIKeySource
    public init(key: APIKey, source: APIKeySource) {
        self.key = key; self.source = source
    }
}

public protocol APIKeyProviding: Sendable {
    func loadAPIKey() -> LoadedAPIKey?
}

public protocol KeychainReading: Sendable {
    func readPassword(service: String, account: String) -> String?
}

/// 로그인 키체인의 일반 암호 항목을 읽는다.
/// 등록 예: `security add-generic-password -s Gaze -a anthropic -w`
public struct SystemKeychain: KeychainReading {
    public init() {}

    public func readPassword(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// 키 로딩 순서: ANTHROPIC_API_KEY 환경 변수 → 키체인(service "Gaze", account "anthropic")
/// → 로컬 개발용 GAZE_ENV_FILE 경로의 .env 파일. 키 값은 어디에도 기록하지 않는다.
public struct APIKeyProvider: APIKeyProviding {
    public static let environmentVariable = "ANTHROPIC_API_KEY"
    public static let envFileVariable = "GAZE_ENV_FILE"
    public static let keychainService = "Gaze"
    public static let keychainAccount = "anthropic"

    private let environment: [String: String]
    private let keychain: any KeychainReading
    private let readFile: @Sendable (String) -> String?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                keychain: any KeychainReading = SystemKeychain(),
                readFile: @escaping @Sendable (String) -> String? = { path in
                    try? String(contentsOfFile: path, encoding: .utf8)
                }) {
        self.environment = environment
        self.keychain = keychain
        self.readFile = readFile
    }

    public func loadAPIKey() -> LoadedAPIKey? {
        if let raw = environment[Self.environmentVariable], let key = APIKey(raw) {
            return LoadedAPIKey(key: key, source: .environment)
        }
        if let raw = keychain.readPassword(service: Self.keychainService, account: Self.keychainAccount),
           let key = APIKey(raw) {
            return LoadedAPIKey(key: key, source: .keychain)
        }
        if let path = environment[Self.envFileVariable]?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty,
           let contents = readFile((path as NSString).expandingTildeInPath),
           let raw = Self.parseDotEnv(contents)[Self.environmentVariable],
           let key = APIKey(raw) {
            return LoadedAPIKey(key: key, source: .envFile)
        }
        return nil
    }

    /// 단순 .env 파서: `KEY=VALUE`, `export KEY=VALUE`, 따옴표 값, `#` 주석을 지원한다.
    public static func parseDotEnv(_ contents: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'" {
                let body = value.dropFirst()
                if let closing = body.firstIndex(of: quote) {
                    value = String(body[..<closing])
                } else {
                    value = String(body)
                }
            } else if let hash = value.range(of: " #") {
                value = value[..<hash.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            result[key] = value
        }
        return result
    }
}
