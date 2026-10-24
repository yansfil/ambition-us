import CoreGraphics
import Foundation

/// 전역 AX/Quartz 좌표(주 화면 좌상단 원점, y 아래로 증가)와
/// Cocoa 전역 좌표(주 화면 좌하단 원점, y 위로 증가) 사이 변환.
/// 두 좌표계 모두 포인트 단위이며 x축은 같다.
public enum CoordinateConversion {
    public static func cocoaPoint(fromAX point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    public static func axPoint(fromCocoa point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    public static func cocoaRect(fromAX rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        let r = rect.standardized
        return CGRect(x: r.minX, y: primaryScreenHeight - r.maxY, width: r.width, height: r.height)
    }

    public static func axRect(fromCocoa rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        let r = rect.standardized
        return CGRect(x: r.minX, y: primaryScreenHeight - r.maxY, width: r.width, height: r.height)
    }

    /// 주 화면(메뉴 막대가 있는 화면) 높이. Cocoa 변환의 기준이다.
    public static func primaryScreenHeight() -> CGFloat {
        CGDisplayBounds(CGMainDisplayID()).height
    }

    /// 창 좌상단 기준 좌표(Orca의 window-local)로 변환.
    public static func windowLocal(fromGlobal point: CGPoint, windowFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x - windowFrame.minX, y: point.y - windowFrame.minY)
    }

    public static func global(fromWindowLocal point: CGPoint, windowFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x + windowFrame.minX, y: point.y + windowFrame.minY)
    }
}

/// 스크린샷 축소 정책. Claude 고해상도 비전 한도는 긴 변 2576px, 총 3.75MP이며
/// computer toolset은 크기를 대신 줄여주지 않으므로 보내기 전에 맞춰야 한다.
public struct ScreenshotScalingPolicy: Sendable, Equatable, Codable {
    public var maxLongEdge: Int
    public var maxTotalPixels: Int?

    public init(maxLongEdge: Int, maxTotalPixels: Int?) {
        self.maxLongEdge = maxLongEdge
        self.maxTotalPixels = maxTotalPixels
    }

    /// Claude 고해상도 한도(긴 변 2576px, 3.75MP).
    public static let claudeMaximum = ScreenshotScalingPolicy(maxLongEdge: 2576, maxTotalPixels: 3_750_000)
    /// 비용과 정확도의 균형점으로 권장되는 1080p 수준.
    public static let balanced1080p = ScreenshotScalingPolicy(maxLongEdge: 1920, maxTotalPixels: 1920 * 1080)

    /// 원본 픽셀 크기를 한도 안으로 줄인 크기. 확대하지 않고 종횡비를 유지한다.
    public func targetPixelSize(forNativePixels native: CGSize) -> CGSize {
        let w = max(1, Double(native.width)), h = max(1, Double(native.height))
        var factor = 1.0
        let longEdge = max(w, h)
        if maxLongEdge > 0, longEdge > Double(maxLongEdge) {
            factor = min(factor, Double(maxLongEdge) / longEdge)
        }
        if let maxTotalPixels, maxTotalPixels > 0, w * h > Double(maxTotalPixels) {
            factor = min(factor, (Double(maxTotalPixels) / (w * h)).squareRoot())
        }
        guard factor < 1 else { return CGSize(width: w.rounded(), height: h.rounded()) }
        // 부동소수 오차로 한도를 1px 넘거나 모자라지 않게 작은 여유를 둔다.
        let tw = max(1, (w * factor + 1e-6).rounded(.down))
        let th = max(1, (h * factor + 1e-6).rounded(.down))
        return CGSize(width: tw, height: th)
    }

    public func fits(_ size: CGSize) -> Bool {
        let longEdge = max(size.width, size.height)
        if maxLongEdge > 0, longEdge > CGFloat(maxLongEdge) { return false }
        if let maxTotalPixels, maxTotalPixels > 0, size.width * size.height > CGFloat(maxTotalPixels) { return false }
        return true
    }
}

/// 스크린샷 픽셀 ↔ 전역 AX 포인트 매핑. Claude가 돌려주는 좌표는 보낸 스크린샷의 픽셀 공간이므로
/// 동작 전에 반드시 이 매핑으로 전역 좌표로 바꾼다(Orca: action = pixel / scale).
public struct ScreenshotGeometry: Sendable, Equatable, Codable {
    /// 캡처한 영역(전역 AX 좌표, 포인트).
    public let sourceRect: CGRect
    /// 출력 이미지 크기(픽셀, 축소 후).
    public let imageSize: CGSize

    public init(sourceRect: CGRect, imageSize: CGSize) {
        self.sourceRect = sourceRect.standardized
        self.imageSize = imageSize
    }

    /// 포인트당 픽셀 수. Orca 스크린샷의 `scale`과 같은 의미다.
    public var pixelsPerPointX: CGFloat { sourceRect.width > 0 ? imageSize.width / sourceRect.width : 1 }
    public var pixelsPerPointY: CGFloat { sourceRect.height > 0 ? imageSize.height / sourceRect.height : 1 }

    public func globalPoint(fromImagePixel pixel: CGPoint) -> CGPoint {
        CGPoint(x: sourceRect.minX + pixel.x / pixelsPerPointX,
                y: sourceRect.minY + pixel.y / pixelsPerPointY)
    }

    public func imagePixel(fromGlobal point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - sourceRect.minX) * pixelsPerPointX,
                y: (point.y - sourceRect.minY) * pixelsPerPointY)
    }

    public func globalRect(fromImagePixelRect rect: CGRect) -> CGRect {
        let r = rect.standardized
        let origin = globalPoint(fromImagePixel: r.origin)
        return CGRect(x: origin.x, y: origin.y, width: r.width / pixelsPerPointX, height: r.height / pixelsPerPointY)
    }

    public func imagePixelRect(fromGlobal rect: CGRect) -> CGRect {
        let r = rect.standardized
        let origin = imagePixel(fromGlobal: r.origin)
        return CGRect(x: origin.x, y: origin.y, width: r.width * pixelsPerPointX, height: r.height * pixelsPerPointY)
    }

    public func containsImagePixel(_ pixel: CGPoint) -> Bool {
        pixel.x >= 0 && pixel.y >= 0 && pixel.x < imageSize.width && pixel.y < imageSize.height
    }

    /// 이미지 밖 좌표를 가장자리로 붙인 뒤 전역 좌표로 바꾼다.
    public func clampedGlobalPoint(fromImagePixel pixel: CGPoint) -> CGPoint {
        let x = min(max(pixel.x, 0), max(0, imageSize.width - 1))
        let y = min(max(pixel.y, 0), max(0, imageSize.height - 1))
        return globalPoint(fromImagePixel: CGPoint(x: x, y: y))
    }
}

extension CGRect {
    var axCenter: CGPoint { CGPoint(x: midX, y: midY) }
}
