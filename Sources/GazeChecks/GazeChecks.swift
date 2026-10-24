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
    }
    check(runScript([(a, 1.0)]).isEmpty, "짧은 응시는 단서 없음")

    let revisit = runScript([(a, 0.5), (b, 0.5), (a, 0.5)])
    check(revisit.count == 1 && revisit.first?.kind == .revisit, "A→B→A → revisit 1회")
    check(revisit.first?.targetID == "gaze-region-1@1", "revisit 대상은 처음 본 영역 A")

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
