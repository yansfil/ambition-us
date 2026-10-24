import AgentContracts
import CoreGraphics
import CoreVideo
import Foundation
import Gaze
import Synchronization

func gazeChecks() async {
    await suite("Gaze · OneEuro") { oneEuroChecks() }
    await suite("Gaze · Calibration") { try calibrationChecks() }
    await suite("Gaze · Fixation") { fixationChecks() }
    await suite("Gaze · Cues") { cueChecks() }
    await suite("Gaze · Pipeline") { try pipelineChecks() }
    await suite("Gaze · Estimators") { estimatorChecks() }
    await suite("Gaze · Sources") { try await sourceChecks() }
    await suite("Gaze · Frames") { frameChecks() }
    await suite("Gaze · Geometry") { geometryChecks() }
    await suite("Gaze · CNN preprocessing") { cnnPreprocessingChecks() }
    await suite("Gaze · CNN decode") { cnnDecodeChecks() }
    await suite("Gaze · Calibration v2") { try calibrationV2Checks() }
    await suite("Gaze · Validation") { try validationChecks() }
    await suite("Gaze · Implicit calibration") { try implicitChecks() }
    await suite("Gaze · Head guidance") { headGuidanceChecks() }
    await suite("Gaze · Stability") { try stabilityChecks() }
}

/// 카메라 없이 합성 420f 버퍼로 Vision 요청 경로와 밝기 평면 읽기를 실행한다.
private func frameChecks() {
    let width = 640, height = 480
    var created: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                     [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &created)
    guard status == kCVReturnSuccess, let buffer = created else {
        check(false, "합성 픽셀 버퍼 생성")
        return
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    for plane in 0..<2 {
        let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt8.self)
        let rows = CVPixelBufferGetHeightOfPlane(buffer, plane), stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
        for row in 0..<rows {
            for column in 0..<stride { base[row * stride + column] = plane == 0 ? UInt8((column + row) % 256) : 128 }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])

    let crop = PupilLocator.lumaCrop(buffer, rect: CGRect(x: 100, y: 50, width: 20, height: 10))
    check(crop.map { $0.image.width == 20 && $0.image.height == 10 && $0.image[3, 2] == UInt8((103 + 52) % 256) } ?? false,
          "Y 평면 부분 복사 좌표")
    check(PupilLocator.lumaCrop(buffer, rect: CGRect(x: 638, y: 478, width: 20, height: 20)) == nil, "가장자리 밖 크롭 → nil")
    check(VisionFaceAnalyzer.measure(pixelBuffer: buffer, time: mt(0)) == nil, "얼굴 없는 프레임 → Vision 측정 nil(크래시 없음)")
}

// MARK: - 도우미

private func mt(_ seconds: Double) -> MonotonicTime {
    MonotonicTime(nanoseconds: UInt64((seconds * 1_000_000_000).rounded()))
}

private func secs(_ t: MonotonicTime) -> Double { Double(t.nanoseconds) / 1_000_000_000 }

private func dist(_ a: CGPoint, _ b: CGPoint) -> Double { Double(hypot(a.x - b.x, a.y - b.y)) }

/// 재현 가능한 난수(SplitMix64) + Box-Muller 가우시안.
private struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func gaussian(_ sigma: Double = 1) -> Double {
        let u1 = max(uniform(), 1e-12), u2 = uniform()
        return sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

private final class ManualClock: MonotonicClock {
    private let current = Mutex<UInt64>(0)
    func set(_ seconds: Double) { current.withLock { $0 = UInt64(seconds * 1_000_000_000) } }
    func now() -> MonotonicTime { MonotonicTime(nanoseconds: current.withLock { $0 }) }
}

private let mainDisplay = DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
private let sideDisplay = DisplayGeometry(id: 2, frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080))

/// 합성 정답 매핑(2차 + 머리 자세 선형 항), 디스플레이 로컬 좌표.
private func truth(_ f: GazeFeatures) -> CGPoint {
    let ex = f.primary.x, ey = f.primary.y, yaw = f.auxiliary[0], pitch = f.auxiliary[1]
    return CGPoint(x: 756 + 900 * ex + 120 * ex * ex + 60 * ex * ey + 300 * yaw,
                   y: 491 + 700 * ey - 90 * ey * ey + 250 * pitch)
}

private func features(ex: Double, ey: Double, at t: Double = 0, rng: inout SeededRandom,
                      eyeNoise: Double = 0.01, headPose: HeadPose? = nil) -> GazeFeatures {
    GazeFeatures(time: mt(t), primary: SIMD2(ex + rng.gaussian(eyeNoise), ey + rng.gaussian(eyeNoise)),
                 auxiliary: [rng.gaussian(0.005), rng.gaussian(0.005), 0.5 + rng.gaussian(0.002),
                             0.45 + rng.gaussian(0.002), 0.3 + rng.gaussian(0.001)],
                 headPose: headPose, confidence: 0.9)
}

/// 표적마다 평균 특징 → 정답 위치를 표적으로, 잡음 섞인 특징을 표본으로 만든다.
private func syntheticSamples(grid: [Double], gridY: [Double], perTarget: Int = 25, display: DisplayGeometry = mainDisplay,
                              seed: UInt64 = 7) -> [CalibrationSample] {
    var rng = SeededRandom(seed: seed)
    var samples: [CalibrationSample] = []
    for ey in gridY {
        for ex in grid {
            let mean = GazeFeatures(time: mt(0), primary: SIMD2(ex, ey), auxiliary: [0, 0, 0.5, 0.45, 0.3])
            let local = truth(mean)
            let target = CGPoint(x: local.x + display.frame.minX, y: local.y + display.frame.minY)
            for k in 0..<perTarget {
                samples.append(CalibrationSample(features: features(ex: ex, ey: ey, at: Double(k) / 30, rng: &rng),
                                                 target: target))
            }
        }
    }
    return samples
}

private func heldOutError(_ model: CalibrationModel, ex: Double, ey: Double) -> Double {
    let f = GazeFeatures(time: mt(0), primary: SIMD2(ex, ey), auxiliary: [0, 0, 0.5, 0.45, 0.3])
    guard let predicted = model.predictLocal(f) else { return .infinity }
    return dist(predicted, truth(f))
}

// MARK: - One Euro

private func oneEuroChecks() {
    var constant = OneEuroFilter(parameters: .init(minCutoff: 1, beta: 0.01))
    let constantOK = (0..<120).allSatisfy { abs(constant.filter(5, at: Double($0) / 60) - 5) < 1e-12 }
    check(constantOK, "상수 입력은 그대로 통과")

    var rng = SeededRandom(seed: 1)
    var noisy = OneEuroFilter(parameters: .init(minCutoff: 1, beta: 0))
    var inputs: [Double] = [], outputs: [Double] = []
    for i in 0..<600 {
        let x = 100 + rng.gaussian(10)
        let y = noisy.filter(x, at: Double(i) / 60)
        if i >= 60 { inputs.append(x); outputs.append(y) }
    }
    func std(_ v: [Double]) -> Double {
        let m = v.reduce(0, +) / Double(v.count)
        return (v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count)).squareRoot()
    }
    check(std(outputs) < 0.35 * std(inputs), "정지 잡음 표준편차 감소 (\(String(format: "%.2f", std(outputs))) < 0.35×\(String(format: "%.2f", std(inputs))))")

    func settleTime(beta: Double) -> Double {
        var f = OneEuroFilter(parameters: .init(minCutoff: 1, beta: beta))
        for i in 0..<60 { _ = f.filter(0, at: Double(i) / 60) }
        for i in 60..<300 where abs(f.filter(500, at: Double(i) / 60) - 500) < 50 { return Double(i - 60) / 60 }
        return .infinity
    }
    let slow = settleTime(beta: 0), fast = settleTime(beta: OneEuroParameters().beta)
    check(fast < slow, "beta가 크면 계단 응답 지연 감소 (\(String(format: "%.3f", fast))s < \(String(format: "%.3f", slow))s)")

    var duplicate = OneEuroFilter()
    _ = duplicate.filter(1, at: 1)
    check(duplicate.filter(100, at: 1) == 1, "같은 시각 입력은 이전 출력 유지")

    var planar = OneEuroFilter2D(parameters: .init(minCutoff: 1, beta: 0))
    var rawSpread = 0.0, filteredSpread = 0.0
    for i in 0..<600 {
        let p = CGPoint(x: 300 + rng.gaussian(20), y: 200 + rng.gaussian(20))
        let q = planar.filter(p, at: Double(i) / 60)
        if i >= 60 {
            rawSpread += dist(p, CGPoint(x: 300, y: 200))
            filteredSpread += dist(q, CGPoint(x: 300, y: 200))
        }
    }
    check(filteredSpread < 0.4 * rawSpread, "2D 필터 정지 떨림 감소")
}

// MARK: - 보정

private func calibrationChecks() throws {
    let nine = syntheticSamples(grid: [-0.6, 0, 0.6], gridY: [-0.5, 0, 0.5])
    let model = try CalibrationModel.fit(samples: nine, display: mainDisplay)
    check(model.kind == .quadratic && model.targetCount == 9 && model.sampleCount == 225, "9점 보정: 2차 모델, 표본 225")
    check(model.crossValidatedRMSE > 1 && model.crossValidatedRMSE < 40,
          "교차검증 RMSE가 잡음 수준 (\(String(format: "%.1f", model.crossValidatedRMSE))pt)")
    let error9 = heldOutError(model, ex: 0.3, ey: -0.25)
    check(error9 < 25, "9점 보정 미관측 위치 오차 < 25pt (\(String(format: "%.1f", error9))pt)")
    check(model.residualAnchors.count == 9, "표적별 잔차 앵커 9개")
    let center = model.expectedError(atLocal: CGPoint(x: 756, y: 491))
    check(center > 0 && center.isFinite, "위치별 기대 오차 보간")

    let sixteen = syntheticSamples(grid: [-0.6, -0.2, 0.2, 0.6], gridY: [-0.5, -0.17, 0.17, 0.5], seed: 11)
    let model16 = try CalibrationModel.fit(samples: sixteen, display: mainDisplay)
    let error16 = heldOutError(model16, ex: -0.4, ey: 0.3)
    check(model16.targetCount == 16 && error16 < 20, "16점 보정 미관측 위치 오차 < 20pt (\(String(format: "%.1f", error16))pt)")

    let linear = try CalibrationModel.fit(samples: nine, display: mainDisplay, options: .init(kind: .linear))
    check(model.crossValidatedRMSE < linear.crossValidatedRMSE, "2차 정답에서 2차 모델이 1차보다 교차검증 오차 작음")

    let roundTrip = try JSONDecoder().decode(CalibrationModel.self, from: JSONEncoder().encode(model))
    let probe = GazeFeatures(time: mt(0), primary: SIMD2(0.1, 0.2), auxiliary: [0, 0, 0.5, 0.45, 0.3])
    check(roundTrip == model && roundTrip.predictLocal(probe) == model.predictLocal(probe), "모델 Codable 왕복")
    check(model.predictLocal(GazeFeatures(time: mt(0), primary: SIMD2(0, 0))) == nil, "특징 차원이 다르면 예측 nil")

    let tooFew = Array(nine.prefix(75)) // 표적 3개
    do {
        _ = try CalibrationModel.fit(samples: tooFew, display: mainDisplay)
        check(false, "표적 부족 시 오류")
    } catch let error as CalibrationError {
        check(error == .insufficientTargets(found: 3, required: 5), "표적 부족 시 insufficientTargets")
    }
    var mixed = nine
    mixed[0].features.auxiliary = [0]
    do {
        _ = try CalibrationModel.fit(samples: mixed, display: mainDisplay)
        check(false, "특징 차원 불일치 오류")
    } catch let error as CalibrationError {
        check(error == .inconsistentFeatureDimensions, "특징 차원 불일치 시 inconsistentFeatureDimensions")
    }

    // 저장소: 리비전과 디스플레이 변경 무효화
    var store = CalibrationStore(displays: [mainDisplay, sideDisplay])
    let first = try store.fit(samples: nine, display: mainDisplay)
    check(first.revision == 1 && store.revision == 1, "첫 보정 리비전 1")
    let mapped = store.map(probe)
    check(mapped?.displayID == 1 && mapped?.revision == 1 && mapped?.wasClamped == false, "보정된 디스플레이로 매핑")
    let second = try store.fit(samples: nine, display: mainDisplay)
    check(second.revision == 2, "재보정 시 리비전 증가")
    let sideSamples = syntheticSamples(grid: [-0.6, 0, 0.6], gridY: [-0.5, 0, 0.5], display: sideDisplay, seed: 3)
    let side = try store.fit(samples: sideSamples, display: sideDisplay)
    check(side.revision == 3 && store.models.count == 2, "디스플레이별 모델 유지")
    let mappedWithPreference = store.map(probe, preferredDisplay: 2)
    check(mappedWithPreference?.displayID == 2, "두 디스플레이 모두 화면 안이면 직전 디스플레이 유지")
    let offscreen = GazeFeatures(time: mt(0), primary: SIMD2(3, 0), auxiliary: [0, 0, 0.5, 0.45, 0.3])
    if let clamped = store.map(offscreen, preferredDisplay: 1) {
        let display = clamped.displayID == 1 ? mainDisplay : sideDisplay
        check(clamped.wasClamped && display.contains(clamped.point), "화면 밖 예측은 클램프 표시")
    } else {
        check(false, "화면 밖 예측도 매핑")
    }

    let resized = DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117))
    let invalidated = store.updateDisplays([resized, sideDisplay])
    check(invalidated == [1] && store.model(for: 1) == nil && store.revision == 4, "디스플레이 변경 시 해당 보정 무효화 + 리비전 증가")
    check(store.model(for: 2) != nil, "변경 없는 디스플레이 보정은 유지")
    do {
        try store.install(model)
        check(false, "옛 배치 모델 설치 거부")
    } catch let error as CalibrationError {
        check(error == .displayMismatch(1), "옛 배치 모델 설치 시 displayMismatch")
    }
    _ = store.updateDisplays([resized])
    check(store.models.isEmpty && store.map(probe) == nil, "디스플레이 제거 시 무효화, 미보정이면 매핑 없음")

    // 수집기: 정착 시간과 이상치 제거
    var collector = CalibrationCollector(display: mainDisplay)
    var rng = SeededRandom(seed: 5)
    collector.beginTarget(CGPoint(x: 100, y: 100), at: mt(10))
    collector.add(features(ex: 0.9, ey: 0.9, at: 10.1, rng: &rng)) // 정착 전
    for k in 0..<20 { collector.add(features(ex: 0.1, ey: 0.1, at: 10.4 + Double(k) / 30, rng: &rng)) }
    collector.add(features(ex: 2, ey: -2, at: 11.2, rng: &rng)) // 이상치
    let accepted = collector.endTarget()
    check(accepted == 20 && collector.targetCount == 1, "정착 전 표본과 이상치 제거 (채택 \(accepted))")
    check(collector.endTarget() == 0, "진행 중 표적 없으면 0")

    let layout = CalibrationTargetLayout.nine(in: mainDisplay)
    check(layout.count == 9 && layout.allSatisfy(mainDisplay.contains), "9점 배치가 화면 안")
    check(CalibrationTargetLayout.sixteen(in: sideDisplay).allSatisfy(sideDisplay.contains), "16점 배치가 보조 화면 안")
}

// MARK: - 고정 검출

private func fixationChecks() {
    var detector = FixationDetector()
    var rng = SeededRandom(seed: 9)
    let a = CGPoint(x: 400, y: 300), b = CGPoint(x: 1000, y: 600)
    var began: [Fixation] = [], ended: [Fixation] = []
    var t = 0.0
    var saccadeFlags: [Bool] = []
    var lastAFlag = false
    func feed(_ p: CGPoint) -> FixationUpdate {
        let u = detector.update(point: p, time: mt(t), displayID: 1, confidence: 0.8)
        if let f = u.began { began.append(f) }
        if let f = u.ended { ended.append(f) }
        t += 1.0 / 60
        return u
    }
    for _ in 0..<30 { lastAFlag = feed(CGPoint(x: a.x + rng.gaussian(2), y: a.y + rng.gaussian(2))).isFixation }
    // 단일 스파이크는 같은 고정으로 이어 붙인다.
    _ = feed(CGPoint(x: a.x + 200, y: a.y))
    for _ in 0..<6 { _ = feed(CGPoint(x: a.x + rng.gaussian(2), y: a.y + rng.gaussian(2))) }
    check(began.count == 1 && ended.isEmpty, "짧은 속도 스파이크는 고정을 끊지 않음")
    check(lastAFlag, "고정 중 isFixation = true")
    for k in 1...3 {
        let f = Double(k) / 4
        saccadeFlags.append(feed(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)).isFixation)
    }
    check(saccadeFlags.allSatisfy { !$0 }, "사케이드 중 isFixation = false")
    var lastB = FixationUpdate()
    for _ in 0..<30 { lastB = feed(CGPoint(x: b.x + rng.gaussian(2), y: b.y + rng.gaussian(2))) }
    check(began.count == 2 && ended.count == 1, "고정 2개 시작, 1개 종료")
    if began.count == 2, let firstEnded = ended.first {
        check(dist(firstEnded.centroid, a) < 5 && dist(began[1].centroid, b) < 5, "고정 중심이 A/B 근처")
        check(firstEnded.duration > 0.55 && firstEnded.duration < 0.75, "첫 고정 지속시간 (\(String(format: "%.2f", firstEnded.duration))s)")
        check(abs(firstEnded.meanConfidence - 0.8) < 1e-9, "고정 평균 신뢰도")
    }
    check(lastB.isFixation && lastB.current?.id == began.last?.id, "두 번째 고정 진행 중")
    let reset = detector.reset()
    check(reset.ended?.id == began.last?.id, "reset 시 진행 중 고정 종료")

    var shortDetector = FixationDetector()
    var anyFixation = false
    for i in 0..<5 { // 0.067s < 최소 0.1s
        anyFixation = anyFixation || shortDetector.update(point: a, time: mt(Double(i) / 60), displayID: 1).isFixation
    }
    check(!anyFixation, "최소 지속시간 전에는 고정 아님")
}

// MARK: - 단서

/// (위치, 지속시간) 스크립트를 60Hz로 흘려 고정·단서를 만든다.
private func runScript(_ script: [(CGPoint, Double)], keyer: GazeRegionKeying? = nil) -> [NonverbalCue] {
    var detector = FixationDetector()
    var cues = AttentionCueDetector(regionKeyer: keyer)
    var rng = SeededRandom(seed: 21)
    var output: [NonverbalCue] = []
    var t = 0.0
    for (point, duration) in script {
        for _ in 0..<Int((duration * 60).rounded()) {
            let p = CGPoint(x: point.x + rng.gaussian(1.5), y: point.y + rng.gaussian(1.5))
            let update = detector.update(point: p, time: mt(t), displayID: 1, confidence: 0.9)
            output += cues.update(update, uncertaintyRadius: 30, now: mt(t))
            t += 1.0 / 60
        }
    }
    output += cues.update(detector.reset(), uncertaintyRadius: 30, now: mt(t))
    return output
}

private func cueChecks() {
    let a = CGPoint(x: 400, y: 300), b = CGPoint(x: 1000, y: 600), c = CGPoint(x: 200, y: 800)

    let dwell = runScript([(a, 2.0)])
    check(dwell.count == 1 && dwell.first?.kind == .prolongedDwell, "2초 응시 → prolongedDwell 1회")
    if let cue = dwell.first {
        check(secs(cue.time) >= 1.2 && secs(cue.time) < 1.5, "dwell 시점이 임계 직후 (\(String(format: "%.2f", secs(cue.time)))s)")
        check(cue.targetID == "gaze-region-1@1" && abs(cue.confidence - 0.9) < 1e-9, "dwell 대상 키와 신뢰도")
        check(cue.displayID == 1 && (cue.point.map { hypot($0.x - a.x, $0.y - a.y) < 10 } ?? false),
              "dwell 단서에 응시 중심점·디스플레이(Fusion이 UI 요소로 해석)")
    }
    check(runScript([(a, 1.0)]).isEmpty, "짧은 응시는 단서 없음")

    let revisit = runScript([(a, 0.5), (b, 0.5), (a, 0.5)])
    check(revisit.count == 1 && revisit.first?.kind == .revisit, "A→B→A → revisit 1회")
    check(revisit.first?.targetID == "gaze-region-1@1", "revisit 대상은 처음 본 영역 A")
    check(revisit.first?.point.map { hypot($0.x - a.x, $0.y - a.y) < 10 } ?? false, "revisit 단서 위치 = 돌아온 응시점")

    let twice = runScript([(a, 0.5), (b, 0.5), (a, 0.5), (c, 0.5), (a, 0.5)]).filter { $0.kind == .revisit }
    check(twice.count == 2 && twice[1].confidence > twice[0].confidence, "반복 재방문은 신뢰도 증가")

    let stale = runScript([(a, 0.5), (b, 11.0), (a, 0.5)])
    check(!stale.contains { $0.kind == .revisit }, "재방문 창(10초) 밖이면 revisit 없음")
    check(stale.filter { $0.kind == .prolongedDwell }.count == 1, "B 장기 응시 dwell은 한 번만")

    let keyed = runScript([(a, 0.5), (b, 0.5), (a, 0.5)]) { point, _ in "button-\(Int(point.x / 300))" }
    check(keyed.first?.targetID == "button-1", "주입한 영역 키를 targetID로 사용")

    var head = HeadGestureDetector()
    var shakes: [NonverbalCue] = []
    for i in 0..<42 { // 30Hz, 1.4초, 2.5Hz ±10°
        let t = Double(i) / 30
        let pose = HeadPose(yaw: 10 * .pi / 180 * sin(2 * .pi * 2.5 * t), pitch: 0.3 * .pi / 180 * sin(2 * .pi * 0.7 * t), roll: 0)
        if let cue = head.update(pose, confidence: 0.9, at: mt(t)) { shakes.append(cue) }
    }
    check(shakes.count == 1 && shakes.first?.kind == .headShake, "좌우 왕복 → headShake 1회(쿨다운)")
    check((shakes.first?.confidence ?? 0) > 0.4, "headShake 신뢰도")

    head = HeadGestureDetector()
    var nods: [NonverbalCue] = []
    for i in 0..<45 { // 1초 정지 후 0.5초 동안 한 번 끄덕임(아래→위)
        let t = Double(i) / 30
        let pitch = t < 1 ? 0 : -8 * .pi / 180 * sin(2 * .pi * (t - 1))
        if let cue = head.update(HeadPose(yaw: 0.002 * sin(Double(i)), pitch: pitch, roll: 0), confidence: 0.9, at: mt(t)) {
            nods.append(cue)
        }
    }
    check(nods.count == 1 && nods.first?.kind == .headNod, "정지 후 한 번 끄덕임 → headNod")

    head = HeadGestureDetector()
    var slow: [NonverbalCue] = []
    for i in 0..<60 { // 2초에 걸친 느린 회전
        let t = Double(i) / 30
        if let cue = head.update(HeadPose(yaw: 30 * .pi / 180 * t / 2, pitch: 0, roll: 0), confidence: 0.9, at: mt(t)) {
            slow.append(cue)
        }
    }
    check(slow.isEmpty, "느린 한 방향 회전은 제스처 아님")

    head = HeadGestureDetector()
    var lookAround: [NonverbalCue] = []
    for i in 0..<90 { // 0.4Hz 느린 좌우 둘러보기
        let t = Double(i) / 30
        if let cue = head.update(HeadPose(yaw: 15 * .pi / 180 * sin(2 * .pi * 0.4 * t), pitch: 0, roll: 0),
                                 confidence: 0.9, at: mt(t)) { lookAround.append(cue) }
    }
    check(lookAround.isEmpty, "느린 둘러보기는 도리질 아님")
}

// MARK: - 파이프라인

private func pipelineChecks() throws {
    var store = CalibrationStore(displays: [mainDisplay])
    let model = try store.fit(samples: syntheticSamples(grid: [-0.6, 0, 0.6], gridY: [-0.5, 0, 0.5]), display: mainDisplay)
    var pipeline = GazePipeline(calibration: store)
    var rng = SeededRandom(seed: 33)
    var outputs: [GazePipelineOutput] = []
    for i in 0..<30 { // 30Hz 1초 응시
        outputs.append(pipeline.process(features(ex: 0.3, ey: -0.25, at: Double(i) / 30, rng: &rng)))
    }
    let samples = outputs.compactMap(\.sample)
    check(samples.count == 30, "보정 후 프레임마다 표본")
    if let last = samples.last {
        let expected = truth(GazeFeatures(time: mt(0), primary: SIMD2(0.3, -0.25), auxiliary: [0, 0, 0.5, 0.45, 0.3]))
        check(dist(last.point, expected) < 40, "필터 출력이 정답 근처 (\(String(format: "%.1f", dist(last.point, expected)))pt)")
        check(last.isFixation && last.calibrationRevision == model.revision && last.displayID == 1, "고정·리비전·디스플레이 표시")
        check(last.uncertaintyRadius >= 20 && last.uncertaintyRadius <= 400
              && last.uncertaintyRadius >= model.crossValidatedRMSE * 0.5,
              "불확실성 반경이 보정 잔차 반영 (\(String(format: "%.1f", last.uncertaintyRadius))pt)")
        check(abs(last.confidence - 0.9) < 1e-9, "신뢰도 전달")
    }
    let jittery = (0..<30).map { i in
        pipeline.process(features(ex: 0.3, ey: -0.25, at: 1 + Double(i) / 30, rng: &rng, eyeNoise: 0.06))
    }.compactMap(\.sample).last
    if let jittery, let calm = samples.last {
        check(jittery.uncertaintyRadius > calm.uncertaintyRadius, "떨림이 크면 반경 증가")
    }
    let lost = pipeline.noObservation(at: mt(2.1))
    check(lost.cues.isEmpty && lost.sample == nil, "짧은 공백(깜빡임)은 추적 유지")
    _ = pipeline.noObservation(at: mt(2.6))
    let resumed = pipeline.process(features(ex: 0.3, ey: -0.25, at: 2.7, rng: &rng))
    check(resumed.sample?.isFixation == false, "긴 공백 뒤에는 고정 재시작")

    var uncalibrated = GazePipeline()
    var headCues: [NonverbalCue] = []
    var anySample = false
    for i in 0..<42 {
        let t = Double(i) / 30
        let pose = HeadPose(yaw: 10 * .pi / 180 * sin(2 * .pi * 2.5 * t), pitch: 0, roll: 0)
        let out = uncalibrated.process(features(ex: 0, ey: 0, at: t, rng: &rng, headPose: pose))
        anySample = anySample || out.sample != nil
        headCues += out.cues
    }
    check(!anySample, "미보정이면 시선 표본 없음")
    check(headCues.map(\.kind) == [.headShake], "미보정이어도 머리 제스처 단서")
}

// MARK: - 추정기

private func eyeContour(center: CGPoint, width: Double, height: Double, rotation: Double = 0,
                        imageSize: CGSize) -> [CGPoint] {
    (0..<8).map { k in
        let angle = Double(k) / 8 * 2 * .pi
        let x = cos(angle) * width / 2, y = sin(angle) * height / 2
        let rx = x * cos(rotation) - y * sin(rotation), ry = x * sin(rotation) + y * cos(rotation)
        return CGPoint(x: (center.x + rx) / imageSize.width, y: (center.y + ry) / imageSize.height)
    }
}

private func estimatorChecks() {
    let size = CGSize(width: 1280, height: 720)
    let estimator = LandmarkGazeEstimator()
    func face(pupilShift: Double, rotation: Double = 0, height: Double = 14, bothEyes: Bool = true) -> FaceMeasurement {
        func eye(_ center: CGPoint) -> EyeMeasurement {
            let pupil = CGPoint(x: (center.x + pupilShift * cos(rotation)) / size.width,
                                y: (center.y + pupilShift * sin(rotation)) / size.height)
            return EyeMeasurement(contour: eyeContour(center: center, width: 50, height: height, rotation: rotation, imageSize: size),
                                  pupil: pupil)
        }
        return FaceMeasurement(time: mt(1), imageSize: size, boundingBox: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.35),
                               headPose: HeadPose(yaw: 0.1, pitch: -0.05, roll: rotation),
                               leftEye: eye(CGPoint(x: 580, y: 300)), rightEye: bothEyes ? eye(CGPoint(x: 700, y: 300)) : nil,
                               confidence: 0.8)
    }
    let straight = estimator.estimate(face: face(pupilShift: 0))
    let right = estimator.estimate(face: face(pupilShift: 6))
    check(straight.map { abs($0.primary.x) < 1e-9 && abs($0.primary.y) < 1e-9 } ?? false, "정면 동공 → 오프셋 0")
    check(right.map { abs($0.primary.x - 0.12) < 1e-6 } ?? false, "동공 6px 이동 → 눈 너비 정규화 0.12")
    check(right?.auxiliary.count == LandmarkGazeEstimator.auxiliaryCount && right?.auxiliary[0] == 0.1, "보조 특징에 머리 yaw")
    let rolled = estimator.estimate(face: face(pupilShift: 6, rotation: 20 * .pi / 180))
    check(rolled.map { abs($0.primary.x - 0.12) < 1e-3 && abs($0.primary.y) < 1e-3 } ?? false, "머리 roll 20°에도 눈 좌표계 오프셋 유지")
    check(estimator.estimate(face: face(pupilShift: 0, height: 3)) == nil, "눈 감김(깜빡임) → nil")
    check(estimator.estimate(face: face(pupilShift: 0, bothEyes: false)).map { abs($0.confidence - 0.56) < 1e-9 } ?? false,
          "한쪽 눈만 유효하면 신뢰도 0.7배")

    // 동공 재탐색: 밝은 흰자 위 어두운 원
    let width = 80, height = 40
    var pixels = [UInt8](repeating: 200, count: width * height)
    let pupil = CGPoint(x: 47, y: 20)
    for y in 0..<height {
        for x in 0..<width where hypot(Double(x) + 0.5 - pupil.x, Double(y) + 0.5 - pupil.y) <= 7 {
            pixels[y * width + x] = 25
        }
    }
    let image = LumaImage(width: width, height: height, pixels: pixels)
    let polygon = (0..<16).map { k -> CGPoint in
        let angle = Double(k) / 16 * 2 * .pi
        return CGPoint(x: 40 + 35 * cos(angle), y: 20 + 15 * sin(angle))
    }
    let located = PupilLocator.locate(in: image, eyePolygon: polygon)
    check(located.map { dist($0, pupil) < 1 } ?? false, "어두운 영역 무게중심으로 동공 위치 (\(located.map { "\($0)" } ?? "nil"))")
    check(PupilLocator.locate(in: image, eyePolygon: Array(polygon.prefix(2))) == nil, "윤곽이 부족하면 nil")

    var logits = [Double](repeating: 0, count: 90)
    logits[50] = 1000
    let decoded = L2CSGazeEstimator.decodeAngle(logits: logits)
    check(decoded.map { abs($0 - 20 * .pi / 180) < 1e-9 } ?? false, "L2CS 빈 기댓값 디코딩 (bin 50 → 20°)")
    check(L2CSGazeEstimator.decodeAngle(logits: [0, 1]) == nil, "L2CS 빈 개수 불일치 → nil")
}

// MARK: - 소스

private func sourceChecks() async throws {
    let beam = BeamGazeSource()
    let asSource: any GazeSource = beam
    do {
        try await asSource.start()
        check(false, "Beam SDK 미통합이면 start 실패")
    } catch let error as GazeSourceError {
        check(error == .sdkUnavailable("Beam Eye Tracker"), "Beam start → sdkUnavailable")
    }
    for i in 0..<36 { // 60Hz 0.6초 고정 + 머리 도리질
        let t = Double(i) / 60
        beam.ingest(.init(time: mt(t), point: CGPoint(x: 500, y: 400), displayID: 1, confidence: 0.9,
                          headPose: HeadPose(yaw: 10 * .pi / 180 * sin(2 * .pi * 2.5 * t), pitch: 0, roll: 0),
                          calibrationRevision: 7))
    }
    beam.engine.finish()
    var beamSamples: [GazeSample] = []
    for await sample in beam.samples { beamSamples.append(sample) }
    var beamCues: [NonverbalCue] = []
    for await cue in beam.nonverbalCues { beamCues.append(cue) }
    check(beamSamples.count == 8, "표본 스트림은 최신 8개만 버퍼링 (\(beamSamples.count))")
    check(beamSamples.last.map { $0.isFixation && $0.calibrationRevision == 7 && $0.displayID == 1 } ?? false,
          "Beam 프레임이 같은 후처리를 거쳐 표본으로")
    check(beamCues.map(\.kind) == [.headShake], "Beam 머리 자세로 도리질 단서")

    // 엔진 보정 흐름(수동 시계)
    let clock = ManualClock()
    let engine = GazeEngine(clock: clock)
    engine.updateDisplays([mainDisplay])
    do {
        try engine.beginCalibrationTarget(.zero)
        check(false, "세션 없이 표적 시작 불가")
    } catch let error as CalibrationError {
        check(error == .noActiveSession, "세션 없이 표적 시작 → noActiveSession")
    }
    try engine.beginCalibration(displayID: 1)
    var rng = SeededRandom(seed: 44)
    var t = 0.0
    var accepted: [Int] = []
    for ey in [-0.5, 0, 0.5] {
        for ex in [-0.6, 0, 0.6] {
            let local = truth(GazeFeatures(time: mt(0), primary: SIMD2(ex, ey), auxiliary: [0, 0, 0.5, 0.45, 0.3]))
            clock.set(t)
            try engine.beginCalibrationTarget(local)
            for _ in 0..<30 {
                engine.ingest(features(ex: ex, ey: ey, at: t, rng: &rng))
                t += 1.0 / 30
            }
            accepted.append(try engine.endCalibrationTarget())
        }
    }
    check(accepted.allSatisfy { $0 >= 15 && $0 <= 20 }, "정착 시간 뒤 표본만 채택 (\(accepted))")
    let report = try engine.finishCalibration()
    check(report.revision == 1 && report.targetCount == 9 && report.kind == .quadratic && !engine.isCalibrating,
          "엔진 보정 완료 리포트 (CV \(String(format: "%.1f", report.crossValidatedRMSE))pt)")
    for _ in 0..<12 {
        engine.ingest(features(ex: 0, ey: 0, at: t, rng: &rng))
        t += 1.0 / 30
    }
    let invalidated = engine.updateDisplays([DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117))])
    check(invalidated == [1] && engine.calibrationRevision == 2 && engine.calibrationModels.isEmpty,
          "디스플레이 변경 → 엔진 보정 무효화")
    engine.finish()
    var engineSamples: [GazeSample] = []
    for await sample in engine.samples { engineSamples.append(sample) }
    check(!engineSamples.isEmpty && engineSamples.allSatisfy { $0.calibrationRevision == 1 },
          "보정 후 표본 스트림 (리비전 1, \(engineSamples.count)개)")
    if let last = engineSamples.last {
        check(dist(last.point, CGPoint(x: 756, y: 491)) < 40, "엔진 표본이 화면 중앙 근처")
    }
}

// MARK: - 기하(시선 광선 → 화면 평면)

private let cameraSize = CGSize(width: 1920, height: 1080)
private let cnnFloors = CNNGazeEstimator.defaultFeatureScaleFloors

/// 눈 위치(카메라 좌표 cm)와 맞는 합성 얼굴 측정값(랜드마크 눈 윤곽 중심 = 눈 위치 투영).
private func syntheticFace(eye: SIMD3<Double>, time: Double = 0, eyeHeightRatio: Double = 0.33,
                           pose: HeadPose = HeadPose(yaw: 0, pitch: 0, roll: 0)) -> FaceMeasurement {
    let f = CameraIntrinsics().focalLength(imageWidth: Double(cameraSize.width))
    let faceWidth = f * CNNGazeEstimator.Configuration().faceWidthCm / eye.z
    let u = Double(cameraSize.width) / 2 + eye.x * f / eye.z, v = Double(cameraSize.height) / 2 + eye.y * f / eye.z
    let iod = faceWidth * 0.42, eyeWidth = iod * 0.45
    func eyeAt(_ cx: Double) -> EyeMeasurement {
        EyeMeasurement(contour: eyeContour(center: CGPoint(x: cx, y: v), width: eyeWidth, height: eyeWidth * eyeHeightRatio,
                                           imageSize: cameraSize),
                       pupil: CGPoint(x: cx / cameraSize.width, y: v / cameraSize.height))
    }
    let box = CGRect(x: (u - faceWidth / 2) / cameraSize.width, y: (v - faceWidth * 0.4) / cameraSize.height,
                     width: faceWidth / cameraSize.width, height: faceWidth / cameraSize.height)
    return FaceMeasurement(time: mt(time), imageSize: cameraSize, boundingBox: box, headPose: pose,
                           leftEye: eyeAt(u - iod / 2), rightEye: eyeAt(u + iod / 2), confidence: 0.9)
}

private func geometryChecks() {
    var rng = SeededRandom(seed: 101)
    var worst = 0.0
    for _ in 0..<200 {
        let eye = SIMD3(rng.gaussian(8), rng.gaussian(5) + 3, 45 + rng.uniform() * 30)
        let target = SIMD2(rng.uniform() * 30 - 15, 1 + rng.uniform() * 19)
        let a = GazeGeometry.angles(lookingFrom: eye, at: target)
        guard let p = GazeGeometry.screenPlaneIntersection(eye: eye, yaw: a.yaw, pitch: a.pitch) else { worst = .infinity; break }
        worst = max(worst, hypot(p.x - target.x, p.y - target.y))
    }
    check(worst < 1e-9, "Gaze360 각도 ↔ 화면 평면 교점 왕복 (최대 \(String(format: "%.1e", worst))cm)")

    let onAxis = SIMD3<Double>(0, 0, 60)
    let left = GazeGeometry.screenPlaneIntersection(eye: onAxis, yaw: 0.2, pitch: 0)
    check(left.map { $0.x > 0 && abs($0.y) < 1e-9 } ?? false, "양의 yaw(영상 왼쪽) → 사용자 오른쪽(+X)")
    check(GazeGeometry.screenPlaneIntersection(eye: onAxis, yaw: 0, pitch: 0.1).map { $0.y < 0 } ?? false,
          "양의 pitch(위) → 카메라 위쪽(−Y)")
    check(GazeGeometry.screenPlaneIntersection(eye: onAxis, yaw: 0, pitch: 0).map { hypot($0.x, $0.y) < 1e-9 } ?? false,
          "yaw = pitch = 0 → 카메라 위치")
    check(GazeGeometry.screenPlaneIntersection(eye: onAxis, yaw: .pi * 0.8, pitch: 0) == nil, "화면 반대쪽 시선 → 교점 없음")
    let offAxis = SIMD3<Double>(10, -4, 55)
    let toCamera = GazeGeometry.angles(lookingFrom: offAxis, at: SIMD2(0, 0))
    check(abs(toCamera.yaw) < 1e-12 && abs(toCamera.pitch) < 1e-12, "축 밖 눈이 카메라를 보면 각도 0 (Gaze360 눈 좌표계)")
    let original = GazeGeometry.angles(lookingFrom: offAxis, at: SIMD2(5, 8))
    let mirrored = GazeGeometry.angles(lookingFrom: SIMD3(-offAxis.x, offAxis.y, offAxis.z), at: SIMD2(-5, 8))
    check(abs(mirrored.yaw + original.yaw) < 1e-12 && abs(mirrored.pitch - original.pitch) < 1e-12,
          "좌우 반전 영상: yaw 부호만 바뀜(보정이 흡수)")

    var worstFeature = 0.0
    for eye in [SIMD3(0.0, 0, 60), SIMD3(6.0, 3, 55), SIMD3(-7.0, -2, 70), SIMD3(3.0, 5, 48)] {
        for target in [SIMD2(-12.0, 4), SIMD2(10.0, 15), SIMD2(0.0, 9)] {
            let a = GazeGeometry.angles(lookingFrom: eye, at: target)
            guard let feature = CNNGazeEstimator.features(face: syntheticFace(eye: eye),
                                                          angles: GazeAngles(yaw: a.yaw, pitch: a.pitch)) else {
                worstFeature = .infinity; continue
            }
            worstFeature = max(worstFeature, hypot(feature.primary.x - target.x, feature.primary.y - target.y))
        }
    }
    check(worstFeature < 1e-6, "CNN 특징: 머리 위치·거리가 달라도 같은 화면 점이면 같은 primary (최대 \(String(format: "%.1e", worstFeature))cm)")
    // Gaze360 각도는 눈→카메라 축 기준이라 옆 이동에는 2차로만 변하지만, 거리에는 거의 반비례한다.
    let near = GazeGeometry.angles(lookingFrom: SIMD3(0, 0, 45), at: SIMD2(10, 9))
    let farther = GazeGeometry.angles(lookingFrom: SIMD3(0, 0, 70), at: SIMD2(10, 9))
    check(abs(near.yaw - farther.yaw) > 0.05 && abs(near.pitch - farther.pitch) > 0.04,
          "같은 화면 점이라도 거리가 바뀌면 원시 각도가 크게 달라짐(기하 정규화가 필요한 이유)")
    let sample = CNNGazeEstimator.features(face: syntheticFace(eye: onAxis), angles: GazeAngles(yaw: 0.05, pitch: -0.1))
    check(sample.map { $0.auxiliary.count == CNNGazeEstimator.auxiliaryCount && $0.gazeAngles != nil && $0.faceBox != nil
        && $0.vector.count == cnnFloors.count } ?? false, "CNN 특징 배치: primary 2 + 보조 7 + 원시 각도·얼굴 상자")
    check(CNNGazeEstimator.eyesClosed(syntheticFace(eye: onAxis, eyeHeightRatio: 0.04), minimumOpenness: 0.1)
          && !CNNGazeEstimator.eyesClosed(syntheticFace(eye: onAxis), minimumOpenness: 0.1), "양쪽 눈 감김 → 추론 생략(깜빡임)")
    let configuration = CNNGazeEstimator.Configuration()
    let narrow = GazeAngles(yaw: 0, pitch: 0, yawSpread: 55 * .pi / 180, pitchSpread: 60 * .pi / 180)
    let wide = GazeAngles(yaw: 0, pitch: 0, yawSpread: 130 * .pi / 180, pitchSpread: 125 * .pi / 180)
    let middle = GazeAngles(yaw: 0, pitch: 0, yawSpread: 95 * .pi / 180, pitchSpread: 95 * .pi / 180)
    let cMiddle = CNNGazeEstimator.spreadConfidence(middle, configuration: configuration)
    check(CNNGazeEstimator.spreadConfidence(narrow, configuration: configuration) == 1
          && abs(CNNGazeEstimator.spreadConfidence(wide, configuration: configuration) - configuration.minimumSpreadConfidence) < 1e-12
          && cMiddle < 1 && cMiddle > configuration.minimumSpreadConfidence, "빈 분포 폭 → 신뢰도(정면 얼굴 50–65°는 1, 넓으면 하한)")
}

// MARK: - CNN 전처리(크롭·리샘플)

/// Python `crop_resize`와 같은 규칙의 독립 참조 구현(Double).
private func referenceCrop(_ pixels: [UInt8], width: Int, height: Int, channels: Int, crop: CGRect, n: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: n * n * 4)
    for i in 0..<n {
        for j in 0..<n {
            let sx = min(max(Double(crop.minX) + (Double(j) + 0.5) * Double(crop.width) / Double(n) - 0.5, 0), Double(width - 1))
            let sy = min(max(Double(crop.minY) + (Double(i) + 0.5) * Double(crop.height) / Double(n) - 0.5, 0), Double(height - 1))
            let x0 = Int(sx.rounded(.down)), y0 = Int(sy.rounded(.down))
            let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
            let fx = sx - Double(x0), fy = sy - Double(y0)
            for c in 0..<3 {
                func p(_ x: Int, _ y: Int) -> Double { Double(pixels[(y * width + x) * channels + c]) }
                let v = (1 - fy) * ((1 - fx) * p(x0, y0) + fx * p(x1, y0)) + fy * ((1 - fx) * p(x0, y1) + fx * p(x1, y1))
                out[(i * n + j) * 4 + c] = UInt8((v + 0.5).rounded(.down))
            }
            out[(i * n + j) * 4 + 3] = 255
        }
    }
    return out
}

private func makeTestBuffer(_ width: Int, _ height: Int, _ format: OSType) -> CVPixelBuffer? {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                        [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary, &buffer)
    return buffer
}

private func cnnPreprocessingChecks() {
    let rect = FaceCropGeometry.cropRect(faceBox: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3),
                                         imageSize: CGSize(width: 1000, height: 500),
                                         configuration: FaceCropConfiguration(scale: 1.2, verticalOffset: -0.1))
    check(abs(rect.width - 240) < 1e-9 && abs(rect.height - 240) < 1e-9 && abs(rect.midX - 500) < 1e-9
          && abs(rect.midY - 205) < 1e-9, "얼굴 상자 → 정사각형 확대 크롭(한 변 = max(w,h)·배율, 세로 이동 = 비율×한 변)")

    // 정수 정렬 크롭은 원본 픽셀 그대로.
    let w = 23, h = 17
    var rng = SeededRandom(seed: 77)
    var pixels = [UInt8](repeating: 255, count: w * h * 4)
    for k in 0..<(w * h) { for c in 0..<3 { pixels[k * 4 + c] = UInt8(rng.next() % 256) } }
    let same = FaceCropSampler.resample(pixels: pixels, width: w, height: h, bytesPerPixel: 4,
                                        crop: CGRect(x: 3, y: 2, width: 9, height: 9), outputSize: 9)
    var identical = true
    for i in 0..<9 {
        for j in 0..<9 {
            for c in 0..<3 where same[(i * 9 + j) * 4 + c] != pixels[((i + 2) * w + j + 3) * 4 + c] { identical = false }
        }
    }
    check(identical, "정수 정렬 같은 크기 크롭 = 원본 픽셀")

    // 실수 크롭·확대·축소·가장자리 밖 → 독립 참조 구현과 비교.
    var maxDiff = 0, totalDiff = 0, count = 0
    for crop in [CGRect(x: 2.3, y: 1.7, width: 13.4, height: 13.4), CGRect(x: -4.2, y: -3.1, width: 30, height: 30),
                 CGRect(x: 10.6, y: 6.2, width: 5.5, height: 5.5)] {
        for n in [8, 31] {
            let swift = FaceCropSampler.resample(pixels: pixels, width: w, height: h, bytesPerPixel: 4, crop: crop, outputSize: n)
            let reference = referenceCrop(pixels, width: w, height: h, channels: 4, crop: crop, n: n)
            for k in swift.indices {
                let d = abs(Int(swift[k]) - Int(reference[k]))
                maxDiff = max(maxDiff, d); totalDiff += d; count += 1
            }
        }
    }
    let meanDiff = Double(totalDiff) / Double(count)
    check(maxDiff <= 1 && meanDiff < 0.02,
          "쌍선형 크롭이 Python 규칙 참조 구현과 일치 (최대 \(maxDiff), 평균 \(String(format: "%.4f", meanDiff)))")
    let edge = FaceCropSampler.resample(pixels: pixels, width: w, height: h, bytesPerPixel: 4,
                                        crop: CGRect(x: -20, y: 0, width: 4, height: 4), outputSize: 4)
    check(edge[0] == pixels[0] && edge[4] == pixels[0], "영상 밖 크롭은 가장자리 픽셀 반복")

    // CVPixelBuffer 경로: BGRA와 420f(BT.709 full)가 같은 크롭을 만든다(부드러운 영상, 색차 반 해상도 오차만).
    let bw = 64, bh = 48
    func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
        (60 + 2.0 * Double(x), 40 + 3.0 * Double(y), 120 + Double(x + y))
    }
    guard let bgra = makeTestBuffer(bw, bh, kCVPixelFormatType_32BGRA),
          let yuv = makeTestBuffer(bw, bh, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
          let cropA = makeTestBuffer(16, 16, kCVPixelFormatType_32BGRA),
          let cropB = makeTestBuffer(16, 16, kCVPixelFormatType_32BGRA) else {
        check(false, "픽셀 버퍼 생성"); return
    }
    CVPixelBufferLockBaseAddress(bgra, []); CVPixelBufferLockBaseAddress(yuv, [])
    let bp = CVPixelBufferGetBaseAddress(bgra)!.assumingMemoryBound(to: UInt8.self), bs = CVPixelBufferGetBytesPerRow(bgra)
    let yp = CVPixelBufferGetBaseAddressOfPlane(yuv, 0)!.assumingMemoryBound(to: UInt8.self)
    let ys = CVPixelBufferGetBytesPerRowOfPlane(yuv, 0)
    let cp = CVPixelBufferGetBaseAddressOfPlane(yuv, 1)!.assumingMemoryBound(to: UInt8.self)
    let cs = CVPixelBufferGetBytesPerRowOfPlane(yuv, 1)
    for y in 0..<bh {
        for x in 0..<bw {
            let (r, g, b) = rgb(x, y)
            bp[y * bs + x * 4] = UInt8(b); bp[y * bs + x * 4 + 1] = UInt8(g)
            bp[y * bs + x * 4 + 2] = UInt8(r); bp[y * bs + x * 4 + 3] = 255
            yp[y * ys + x] = UInt8((0.2126 * r + 0.7152 * g + 0.0722 * b).rounded())
        }
    }
    for cy in 0..<(bh / 2) {
        for cx in 0..<(bw / 2) {
            var cb = 0.0, cr = 0.0
            for dy in 0..<2 {
                for dx in 0..<2 {
                    let (r, g, b) = rgb(cx * 2 + dx, cy * 2 + dy)
                    let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
                    cb += (b - luma) / 1.8556; cr += (r - luma) / 1.5748
                }
            }
            cp[cy * cs + cx * 2] = UInt8((cb / 4 + 128).rounded()); cp[cy * cs + cx * 2 + 1] = UInt8((cr / 4 + 128).rounded())
        }
    }
    CVPixelBufferUnlockBaseAddress(yuv, []); CVPixelBufferUnlockBaseAddress(bgra, [])
    CVBufferSetAttachment(yuv, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    let crop = CGRect(x: 10.5, y: 8.25, width: 30, height: 30)
    let okA = FaceCropSampler.sample(pixelBuffer: bgra, crop: crop, into: cropA)
    let okB = FaceCropSampler.sample(pixelBuffer: yuv, crop: crop, into: cropB)
    CVPixelBufferLockBaseAddress(cropA, .readOnly); CVPixelBufferLockBaseAddress(cropB, .readOnly)
    let pa = CVPixelBufferGetBaseAddress(cropA)!.assumingMemoryBound(to: UInt8.self)
    let pb = CVPixelBufferGetBaseAddress(cropB)!.assumingMemoryBound(to: UInt8.self)
    let sa = CVPixelBufferGetBytesPerRow(cropA), sb = CVPixelBufferGetBytesPerRow(cropB)
    var yuvMax = 0
    for y in 0..<16 {
        for x in 0..<16 {
            for c in 0..<3 { yuvMax = max(yuvMax, abs(Int(pa[y * sa + x * 4 + c]) - Int(pb[y * sb + x * 4 + c]))) }
        }
    }
    let corner = (Double(pa[2]), Double(pa[1]))
    CVPixelBufferUnlockBaseAddress(cropB, .readOnly); CVPixelBufferUnlockBaseAddress(cropA, .readOnly)
    let sx = 10.5 + 0.5 * 30 / 16 - 0.5, sy = 8.25 + 0.5 * 30 / 16 - 0.5
    check(okA && abs(corner.0 - (60 + 2 * sx)) <= 1 && abs(corner.1 - (40 + 3 * sy)) <= 1, "BGRA 버퍼 크롭이 선형 그라디언트 값 재현")
    check(okA && okB && yuvMax <= 3, "420f 버퍼 경로 = BGRA 경로 (최대 차이 \(yuvMax))")
    if let luma = PupilLocator.lumaCrop(bgra, rect: CGRect(x: 5, y: 4, width: 8, height: 8)) {
        let (r, g, b) = rgb(5 + 2, 4 + 3)
        check(abs(Int(luma.image[2, 3]) - Int((0.299 * r + 0.587 * g + 0.114 * b).rounded())) <= 1, "BGRA 밝기 평면 추출(동공 재탐색용)")
    } else {
        check(false, "BGRA 밝기 평면 추출")
    }

    // 정렬: 랜드마크가 있으면 무게중심·반경, 없으면 상자. 정렬 필터는 정지 떨림을 줄이고 이동은 따라간다.
    var face = syntheticFace(eye: SIMD3(0, 0, 60))
    let boxAlignment = FaceCropGeometry.alignment(face: face)
    check(abs(boxAlignment.side - Double(face.boundingBox.width * cameraSize.width)) < 1e-9, "랜드마크 없으면 Vision 상자로 정렬")
    face.landmarkCenter = CGPoint(x: 0.5, y: 0.45)
    face.landmarkRadius = 100
    let landmarkAlignment = FaceCropGeometry.alignment(face: face)
    check(abs(landmarkAlignment.side - 315) < 1e-9 && abs(landmarkAlignment.center.x - 960) < 1e-9
          && abs(landmarkAlignment.center.y - 486) < 1e-9, "랜드마크 무게중심·RMS 반경×3.15로 정렬")
    var filter = AlignmentFilter()
    var jitterRng = SeededRandom(seed: 61)
    var rawX: [Double] = [], filteredX: [Double] = []
    for k in 0..<90 {
        let raw = FaceAlignment(center: CGPoint(x: 960 + jitterRng.gaussian(0.5), y: 486 + jitterRng.gaussian(0.5)),
                                side: 315 + jitterRng.gaussian(1))
        let out = filter.update(raw, at: Double(k) / 30)
        if k >= 30 { rawX.append(Double(raw.center.x)); filteredX.append(Double(out.center.x)) }
    }
    func spread(_ v: [Double]) -> Double {
        let m = v.reduce(0, +) / Double(v.count)
        return (v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count)).squareRoot()
    }
    check(spread(filteredX) < 0.5 * spread(rawX), "정렬 필터: 정지 떨림 감소 (\(String(format: "%.2f → %.2f", spread(rawX), spread(filteredX)))px)")
    var lag = 0.0
    for k in 90..<120 { // 초당 60px로 이동(머리 2cm/s)
        let t = Double(k) / 30
        let truth = 960 + (t - 3) * 60
        let out = filter.update(FaceAlignment(center: CGPoint(x: truth, y: 486), side: 315), at: t)
        lag = abs(Double(out.center.x) - truth)
    }
    check(lag < 3, "정렬 필터: 머리가 움직이면 따라감 (지연 오차 \(String(format: "%.2f", lag))px)")
    let restarted = filter.update(FaceAlignment(center: CGPoint(x: 200, y: 200), side: 300), at: 10)
    check(restarted == FaceAlignment(center: CGPoint(x: 200, y: 200), side: 300), "긴 공백 뒤에는 새로 시작")
}

// MARK: - CNN 출력 디코딩·메타데이터

private func cnnDecodeChecks() {
    var oneHot = [Double](repeating: -50, count: 90)
    oneHot[45] = 50
    let decoded = GazeBinDecoder.decode(logits: oneHot)
    check(decoded.map { abs($0.mean) < 1e-9 && $0.spread < 1e-9 } ?? false, "빈 45 → 0°, 분포 폭 0")
    var pair = [Double](repeating: -1e9, count: 90)
    pair[44] = 3; pair[45] = 3
    let midpoint = GazeBinDecoder.decode(logits: pair)
    check(midpoint.map { abs($0.mean - (-2 * .pi / 180)) < 1e-9 && abs($0.spread - 2 * .pi / 180) < 1e-9 } ?? false,
          "인접 두 빈 동률 → 중간 각도(−2°), 폭 2°")
    let uniform = GazeBinDecoder.decode(logits: [Double](repeating: 0, count: 90))
    let uniformSpread = (Double(90 * 90 - 1) / 12).squareRoot() * 4 * .pi / 180
    check(uniform.map { abs($0.mean - (-2 * .pi / 180)) < 1e-9 && abs($0.spread - uniformSpread) < 1e-9 } ?? false,
          "균등 분포 → 기댓값 −2°, 폭 \(String(format: "%.1f", uniformSpread * 180 / .pi))°")
    var shifted = oneHot.map { $0 + 1000 }
    shifted[10] = 1040
    let a = GazeBinDecoder.decode(logits: shifted), b = GazeBinDecoder.decode(logits: shifted.map { $0 - 1000 })
    check(a != nil && abs((a?.mean ?? 0) - (b?.mean ?? 1)) < 1e-12, "로짓 상수 이동 불변(수치 안정)")
    check(GazeBinDecoder.decode(logits: []) == nil && GazeBinDecoder.decode(logits: [.nan, 1]) == nil, "빈 입력·NaN → nil")

    let info = GazeModelInfo(metadata: ["gaze.arch": "resnet18", "gaze.tta": "1", "gaze.cropScale": "1.25",
                                        "gaze.cropYOffset": "-0.08", "gaze.version": "1", "gaze.binwidth": "4"],
                             inputNames: ["image"], outputNames: ["gaze"])
    check(info.arch == "resnet18" && info.testTimeFlip && info.crop.widthScale == 1.25 && info.crop.heightScale == 1.25
          && info.crop.verticalOffset == -0.08 && info.outputKind == .continuous && info.inputName == "image",
          "모델 메타데이터 해석(정사각형 배율 키)")
    check(info.estimatorID == "cnn-resnet18-tta-w1.25h1.25o-0.08-v1", "추정기 ID에 구조·TTA·크롭 포함 (\(info.estimatorID))")
    let rect = GazeModelInfo(metadata: ["gaze.cropWidthScale": "0.85", "gaze.cropHeightScale": "1.19", "gaze.cropYOffset": "-0.1"],
                             inputNames: ["image"], outputNames: ["gaze"])
    check(rect.crop == FaceCropConfiguration(), "RetinaFace 대응 직사각형 크롭 메타데이터 = 기본값(폭 0.85, 높이 1.19, 위 0.10)")
    let retinaLike = FaceCropGeometry.cropRect(faceBox: CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.2 * 16 / 9),
                                               imageSize: CGSize(width: 1600, height: 900), configuration: FaceCropConfiguration())
    check(abs(retinaLike.width - 272) < 1e-9 && abs(retinaLike.height - 380.8) < 1e-9 && abs(retinaLike.midY - (430 - 32)) < 1e-9,
          "Vision 정사각 상자 320px → RetinaFace형 크롭 272×381, 중심 32px 위")
    let logits = GazeModelInfo(metadata: [:], inputNames: ["input"], outputNames: ["yaw", "pitch"])
    check(logits.outputKind == .logits && logits.inputName == "input" && logits.bins == 90, "로짓 출력 모델은 Swift에서 디코딩")

    var latency = LatencyStats()
    for v in 1...100 { latency.add(Double(v)) }
    check(latency.median == 51 && latency.p95 == 95 && abs(latency.mean - 50.5) < 1e-9, "지연 통계 중앙값·p95")
}

// MARK: - 보정 v2(구조 선택, 척도 하한, 가중 암묵 표본, 예전 파일 호환)

/// CNN 유사 특징: primary = 화면 평면 cm, 보조 7개.
private func cnnFeatures(x: Double, y: Double, aux: [Double] = [0, 0, 0.5, 0.45, 0.19, 0, 0], at t: Double = 0,
                         rng: inout SeededRandom, noise: Double = 0.4, auxNoise: Double = 0.001) -> GazeFeatures {
    GazeFeatures(time: mt(t), primary: SIMD2(x + rng.gaussian(noise), y + rng.gaussian(noise)),
                 auxiliary: aux.map { $0 + rng.gaussian(auxNoise) }, headPose: HeadPose(yaw: aux[0], pitch: aux[1], roll: 0),
                 confidence: 0.9)
}

/// 정답: 화면 평면 cm → 디스플레이 로컬 pt (+ 선택적 머리 yaw/pitch 효과, 드리프트).
private func truthV2(x: Double, y: Double, headYaw: Double = 0, headPitch: Double = 0, drift: CGPoint = .zero) -> CGPoint {
    CGPoint(x: 756 + 50 * x + 0.3 * x * x + 300 * headYaw + drift.x,
            y: -10 + 50 * y - 0.4 * (y - 10) * (y - 10) + 250 * headPitch + drift.y)
}

private func cnnSamples(xs: [Double], ys: [Double], perTarget: Int = 30, headSpread: Double = 0, seed: UInt64 = 5,
                        auxNoise: Double = 0.001) -> [CalibrationSample] {
    var rng = SeededRandom(seed: seed)
    var samples: [CalibrationSample] = []
    for y in ys {
        for x in xs {
            let yaw = rng.gaussian(headSpread), pitch = rng.gaussian(headSpread)
            let target = truthV2(x: x, y: y, headYaw: yaw, headPitch: pitch)
            for k in 0..<perTarget {
                samples.append(CalibrationSample(features: cnnFeatures(x: x, y: y, aux: [yaw, pitch, 0.5, 0.45, 0.19, 0, 0],
                                                                       at: Double(k) / 30, rng: &rng, auxNoise: auxNoise),
                                                 target: target))
            }
        }
    }
    return samples
}

private let gridX = [-12.0, -4, 4, 12], gridY = [2.0, 7.5, 13, 18.5]

private func calibrationV2Checks() throws {
    var options = CalibrationOptions()
    options.scaleFloors = cnnFloors
    options.estimatorID = "cnn-test"
    let plain = try CalibrationModel.fit(samples: cnnSamples(xs: gridX, ys: gridY), display: mainDisplay, options: options)
    check(plain.auxiliaryTerms == .none && plain.kind == .quadratic && plain.estimatorID == "cnn-test",
          "보조 특징이 잡음뿐이면 보조 항 제외(\(plain.kind.rawValue)+\(plain.auxiliaryTerms.rawValue))")
    check(plain.crossValidatedRMSE < 40 && plain.structureScores.count >= 4,
          "16점 그룹 교차검증 RMSE (\(String(format: "%.1f", plain.crossValidatedRMSE))pt), 후보 구조 \(plain.structureScores.count)개 비교")
    let head = try CalibrationModel.fit(samples: cnnSamples(xs: gridX, ys: gridY, headSpread: 0.12, seed: 6),
                                        display: mainDisplay, options: options)
    check(head.auxiliaryTerms != .none, "머리 자세가 화면 위치에 영향을 주면 보조 항 포함(\(head.auxiliaryTerms.rawValue))")
    let five = cnnSamples(xs: [-12, 0, 12], ys: [2, 18.5]).filter { !(abs($0.target.x - 756) < 1 && $0.target.y < 200) }
    let few = try CalibrationModel.fit(samples: five, display: mainDisplay, options: options)
    check(few.targetCount == 5 && few.kind == .linear && few.auxiliaryTerms == .none, "표적 5개면 2차·보조 항 금지(과적합 방지)")

    // 척도 하한: 보정 중 거의 변하지 않은 보조 특징이 나중에 조금 바뀌어도 예측이 튀지 않는다.
    var forced = options
    forced.structures = [CalibrationModel.Structure(kind: .quadratic, auxiliary: .all)]
    var unfloored = forced
    unfloored.scaleFloors = []
    let tinyAux = cnnSamples(xs: gridX, ys: gridY, seed: 8, auxNoise: 1e-4)
    let floored = try CalibrationModel.fit(samples: tinyAux, display: mainDisplay, options: forced)
    let raw = try CalibrationModel.fit(samples: tinyAux, display: mainDisplay, options: unfloored)
    var probeRng = SeededRandom(seed: 3)
    let probe = cnnFeatures(x: 1, y: 9, rng: &probeRng, noise: 0, auxNoise: 0)
    var drifted = probe
    drifted.auxiliary[2] += 0.02 // 얼굴이 영상에서 2% 이동
    drifted.auxiliary[5] += 0.02 // 홍채 오프셋 잡음
    func shift(_ m: CalibrationModel) -> Double {
        guard let a = m.predictLocal(probe), let b = m.predictLocal(drifted) else { return .infinity }
        return dist(a, b)
    }
    check(shift(floored) < 15 && shift(floored) < shift(raw),
          "척도 하한: 거의 상수였던 보조 특징 변화에 둔감 (\(String(format: "%.1f", shift(floored)))pt vs 하한 없음 \(String(format: "%.1f", shift(raw)))pt)")

    // 가중 암묵 표본: 드리프트(정답 +60, −40pt)를 클릭 표본이 따라간다. 가중치가 클수록 더 많이.
    let explicit = cnnSamples(xs: gridX, ys: gridY, seed: 9)
    let base = try CalibrationModel.fit(samples: explicit, display: mainDisplay, options: options)
    let drift = CGPoint(x: 60, y: -40)
    func implicitSamples(weight: Double, count: Int) -> [CalibrationSample] {
        var rng = SeededRandom(seed: 10)
        return (0..<count).map { k in
            let x = rng.uniform() * 26 - 13, y = 1.5 + rng.uniform() * 17.5
            return CalibrationSample(features: cnnFeatures(x: x, y: y, rng: &rng), target: truthV2(x: x, y: y, drift: drift),
                                     source: .implicit, weight: weight, groupID: k + 1)
        }
    }
    func driftError(_ m: CalibrationModel) -> Double {
        var rng = SeededRandom(seed: 12)
        var total = 0.0
        for _ in 0..<20 {
            let x = rng.uniform() * 24 - 12, y = 2 + rng.uniform() * 16
            let f = cnnFeatures(x: x, y: y, rng: &rng, noise: 0, auxNoise: 0)
            total += dist(m.predictLocal(f) ?? .zero, truthV2(x: x, y: y, drift: drift))
        }
        return total / 20
    }
    let aged = explicit.map { sample -> CalibrationSample in
        var s = sample
        s.weight = 0.3
        return s
    }
    let light = try CalibrationModel.fit(samples: aged + implicitSamples(weight: 0.05, count: 30), display: mainDisplay, options: options)
    let heavy = try CalibrationModel.fit(samples: aged + implicitSamples(weight: 0.5, count: 30), display: mainDisplay, options: options)
    check(driftError(base) > 60 && driftError(heavy) < 0.4 * driftError(base) && driftError(heavy) < driftError(light),
          "가중 클릭 표본이 드리프트 보정 (\(String(format: "%.0f → %.0f(w0.05) → %.0fpt(w0.5)", driftError(base), driftError(light), driftError(heavy))))")
    check(heavy.implicitCount == 30 && heavy.targetCount == 16, "암묵 표본은 그룹 하나씩, 표적 수에는 미포함")
    let configuration = ImplicitCalibrationConfiguration()
    check(configuration.explicitWeight(age: 0) == 1
          && abs(configuration.explicitWeight(age: configuration.explicitHalfLife) - 0.5) < 1e-12
          && configuration.explicitWeight(age: 1e6) == configuration.explicitMinimumWeight, "명시 보정 표본 나이 가중(반감기, 하한)")

    // 저장소: 추정기 불일치 거부, 리비전 유지 갱신.
    var store = CalibrationStore(displays: [mainDisplay])
    store.setEstimator("cnn-test")
    let installed = try store.install(base)
    do {
        try store.install(try CalibrationModel.fit(samples: syntheticSamples(grid: [-0.6, 0, 0.6], gridY: [-0.5, 0, 0.5]),
                                                   display: mainDisplay))
        check(false, "다른 추정기 모델 설치 거부")
    } catch let error as CalibrationError {
        check(error == .estimatorMismatch("landmarks-v1"), "다른 추정기(landmarks-v1) 모델 설치 → estimatorMismatch")
    }
    let refined = try store.refine(heavy)
    check(refined.revision == installed.revision && store.revision == installed.revision, "암묵 재적합은 리비전 유지(하류 버퍼 유지)")
    check(store.setEstimator("cnn-other") == [1] && store.models.isEmpty, "추정기 변경 → 기존 보정 무효화")

    // 예전 calibration.json(landmarks-v1, 사용자 파일 형식) 복원.
    let legacy = #"[{"lambda":0.01,"crossValidatedRMSE":288.8759272203502,"featureMean":[-0.03333481099880032,-0.07049912755504638,0.0578966067959238,0.07400340524511141,0.5231348400555768,0.7729821521999344,0.26460886638141373],"targetCount":9,"featureDimension":7,"weightsY":[506.3740004122654,50.40087285239432,52.8749046063585,15.058698631889033,-28.07002055382779,0.6806263397818679,-46.206813335174466,63.32344334827307,23.972910077576234,197.94382074441089,-87.53999281750514],"featureScale":[0.06470891527472514,0.012292295128780887,0.015545944096817445,0.025116411112567485,0.0018355883729823678,0.004469472094602939,0.0045020508153318555],"display":{"id":1,"frame":[[0,0],[1512,982]]},"trainingRMSE":164.37751072902955,"weightsX":[740.8303637514539,-463.14871067203,14.067348416433367,26.14474936220292,4.764842097315355,-3.9068028352229685,-58.26845539558905,44.639556978362734,-20.296917339024866,-20.517079546115394,-20.94747070306688],"revision":1,"residualAnchors":[{"rmse":423.226314956183,"point":[120.96000000000001,78.56]}],"kind":"quadratic","sampleCount":206}]"#
    let models = try JSONDecoder().decode([CalibrationModel].self, from: Data(legacy.utf8))
    let mean = GazeFeatures(time: mt(0), primary: SIMD2(-0.03333481099880032, -0.07049912755504638),
                            auxiliary: [0.0578966067959238, 0.07400340524511141, 0.5231348400555768, 0.7729821521999344,
                                        0.26460886638141373])
    let predicted = models.first?.predictLocal(mean)
    check((models.first.map { $0.estimatorID == "landmarks-v1" && $0.auxiliaryTerms == .all && $0.validation == nil } ?? false)
          && (predicted.map { abs($0.x - 740.8303637514539) < 1e-6 && abs($0.y - 506.3740004122654) < 1e-6 } ?? false),
          "예전 보정 파일(landmarks-v1) 해석·예측 호환")
    var cnnStore = CalibrationStore(displays: [mainDisplay])
    cnnStore.setEstimator("cnn-test")
    check((try? cnnStore.install(models[0])) == nil, "CNN 추정기에서는 예전 랜드마크 보정을 설치하지 않음")

    // 축별 척도 이상치 제거: x 잡음이 큰 축과 y 잡음이 작은 축.
    var collector = CalibrationCollector(display: mainDisplay)
    var rng = SeededRandom(seed: 13)
    collector.beginTarget(CGPoint(x: 300, y: 300), at: mt(0), settle: 0.5)
    for k in 0..<30 {
        collector.add(GazeFeatures(time: mt(0.5 + Double(k) / 30), primary: SIMD2(rng.gaussian(1.0), rng.gaussian(0.01)),
                                   auxiliary: [], confidence: 0.9))
    }
    collector.add(GazeFeatures(time: mt(1.6), primary: SIMD2(0, 0.25), auxiliary: [], confidence: 0.9))
    collector.add(GazeFeatures(time: mt(1.62), primary: SIMD2(0, 0), auxiliary: [], confidence: 0.05)) // 신뢰도 낮음
    let result = collector.endTargetDetailed(rejectFlagged: true)
    check(result.map { $0.accepted == 30 && $0.collected == 32 && $0.issue == nil && $0.committed } ?? false,
          "축별 MAD 이상치·저신뢰 표본 제거 (채택 \(result?.accepted ?? -1)/\(result?.collected ?? -1))")

    // 머리 움직임 표시: 첫 시도는 버리고 다시.
    collector.beginTarget(CGPoint(x: 600, y: 300), at: mt(10), settle: 0.5)
    for k in 0..<30 {
        let box = CGRect(x: 0.4 + Double(k) * 0.003, y: 0.3, width: 0.2, height: 0.2)
        collector.add(GazeFeatures(time: mt(10.5 + Double(k) / 30), primary: SIMD2(rng.gaussian(0.3), rng.gaussian(0.3)),
                                   auxiliary: [], confidence: 0.9, faceBox: box))
    }
    let moved = collector.endTargetDetailed(rejectFlagged: true)
    check((moved.map { $0.issue == .headMoved && !$0.committed && $0.headTranslation > 0.15 } ?? false) && collector.targetCount == 1,
          "머리가 움직인 표적은 표시하고 첫 시도는 저장 안 함 (이동 \(String(format: "%.2f", moved?.headTranslation ?? 0)) 얼굴 폭)")
    collector.beginTarget(CGPoint(x: 600, y: 300), at: mt(20), settle: 0.5)
    for k in 0..<3 { collector.add(GazeFeatures(time: mt(20.6 + Double(k) / 30), primary: .zero, auxiliary: [], confidence: 0.9)) }
    let sparse = collector.endTargetDetailed(rejectFlagged: false)
    check((sparse.map { $0.issue == .insufficientSamples && $0.committed } ?? false) && collector.targetCount == 2,
          "표본 부족 표시, 재시도(rejectFlagged=false)는 저장")

    let serpentine = CalibrationTargetLayout.serpentine(rows: 4, columns: 4, in: mainDisplay)
    check(serpentine.count == 16 && serpentine[3].x > serpentine[0].x && serpentine[4].x > serpentine[7].x
          && Set(serpentine.map { "\($0)" }).count == 16, "16점 지그재그 순서")
    let validation = CalibrationTargetLayout.validation(in: mainDisplay)
    let grid = Set(CalibrationTargetLayout.sixteen(in: mainDisplay).map { "\($0)" })
    check(validation.count == 5 && validation.allSatisfy(mainDisplay.contains) && validation.allSatisfy { !grid.contains("\($0)") },
          "검증 5점은 화면 안, 보정 격자와 겹치지 않음")
}

// MARK: - 검증 단계

private func validationChecks() throws {
    var options = CalibrationOptions()
    options.scaleFloors = cnnFloors
    let model = try CalibrationModel.fit(samples: cnnSamples(xs: gridX, ys: gridY), display: mainDisplay, options: options)
    var rng = SeededRandom(seed: 21)
    let points: [(Double, Double)] = [(-6, 5), (6, 5), (0, 10), (-5, 15), (5, 15)]
    var targets: [(target: CGPoint, features: [GazeFeatures])] = points.map { x, y in
        let truth = truthV2(x: x, y: y)
        // 사용자가 실제로는 표적에서 (30, 40)pt 떨어진 곳을 봤다 → 오차 50pt.
        let target = CGPoint(x: truth.x - 30, y: truth.y - 40)
        return (target, (0..<30).map { k in cnnFeatures(x: x, y: y, at: Double(k) / 30, rng: &rng, noise: 0.2) })
    }
    targets.append((CGPoint(x: 100, y: 100), []))
    let report = CalibrationValidation.evaluate(model: model, targets: targets, pointsPerCentimeter: 50)
    check(report.points.count == 5 && report.missingPoints == 1, "표본 없는 검증 점은 제외하고 개수 보고")
    check(abs(report.meanError - 50) < 12 && abs((report.meanErrorCm ?? 0) - report.meanError / 50) < 1e-12,
          "검증 평균 오차 pt·cm (\(String(format: "%.1fpt = %.2fcm", report.meanError, report.meanErrorCm ?? 0)))")
    check(report.maxError >= report.meanError && report.rmse >= report.meanError - 1e-9 && report.medianError > 0, "최대 ≥ RMS ≥ 평균")
    let clampTargets: [(target: CGPoint, features: [GazeFeatures])] = [
        (CGPoint(x: 1512, y: 491), (0..<5).map { _ in cnnFeatures(x: 40, y: 10, rng: &rng) }),
    ]
    let clamped = CalibrationValidation.evaluate(model: model, targets: clampTargets, pointsPerCentimeter: nil)
    check((clamped.points.first.map { $0.predicted.x <= 1512 } ?? false) && clamped.meanErrorCm == nil,
          "화면 밖 예측은 클램프, 물리 크기 모르면 cm 없음")
    check((DisplayGeometry.pointsPerCentimeter(frame: mainDisplay.frame, physicalMillimeters: CGSize(width: 302.4, height: 196.4))
            .map { abs($0 - 50) < 1e-9 } ?? false)
          && DisplayGeometry.pointsPerCentimeter(frame: mainDisplay.frame, physicalMillimeters: nil) == nil,
          "CGDisplayScreenSize(mm) → cm당 포인트")

    let withValidation = model.withValidation(report.summary)
    check(withValidation.expectedError(atLocal: CGPoint(x: 756, y: 491)) >= report.rmse - 1e-9
          && withValidation.expectedRMSE == max(model.crossValidatedRMSE, report.rmse), "검증 오차가 기대 오차(불확실성) 하한")

    // 엔진 흐름: 보정 → 검증 → 수락(검증 점 합침, 리비전 유지).
    let clock = ManualClock()
    let engine = GazeEngine(clock: clock)
    engine.updateDisplays([mainDisplay])
    engine.setEstimator(id: "cnn-test", scaleFloors: cnnFloors)
    var t = 0.0
    var issues = 0
    try engine.beginCalibration(displayID: 1)
    for y in gridY {
        for x in gridX {
            clock.set(t)
            try engine.beginCalibrationTarget(truthV2(x: x, y: y), settle: 0.5)
            for _ in 0..<51 { engine.ingest(cnnFeatures(x: x, y: y, at: t, rng: &rng)); t += 1.0 / 30 }
            if try engine.endCalibrationTarget(rejectFlagged: true).issue != nil { issues += 1 }
        }
    }
    let calibrated = try engine.finishCalibration()
    check(calibrated.estimatorID == "cnn-test" && calibrated.targetCount == 16 && issues == 0, "엔진 16점 보정(추정기 ID 기록)")
    try engine.beginValidation()
    for (x, y) in points {
        clock.set(t)
        try engine.beginValidationTarget(truthV2(x: x, y: y), settle: 0.5)
        for _ in 0..<45 { engine.ingest(cnnFeatures(x: x, y: y, at: t, rng: &rng)); t += 1.0 / 30 }
        _ = try engine.endValidationTarget(rejectFlagged: true)
    }
    let validated = try engine.finishValidation()
    let afterValidation = engine.calibrationModels.first
    check(validated.points.count == 5 && validated.meanError < 30 && afterValidation?.validation?.pointCount == 5
          && afterValidation?.revision == calibrated.revision,
          "엔진 검증: 평균 \(String(format: "%.1f", validated.meanError))pt, 모델에 요약 첨부(리비전 유지)")
    let accepted = try engine.acceptValidation()
    check(accepted.targetCount == 21 && accepted.revision == calibrated.revision && accepted.validation?.pointCount == 5,
          "검증 수락 → 표적 21개로 재적합, 검증 요약 유지")
}

// MARK: - 암묵 재보정(클릭)

private enum PairOutcome: Equatable {
    case accepted
    case rejected(ImplicitPairRejection)
}

private func outcome<T>(_ result: Result<T, ImplicitPairRejection>) -> PairOutcome {
    switch result {
    case .success: .accepted
    case .failure(let reason): .rejected(reason)
    }
}

private func implicitChecks() throws {
    var options = CalibrationOptions()
    options.scaleFloors = cnnFloors
    let model = try CalibrationModel.fit(samples: cnnSamples(xs: gridX, ys: gridY), display: mainDisplay, options: options)
    var rng = SeededRandom(seed: 31)
    func history(x: Double, y: Double, start: Double, frames: Int = 9, noise: Double = 0.3) -> [GazeFeatures] {
        (0..<frames).map { cnnFeatures(x: x, y: y, at: start + Double($0) / 30, rng: &rng, noise: noise) }
    }
    let steady = history(x: 3, y: 9, start: 10)
    let clickTime = mt(10 + 8.0 / 30 + 0.1)
    let click = truthV2(x: 3, y: 9)
    switch ImplicitCalibration.pair(click: click, clickTime: clickTime, history: steady, model: model) {
    case .success(let paired):
        check(paired.predictionError < 40 && abs(paired.features.primary.x - 3) < 0.4,
              "클릭 전 창의 중앙값 특징과 짝지음 (오차 \(String(format: "%.0f", paired.predictionError))pt)")
    case .failure(let reason):
        check(false, "안정 시선 클릭 짝짓기 실패: \(reason)")
    }
    check(outcome(ImplicitCalibration.pair(click: click, clickTime: clickTime, history: steady, model: nil)) == .rejected(.uncalibrated),
          "보정 없으면 거부")
    check(outcome(ImplicitCalibration.pair(click: CGPoint(x: 2000, y: 100), clickTime: clickTime, history: steady, model: model))
          == .rejected(.otherDisplay), "다른 디스플레이 클릭 거부")
    check(outcome(ImplicitCalibration.pair(click: click, clickTime: mt(30), history: steady, model: model)) == .rejected(.tooFewFrames),
          "클릭 직전 프레임이 없으면 거부")
    let saccade = history(x: -10, y: 4, start: 20, frames: 6) + history(x: 10, y: 16, start: 20 + 6.0 / 30, frames: 3)
    check(outcome(ImplicitCalibration.pair(click: click, clickTime: mt(20 + 8.0 / 30 + 0.1), history: saccade, model: model))
          == .rejected(.unstableGaze), "클릭 직전 시선 이동 중이면 거부")
    let far = CGPoint(x: 1400, y: 900)
    check(outcome(ImplicitCalibration.pair(click: far, clickTime: clickTime, history: steady, model: model)) == .rejected(.wildlyOff),
          "모델이 쓸 만하면 화면 25% 넘게 어긋난 클릭 거부")
    let poor = model.withValidation(.init(meanError: 300, rmse: 320, maxError: 500, meanErrorCm: 6, pointCount: 5))
    check(outcome(ImplicitCalibration.pair(click: far, clickTime: clickTime, history: steady, model: poor)) == .accepted,
          "모델이 아직 부정확하면(기대 오차 큼) 먼 클릭도 받음")

    // 버퍼: 같은 자리 반복 클릭 합침, 용량, 최신성 가중치.
    var buffer = ImplicitCalibrationBuffer()
    var configuration = ImplicitCalibrationConfiguration()
    configuration.capacity = 5
    let now = Date()
    let f = steady[0]
    buffer.add(features: f, target: CGPoint(x: 100, y: 100), at: now, predictionError: 10, configuration: configuration)
    buffer.add(features: f, target: CGPoint(x: 120, y: 110), at: now.addingTimeInterval(2), predictionError: 10,
               configuration: configuration)
    check(buffer.count == 1 && buffer.entries[0].target == CGPoint(x: 120, y: 110), "같은 자리 반복 클릭은 하나로 합침")
    for k in 0..<7 {
        buffer.add(features: f, target: CGPoint(x: 300 + Double(k) * 100, y: 300), at: now.addingTimeInterval(Double(10 + k)),
                   predictionError: nil, configuration: configuration)
    }
    check(buffer.count == 5 && buffer.entries.first?.target.x == 500, "용량 초과 시 오래된 표본부터 버림")
    let weights = buffer.samples(now: now.addingTimeInterval(16 + configuration.halfLife), configuration: configuration).map(\.weight)
    check(weights.count == 5 && abs((weights.last ?? 0) - configuration.baseWeight / 2) < 1e-9
          && Set(buffer.samples(now: now, configuration: configuration).compactMap(\.groupID)).count == 5,
          "반감기 뒤 가중치 절반, 표본마다 고유 그룹")
    buffer.prune(now: now.addingTimeInterval(configuration.halfLife * 20), configuration: configuration)
    check(buffer.count == 0, "가중치가 바닥인 오래된 표본 정리")
    let aggregated = ImplicitCalibration.aggregate([
        GazeFeatures(time: mt(1), primary: SIMD2(1, 10), auxiliary: [0.1]),
        GazeFeatures(time: mt(2), primary: SIMD2(2, 30), auxiliary: [0.3]),
        GazeFeatures(time: mt(3), primary: SIMD2(9, 20), auxiliary: [0.2]),
    ])
    check(aggregated.map { $0.primary == SIMD2(2, 20) && $0.auxiliary == [0.2] && $0.time == mt(3) } ?? false, "성분별 중앙값 집계")

    // 엔진: 보정 → 드리프트 뒤 클릭 → 디바운스 재적합(리비전 유지) → 드리프트 보정, 저장·복원.
    let clock = ManualClock()
    let engine = GazeEngine(clock: clock)
    engine.updateDisplays([mainDisplay])
    engine.setEstimator(id: "cnn-test", scaleFloors: cnnFloors)
    let events = Mutex<[String]>([])
    engine.setCalibrationObserver { event in
        events.withLock { list in
            switch event {
            case .calibrated: list.append("calibrated")
            case .refined: list.append("refined")
            case .validated: list.append("validated")
            case .restored: list.append("restored")
            }
        }
    }
    try engine.beginCalibration(displayID: 1)
    var t = 0.0
    for y in gridY {
        for x in gridX {
            clock.set(t)
            try engine.beginCalibrationTarget(truthV2(x: x, y: y), settle: 0.5)
            for _ in 0..<51 { engine.ingest(cnnFeatures(x: x, y: y, at: t, rng: &rng)); t += 1.0 / 30 }
            _ = try engine.endCalibrationTarget(rejectFlagged: false)
        }
    }
    let calibrated = try engine.finishCalibration()
    check(outcome(engine.recordImplicitClick(at: CGPoint(x: 10, y: 10), time: mt(t + 5))) == .rejected(.tooFewFrames),
          "클릭 직전 특징이 없으면 엔진도 거부")
    let drift = CGPoint(x: 50, y: -35)
    let date = Date().addingTimeInterval(3 * 3600) // 보정 3시간 뒤: 명시 표본 가중치가 하한으로 줄어 있다.
    var accepted = 0
    for k in 0..<25 {
        let x = rng.uniform() * 24 - 12, y = 2 + rng.uniform() * 16
        for _ in 0..<9 { engine.ingest(cnnFeatures(x: x, y: y, at: t, rng: &rng)); t += 1.0 / 30 }
        if case .success = engine.recordImplicitClick(at: truthV2(x: x, y: y, drift: drift), time: mt(t + 0.05),
                                                      date: date.addingTimeInterval(Double(k) * 10)) {
            accepted += 1
        }
        t += 0.5
    }
    clock.set(t)
    engine.flushImplicitRefit()
    let refined = engine.calibrationModels.first
    func error(_ m: CalibrationModel?) -> Double {
        guard let m else { return .infinity }
        var total = 0.0
        for (x, y) in [(-8.0, 5.0), (8.0, 5.0), (0.0, 10.0), (-6.0, 16.0), (6.0, 16.0)] {
            total += dist(m.predictLocal(cnnFeatures(x: x, y: y, rng: &rng, noise: 0, auxNoise: 0)) ?? .zero,
                          truthV2(x: x, y: y, drift: drift))
        }
        return total / 5
    }
    check(accepted >= 20 && refined?.implicitCount == accepted, "클릭 \(accepted)개 채택 → 암묵 재적합에 반영")
    check(refined?.revision == calibrated.revision && engine.implicitStats.refits == 1
          && events.withLock { $0 } == ["calibrated", "refined"], "암묵 재적합은 리비전 유지 + 저장 알림")
    check(error(refined) < 35,
          "클릭으로 드리프트 보정 (재적합 후 \(String(format: "%.1f", error(refined)))pt, 드리프트 \(String(format: "%.0f", hypot(drift.x, drift.y)))pt)")

    let encoder = JSONEncoder(), decoder = JSONDecoder()
    encoder.dateEncodingStrategy = .iso8601; decoder.dateDecodingStrategy = .iso8601
    let archive = try decoder.decode(CalibrationArchive.self, from: encoder.encode(engine.exportArchive()))
    check(archive.version == 2 && archive.estimatorID == "cnn-test" && archive.datasets.first?.implicit.count == accepted
          && archive.datasets.first?.samples.count == engine.datasets.first?.samples.count, "보관 파일 JSON 왕복(모델·표본·클릭)")
    let restored = GazeEngine(clock: clock)
    restored.updateDisplays([mainDisplay])
    restored.setEstimator(id: "cnn-test", scaleFloors: cnnFloors)
    let probe = cnnFeatures(x: 1, y: 9, rng: &rng, noise: 0, auxNoise: 0)
    let restoredCount = restored.importArchive(archive)
    let restoredPrediction = restored.calibrationModels.first?.predictLocal(probe)
    let originalPrediction = refined?.predictLocal(probe)
    check(restoredCount == 1 && restored.datasets.count == 1 && restoredPrediction != nil
          && dist(restoredPrediction ?? .zero, originalPrediction ?? CGPoint(x: 1e9, y: 0)) < 1e-6, "같은 추정기면 복원")
    let other = GazeEngine(clock: clock)
    other.updateDisplays([mainDisplay])
    other.setEstimator(id: "landmarks-v1", scaleFloors: [])
    check(other.importArchive(archive) == 0 && other.calibrationModels.isEmpty, "다른 추정기면 복원하지 않음(재보정 필요)")
    try engine.beginCalibration(displayID: 1)
    check(outcome(engine.recordImplicitClick(at: CGPoint(x: 10, y: 10), time: mt(t))) == .rejected(.calibrating),
          "보정 중에는 클릭 무시")
    engine.cancelCalibration()
}

// MARK: - 자세 안내

private func headGuidanceChecks() {
    let status = HeadPositionStatus(face: syntheticFace(eye: SIMD3(0, 0, 60)))
    check(abs(status.distanceCm - 60) < 0.5, "얼굴 폭 → 거리 추정 (\(String(format: "%.1f", status.distanceCm))cm)")
    check(HeadPositionGuidance.evaluate(status, now: mt(0.1)).isEmpty, "정면 60cm → 안내 없음")
    check(HeadPositionGuidance.evaluate(status, now: mt(2)) == [.noFace] && HeadPositionGuidance.evaluate(nil, now: mt(0)) == [.noFace],
          "오래된 상태·얼굴 없음 → noFace")
    func first(_ eye: SIMD3<Double>) -> HeadPositionGuidance.Issue? {
        HeadPositionGuidance.evaluate(HeadPositionStatus(face: syntheticFace(eye: eye)), now: mt(0)).first
    }
    if case .tooFar = first(SIMD3(0, 0, 95)) { check(true, "95cm → 가까이") } else { check(false, "95cm → 가까이") }
    if case .tooClose = first(SIMD3(0, 0, 35)) { check(true, "35cm → 뒤로") } else { check(false, "35cm → 뒤로") }
    // 사용자가 자기 왼쪽에 치우침 = 카메라 영상 오른쪽(+x) → 오른쪽으로 옮기라고 안내.
    let shifted = HeadPositionStatus(face: syntheticFace(eye: SIMD3(20, 0, 60)))
    check(HeadPositionGuidance.evaluate(shifted, now: mt(0)).contains(.moveRight) && shifted.mirroredX < 0.5,
          "영상 오른쪽 얼굴 → ‘오른쪽으로’ 안내, 미니맵은 거울 방향")
    let turned = HeadPositionStatus(face: syntheticFace(eye: SIMD3(0, 0, 60), pose: HeadPose(yaw: 0.5, pitch: 0, roll: 0)))
    check(HeadPositionGuidance.evaluate(turned, now: mt(0)).contains(.faceTurned), "고개 돌림 안내")
    check(HeadPositionGuidance.primaryMessage([.moveLeft]) != nil && HeadPositionGuidance.primaryMessage([]) == nil, "안내 문구")
}

// MARK: - 안정성(One Euro + 고정 중심 표시)

private func stabilityChecks() throws {
    func run(stabilize: Bool, noise: Double, seed: UInt64) -> (jitter: Double, settle: Double) {
        var configuration = GazePipelineConfiguration()
        configuration.stabilization.enabled = stabilize
        var pipeline = GazePipeline(configuration: configuration)
        var rng = SeededRandom(seed: seed)
        let a = CGPoint(x: 400, y: 300), b = CGPoint(x: 1000, y: 650)
        var outputs: [(Double, CGPoint)] = []
        for i in 0..<120 { // 2초 A, 2초 B (30Hz)
            let t = Double(i) / 30
            let truth = t < 2 ? a : b
            let point = CGPoint(x: truth.x + rng.gaussian(noise), y: truth.y + rng.gaussian(noise))
            if let sample = pipeline.processScreenPoint(point, displayID: 1, time: mt(t), confidence: 0.9, calibrationRevision: 1,
                                                        expectedError: 50).sample {
                outputs.append((t, sample.point))
            }
        }
        let fixated = outputs.filter { $0.0 >= 0.6 && $0.0 < 2 }.map(\.1)
        let mx = fixated.reduce(0.0) { $0 + Double($1.x) } / Double(fixated.count)
        let my = fixated.reduce(0.0) { $0 + Double($1.y) } / Double(fixated.count)
        let jitter = (fixated.reduce(0.0) { $0 + pow(Double($1.x) - mx, 2) + pow(Double($1.y) - my, 2) }
            / Double(fixated.count)).squareRoot()
        let settle = outputs.first { $0.0 >= 2 && dist($0.1, b) < 80 }.map { $0.0 - 2 } ?? .infinity
        return (jitter, settle)
    }
    let off = run(stabilize: false, noise: 30, seed: 41), on = run(stabilize: true, noise: 30, seed: 41)
    check(on.jitter < 0.8 * off.jitter, "고정 중심 표시로 떨림 감소 (\(String(format: "%.1f → %.1f", off.jitter, on.jitter))pt)")
    check(on.settle <= 0.2, "사케이드 후 0.2초 안에 새 위치 근처 (\(String(format: "%.3f", on.settle))s)")
    let defaults = OneEuroParameters()
    check(defaults.minCutoff == 0.6 && defaults.beta == 0.0015, "One Euro 기본값(시뮬레이션 조정)")

    // 느린 드리프트는 분산 한계로 고정을 나눈다.
    var detector = FixationDetector()
    var ended = 0
    for i in 0..<120 { // 4초에 300pt(초당 75pt ≈ 1.7°/s) 천천히 이동
        let update = detector.update(point: CGPoint(x: 300 + Double(i) * 2.5, y: 400), time: mt(Double(i) / 30), displayID: 1)
        if update.ended != nil { ended += 1 }
    }
    check(ended >= 1, "느린 드리프트가 한 고정으로 무한히 이어지지 않음(분산 한계, 종료 \(ended)회)")

    // 불확실성 반경: 검증 오차를 반영하고 범위 안.
    var options = CalibrationOptions()
    options.scaleFloors = cnnFloors
    let model = try CalibrationModel.fit(samples: cnnSamples(xs: gridX, ys: gridY), display: mainDisplay, options: options)
    func radius(_ m: CalibrationModel) throws -> Double {
        var store = CalibrationStore(displays: [mainDisplay])
        try store.install(m)
        var pipeline = GazePipeline(calibration: store)
        var rng = SeededRandom(seed: 51)
        var last = 0.0
        for i in 0..<30 {
            last = pipeline.process(cnnFeatures(x: 0, y: 9, at: Double(i) / 30, rng: &rng)).sample?.uncertaintyRadius ?? 0
        }
        return last
    }
    let calm = try radius(model)
    let poor = try radius(model.withValidation(.init(meanError: 150, rmse: 170, maxError: 260, meanErrorCm: 3, pointCount: 5)))
    check(calm >= 20 && calm <= 400 && poor > calm && poor >= 170, "불확실성 반경이 검증 오차 반영 (\(String(format: "%.0f → %.0f", calm, poor))pt)")
}
