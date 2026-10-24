import CoreGraphics
import CoreVideo
import Foundation

/// 얼굴 상자 → CNN 입력 크롭 규칙.
///
/// 저장소 추론(yakhyo/gaze-estimation `onnx_inference.py`)은 RetinaFace 얼굴 상자를 그대로 잘라 448×448로 늘린다
/// (가로세로 비율 무시). Vision 얼굴 상자는 정사각형이고 RetinaFace보다 넓고 아래로 치우쳐 있어서,
/// 표본 16장에서 잰 대응 관계(폭 ×0.85, 높이 ×1.19, 중심 위로 0.10×높이)로 RetinaFace 상자를 흉내 낸다.
/// 모델 메타데이터(`gaze.cropWidthScale` 등)가 있으면 그 값을 쓴다.
public struct FaceCropConfiguration: Sendable, Equatable, Codable {
    /// 크롭 폭 = Vision 상자 폭 × widthScale.
    public var widthScale: Double
    /// 크롭 높이 = Vision 상자 높이 × heightScale.
    public var heightScale: Double
    /// 크롭 중심의 세로 이동(Vision 상자 높이 비율, 양수 = 아래).
    public var verticalOffset: Double
    public var outputSize: Int

    public init(widthScale: Double = 0.85, heightScale: Double = 1.19, verticalOffset: Double = -0.10,
                outputSize: Int = 448) {
        self.widthScale = widthScale; self.heightScale = heightScale; self.verticalOffset = verticalOffset
        self.outputSize = outputSize
    }

    /// 정사각형(같은 배율) 규칙.
    public init(scale: Double, verticalOffset: Double, outputSize: Int = 448) {
        self.init(widthScale: scale, heightScale: scale, verticalOffset: verticalOffset, outputSize: outputSize)
    }
}

/// 크롭 정렬 기준: 중심(픽셀)과 'Vision 상자 한 변에 해당하는 길이'(픽셀).
public struct FaceAlignment: Sendable, Equatable {
    public var center: CGPoint
    public var side: Double
    public init(center: CGPoint, side: Double) { self.center = center; self.side = side }
}

public enum FaceCropGeometry {
    /// Vision 상자 한 변 ≈ 랜드마크 RMS 반경 × 3.15(표본 16장 평균, 변동 2.5%). 상자 중심 ≈ 랜드마크 무게중심.
    public static let landmarkSideRatio = 3.15

    /// 정렬 기준. 랜드마크(76점 무게중심·RMS 반경)가 있으면 그것을, 없으면 Vision 상자를 쓴다.
    /// 랜드마크 무게중심은 센서 잡음에서 상자 중심보다 3–4배 덜 흔들린다(0.1% vs 0.3–0.4%, GazeBench jitter).
    public static func alignment(face: FaceMeasurement) -> FaceAlignment {
        let w = Double(face.imageSize.width), h = Double(face.imageSize.height)
        if let center = face.landmarkCenter, let radius = face.landmarkRadius, radius > 1 {
            return FaceAlignment(center: CGPoint(x: Double(center.x) * w, y: Double(center.y) * h),
                                 side: radius * landmarkSideRatio)
        }
        let box = face.boundingBox
        return FaceAlignment(center: CGPoint(x: Double(box.midX) * w, y: Double(box.midY) * h),
                             side: max(Double(box.width) * w, Double(box.height) * h))
    }

    /// 정렬 기준 → 픽셀 크롭 사각형(실수, 좌상단 원점). 영상 밖으로 나가도 자르지 않는다(샘플러가 가장자리를 반복).
    public static func cropRect(alignment: FaceAlignment, configuration: FaceCropConfiguration) -> CGRect {
        let side = alignment.side
        let width = side * configuration.widthScale, height = side * configuration.heightScale
        let cx = Double(alignment.center.x)
        let cy = Double(alignment.center.y) + configuration.verticalOffset * side
        return CGRect(x: cx - width / 2, y: cy - height / 2, width: width, height: height)
    }

    /// 정규화 얼굴 상자(좌상단 원점) → 픽셀 크롭 사각형. Vision 상자가 정사각형이 아니면 긴 변 기준.
    public static func cropRect(faceBox: CGRect, imageSize: CGSize, configuration: FaceCropConfiguration) -> CGRect {
        let w = Double(faceBox.width * imageSize.width), h = Double(faceBox.height * imageSize.height)
        let alignment = FaceAlignment(center: CGPoint(x: Double(faceBox.midX * imageSize.width),
                                                      y: Double(faceBox.midY * imageSize.height)), side: max(w, h))
        return cropRect(alignment: alignment, configuration: configuration)
    }
}

/// 크롭 정렬 떨림 억제(One Euro, 픽셀 단위). CNN 출력은 크롭이 얼굴에 대해 0.5%(약 2px)만 어긋나도 2–5° 바뀌므로
/// 크롭은 얼굴을 정확히 따라가야 한다(고정해 두면 머리 미세 움직임이 그대로 시선 오차가 된다).
/// 정지 시에는 강하게 평균하고, 움직이면 차단 주파수를 올려 지연(=정렬 오차)을 줄인다.
public struct AlignmentFilter: Sendable {
    public struct Configuration: Sendable, Equatable {
        public var minCutoff = 1.0
        /// (px/s)당 Hz.
        public var beta = 0.2
        public var derivativeCutoff = 1.0
        /// 이보다 긴 공백 뒤에는 새로 시작한다(초).
        public var resetAfter = 0.5
        public init() {}
    }

    public var configuration: Configuration
    private var x: OneEuroFilter
    private var y: OneEuroFilter
    private var side: OneEuroFilter
    private var lastTime: Double?

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        let parameters = OneEuroParameters(minCutoff: configuration.minCutoff, beta: configuration.beta,
                                           derivativeCutoff: configuration.derivativeCutoff)
        x = OneEuroFilter(parameters: parameters)
        y = OneEuroFilter(parameters: parameters)
        side = OneEuroFilter(parameters: parameters)
    }

    public mutating func reset() {
        x.reset(); y.reset(); side.reset(); lastTime = nil
    }

    public mutating func update(_ alignment: FaceAlignment, at time: Double) -> FaceAlignment {
        if let lastTime, time - lastTime > configuration.resetAfter || time < lastTime { reset() }
        lastTime = time
        return FaceAlignment(center: CGPoint(x: x.filter(Double(alignment.center.x), at: time),
                                             y: y.filter(Double(alignment.center.y), at: time)),
                             side: side.filter(alignment.side, at: time))
    }
}

/// 크롭 + 쌍선형 리샘플링. Python 기준 구현(`scripts/gaze_model/common.py` `crop_resize`)과 같은 규칙:
/// 출력 (열 j, 행 i)의 원본 좌표 sx = x0 + (j + 0.5)·w/N − 0.5, sy = y0 + (i + 0.5)·h/N − 0.5,
/// 좌표를 [0, W−1]·[0, H−1]로 자른 뒤 쌍선형 보간, 반올림(floor(v + 0.5)).
public enum FaceCropSampler {
    /// 축 하나의 표본 위치(왼쪽 인덱스, 오른쪽 인덱스, 오른쪽 가중치).
    struct Taps {
        var lower: [Int]
        var upper: [Int]
        var fraction: [Float]

        init(origin: Double, length: Double, count: Int, limit: Int) {
            lower = [Int](repeating: 0, count: count)
            upper = [Int](repeating: 0, count: count)
            fraction = [Float](repeating: 0, count: count)
            let step = length / Double(count)
            let maxIndex = Double(max(limit - 1, 0))
            for k in 0..<count {
                let s = clamp(origin + (Double(k) + 0.5) * step - 0.5, 0, maxIndex)
                let i0 = Int(s.rounded(.down))
                lower[k] = i0
                upper[k] = min(i0 + 1, limit - 1)
                fraction[k] = Float(s - Double(i0))
            }
        }
    }

    /// 인터리브 8비트 영상(채널 순서 그대로) → N×N 크롭. 첫 3채널을 보간하고 4번째 채널은 255로 채운다.
    /// `bytesPerPixel`은 3 또는 4.
    public static func resample(source: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int,
                                bytesPerPixel: Int, crop: CGRect, outputSize n: Int,
                                destination: UnsafeMutablePointer<UInt8>, destinationBytesPerRow: Int,
                                destinationBytesPerPixel: Int = 4) {
        let xs = Taps(origin: Double(crop.minX), length: Double(crop.width), count: n, limit: width)
        let ys = Taps(origin: Double(crop.minY), length: Double(crop.height), count: n, limit: height)
        for i in 0..<n {
            let row0 = source + ys.lower[i] * bytesPerRow
            let row1 = source + ys.upper[i] * bytesPerRow
            let fy = ys.fraction[i], gy = 1 - fy
            let out = destination + i * destinationBytesPerRow
            for j in 0..<n {
                let a = xs.lower[j] * bytesPerPixel, b = xs.upper[j] * bytesPerPixel
                let fx = xs.fraction[j], gx = 1 - fx
                let o = j * destinationBytesPerPixel
                for c in 0..<3 {
                    let top = gx * Float(row0[a + c]) + fx * Float(row0[b + c])
                    let bottom = gx * Float(row1[a + c]) + fx * Float(row1[b + c])
                    out[o + c] = UInt8(gy * top + fy * bottom + 0.5)
                }
                if destinationBytesPerPixel == 4 { out[o + 3] = 255 }
            }
        }
    }

    /// 배열 버전(검사·도구용). 결과는 N×N×4(첫 3채널 보간, 4번째 255).
    public static func resample(pixels: [UInt8], width: Int, height: Int, bytesPerPixel: Int, crop: CGRect,
                                outputSize n: Int) -> [UInt8] {
        precondition(pixels.count >= width * height * bytesPerPixel)
        var output = [UInt8](repeating: 0, count: n * n * 4)
        pixels.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                resample(source: src.baseAddress!, width: width, height: height, bytesPerRow: width * bytesPerPixel,
                         bytesPerPixel: bytesPerPixel, crop: crop, outputSize: n, destination: dst.baseAddress!,
                         destinationBytesPerRow: n * 4)
            }
        }
        return output
    }

    /// YCbCr → RGB 행렬 계수.
    struct YCbCrMatrix: Equatable {
        var crToR: Float, cbToG: Float, crToG: Float, cbToB: Float
        static let bt601 = YCbCrMatrix(crToR: 1.402, cbToG: 0.344136, crToG: 0.714136, cbToB: 1.772)
        static let bt709 = YCbCrMatrix(crToR: 1.5748, cbToG: 0.187324, crToG: 0.468124, cbToB: 1.8556)
    }

    /// 카메라 버퍼(32BGRA 또는 420 bi-planar) → 32BGRA N×N 버퍼. 지원하지 않는 형식이면 false.
    @discardableResult
    public static func sample(pixelBuffer: CVPixelBuffer, crop: CGRect, into output: CVPixelBuffer) -> Bool {
        let n = CVPixelBufferGetWidth(output)
        guard n == CVPixelBufferGetHeight(output), CVPixelBufferGetPixelFormatType(output) == kCVPixelFormatType_32BGRA
        else { return false }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])
        defer {
            CVPixelBufferUnlockBaseAddress(output, [])
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        guard let dst = CVPixelBufferGetBaseAddress(output)?.assumingMemoryBound(to: UInt8.self) else { return false }
        let dstStride = CVPixelBufferGetBytesPerRow(output)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        switch format {
        case kCVPixelFormatType_32BGRA:
            guard let src = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else { return false }
            resample(source: src, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer),
                     bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), bytesPerPixel: 4, crop: crop, outputSize: n,
                     destination: dst, destinationBytesPerRow: dstStride)
            return true
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard let y = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)?.assumingMemoryBound(to: UInt8.self),
                  let uv = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)?.assumingMemoryBound(to: UInt8.self)
            else { return false }
            let matrix = Self.matrix(of: pixelBuffer)
            resample420(luma: y, lumaWidth: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                        lumaHeight: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
                        lumaStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
                        chroma: uv, chromaWidth: CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
                        chromaHeight: CVPixelBufferGetHeightOfPlane(pixelBuffer, 1),
                        chromaStride: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1),
                        fullRange: format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, matrix: matrix,
                        crop: crop, outputSize: n, destination: dst, destinationBytesPerRow: dstStride)
            return true
        default:
            return false
        }
    }

    static func matrix(of buffer: CVPixelBuffer) -> YCbCrMatrix {
        guard let value = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) else { return .bt709 }
        if CFEqual(value, kCVImageBufferYCbCrMatrix_ITU_R_601_4) { return .bt601 }
        return .bt709
    }

    /// 420 bi-planar → BGRA. 밝기는 같은 규칙으로, 색차는 반 해상도 평면에서 중심 정렬 좌표로 보간한다.
    static func resample420(luma: UnsafePointer<UInt8>, lumaWidth: Int, lumaHeight: Int, lumaStride: Int,
                            chroma: UnsafePointer<UInt8>, chromaWidth: Int, chromaHeight: Int, chromaStride: Int,
                            fullRange: Bool, matrix: YCbCrMatrix, crop: CGRect, outputSize n: Int,
                            destination: UnsafeMutablePointer<UInt8>, destinationBytesPerRow: Int) {
        let xs = Taps(origin: Double(crop.minX), length: Double(crop.width), count: n, limit: lumaWidth)
        let ys = Taps(origin: Double(crop.minY), length: Double(crop.height), count: n, limit: lumaHeight)
        // 색차 표본 k의 중심은 밝기 좌표 2k + 0.5이므로 c = (s − 0.5)/2 = x0/2 + (j + 0.5)·(w/2)/N − 0.5.
        let cxs = Taps(origin: Double(crop.minX) / 2, length: Double(crop.width) / 2, count: n, limit: chromaWidth)
        let cys = Taps(origin: Double(crop.minY) / 2, length: Double(crop.height) / 2, count: n, limit: chromaHeight)
        let yScale: Float = fullRange ? 1 : 255 / 219, yOffset: Float = fullRange ? 0 : 16
        let cScale: Float = fullRange ? 1 : 255 / 224
        for i in 0..<n {
            let l0 = luma + ys.lower[i] * lumaStride, l1 = luma + ys.upper[i] * lumaStride
            let c0 = chroma + cys.lower[i] * chromaStride, c1 = chroma + cys.upper[i] * chromaStride
            let fy = ys.fraction[i], cfy = cys.fraction[i]
            let out = destination + i * destinationBytesPerRow
            for j in 0..<n {
                let a = xs.lower[j], b = xs.upper[j], fx = xs.fraction[j]
                let top = (1 - fx) * Float(l0[a]) + fx * Float(l0[b])
                let bottom = (1 - fx) * Float(l1[a]) + fx * Float(l1[b])
                let yv = ((1 - fy) * top + fy * bottom - yOffset) * yScale
                let ca = cxs.lower[j] * 2, cb = cxs.upper[j] * 2, cfx = cxs.fraction[j]
                func chromaAt(_ k: Int) -> Float {
                    let t = (1 - cfx) * Float(c0[ca + k]) + cfx * Float(c0[cb + k])
                    let u = (1 - cfx) * Float(c1[ca + k]) + cfx * Float(c1[cb + k])
                    return ((1 - cfy) * t + cfy * u - 128) * cScale
                }
                let cbv = chromaAt(0), crv = chromaAt(1)
                let r = yv + matrix.crToR * crv
                let g = yv - matrix.cbToG * cbv - matrix.crToG * crv
                let bl = yv + matrix.cbToB * cbv
                let o = j * 4
                // 255.5는 0 쪽으로 잘려 255가 된다.
                out[o] = UInt8(clamp(bl, 0, 255) + 0.5)
                out[o + 1] = UInt8(clamp(g, 0, 255) + 0.5)
                out[o + 2] = UInt8(clamp(r, 0, 255) + 0.5)
                out[o + 3] = 255
            }
        }
    }
}
