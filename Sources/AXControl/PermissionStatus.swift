import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// AXControl이 쓰는 macOS 권한.
public enum PermissionKind: String, Sendable, Codable, CaseIterable {
    /// 손쉬운 사용: AX 읽기·동작.
    case accessibility
    /// 화면 기록: ScreenCaptureKit 캡처.
    case screenRecording
    /// 다른 앱으로 CGEvent 보내기(손쉬운 사용 목록에서 함께 허용된다).
    case postEvents
}

/// 권한 상태 조회와 요청. 확인 함수는 대화상자를 띄우지 않고, request* 함수만 시스템 안내를 띄운다.
/// `swift run`으로 실행하면 권한은 이 바이너리가 아니라 실행한 터미널 앱에 붙는다.
public struct PermissionStatus: Sendable, Equatable, Codable {
    public let accessibility: Bool
    public let screenRecording: Bool
    public let postEvents: Bool

    public init(accessibility: Bool, screenRecording: Bool, postEvents: Bool) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.postEvents = postEvents
    }

    public static func current() -> PermissionStatus {
        PermissionStatus(accessibility: isAccessibilityTrusted(), screenRecording: isScreenCaptureAllowed(),
                         postEvents: canPostEvents())
    }

    public var missing: [PermissionKind] {
        var result: [PermissionKind] = []
        if !accessibility { result.append(.accessibility) }
        if !screenRecording { result.append(.screenRecording) }
        if !postEvents { result.append(.postEvents) }
        return result
    }

    public var allGranted: Bool { missing.isEmpty }

    /// AXIsProcessTrustedWithOptions. prompt가 true면 시스템이 손쉬운 사용 허용 안내를 띄운다.
    public static func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        // kAXTrustedCheckOptionPrompt 전역 변수는 Swift 6 동시성 검사에 걸려 같은 값의 문자열을 쓴다.
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    public static func requestAccessibility() -> Bool { isAccessibilityTrusted(prompt: true) }

    /// CGPreflightScreenCaptureAccess. 대화상자를 띄우지 않는다.
    public static func isScreenCaptureAllowed() -> Bool { CGPreflightScreenCaptureAccess() }

    /// CGRequestScreenCaptureAccess. 처음 한 번만 시스템 안내를 띄우고, 허용 후에는 앱을 다시 시작해야 반영된다.
    @discardableResult
    public static func requestScreenCapture() -> Bool { CGRequestScreenCaptureAccess() }

    /// 화면 기록 요청을 시스템 설정 목록에 확실히 등록한다.
    /// CGRequestScreenCaptureAccess만으로는 목록에 앱이 나타나지 않는 경우가 있어 ScreenCaptureKit 조회로 TCC 요청을 만든다.
    public static func registerScreenCaptureRequest() async {
        _ = CGRequestScreenCaptureAccess()
        _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    public static func canPostEvents() -> Bool { CGPreflightPostEventAccess() }

    @discardableResult
    public static func requestPostEvents() -> Bool { CGRequestPostEventAccess() }

    /// 시스템 설정의 해당 개인정보 보호 패널 주소.
    public static func settingsURL(for kind: PermissionKind) -> URL {
        let anchor = switch kind {
        case .accessibility, .postEvents: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    @MainActor
    @discardableResult
    public static func openSettings(for kind: PermissionKind) -> Bool {
        NSWorkspace.shared.open(settingsURL(for: kind))
    }
}
