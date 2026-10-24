import CoreGraphics
import Foundation

/// 디스플레이 하나의 전역 프레임(AX와 같은 좌상단 원점, 포인트 단위).
public struct DisplayGeometry: Sendable, Codable, Equatable {
    public let id: UInt32
    public let frame: CGRect

    public init(id: UInt32, frame: CGRect) {
        self.id = id
        self.frame = frame
    }

    public func contains(_ point: CGPoint) -> Bool {
        point.x >= frame.minX && point.x <= frame.maxX && point.y >= frame.minY && point.y <= frame.maxY
    }

    public func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: Gaze.clamp(point.x, frame.minX, frame.maxX), y: Gaze.clamp(point.y, frame.minY, frame.maxY))
    }

    /// 프레임 밖이면 가장 가까운 경계까지의 거리, 안이면 0.
    public func distanceOutside(_ point: CGPoint) -> Double {
        let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
        return Double(hypot(dx, dy))
    }

    /// 점을 포함하는 디스플레이, 없으면 가장 가까운 디스플레이.
    public static func display(for point: CGPoint, in displays: [DisplayGeometry]) -> DisplayGeometry? {
        if let hit = displays.first(where: { $0.contains(point) }) { return hit }
        return displays.min { $0.distanceOutside(point) < $1.distanceOutside(point) }
    }

    /// 물리 크기(mm). `CGDisplayScreenSize`가 모르면 nil.
    public static func physicalSizeMillimeters(displayID: UInt32) -> CGSize? {
        let size = CGDisplayScreenSize(displayID)
        guard size.width > 1, size.height > 1 else { return nil }
        return size
    }

    /// cm당 포인트(가로 기준). 물리 크기를 모르면 nil.
    public static func pointsPerCentimeter(frame: CGRect, physicalMillimeters: CGSize?) -> Double? {
        guard let mm = physicalMillimeters, mm.width > 1, frame.width > 0 else { return nil }
        return Double(frame.width) / (Double(mm.width) / 10)
    }

    /// 이 디스플레이의 cm당 포인트.
    public var pointsPerCentimeter: Double? {
        Self.pointsPerCentimeter(frame: frame, physicalMillimeters: Self.physicalSizeMillimeters(displayID: id))
    }

    /// 현재 활성 디스플레이 목록. `CGDisplayBounds`는 주 디스플레이 좌상단 원점 전역 좌표를 준다.
    public static func active() -> [DisplayGeometry] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { DisplayGeometry(id: $0, frame: CGDisplayBounds($0)) }
    }
}
