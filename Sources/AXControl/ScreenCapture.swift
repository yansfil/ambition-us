import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// 캡처 결과. 이미지는 정책 한도 안으로 줄어 있고, geometry로 픽셀 ↔ 전역 좌표를 바꾼다.
public struct CapturedScreenshot: @unchecked Sendable {
    public let image: CGImage
    public let geometry: ScreenshotGeometry
    public let displayID: CGDirectDisplayID?
    public let windowID: CGWindowID?

    public init(image: CGImage, geometry: ScreenshotGeometry, displayID: CGDirectDisplayID?, windowID: CGWindowID?) {
        self.image = image
        self.geometry = geometry
        self.displayID = displayID
        self.windowID = windowID
    }

    public func pngData() -> Data? { encode(type: .png, properties: [:]) }

    public func jpegData(quality: Double = 0.85) -> Data? {
        encode(type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    private func encode(type: UTType, properties: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

public enum ScreenCaptureError: Error, Sendable, Equatable, CustomStringConvertible {
    case permissionDenied
    case displayNotFound
    case windowNotFound
    case emptyRegion
    case captureFailed(String)

    public var description: String {
        switch self {
        case .permissionDenied: "screen_recording_permission_missing: grant Screen Recording access"
        case .displayNotFound: "screenshot_failed: display not found"
        case .windowNotFound: "window_not_found: window is not on screen"
        case .emptyRegion: "invalid_argument: capture region is empty or off-screen"
        case .captureFailed(let message): "screenshot_failed: \(message)"
        }
    }
}

/// ScreenCaptureKit 기반 스크린샷. Claude computer toolset의 screenshot·zoom 멤버를 지원한다.
/// 디스플레이 캡처에서는 Gaze 자신의 창(오버레이)을 기본으로 뺀다.
public struct ScreenCapture: Sendable {
    public var policy: ScreenshotScalingPolicy
    public var excludeOwnProcess: Bool
    public var showsCursor: Bool

    public init(policy: ScreenshotScalingPolicy = .claudeMaximum, excludeOwnProcess: Bool = true, showsCursor: Bool = false) {
        self.policy = policy
        self.excludeOwnProcess = excludeOwnProcess
        self.showsCursor = showsCursor
    }

    /// 디스플레이 전체 또는 일부를 캡처한다.
    /// - Parameters:
    ///   - displayID: nil이면 주 화면.
    ///   - region: 전역 AX 좌표 영역(zoom용). 디스플레이와 겹치는 부분만 캡처한다.
    public func captureDisplay(_ displayID: CGDirectDisplayID? = nil, region: CGRect? = nil) async throws -> CapturedScreenshot {
        try ensurePermission()
        let id = displayID ?? CGMainDisplayID()
        let content = try await shareableContent()
        guard let display = content.displays.first(where: { $0.displayID == id }) else { throw ScreenCaptureError.displayNotFound }
        let displayBounds = CGDisplayBounds(id)
        var source = displayBounds
        if let region {
            source = region.standardized.intersection(displayBounds)
            guard !source.isNull, source.width >= 1, source.height >= 1 else { throw ScreenCaptureError.emptyRegion }
        }

        let ownApps = excludeOwnProcess
            ? content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier } : []
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        if region != nil {
            // sourceRect는 디스플레이 좌상단 기준 포인트.
            config.sourceRect = source.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY)
        }
        let scale = CGFloat(filter.pointPixelScale > 0 ? filter.pointPixelScale : 1)
        return try await capture(filter: filter, config: config, sourceRect: source, pointPixelScale: scale,
                                 displayID: id, windowID: nil)
    }

    /// 전역 좌표가 속한 디스플레이를 캡처한다.
    public func captureDisplay(containing point: CGPoint) async throws -> CapturedScreenshot {
        guard let id = Self.displayID(containing: point) else { throw ScreenCaptureError.displayNotFound }
        return try await captureDisplay(id)
    }

    /// 창 하나를 다른 창에 가리지 않은 상태로 캡처한다(그림자 제외).
    public func captureWindow(_ windowID: CGWindowID) async throws -> CapturedScreenshot {
        try ensurePermission()
        let content = try await shareableContent()
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else { throw ScreenCaptureError.windowNotFound }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.ignoreShadowsSingleWindow = true
        let scale = CGFloat(filter.pointPixelScale > 0 ? filter.pointPixelScale : 1)
        return try await capture(filter: filter, config: config, sourceRect: window.frame, pointPixelScale: scale,
                                 displayID: Self.displayID(containing: window.frame.axCenter), windowID: windowID)
    }

    /// pid 앱의 가장 앞에 있는 보통 창(layer 0)을 캡처한다.
    public func captureFrontWindow(pid: pid_t) async throws -> CapturedScreenshot {
        guard let windowID = Self.frontWindowID(pid: pid) else { throw ScreenCaptureError.windowNotFound }
        return try await captureWindow(windowID)
    }

    /// 전역 좌표를 포함하는 디스플레이.
    public static func displayID(containing point: CGPoint) -> CGDirectDisplayID? {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &id, &count) == .success, count > 0 else { return nil }
        return id
    }

    /// 앞에서 뒤 순서 창 목록에서 pid의 첫 layer 0 창.
    public static func frontWindowID(pid: pid_t) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        for info in list {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            if let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
               let bounds = CGRect(dictionaryRepresentation: boundsDict), bounds.width < 2 || bounds.height < 2 {
                continue
            }
            return number
        }
        return nil
    }

    // MARK: 내부

    private func ensurePermission() throws {
        guard CGPreflightScreenCaptureAccess() else { throw ScreenCaptureError.permissionDenied }
    }

    private func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenCaptureError.captureFailed("shareable content unavailable: \(error.localizedDescription)")
        }
    }

    private func capture(filter: SCContentFilter, config: SCStreamConfiguration, sourceRect: CGRect,
                         pointPixelScale: CGFloat, displayID: CGDirectDisplayID?, windowID: CGWindowID?) async throws -> CapturedScreenshot {
        let native = CGSize(width: sourceRect.width * pointPixelScale, height: sourceRect.height * pointPixelScale)
        let target = policy.targetPixelSize(forNativePixels: native)
        config.width = Int(target.width)
        config.height = Int(target.height)
        config.scalesToFit = true
        config.preservesAspectRatio = true
        config.showsCursor = showsCursor
        config.captureResolution = .best

        var image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw ScreenCaptureError.captureFailed(error.localizedDescription)
        }
        let actual = CGSize(width: image.width, height: image.height)
        if !policy.fits(actual) {
            let fitted = policy.targetPixelSize(forNativePixels: actual)
            guard let resized = Self.resize(image, to: fitted) else {
                throw ScreenCaptureError.captureFailed("could not downscale \(image.width)x\(image.height)")
            }
            image = resized
        }
        let geometry = ScreenshotGeometry(sourceRect: sourceRect, imageSize: CGSize(width: image.width, height: image.height))
        return CapturedScreenshot(image: image, geometry: geometry, displayID: displayID, windowID: windowID)
    }

    /// CPU 축소(캡처 결과가 한도를 넘는 드문 경우의 안전장치).
    static func resize(_ image: CGImage, to size: CGSize) -> CGImage? {
        let width = max(1, Int(size.width)), height = max(1, Int(size.height))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
