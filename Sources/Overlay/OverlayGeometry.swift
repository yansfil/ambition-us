import AgentContracts
import CoreGraphics
import Foundation

// 오버레이의 순수 기하 함수 모음. AppKit/SwiftUI에 의존하지 않으므로 GazeChecks에서 직접 검사한다.
//
// 좌표계 약속
// - "AX 전역"(top-left global): 주 화면(메뉴 막대가 있는 화면) 좌상단이 원점, y는 아래로 증가.
//   GazeSample.point, UITarget.frame, AgentRegion.target(frame:)이 이 좌표계다.
// - "Cocoa 전역": 주 화면 좌하단이 원점, y는 위로 증가. NSScreen.frame, NSWindow.frame이 이 좌표계다.
// - "디스플레이 로컬": 각 디스플레이 오버레이 패널(SwiftUI) 좌상단이 원점, y는 아래로 증가.

/// 디스플레이 한 대의 기하 정보. frame/visibleFrame은 NSScreen과 같은 Cocoa 전역 좌표다.
public struct DisplayGeometry: Sendable, Equatable {
    public var id: UInt32
    public var frame: CGRect
    /// 메뉴 막대와 Dock을 뺀 영역(Cocoa 전역).
    public var visibleFrame: CGRect

    public init(id: UInt32, frame: CGRect, visibleFrame: CGRect) {
        self.id = id; self.frame = frame; self.visibleFrame = visibleFrame
    }

    /// AX 전역 좌표로 표현한 디스플레이 영역.
    public func topLeftFrame(primaryHeight: CGFloat) -> CGRect {
        OverlayGeometry.cocoaToTopLeft(frame, primaryHeight: primaryHeight)
    }

    /// AX 전역 좌표로 표현한 가시 영역(메뉴 막대·Dock 제외).
    public func topLeftVisibleFrame(primaryHeight: CGFloat) -> CGRect {
        OverlayGeometry.cocoaToTopLeft(visibleFrame, primaryHeight: primaryHeight)
    }

    /// 디스플레이 로컬 좌표계의 전체 영역.
    public var localBounds: CGRect { CGRect(origin: .zero, size: frame.size) }
}

public enum OverlayGeometry {
    // MARK: - 좌표 변환

    /// AX 전역(좌상단 원점) 점 → Cocoa 전역(좌하단 원점) 점.
    public static func topLeftToCocoa(_ point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// AX 전역 사각형 → Cocoa 전역 사각형. 원점이 위 모서리에서 아래 모서리로 바뀐다.
    public static func topLeftToCocoa(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        let r = rect.standardized
        return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    public static func cocoaToTopLeft(_ point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// 변환이 자기 역변환이므로 같은 식을 쓴다.
    public static func cocoaToTopLeft(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        topLeftToCocoa(rect, primaryHeight: primaryHeight)
    }

    /// AX 전역 점 → 디스플레이 로컬 점.
    public static func local(_ point: CGPoint, inDisplayTopLeftFrame display: CGRect) -> CGPoint {
        CGPoint(x: point.x - display.minX, y: point.y - display.minY)
    }

    /// AX 전역 사각형 → 디스플레이 로컬 사각형.
    public static func local(_ rect: CGRect, inDisplayTopLeftFrame display: CGRect) -> CGRect {
        rect.standardized.offsetBy(dx: -display.minX, dy: -display.minY)
    }

    /// 디스플레이 로컬 사각형 → AX 전역 사각형.
    public static func global(_ rect: CGRect, fromDisplayTopLeftFrame display: CGRect) -> CGRect {
        rect.offsetBy(dx: display.minX, dy: display.minY)
    }

    // MARK: - 디스플레이 선택

    /// 점을 포함하는 디스플레이. 경계에 걸치면 먼저 나온 것을 고른다.
    public static func displayIndex(containing point: CGPoint, in frames: [CGRect]) -> Int? {
        frames.firstIndex { frame in
            point.x >= frame.minX && point.x < frame.maxX && point.y >= frame.minY && point.y < frame.maxY
        }
    }

    /// 사각형과 가장 많이 겹치는 디스플레이. 겹치는 곳이 없으면 중심에서 가장 가까운 디스플레이.
    public static func displayIndex(bestFor rect: CGRect, in frames: [CGRect]) -> Int? {
        guard !frames.isEmpty else { return nil }
        var best: (index: Int, area: CGFloat)?
        for (index, frame) in frames.enumerated() {
            let overlap = frame.intersection(rect)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if best == nil || area > best!.area { best = (index, area) }
        }
        if let best, best.area > 0 { return best.index }
        if let contained = displayIndex(containing: CGPoint(x: rect.midX, y: rect.midY), in: frames) {
            return contained
        }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return frames.indices.min { distance(from: center, to: frames[$0]) < distance(from: center, to: frames[$1]) }
    }

    /// 점에서 사각형까지 거리(안이면 0).
    public static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: - 시선 유리

    public static let gazeGlassMinSize = CGSize(width: 76, height: 52)
    public static let gazeGlassMaxSize = CGSize(width: 420, height: 280)

    /// 추정 오차 반경으로 유리 크기를 정한다. 가로로 조금 긴 둥근 사각형(텍스트 줄을 덮기 좋게).
    public static func gazeGlassSize(uncertaintyRadius: Double) -> CGSize {
        let r = CGFloat(uncertaintyRadius.isFinite ? max(uncertaintyRadius, 0) : 0)
        return CGSize(width: clamp(r * 2.4, gazeGlassMinSize.width, gazeGlassMaxSize.width),
                      height: clamp(r * 1.6, gazeGlassMinSize.height, gazeGlassMaxSize.height))
    }

    /// 시선 점을 중심으로 한 유리 영역(입력과 같은 좌표계).
    public static func gazeGlassRect(center: CGPoint, uncertaintyRadius: Double) -> CGRect {
        let size = gazeGlassSize(uncertaintyRadius: uncertaintyRadius)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    public static func gazeGlassCornerRadius(for size: CGSize) -> CGFloat {
        min(min(size.width, size.height) / 2, 26)
    }

    /// 이 값보다 신뢰도가 낮으면 시선을 잃은 것으로 보고 유리를 숨긴다.
    public static let gazeLostConfidence = 0.15

    /// 신뢰도 → 유리 불투명도. 시선이 없거나 신뢰도가 낮으면 0(페이드 아웃).
    public static func gazeOpacity(confidence: Double?) -> Double {
        guard let confidence, confidence.isFinite, confidence >= gazeLostConfidence else { return 0 }
        let t = (min(confidence, 1) - gazeLostConfidence) / (1 - gazeLostConfidence)
        return 0.55 + 0.45 * t
    }

    /// 이 거리 이상 한 번에 움직이면 "점프"로 본다(모션 감소 모드에서는 보간 대신 페이드).
    public static let gazeJumpDistance: CGFloat = 180

    public static func isGazeJump(from old: CGPoint, to new: CGPoint, threshold: CGFloat = gazeJumpDistance) -> Bool {
        hypot(new.x - old.x, new.y - old.y) >= threshold
    }

    // MARK: - 음성 배지

    public static let voiceBadgeSize = CGSize(width: 46, height: 24)

    /// 둥근 모서리 호의 45° 지점(우하단). 배지 중심을 여기에 붙이면 모서리에 "매달린" 모양이 된다.
    public static func bottomRightCornerPoint(of rect: CGRect, cornerRadius: CGFloat) -> CGPoint {
        let r = max(0, min(cornerRadius, min(rect.width, rect.height) / 2))
        let inset = r * (1 - CGFloat(0.5).squareRoot())
        return CGPoint(x: rect.maxX - inset, y: rect.maxY - inset)
    }

    /// 시선 유리 우하단 모서리에 붙는 배지 위치(로컬 좌상단 좌표). 화면 밖으로 나가지 않게 bounds 안으로 민다.
    public static func badgeFrame(glass: CGRect, cornerRadius: CGFloat, badgeSize: CGSize = voiceBadgeSize,
                                  bounds: CGRect, margin: CGFloat = 4) -> CGRect {
        let anchor = bottomRightCornerPoint(of: glass, cornerRadius: cornerRadius)
        var frame = CGRect(x: anchor.x - badgeSize.width / 2, y: anchor.y - badgeSize.height / 2,
                           width: badgeSize.width, height: badgeSize.height)
        frame = clampRect(frame, into: bounds.insetBy(dx: margin, dy: margin))
        return frame
    }

    // MARK: - 파형

    public static let silenceThreshold = 0.02

    /// 마이크 표본 → 배지 상태.
    public static func voiceBadgeMode(for sample: AudioLevelSample?, silenceThreshold: Double = silenceThreshold) -> VoiceBadgeMode {
        guard let sample else { return .hidden }
        switch sample.micState {
        case .muted: return .muted
        case .unavailable: return .unavailable
        case .active:
            let rms = sample.rms.isFinite ? min(max(sample.rms, 0), 1) : 0
            if sample.isVoice || rms > silenceThreshold { return .speaking(level: rms) }
            return .silent
        }
    }

    /// 체감 음량(작은 RMS도 보이도록 제곱근 곡선).
    public static func perceivedLevel(rms: Double) -> Double {
        let r = rms.isFinite ? min(max(rms, 0), 1) : 0
        return min(1, r.squareRoot() * 1.4)
    }

    /// 막대별 높이(0...1). 가운데 막대가 가장 높고, phase로 살짝 흔들린다. 모션 감소면 phase를 0으로 고정해 쓴다.
    public static func waveformLevels(rms: Double, barCount: Int = 5, phase: Double = 0, floor: Double = 0.18) -> [Double] {
        guard barCount > 0 else { return [] }
        let level = perceivedLevel(rms: rms)
        let mid = Double(barCount - 1) / 2
        return (0..<barCount).map { i in
            let distance = mid == 0 ? 0 : abs(Double(i) - mid) / mid
            let envelope = 1 - 0.45 * distance
            let wobble = 0.78 + 0.22 * sin(phase + Double(i) * 1.7)
            return min(1, max(floor, floor + (1 - floor) * level * envelope * wobble))
        }
    }

    // MARK: - 에이전트 영역

    /// 대상 프레임을 테두리 여백만큼 키운다(테두리가 대상 내용을 가리지 않게).
    public static func paddedTargetRect(_ frame: CGRect, padding: CGFloat) -> CGRect {
        frame.standardized.insetBy(dx: -padding, dy: -padding)
    }

    /// 안쪽 글로 폭. 작은 대상(입력칸 한 줄 등)은 글로가 내용을 덮지 않도록 짧은 변의 20%로 줄인다.
    public static func innerGlowWidth(for size: CGSize, maximum: CGFloat) -> CGFloat {
        let short = max(0, min(size.width, size.height))
        return min(maximum, max(4, short * 0.2))
    }

    /// 상태 라벨 위치: 영역 바깥 위쪽에 둘 공간이 없으면(메뉴 막대·화면 위) 안쪽 위로 넣는다.
    public static func statusLabelPosition(regionRect: CGRect, labelHeight: CGFloat, safeTop: CGFloat, gap: CGFloat = 4) -> StatusLabelPosition {
        regionRect.minY - gap - labelHeight >= safeTop ? .outsideTop : .insideTop
    }

    /// 상태 라벨 문구. 승인 대기가 있으면 영역 라벨보다 우선한다.
    public static func statusLabel(region: AgentRegion, hasPendingApproval: Bool) -> String? {
        if hasPendingApproval { return OverlayStatusLabel.awaitingApproval }
        switch region {
        case .idleScreenEdge: return nil
        case .target(_, let label): return label.isEmpty ? nil : label
        }
    }

    // MARK: - 말풍선 배치

    /// 대상(anchor) 근처에 말풍선 몸체를 두고 꼬리가 anchor를 가리키게 한다.
    /// 모든 입력은 같은 좌표계(AX 전역 권장)이고, visibleFrame은 메뉴 막대·Dock을 뺀 영역이다.
    /// 선호 순서대로 시도해 화면 안에 들어가고 anchor를 가리지 않는 첫 배치를 고른다.
    /// 어느 쪽도 맞지 않으면 여유 공간이 가장 큰 쪽에 두고 화면 안으로 밀어 넣는다.
    public static func placeBubble(size: CGSize, anchor: CGRect?, visibleFrame: CGRect,
                                   margin: CGFloat = 10, gap: CGFloat = 6, tailLength: CGFloat = BubbleMetrics.tailLength,
                                   preferred: [BubbleSide] = [.below, .above, .trailing, .leading]) -> BubblePlacement {
        let bounds = visibleFrame.insetBy(dx: margin, dy: margin)
        guard let rawAnchor = anchor?.standardized, !rawAnchor.isNull, !rawAnchor.isInfinite else {
            // 대상이 없으면 가시 영역 아래쪽 가운데에 꼬리 없이 둔다.
            let body = clampRect(CGRect(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height - 40,
                                        width: size.width, height: size.height), into: bounds)
            return BubblePlacement(side: nil, bodyFrame: body, tailTip: nil)
        }
        // 화면 밖으로 나간 부분은 잘라서 계산한다.
        let clipped = rawAnchor.intersection(visibleFrame)
        let target = clipped.isNull || clipped.isEmpty ? rawAnchor : clipped
        let reach = gap + tailLength

        func candidate(_ side: BubbleSide) -> (placement: BubblePlacement, fits: Bool, room: CGFloat) {
            var body: CGRect
            let room: CGFloat
            switch side {
            case .below:
                body = CGRect(x: target.midX - size.width / 2, y: target.maxY + reach, width: size.width, height: size.height)
                room = bounds.maxY - target.maxY - reach - size.height
            case .above:
                body = CGRect(x: target.midX - size.width / 2, y: target.minY - reach - size.height, width: size.width, height: size.height)
                room = target.minY - reach - size.height - bounds.minY
            case .trailing:
                body = CGRect(x: target.maxX + reach, y: target.midY - size.height / 2, width: size.width, height: size.height)
                room = bounds.maxX - target.maxX - reach - size.width
            case .leading:
                body = CGRect(x: target.minX - reach - size.width, y: target.midY - size.height / 2, width: size.width, height: size.height)
                room = target.minX - reach - size.width - bounds.minX
            }
            // 주축 반대 방향(가로 배치면 세로, 세로 배치면 가로)으로만 화면 안에 밀어 넣는다.
            let fitsMainAxis = room >= 0
            body = clampRect(body, into: bounds)
            let tip = tailTip(for: side, body: body, target: target, gap: gap)
            let placement = BubblePlacement(side: side, bodyFrame: body, tailTip: tip)
            let fits = fitsMainAxis && !body.intersects(target) && bounds.contains(body)
            return (placement, fits, room)
        }

        let options = (preferred.isEmpty ? BubbleSide.allCases : preferred).map(candidate)
        if let first = options.first(where: { $0.fits }) { return first.placement }
        return options.max { $0.room < $1.room }!.placement
    }

    /// 꼬리 끝점: anchor 가장자리에서 gap만큼 떨어진 곳. 몸체의 둥근 모서리를 벗어나지 않게 제한한다.
    static func tailTip(for side: BubbleSide, body: CGRect, target: CGRect, gap: CGFloat) -> CGPoint {
        let inset = BubbleMetrics.cornerRadius + BubbleMetrics.tailBaseWidth / 2
        switch side {
        case .below, .above:
            let lo = max(body.minX + inset, target.minX), hi = min(body.maxX - inset, target.maxX)
            let x = lo <= hi ? clamp(target.midX, lo, hi) : clamp(target.midX, body.minX + inset, body.maxX - inset)
            return CGPoint(x: x, y: side == .below ? min(target.maxY + gap, body.minY) : max(target.minY - gap, body.maxY))
        case .trailing, .leading:
            let lo = max(body.minY + inset, target.minY), hi = min(body.maxY - inset, target.maxY)
            let y = lo <= hi ? clamp(target.midY, lo, hi) : clamp(target.midY, body.minY + inset, body.maxY - inset)
            return CGPoint(x: side == .trailing ? min(target.maxX + gap, body.minX) : max(target.minX - gap, body.maxX), y: y)
        }
    }

    // MARK: - 보간

    public static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    public static func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        CGPoint(x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t))
    }

    public static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: lerp(a.minX, b.minX, t), y: lerp(a.minY, b.minY, t),
               width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t))
    }

    /// 0...1 → 0...1 부드러운 가감속(smoothstep 계열, 양 끝 기울기 0).
    public static func easeInOut(_ t: CGFloat) -> CGFloat {
        let x = clamp(t, 0, 1)
        return x * x * (3 - 2 * x)
    }

    /// 화면 테두리 → 대상 프레임으로 줄어드는 중간 프레임(진행률 0...1, 가감속 포함).
    public static func regionFrame(from: CGRect, to: CGRect, progress: CGFloat) -> CGRect {
        lerp(from, to, easeInOut(progress))
    }

    /// 지수 평활 계수. dt 동안 시간상수 tau로 목표에 다가가는 비율.
    public static func smoothingFactor(dt: Double, timeConstant tau: Double) -> Double {
        guard dt > 0 else { return 0 }
        guard tau > 0 else { return 1 }
        return 1 - exp(-dt / tau)
    }

    // MARK: - 보조

    public static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        lo > hi ? (lo + hi) / 2 : min(max(v, lo), hi)
    }

    /// rect를 bounds 안으로 평행 이동한다. bounds보다 크면 가운데 정렬한다.
    public static func clampRect(_ rect: CGRect, into bounds: CGRect) -> CGRect {
        var r = rect
        r.origin.x = clamp(r.minX, bounds.minX, bounds.maxX - r.width)
        r.origin.y = clamp(r.minY, bounds.minY, bounds.maxY - r.height)
        return r
    }
}

// MARK: - 기하 결과 타입

public enum VoiceBadgeMode: Sendable, Equatable {
    case hidden
    /// 마이크는 켜졌지만 말소리가 없다.
    case silent
    case speaking(level: Double)
    case muted
    case unavailable
}

public enum StatusLabelPosition: Sendable, Equatable { case outsideTop, insideTop }

/// 말풍선 몸체가 anchor의 어느 쪽에 놓이는지.
public enum BubbleSide: String, Sendable, Equatable, CaseIterable {
    case below, above, trailing, leading
}

public enum BubbleTailEdge: String, Sendable, Equatable { case top, bottom, leading, trailing }

public enum BubbleMetrics {
    public static let tailLength: CGFloat = 10
    public static let tailBaseWidth: CGFloat = 18
    public static let cornerRadius: CGFloat = 14
}

public struct BubblePlacement: Sendable, Equatable {
    /// nil이면 꼬리 없음(가리킬 대상이 없다).
    public var side: BubbleSide?
    /// 꼬리를 뺀 말풍선 몸체.
    public var bodyFrame: CGRect
    /// 꼬리 끝점(anchor 가장자리 근처).
    public var tailTip: CGPoint?

    public init(side: BubbleSide?, bodyFrame: CGRect, tailTip: CGPoint?) {
        self.side = side; self.bodyFrame = bodyFrame; self.tailTip = tailTip
    }

    /// 꼬리가 붙는 몸체 가장자리. 몸체가 anchor 아래(.below)에 있으면 꼬리는 몸체 위쪽(.top)에 붙는다.
    public var tailEdge: BubbleTailEdge? {
        switch side {
        case .below: .top
        case .above: .bottom
        case .trailing: .leading
        case .leading: .trailing
        case nil: nil
        }
    }

    /// 컨테이너(패널) 로컬 좌상단 좌표의 몸체.
    public var localBodyFrame: CGRect {
        let c = containerFrame
        return bodyFrame.offsetBy(dx: -c.minX, dy: -c.minY)
    }

    /// 컨테이너 로컬 좌상단 좌표의 꼬리 끝.
    public var localTailTip: CGPoint? {
        guard let tailTip else { return nil }
        let c = containerFrame
        return CGPoint(x: tailTip.x - c.minX, y: tailTip.y - c.minY)
    }

    /// 몸체+꼬리를 모두 담는 영역. 상호작용 패널은 이 크기로 만든다.
    public var containerFrame: CGRect {
        guard let tailTip else { return bodyFrame }
        let minX = min(bodyFrame.minX, tailTip.x), maxX = max(bodyFrame.maxX, tailTip.x)
        let minY = min(bodyFrame.minY, tailTip.y), maxY = max(bodyFrame.maxY, tailTip.y)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// 상태 라벨 문구(설계서 고정값).
public enum OverlayStatusLabel {
    public static let reading = "읽는 중"
    public static let typing = "입력 중"
    public static let awaitingApproval = "확인 대기"
}
