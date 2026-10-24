import AgentContracts
import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import Gaze
import ImageIO
import UniformTypeIdentifiers
import Vision

// 카메라를 열지 않고 시선 파이프라인을 확인하는 도구.
//
//   swift run -c release GazeBench faces <image...>              Vision 얼굴 상자·눈 위치
//   swift run -c release GazeBench parity --out DIR <image...>   448 크롭 PNG + CoreML 출력 JSON(parity.py 입력)
//   swift run -c release GazeBench bench [--image P] [--frames N] [--units all|ane|gpu|cpu] [--size 1080|720]
//   swift run -c release GazeBench tune-filter                   One Euro·고정 안정화 매개변수 시뮬레이션
//
// 모델은 GAZE_MODEL_PATH 또는 ~/Library/Application Support/Gaze/Models/GazeEstimator.mlpackage에서 찾는다.

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "help"
let rest = Array(arguments.dropFirst())

func option(_ name: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func positional(_ args: [String], valued: Set<String>) -> [String] {
    var result: [String] = []
    var skip = false
    for arg in args {
        if skip { skip = false; continue }
        if valued.contains(arg) { skip = true; continue }
        if arg.hasPrefix("--") { continue }
        result.append(arg)
    }
    return result
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

// MARK: 이미지 ↔ 버퍼

func makeBGRABuffer(width: Int, height: Int) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
    guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer)
            == kCVReturnSuccess, let buffer else { fail("픽셀 버퍼 생성 실패") }
    return buffer
}

func loadImage(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("이미지를 읽을 수 없음: \(path)") }
    return image
}

/// 이미지를 BGRA 버퍼에 그린다(이미지 자체 색 공간을 써서 색 변환 없이 값 그대로). `canvas`가 있으면 그 크기 가운데에 배치.
func bgraBuffer(from image: CGImage, canvas: CGSize? = nil, scale: Double = 1) -> CVPixelBuffer {
    let width = Int(canvas?.width ?? CGFloat(image.width)), height = Int(canvas?.height ?? CGFloat(image.height))
    let buffer = makeBGRABuffer(width: width, height: height)
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: space.model == .rgb ? space : CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: info) else { fail("CGContext 생성 실패") }
    context.interpolationQuality = .high
    context.setFillColor(CGColor(red: 0.45, green: 0.45, blue: 0.45, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let w = Double(image.width) * scale, h = Double(image.height) * scale
    context.draw(image, in: CGRect(x: (Double(width) - w) / 2, y: (Double(height) - h) / 2, width: w, height: h))
    return buffer
}

func writePNG(_ buffer: CVPixelBuffer, to path: String) {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
    let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info),
          let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                            UTType.png.identifier as CFString, 1, nil)
    else { fail("PNG 저장 실패: \(path)") }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

/// BGRA → 420f(BT.709 full range) 변환. 420 샘플링 경로 검사용.
func yuv420Buffer(from bgra: CVPixelBuffer) -> CVPixelBuffer {
    let width = CVPixelBufferGetWidth(bgra), height = CVPixelBufferGetHeight(bgra)
    var created: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes,
                        &created)
    guard let yuv = created else { fail("420 버퍼 생성 실패") }
    CVBufferSetAttachment(yuv, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    CVPixelBufferLockBaseAddress(bgra, .readOnly)
    CVPixelBufferLockBaseAddress(yuv, [])
    defer { CVPixelBufferUnlockBaseAddress(yuv, []); CVPixelBufferUnlockBaseAddress(bgra, .readOnly) }
    let src = CVPixelBufferGetBaseAddress(bgra)!.assumingMemoryBound(to: UInt8.self)
    let srcStride = CVPixelBufferGetBytesPerRow(bgra)
    let yPlane = CVPixelBufferGetBaseAddressOfPlane(yuv, 0)!.assumingMemoryBound(to: UInt8.self)
    let yStride = CVPixelBufferGetBytesPerRowOfPlane(yuv, 0)
    let uvPlane = CVPixelBufferGetBaseAddressOfPlane(yuv, 1)!.assumingMemoryBound(to: UInt8.self)
    let uvStride = CVPixelBufferGetBytesPerRowOfPlane(yuv, 1)
    func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
        let p = src + y * srcStride + x * 4
        return (Double(p[2]), Double(p[1]), Double(p[0]))
    }
    for y in 0..<height {
        for x in 0..<width {
            let (r, g, b) = rgb(x, y)
            yPlane[y * yStride + x] = UInt8(clamping: Int((0.2126 * r + 0.7152 * g + 0.0722 * b).rounded()))
        }
    }
    for cy in 0..<(height / 2) {
        for cx in 0..<(width / 2) {
            var cb = 0.0, cr = 0.0
            for dy in 0..<2 {
                for dx in 0..<2 {
                    let (r, g, b) = rgb(cx * 2 + dx, cy * 2 + dy)
                    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    cb += (b - luma) / 1.8556
                    cr += (r - luma) / 1.5748
                }
            }
            uvPlane[cy * uvStride + cx * 2] = UInt8(clamping: Int((cb / 4 + 128).rounded()))
            uvPlane[cy * uvStride + cx * 2 + 1] = UInt8(clamping: Int((cr / 4 + 128).rounded()))
        }
    }
    return yuv
}

func pixelDifference(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> (max: Int, mean: Double) {
    CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
    let n = CVPixelBufferGetWidth(a)
    let pa = CVPixelBufferGetBaseAddress(a)!.assumingMemoryBound(to: UInt8.self)
    let pb = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self)
    let sa = CVPixelBufferGetBytesPerRow(a), sb = CVPixelBufferGetBytesPerRow(b)
    var maximum = 0, total = 0
    for y in 0..<n {
        for x in 0..<n {
            for c in 0..<3 {
                let d = abs(Int(pa[y * sa + x * 4 + c]) - Int(pb[y * sb + x * 4 + c]))
                maximum = max(maximum, d); total += d
            }
        }
    }
    return (maximum, Double(total) / Double(n * n * 3))
}

extension CGPoint {
    func gap(_ other: CGPoint) -> Double { Double(hypot(x - other.x, y - other.y)) }
}

func time(_ seconds: Double = 0) -> MonotonicTime { MonotonicTime(nanoseconds: UInt64(seconds * 1e9)) }

func computeUnits(_ name: String?) -> MLComputeUnits {
    switch name {
    case "ane": .cpuAndNeuralEngine
    case "gpu": .cpuAndGPU
    case "cpu": .cpuOnly
    default: .all
    }
}

func loadEstimator(units: MLComputeUnits, crop: FaceCropConfiguration?) async -> (CNNGazeEstimator, GazeModelStore.Loaded) {
    do {
        let loaded = try await GazeModelStore.load(computeUnits: units)
        var configuration = CNNGazeEstimator.Configuration()
        configuration.crop = crop
        return (CNNGazeEstimator(loaded: loaded, configuration: configuration), loaded)
    } catch {
        fail("모델 로드 실패: \(error)")
    }
}

func cropOverride(_ args: [String]) -> FaceCropConfiguration? {
    let defaults = FaceCropConfiguration()
    if let square = option("--crop-square", in: args).flatMap(Double.init) {
        return FaceCropConfiguration(scale: square, verticalOffset: option("--crop-offset", in: args).flatMap(Double.init) ?? 0)
    }
    let width = option("--crop-width", in: args).flatMap(Double.init)
    let height = option("--crop-height", in: args).flatMap(Double.init)
    let offset = option("--crop-offset", in: args).flatMap(Double.init)
    guard width != nil || height != nil || offset != nil else { return nil }
    return FaceCropConfiguration(widthScale: width ?? defaults.widthScale, heightScale: height ?? defaults.heightScale,
                                 verticalOffset: offset ?? defaults.verticalOffset)
}

func stats(_ values: [Double]) -> String {
    guard !values.isEmpty else { return "n/a" }
    let sorted = values.sorted()
    let mean = values.reduce(0, +) / Double(values.count)
    let p50 = sorted[sorted.count / 2], p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    return String(format: "mean %.2f · p50 %.2f · p95 %.2f ms", mean, p50, p95)
}

// MARK: 명령

func facesCommand(_ args: [String]) {
    var rows: [[String: Any]] = []
    for path in positional(args, valued: ["--json"]) {
        let buffer = bgraBuffer(from: loadImage(path))
        guard let face = VisionFaceAnalyzer.measure(pixelBuffer: buffer, time: time()) else {
            print("\(path): 얼굴 없음"); continue
        }
        let w = Double(face.imageSize.width), h = Double(face.imageSize.height)
        let box = face.boundingBox
        let pupils = [face.leftEye?.pupil, face.rightEye?.pupil].compactMap { $0 }
        let iod = pupils.count == 2 ? hypot(Double(pupils[0].x - pupils[1].x) * w, Double(pupils[0].y - pupils[1].y) * h) : 0
        let eye = CNNGazeEstimator.eyeCenterPixel(face)
        let boxPx = [Double(box.minX) * w, Double(box.minY) * h, Double(box.maxX) * w, Double(box.maxY) * h]
        print(String(format: "%@: box [%.0f %.0f %.0f %.0f] w %.0f h %.0f · eye y %.2f of box · IOD %.0f px · box/IOD %.2f · pose yaw %.1f° pitch %.1f°",
                     (path as NSString).lastPathComponent, boxPx[0], boxPx[1], boxPx[2], boxPx[3], boxPx[2] - boxPx[0],
                     boxPx[3] - boxPx[1], (Double(eye.y) - boxPx[1]) / (boxPx[3] - boxPx[1]), iod,
                     iod > 0 ? (boxPx[2] - boxPx[0]) / iod : 0,
                     (face.headPose?.yaw ?? 0) * 180 / .pi, (face.headPose?.pitch ?? 0) * 180 / .pi))
        var row: [String: Any] = ["image": path, "vision_box": boxPx, "eye_center": [Double(eye.x), Double(eye.y)], "iod": iod]
        if let c = face.landmarkCenter, let r = face.landmarkRadius {
            row["landmark_center"] = [Double(c.x) * w, Double(c.y) * h]
            row["landmark_radius"] = r
        }
        rows.append(row)
    }
    if let out = option("--json", in: args),
       let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: out))
    }
}

func parityCommand(_ args: [String]) async {
    guard let out = option("--out", in: args) else { fail("--out DIR 필요") }
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    let (estimator, loaded) = await loadEstimator(units: computeUnits(option("--units", in: args)), crop: cropOverride(args))
    let crop = cropOverride(args) ?? loaded.info.crop
    print("model \(loaded.info.arch) tta=\(loaded.info.testTimeFlip) crop w×\(crop.widthScale) h×\(crop.heightScale) dy \(crop.verticalOffset) (\(loaded.sourceURL.path))")
    var rows: [[String: Any]] = []
    for path in positional(args, valued: ["--out", "--units", "--crop-square", "--crop-width", "--crop-height", "--crop-offset"]) {
        let buffer = bgraBuffer(from: loadImage(path))
        guard let face = VisionFaceAnalyzer.measure(pixelBuffer: buffer, time: time()) else {
            print("\(path): 얼굴 없음"); continue
        }
        do {
            guard let detail = try estimator.estimateDetailed(GazeEstimatorInput(face: face, pixelBuffer: buffer),
                                                              stabilize: false) else {
                print("\(path): 추정 없음(눈 감김?)"); continue
            }
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            let cropPath = (out as NSString).appendingPathComponent("\(name)_swift_crop.png")
            writePNG(detail.crop, to: cropPath)
            // 420 경로: 같은 이미지를 420f로 바꿔 같은 크롭을 샘플링해 BGRA 경로와 비교.
            let yuv = yuv420Buffer(from: buffer)
            let crop420 = makeBGRABuffer(width: 448, height: 448)
            FaceCropSampler.sample(pixelBuffer: yuv, crop: detail.cropRect, into: crop420)
            let diff420 = pixelDifference(detail.crop, crop420)
            let angles420 = try estimator.predict(crop: crop420)
            let r = detail.cropRect
            let a = detail.angles
            print(String(format: "%@: yaw %+.2f° pitch %+.2f° spread %.1f°/%.1f° · %.1fms · 420 path Δpx max %d mean %.2f, Δyaw %.2f° Δpitch %.2f°",
                         name, a.yaw * 180 / .pi, a.pitch * 180 / .pi, a.yawSpread * 180 / .pi, a.pitchSpread * 180 / .pi,
                         detail.inferenceMilliseconds, diff420.max, diff420.mean,
                         abs(angles420.yaw - a.yaw) * 180 / .pi, abs(angles420.pitch - a.pitch) * 180 / .pi))
            var row: [String: Any] = [
                "image": path, "box": [r.minX, r.minY, r.maxX, r.maxY].map(Double.init), "crop_png": cropPath,
                "coreml": [a.yaw, a.pitch, a.yawSpread, a.pitchSpread],
                "vision_box": [face.boundingBox.minX * face.imageSize.width, face.boundingBox.minY * face.imageSize.height,
                               face.boundingBox.maxX * face.imageSize.width, face.boundingBox.maxY * face.imageSize.height]
                    .map(Double.init),
                "yuv420_max_pixel_diff": diff420.max, "yuv420_mean_pixel_diff": diff420.mean,
                "yuv420_coreml": [angles420.yaw, angles420.pitch],
            ]
            if let features = detail.features {
                row["plane_cm"] = [features.primary.x, features.primary.y]
            }
            rows.append(row)
        } catch {
            print("\(path): \(error)")
        }
    }
    let jsonPath = (out as NSString).appendingPathComponent("swift_parity.json")
    if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: URL(fileURLWithPath: jsonPath))
        print("→ \(jsonPath)")
    }
}

func benchCommand(_ args: [String]) async {
    let frames = option("--frames", in: args).flatMap(Int.init) ?? 200
    let size: CGSize = option("--size", in: args) == "720" ? CGSize(width: 1280, height: 720) : CGSize(width: 1920, height: 1080)
    guard let imagePath = option("--image", in: args) else { fail("--image 얼굴 이미지 필요") }
    let image = loadImage(imagePath)
    // 얼굴이 60cm 거리처럼 보이도록(얼굴 폭 ≈ 영상 폭 19%) 크기를 맞춘다.
    var scale = 1.0
    let probe = bgraBuffer(from: image)
    if let face = VisionFaceAnalyzer.measure(pixelBuffer: probe, time: time()) {
        let faceWidth = Double(face.boundingBox.width) * Double(image.width)
        scale = 0.19 * Double(size.width) / faceWidth
    }
    let frame = bgraBuffer(from: image, canvas: size, scale: scale)
    let units = computeUnits(option("--units", in: args))
    let started = Date()
    let (estimator, loaded) = await loadEstimator(units: units, crop: cropOverride(args))
    print(String(format: "model %@ (tta %@) load+compile %.2fs [%@], frame %.0fx%.0f, face scale %.2f",
                 loaded.info.arch, loaded.info.testTimeFlip ? "on" : "off", Date().timeIntervalSince(started),
                 option("--units", in: args) ?? "all", size.width, size.height, scale))
    var vision: [Double] = [], refine: [Double] = [], cnnTotal: [Double] = [], inference: [Double] = [], total: [Double] = []
    var yaw: [Double] = []
    for i in 0..<(frames + 10) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard var face = VisionFaceAnalyzer.measure(pixelBuffer: frame, time: time(Double(i) / 30)) else {
            fail("합성 프레임에서 얼굴을 찾지 못함")
        }
        let t1 = DispatchTime.now().uptimeNanoseconds
        face = PupilLocator.refine(face, buffer: frame)
        let t2 = DispatchTime.now().uptimeNanoseconds
        let detail = try? estimator.estimateDetailed(GazeEstimatorInput(face: face, pixelBuffer: frame))
        let t3 = DispatchTime.now().uptimeNanoseconds
        guard i >= 10 else { continue } // 워밍업
        vision.append(Double(t1 - t0) / 1e6)
        refine.append(Double(t2 - t1) / 1e6)
        cnnTotal.append(Double(t3 - t2) / 1e6)
        total.append(Double(t3 - t0) / 1e6)
        if let detail {
            inference.append(detail.inferenceMilliseconds)
            yaw.append(detail.angles.yaw * 180 / .pi)
        }
    }
    print("vision (rect+landmarks): \(stats(vision))")
    print("pupil refine:            \(stats(refine))")
    print("CNN inference only:      \(stats(inference))")
    print("crop+CNN+features:       \(stats(cnnTotal))")
    print("total per frame:         \(stats(total))  (budget 33.3 ms @30fps)")
    if let minimum = yaw.min(), let maximum = yaw.max() {
        print(String(format: "yaw range over identical frames: %.4f° (determinism)", maximum - minimum))
    }
}

/// 합성 시선(고정 + 사케이드 + 잡음)으로 One Euro·고정 안정화 매개변수를 비교한다.
func tuneFilterCommand(_ args: [String]) {
    struct Rng {
        var state: UInt64
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        mutating func gaussian() -> Double {
            (-2 * log(max(next(), 1e-12))).squareRoot() * cos(2 * .pi * next())
        }
    }
    let whiteNoise = option("--noise", in: args).flatMap(Double.init) ?? 40
    let driftNoise = 15.0, driftTau = 0.3, rate = 30.0
    let display = CGSize(width: 1512, height: 982)
    // 정답 시선 열: (시작 시각, 위치)
    var rng = Rng(state: 42)
    var fixations: [(start: Double, point: CGPoint)] = []
    var t = 0.0
    while t < 240 {
        fixations.append((t, CGPoint(x: 80 + rng.next() * (display.width - 160), y: 80 + rng.next() * (display.height - 160))))
        t += 0.4 + rng.next() * 1.6
    }
    let frames = Int(240 * rate)
    var measurements: [CGPoint] = [], truths: [CGPoint] = [], sinceStart: [Double] = [], fixationIndex: [Int] = []
    var drift = SIMD2<Double>(0, 0)
    var k = 0
    let a = exp(-1 / (rate * driftTau))
    for i in 0..<frames {
        let time = Double(i) / rate
        while k + 1 < fixations.count && fixations[k + 1].start <= time { k += 1 }
        drift = drift * a + SIMD2(rng.gaussian(), rng.gaussian()) * driftNoise * (1 - a * a).squareRoot()
        let truth = fixations[k].point
        truths.append(truth)
        sinceStart.append(time - fixations[k].start)
        fixationIndex.append(k)
        measurements.append(CGPoint(x: truth.x + rng.gaussian() * whiteNoise + drift.x,
                                    y: truth.y + rng.gaussian() * whiteNoise + drift.y))
    }
    struct Result { var label: String; var jitter: Double; var error: Double; var settle: Double; var config: String }
    func evaluate(_ filter: OneEuroParameters, stabilize: Bool) -> Result {
        var configuration = GazePipelineConfiguration()
        configuration.filter = filter
        configuration.stabilization.enabled = stabilize
        var pipeline = GazePipeline(configuration: configuration)
        var outputs: [CGPoint] = []
        for (i, m) in measurements.enumerated() {
            let sample = pipeline.processScreenPoint(m, displayID: 1, time: MonotonicTime(nanoseconds: UInt64(Double(i) / rate * 1e9)),
                                                     confidence: 0.9, calibrationRevision: 1, expectedError: 60).sample
            outputs.append(sample?.point ?? m)
        }
        // 고정 0.35초 이후 구간: 고정별 평균 대비 떨림, 정답 대비 오차. 사케이드 후 80pt 안에 드는 시간.
        var jitterSum = 0.0, jitterCount = 0, errorSum = 0.0
        var perFixation: [Int: [CGPoint]] = [:]
        for i in outputs.indices where sinceStart[i] >= 0.35 {
            perFixation[fixationIndex[i], default: []].append(outputs[i])
            errorSum += pow(outputs[i].gap(truths[i]), 2)
        }
        for (_, points) in perFixation where points.count >= 3 {
            let mx = points.reduce(0.0) { $0 + Double($1.x) } / Double(points.count)
            let my = points.reduce(0.0) { $0 + Double($1.y) } / Double(points.count)
            for p in points { jitterSum += pow(Double(p.x) - mx, 2) + pow(Double(p.y) - my, 2); jitterCount += 1 }
        }
        var settles: [Double] = []
        var i = 0
        while i < outputs.count {
            if i > 0, fixationIndex[i] != fixationIndex[i - 1] {
                var j = i
                while j < outputs.count, fixationIndex[j] == fixationIndex[i], outputs[j].gap(truths[j]) > 80 { j += 1 }
                if j < outputs.count, fixationIndex[j] == fixationIndex[i] { settles.append(Double(j - i) / rate) }
            }
            i += 1
        }
        settles.sort()
        let count = Double(max(1, outputs.indices.filter { sinceStart[$0] >= 0.35 }.count))
        return Result(label: "", jitter: (jitterSum / Double(max(jitterCount, 1))).squareRoot(),
                      error: (errorSum / count).squareRoot(), settle: settles.isEmpty ? .infinity : settles[settles.count / 2],
                      config: String(format: "minCutoff %.2f beta %.4f dCutoff %.1f stabilize %@", filter.minCutoff, filter.beta,
                                     filter.derivativeCutoff, stabilize ? "on" : "off"))
    }
    let raw = evaluate(OneEuroParameters(minCutoff: 1000, beta: 0, derivativeCutoff: 1), stabilize: false)
    print(String(format: "noise σ=%.0fpt white + %.0fpt drift. raw: jitter %.1fpt error %.1fpt", whiteNoise, driftNoise, raw.jitter, raw.error))
    let current = evaluate(OneEuroParameters(minCutoff: 0.8, beta: 0.004, derivativeCutoff: 1.0), stabilize: false)
    print(String(format: "previous default: jitter %.1f error %.1f settle %.3fs  (%@)", current.jitter, current.error, current.settle, current.config))
    var results: [Result] = []
    for minCutoff in [0.2, 0.3, 0.5, 0.8, 1.2] {
        for beta in [0.0003, 0.0007, 0.0015, 0.003, 0.006] {
            for dCutoff in [0.5, 1.0] {
                for stabilize in [false, true] {
                    results.append(evaluate(OneEuroParameters(minCutoff: minCutoff, beta: beta, derivativeCutoff: dCutoff),
                                            stabilize: stabilize))
                }
            }
        }
    }
    let maxSettle = option("--max-settle", in: args).flatMap(Double.init) ?? 0.2
    let feasible = results.filter { $0.settle <= maxSettle }.sorted { $0.jitter + 0.5 * $0.error < $1.jitter + 0.5 * $1.error }
    print("best with median settle ≤ \(maxSettle)s (score = jitter + 0.5·error):")
    for r in feasible.prefix(12) {
        print(String(format: "  jitter %5.1f  error %5.1f  settle %.3fs  %@", r.jitter, r.error, r.settle, r.config))
    }
}

/// 같은 프레임에 센서 잡음(σ, 8비트 단계)을 섞어 Vision 정렬 단서(상자·눈 중심·IOD)의 떨림을 잰다.
func jitterCommand(_ args: [String]) {
    guard let imagePath = option("--image", in: args) else { fail("--image 필요") }
    let runs = option("--runs", in: args).flatMap(Int.init) ?? 30
    let sigma = option("--noise", in: args).flatMap(Double.init) ?? 2
    let image = loadImage(imagePath)
    let size = CGSize(width: 1920, height: 1080)
    let probe = bgraBuffer(from: image)
    var scale = 1.0
    if let face = VisionFaceAnalyzer.measure(pixelBuffer: probe, time: time()) {
        scale = 0.19 * Double(size.width) / (Double(face.boundingBox.width) * Double(image.width))
    }
    let clean = bgraBuffer(from: image, canvas: size, scale: scale)
    struct Rng {
        var state: UInt64
        mutating func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
        }
        mutating func gaussian() -> Double { (-2 * log(max(next(), 1e-12))).squareRoot() * cos(2 * .pi * next()) }
    }
    var rng = Rng(state: 7)
    var boxCX: [Double] = [], boxCY: [Double] = [], boxW: [Double] = []
    var eyeCX: [Double] = [], eyeCY: [Double] = [], iod: [Double] = [], allCX: [Double] = [], allCY: [Double] = []
    var rectMs: [Double] = [], landmarkMs: [Double] = [], trackedMs: [Double] = []
    var trackedPitch: [Double] = []
    let w = Double(size.width), h = Double(size.height)
    for _ in 0..<runs {
        let noisy = makeBGRABuffer(width: Int(size.width), height: Int(size.height))
        CVPixelBufferLockBaseAddress(clean, .readOnly); CVPixelBufferLockBaseAddress(noisy, [])
        let src = CVPixelBufferGetBaseAddress(clean)!.assumingMemoryBound(to: UInt8.self)
        let dst = CVPixelBufferGetBaseAddress(noisy)!.assumingMemoryBound(to: UInt8.self)
        let bytes = CVPixelBufferGetBytesPerRow(clean) * Int(size.height)
        for k in 0..<bytes {
            dst[k] = k % 4 == 3 ? 255 : UInt8(clamping: Int((Double(src[k]) + rng.gaussian() * sigma).rounded()))
        }
        CVPixelBufferUnlockBaseAddress(noisy, []); CVPixelBufferUnlockBaseAddress(clean, .readOnly)
        let t0 = DispatchTime.now().uptimeNanoseconds
        let handler = VNImageRequestHandler(cvPixelBuffer: noisy, orientation: .up, options: [:])
        let rectangles = VNDetectFaceRectanglesRequest()
        rectangles.revision = VNDetectFaceRectanglesRequestRevision3
        try? handler.perform([rectangles])
        let t1 = DispatchTime.now().uptimeNanoseconds
        guard let face = rectangles.results?.first else { continue }
        let landmarks = VNDetectFaceLandmarksRequest()
        landmarks.revision = VNDetectFaceLandmarksRequestRevision3
        landmarks.inputFaceObservations = [face]
        try? handler.perform([landmarks])
        let t2 = DispatchTime.now().uptimeNanoseconds
        // 이전 상자만으로 랜드마크(검출 생략) — 추적 모드 비용과 자세 정보 확인.
        let handler2 = VNImageRequestHandler(cvPixelBuffer: noisy, orientation: .up, options: [:])
        let tracked = VNDetectFaceLandmarksRequest()
        tracked.revision = VNDetectFaceLandmarksRequestRevision3
        tracked.inputFaceObservations = [VNFaceObservation(boundingBox: face.boundingBox)]
        try? handler2.perform([tracked])
        let t3 = DispatchTime.now().uptimeNanoseconds
        rectMs.append(Double(t1 - t0) / 1e6); landmarkMs.append(Double(t2 - t1) / 1e6); trackedMs.append(Double(t3 - t2) / 1e6)
        if let pitch = tracked.results?.first?.pitch?.doubleValue { trackedPitch.append(pitch) }
        guard let observed = landmarks.results?.first, let lm = observed.landmarks else { continue }
        let box = observed.boundingBox
        boxCX.append(Double(box.midX) * w); boxCY.append((1 - Double(box.midY)) * h); boxW.append(Double(box.width) * w)
        func centroid(_ region: VNFaceLandmarkRegion2D?) -> (Double, Double)? {
            guard let points = region?.pointsInImage(imageSize: size), !points.isEmpty else { return nil }
            return (points.reduce(0.0) { $0 + Double($1.x) } / Double(points.count),
                    h - points.reduce(0.0) { $0 + Double($1.y) } / Double(points.count))
        }
        if let l = centroid(lm.leftEye), let r = centroid(lm.rightEye) {
            eyeCX.append((l.0 + r.0) / 2); eyeCY.append((l.1 + r.1) / 2); iod.append(hypot(l.0 - r.0, l.1 - r.1))
        }
        if let all = centroid(lm.allPoints) { allCX.append(all.0); allCY.append(all.1) }
    }
    func sd(_ v: [Double]) -> Double {
        guard v.count > 1 else { return .nan }
        let m = v.reduce(0, +) / Double(v.count)
        return (v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count - 1)).squareRoot()
    }
    let size0 = boxW.reduce(0, +) / Double(max(boxW.count, 1))
    print(String(format: "noise σ=%.1f, %d runs, box width %.0f px (1080p)", sigma, boxW.count, size0))
    print(String(format: "Vision box center sd x %.2f y %.2f px (%.2f%% / %.2f%% of box), width sd %.2f px (%.2f%%)",
                 sd(boxCX), sd(boxCY), 100 * sd(boxCX) / size0, 100 * sd(boxCY) / size0, sd(boxW), 100 * sd(boxW) / size0))
    print(String(format: "eye midpoint sd x %.2f y %.2f px (%.2f%% / %.2f%%), IOD sd %.2f px (%.2f%% of IOD %.0f)",
                 sd(eyeCX), sd(eyeCY), 100 * sd(eyeCX) / size0, 100 * sd(eyeCY) / size0, sd(iod),
                 100 * sd(iod) / (iod.reduce(0, +) / Double(max(iod.count, 1))), iod.reduce(0, +) / Double(max(iod.count, 1))))
    print(String(format: "all-landmark centroid sd x %.2f y %.2f px (%.2f%% / %.2f%%)", sd(allCX), sd(allCY),
                 100 * sd(allCX) / size0, 100 * sd(allCY) / size0))
    // 반 해상도 프레임에서 얼굴 상자(+자세)만 검출 → 전체 해상도 랜드마크.
    let half = bgraBuffer(from: image, canvas: CGSize(width: size.width / 2, height: size.height / 2), scale: scale / 2)
    var halfMs: [Double] = [], halfPose = 0, halfBoxDiff: [Double] = []
    for _ in 0..<runs {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        try? VNImageRequestHandler(cvPixelBuffer: half, orientation: .up, options: [:]).perform([request])
        halfMs.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
        if let face = request.results?.first {
            if face.pitch != nil { halfPose += 1 }
            halfBoxDiff.append(abs(Double(face.boundingBox.midX) * w - (boxCX.first ?? 0)))
        }
    }
    print("timing rectangles @960x540: \(stats(halfMs)), pose \(halfPose)/\(runs), |Δcenter x| vs 1080p \(String(format: "%.1f", halfBoxDiff.first ?? -1)) px")
    print("timing rectangles: \(stats(rectMs)); landmarks(given face): \(stats(landmarkMs)); landmarks from bare box: \(stats(trackedMs)); tracked pitch available: \(trackedPitch.count)/\(runs)")
}

switch command {
case "jitter": jitterCommand(rest)
case "faces": facesCommand(rest)
case "parity": await parityCommand(rest)
case "bench": await benchCommand(rest)
case "tune-filter": tuneFilterCommand(rest)
default:
    print("""
    GazeBench — 카메라 없이 시선 파이프라인 확인
      faces <image...> [--json out.json]
      parity --out DIR [--units all|ane|gpu|cpu] [--crop-width W --crop-height H --crop-offset O | --crop-square S] <image...>
      bench --image face.jpg [--frames 200] [--units all|ane|gpu|cpu] [--size 1080|720]
      tune-filter [--noise 40] [--max-settle 0.2]
    """)
}
