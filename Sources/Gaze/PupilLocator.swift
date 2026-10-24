import CoreGraphics
import CoreVideo
import Foundation

/// 8비트 밝기 영상(행 우선, 좌상단 원점).
public struct LumaImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height, "pixels.count must equal width * height")
        self.width = width; self.height = height; self.pixels = pixels
    }

    public subscript(x: Int, y: Int) -> UInt8 { pixels[y * width + x] }
}

/// Vision의 동공 랜드마크는 거칠어서, 눈 윤곽 안에서 가장 어두운 영역의 무게중심으로 다시 잡는다.
public enum PupilLocator {
    public struct Configuration: Sendable, Equatable {
        /// 눈 윤곽 안 픽셀 중 어두운 쪽 비율을 동공 후보로 쓴다.
        public var darkFraction: Double = 0.12
        /// 눈꺼풀·눈꼬리 그림자를 피하려고 윤곽을 중심 쪽으로 줄이는 비율.
        public var polygonShrink: Double = 0.85
        public var minimumPixels: Int = 12
        public init() {}
    }

    /// `polygon`은 `image` 픽셀 좌표(좌상단 원점, 연속 좌표). 결과도 같은 좌표계.
    public static func locate(in image: LumaImage, eyePolygon polygon: [CGPoint],
                              configuration: Configuration = .init()) -> CGPoint? {
        guard polygon.count >= 3 else { return nil }
        let cx = polygon.reduce(0.0) { $0 + Double($1.x) } / Double(polygon.count)
        let cy = polygon.reduce(0.0) { $0 + Double($1.y) } / Double(polygon.count)
        let s = configuration.polygonShrink
        let shrunk = polygon.map { CGPoint(x: cx + (Double($0.x) - cx) * s, y: cy + (Double($0.y) - cy) * s) }

        let minX = max(0, Int(floor(shrunk.map(\.x).min()!)))
        let maxX = min(image.width - 1, Int(ceil(shrunk.map(\.x).max()!)))
        let minY = max(0, Int(floor(shrunk.map(\.y).min()!)))
        let maxY = min(image.height - 1, Int(ceil(shrunk.map(\.y).max()!)))
        guard minX <= maxX, minY <= maxY else { return nil }

        var inside: [(x: Double, y: Double, value: Int)] = []
        for y in minY...maxY {
            for x in minX...maxX {
                let px = Double(x) + 0.5, py = Double(y) + 0.5
                if pointInPolygon(px, py, shrunk) { inside.append((px, py, Int(image[x, y]))) }
            }
        }
        guard inside.count >= configuration.minimumPixels else { return nil }
        let sorted = inside.map(\.value).sorted()
        let index = min(sorted.count - 1, max(0, Int(Double(sorted.count) * configuration.darkFraction)))
        let threshold = sorted[index]
        // 임계값보다 어두울수록 큰 가중치. 모두 같은 밝기면 단순 평균.
        var sx = 0.0, sy = 0.0, sw = 0.0, ux = 0.0, uy = 0.0, un = 0.0
        for p in inside where p.value <= threshold {
            let w = Double(threshold - p.value)
            sx += p.x * w; sy += p.y * w; sw += w
            ux += p.x; uy += p.y; un += 1
        }
        if sw > 0 { return CGPoint(x: sx / sw, y: sy / sw) }
        return un > 0 ? CGPoint(x: ux / un, y: uy / un) : nil
    }

    static func pointInPolygon(_ x: Double, _ y: Double, _ polygon: [CGPoint]) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let xi = Double(polygon[i].x), yi = Double(polygon[i].y)
            let xj = Double(polygon[j].x), yj = Double(polygon[j].y)
            if (yi > y) != (yj > y), x < (xj - xi) * (y - yi) / (yj - yi) + xi { inside.toggle() }
            j = i
        }
        return inside
    }

    /// 420 bi-planar 버퍼의 Y 평면에서 `rect`(픽셀, 좌상단 원점)만 복사한다. 다른 포맷이면 nil.
    public static func lumaCrop(_ buffer: CVPixelBuffer, rect: CGRect) -> (image: LumaImage, origin: CGPoint)? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
        let planeWidth = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let planeHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let x0 = max(0, Int(floor(rect.minX))), y0 = max(0, Int(floor(rect.minY)))
        let x1 = min(planeWidth, Int(ceil(rect.maxX))), y1 = min(planeHeight, Int(ceil(rect.maxY)))
        guard x1 - x0 >= 4, y1 - y0 >= 4 else { return nil }
        let width = x1 - x0, height = y1 - y0
        var pixels = [UInt8](repeating: 0, count: width * height)
        let src = base.assumingMemoryBound(to: UInt8.self)
        pixels.withUnsafeMutableBufferPointer { dst in
            for row in 0..<height {
                let srcRow = src + (y0 + row) * bytesPerRow + x0
                (dst.baseAddress! + row * width).update(from: srcRow, count: width)
            }
        }
        return (LumaImage(width: width, height: height, pixels: pixels), CGPoint(x: x0, y: y0))
    }

    /// 프레임의 눈 영역을 잘라 동공을 다시 찾는다. 결과가 눈 윤곽 경계 밖이면 원래 값을 유지한다.
    public static func refine(_ face: FaceMeasurement, buffer: CVPixelBuffer,
                              configuration: Configuration = .init()) -> FaceMeasurement {
        var refined = face
        refined.leftEye = face.leftEye.map { refine($0, imageSize: face.imageSize, buffer: buffer, configuration) }
        refined.rightEye = face.rightEye.map { refine($0, imageSize: face.imageSize, buffer: buffer, configuration) }
        return refined
    }

    private static func refine(_ eye: EyeMeasurement, imageSize: CGSize, buffer: CVPixelBuffer,
                               _ configuration: Configuration) -> EyeMeasurement {
        guard eye.contour.count >= 3 else { return eye }
        let pixels = eye.contour.map { CGPoint(x: $0.x * imageSize.width, y: $0.y * imageSize.height) }
        let bounds = boundingRect(pixels)
        let crop = bounds.insetBy(dx: -bounds.width * 0.15, dy: -bounds.height * 0.3)
        guard let (image, origin) = lumaCrop(buffer, rect: crop) else { return eye }
        let local = pixels.map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
        guard let found = locate(in: image, eyePolygon: local, configuration: configuration) else { return eye }
        let global = CGPoint(x: found.x + origin.x, y: found.y + origin.y)
        guard bounds.contains(global) else { return eye }
        var result = eye
        result.pupil = CGPoint(x: global.x / imageSize.width, y: global.y / imageSize.height)
        return result
    }

    static func boundingRect(_ points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        let minX = xs.min() ?? 0, minY = ys.min() ?? 0
        return CGRect(x: minX, y: minY, width: (xs.max() ?? 0) - minX, height: (ys.max() ?? 0) - minY)
    }
}
