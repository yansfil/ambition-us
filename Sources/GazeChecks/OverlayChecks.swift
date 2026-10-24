import AgentContracts
import CoreGraphics
import Foundation
import Overlay

func overlayChecks() async {
    await suite("Overlay 좌표 변환") {
        let h: CGFloat = 1080
        let p = OverlayGeometry.topLeftToCocoa(CGPoint(x: 100, y: 80), primaryHeight: h)
        check(p == CGPoint(x: 100, y: 1000), "AX 점 → Cocoa 점(y 뒤집기)")
        check(OverlayGeometry.cocoaToTopLeft(p, primaryHeight: h) == CGPoint(x: 100, y: 80), "점 왕복")
        let r = OverlayGeometry.topLeftToCocoa(CGRect(x: 100, y: 80, width: 200, height: 50), primaryHeight: h)
        check(r == CGRect(x: 100, y: 950, width: 200, height: 50), "AX 사각형 → Cocoa 사각형(원점이 아래 모서리로)")
        check(OverlayGeometry.cocoaToTopLeft(r, primaryHeight: h) == CGRect(x: 100, y: 80, width: 200, height: 50), "사각형 왕복")

        // 주 화면 왼쪽 위에 붙은 보조 화면(Cocoa: y가 주 화면 위쪽).
        let secondary = DisplayGeometry(id: 2, frame: CGRect(x: -1440, y: 1080, width: 1440, height: 900),
                                        visibleFrame: CGRect(x: -1440, y: 1080, width: 1440, height: 875))
        let tl = secondary.topLeftFrame(primaryHeight: h)
        check(tl == CGRect(x: -1440, y: -900, width: 1440, height: 900), "보조 화면의 AX 전역 영역")
        check(OverlayGeometry.local(CGPoint(x: -1000, y: -500), inDisplayTopLeftFrame: tl) == CGPoint(x: 440, y: 400),
              "AX 전역 점 → 보조 화면 로컬 점")
        let localRect = OverlayGeometry.local(CGRect(x: -1000, y: -500, width: 10, height: 10), inDisplayTopLeftFrame: tl)
        check(OverlayGeometry.global(localRect, fromDisplayTopLeftFrame: tl) == CGRect(x: -1000, y: -500, width: 10, height: 10),
              "로컬 ↔ 전역 왕복")
        check(secondary.topLeftVisibleFrame(primaryHeight: h).minY == -875, "가시 영역 위쪽(메뉴 막대 제외) 변환")

        let frames = [CGRect(x: 0, y: 0, width: 1920, height: 1080), tl]
        check(OverlayGeometry.displayIndex(containing: CGPoint(x: 10, y: 10), in: frames) == 0, "점 → 주 화면")
        check(OverlayGeometry.displayIndex(containing: CGPoint(x: -10, y: -10), in: frames) == 1, "점 → 보조 화면")
        check(OverlayGeometry.displayIndex(containing: CGPoint(x: 5000, y: 10), in: frames) == nil, "화면 밖 점")
        let spanning = CGRect(x: -100, y: -50, width: 400, height: 100) // 대부분 주 화면
        check(OverlayGeometry.displayIndex(bestFor: spanning, in: frames) == 0, "걸친 사각형 → 더 많이 겹치는 화면")
        check(OverlayGeometry.displayIndex(bestFor: CGRect(x: 3000, y: 10, width: 10, height: 10), in: frames) == 0,
              "겹치지 않으면 가장 가까운 화면")
    }

    await suite("Overlay 시선 유리·배지") {
        let minSize = OverlayGeometry.gazeGlassSize(uncertaintyRadius: 0)
        check(minSize == OverlayGeometry.gazeGlassMinSize, "반경 0 → 최소 크기")
        check(OverlayGeometry.gazeGlassSize(uncertaintyRadius: 10_000) == OverlayGeometry.gazeGlassMaxSize, "큰 반경 → 최대 크기")
        check(OverlayGeometry.gazeGlassSize(uncertaintyRadius: .nan) == minSize, "NaN 반경은 최소 크기")
        let s60 = OverlayGeometry.gazeGlassSize(uncertaintyRadius: 60), s90 = OverlayGeometry.gazeGlassSize(uncertaintyRadius: 90)
        check(s90.width > s60.width && s90.height > s60.height, "반경이 커지면 유리도 커진다")
        let glass = OverlayGeometry.gazeGlassRect(center: CGPoint(x: 500, y: 300), uncertaintyRadius: 60)
        check(abs(glass.midX - 500) < 0.001 && abs(glass.midY - 300) < 0.001, "유리는 시선 점 중심")

        check(OverlayGeometry.gazeOpacity(confidence: nil) == 0, "시선 없음 → 투명")
        check(OverlayGeometry.gazeOpacity(confidence: 0.1) == 0, "낮은 신뢰도 → 시선 잃음(페이드)")
        check(abs(OverlayGeometry.gazeOpacity(confidence: 1) - 1) < 1e-9, "신뢰도 1 → 불투명")
        let mid = OverlayGeometry.gazeOpacity(confidence: 0.5)
        check(mid > 0.55 && mid < 1, "중간 신뢰도 → 중간 불투명도")

        let bounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let radius = OverlayGeometry.gazeGlassCornerRadius(for: glass.size)
        let corner = OverlayGeometry.bottomRightCornerPoint(of: glass, cornerRadius: radius)
        check(corner.x > glass.midX && corner.y > glass.midY && corner.x <= glass.maxX && corner.y <= glass.maxY,
              "모서리 점은 유리 우하단")
        let badge = OverlayGeometry.badgeFrame(glass: glass, cornerRadius: radius, bounds: bounds)
        check(abs(badge.midX - corner.x) < 0.001 && abs(badge.midY - corner.y) < 0.001, "배지 중심이 우하단 모서리에 붙는다")
        let moved = OverlayGeometry.badgeFrame(glass: glass.offsetBy(dx: 40, dy: 25), cornerRadius: radius, bounds: bounds)
        check(abs(moved.minX - badge.minX - 40) < 0.001 && abs(moved.minY - badge.minY - 25) < 0.001, "배지는 유리와 함께 움직인다")
        let edgeGlass = OverlayGeometry.gazeGlassRect(center: CGPoint(x: 1915, y: 1075), uncertaintyRadius: 60)
        let edgeBadge = OverlayGeometry.badgeFrame(glass: edgeGlass, cornerRadius: radius, bounds: bounds)
        check(bounds.contains(edgeBadge), "화면 가장자리에서도 배지는 화면 안")

        func level(_ rms: Double, _ voice: Bool, _ mic: AudioLevelSample.MicState) -> AudioLevelSample {
            AudioLevelSample(time: .init(nanoseconds: 1), rms: rms, isVoice: voice, micState: mic)
        }
        check(OverlayGeometry.voiceBadgeMode(for: nil) == .hidden, "음성 표본 없음 → 배지 숨김")
        check(OverlayGeometry.voiceBadgeMode(for: level(0.5, true, .muted)) == .muted, "음소거 상태")
        check(OverlayGeometry.voiceBadgeMode(for: level(0, false, .unavailable)) == .unavailable, "사용 불가 상태")
        check(OverlayGeometry.voiceBadgeMode(for: level(0.005, false, .active)) == .silent, "조용함 상태")
        check(OverlayGeometry.voiceBadgeMode(for: level(0.2, true, .active)) == .speaking(level: 0.2), "말하는 중 상태")
        check(OverlayGeometry.voiceBadgeMode(for: level(3, true, .active)) == .speaking(level: 1), "RMS는 0...1로 자른다")

        let quiet = OverlayGeometry.waveformLevels(rms: 0)
        let loud = OverlayGeometry.waveformLevels(rms: 0.3)
        check(quiet.count == 5 && loud.count == 5, "막대 5개")
        check(quiet.allSatisfy { abs($0 - 0.18) < 1e-9 }, "무음이면 바닥 높이")
        check(loud.allSatisfy { $0 >= 0.18 && $0 <= 1 }, "막대 높이는 0...1")
        check(loud.reduce(0, +) > quiet.reduce(0, +), "RMS가 크면 막대가 높다")
        let phased = OverlayGeometry.waveformLevels(rms: 0.3, phase: 1.3)
        check(phased != loud, "phase에 따라 흔들린다")
        check(OverlayGeometry.waveformLevels(rms: 0.3, barCount: 0).isEmpty, "막대 0개")
    }

    await suite("Overlay 말풍선 배치") {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 900 - 25 - 70) // 메뉴 막대 25, Dock 70
        let size = CGSize(width: 240, height: 80)
        let center = CGRect(x: 600, y: 300, width: 200, height: 40)
        let p = OverlayGeometry.placeBubble(size: size, anchor: center, visibleFrame: visible)
        check(p.side == .below, "기본은 대상 아래")
        check(p.bodyFrame.minY > center.maxY && !p.bodyFrame.intersects(center), "대상을 가리지 않는다")
        check(visible.insetBy(dx: 10, dy: 10).contains(p.bodyFrame), "가시 영역 안")
        if let tip = p.tailTip {
            check(tip.x >= center.minX && tip.x <= center.maxX, "꼬리는 대상 가로 범위를 가리킨다")
            check(tip.y >= center.maxY && tip.y < p.bodyFrame.minY, "꼬리 끝은 대상과 몸체 사이")
        } else { check(false, "꼬리가 있어야 한다") }
        check(p.tailEdge == .top, "아래 배치면 꼬리는 몸체 위쪽")
        check(p.containerFrame.contains(p.bodyFrame) && p.containerFrame.height == size.height + BubbleMetrics.tailLength,
              "컨테이너 = 몸체 + 꼬리")
        check(p.localBodyFrame.minY == BubbleMetrics.tailLength && p.localTailTip?.y == 0, "컨테이너 로컬 좌표")

        // Dock 바로 위 대상 → 위쪽.
        let nearDock = CGRect(x: 600, y: visible.maxY - 50, width: 200, height: 40)
        let up = OverlayGeometry.placeBubble(size: size, anchor: nearDock, visibleFrame: visible)
        check(up.side == .above && up.bodyFrame.maxY < nearDock.minY, "아래 공간 없으면 위로")
        check(up.bodyFrame.maxY <= visible.maxY - 10, "Dock 영역을 침범하지 않는다")
        check(up.tailEdge == .bottom, "위 배치면 꼬리는 몸체 아래쪽")

        // 메뉴 막대 바로 아래 오른쪽 끝 버튼 → 아래, 화면 오른쪽 안으로 밀림.
        let topRight = CGRect(x: 1360, y: 30, width: 70, height: 30)
        let tr = OverlayGeometry.placeBubble(size: size, anchor: topRight, visibleFrame: visible)
        check(tr.side == .below && tr.bodyFrame.maxX <= visible.maxX - 10, "오른쪽 끝 대상: 화면 안으로 밀어 넣는다")
        check(tr.bodyFrame.minY >= visible.minY + 10, "메뉴 막대를 침범하지 않는다")
        if let tip = tr.tailTip {
            check(tip.x <= tr.bodyFrame.maxX - BubbleMetrics.cornerRadius, "꼬리는 몸체 둥근 모서리 안쪽")
        }

        // 위아래가 꽉 찬 세로 띠 → 오른쪽.
        let column = CGRect(x: 100, y: 30, width: 300, height: visible.height - 10)
        let side = OverlayGeometry.placeBubble(size: size, anchor: column, visibleFrame: visible)
        check(side.side == .trailing && side.bodyFrame.minX > column.maxX, "위아래 공간 없으면 옆으로")
        check(side.tailEdge == .leading, "오른쪽 배치면 꼬리는 몸체 왼쪽")
        let rightColumn = CGRect(x: 1100, y: 30, width: 330, height: visible.height - 10)
        check(OverlayGeometry.placeBubble(size: size, anchor: rightColumn, visibleFrame: visible).side == .leading,
              "오른쪽도 막히면 왼쪽")

        // 화면 전체를 덮는 대상 → 화면 안에만 둔다.
        let huge = OverlayGeometry.placeBubble(size: size, anchor: visible, visibleFrame: visible)
        check(visible.contains(huge.bodyFrame), "둘 곳이 없어도 화면 안")
        let none = OverlayGeometry.placeBubble(size: size, anchor: nil, visibleFrame: visible)
        check(none.side == nil && none.tailTip == nil && visible.contains(none.bodyFrame), "대상 없으면 꼬리 없이 화면 안")

        let path = OverlayGeometry.bubblePath(body: p.localBodyFrame, tailTip: p.localTailTip, tailEdge: p.tailEdge)
        let box = path.boundingBoxOfPath
        check(abs(box.minY - 0) < 0.5 && abs(box.maxY - p.containerFrame.height) < 0.5, "말풍선 경로 = 몸체 + 꼬리 높이")
        check(path.contains(CGPoint(x: p.localBodyFrame.midX, y: p.localBodyFrame.midY)), "몸체 중심은 경로 안")
        if let tip = p.localTailTip {
            check(path.contains(CGPoint(x: tip.x, y: tip.y + 3)), "꼬리 끝 근처는 경로 안")
        }
    }

    await suite("Overlay 보간·라벨") {
        let a = CGRect(x: 0, y: 0, width: 1920, height: 1080), b = CGRect(x: 100, y: 200, width: 300, height: 40)
        check(OverlayGeometry.regionFrame(from: a, to: b, progress: 0) == a, "진행 0 → 화면 테두리")
        check(OverlayGeometry.regionFrame(from: a, to: b, progress: 1) == b, "진행 1 → 대상 프레임")
        check(OverlayGeometry.lerp(a, b, 0.5) == CGRect(x: 50, y: 100, width: 1110, height: 560), "사각형 선형 보간")
        check(OverlayGeometry.easeInOut(0) == 0 && OverlayGeometry.easeInOut(1) == 1 && OverlayGeometry.easeInOut(0.5) == 0.5,
              "가감속 끝점")
        let samples = stride(from: 0.0, through: 1.0, by: 0.05).map { OverlayGeometry.easeInOut(CGFloat($0)) }
        check(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 }, "가감속 단조 증가")
        check(OverlayGeometry.easeInOut(-1) == 0 && OverlayGeometry.easeInOut(2) == 1, "범위 밖 진행률은 자른다")
        check(OverlayGeometry.smoothingFactor(dt: 0, timeConstant: 0.1) == 0, "dt 0 → 움직이지 않음")
        check(OverlayGeometry.smoothingFactor(dt: 0.1, timeConstant: 0) == 1, "시간상수 0 → 즉시")
        let k = OverlayGeometry.smoothingFactor(dt: 0.016, timeConstant: 0.08)
        check(k > 0 && k < 1, "평활 계수는 0과 1 사이")
        check(OverlayGeometry.isGazeJump(from: .zero, to: CGPoint(x: 300, y: 0)), "큰 이동은 점프")
        check(!OverlayGeometry.isGazeJump(from: .zero, to: CGPoint(x: 20, y: 10)), "작은 이동은 따라가기")

        check(OverlayGeometry.innerGlowWidth(for: CGSize(width: 600, height: 300), maximum: 22) == 22, "큰 영역은 최대 글로")
        check(OverlayGeometry.innerGlowWidth(for: CGSize(width: 600, height: 50), maximum: 22) == 10, "작은 영역은 짧은 변의 20%")
        check(OverlayGeometry.innerGlowWidth(for: CGSize(width: 10, height: 10), maximum: 22) == 4, "글로 최소 폭")
        check(OverlayGeometry.statusLabelPosition(regionRect: CGRect(x: 0, y: 200, width: 100, height: 40),
                                                  labelHeight: 20, safeTop: 25) == .outsideTop, "공간 있으면 라벨은 영역 바깥 위")
        check(OverlayGeometry.statusLabelPosition(regionRect: CGRect(x: 0, y: 30, width: 100, height: 40),
                                                  labelHeight: 20, safeTop: 25) == .insideTop, "메뉴 막대에 닿으면 안쪽 위")
        let region = AgentRegion.target(frame: .zero, label: OverlayStatusLabel.reading)
        check(OverlayGeometry.statusLabel(region: region, hasPendingApproval: false) == "읽는 중", "영역 라벨")
        check(OverlayGeometry.statusLabel(region: region, hasPendingApproval: true) == "확인 대기", "승인 대기 라벨 우선")
        check(OverlayGeometry.statusLabel(region: .idleScreenEdge, hasPendingApproval: false) == nil, "유휴엔 라벨 없음")
    }

    await suite("Overlay 레이아웃") {
        let primary = DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                      visibleFrame: CGRect(x: 0, y: 70, width: 1920, height: 1080 - 25 - 70))
        let secondary = DisplayGeometry(id: 2, frame: CGRect(x: 1920, y: 180, width: 1440, height: 900),
                                        visibleFrame: CGRect(x: 1920, y: 180, width: 1440, height: 875))
        let displays = [primary, secondary]
        let h: CGFloat = 1080
        let t = MonotonicTime(nanoseconds: 1)

        let idle = OverlayLayoutEngine.layout(OverlayState(), displays: displays, primaryHeight: h)
        check(idle.displays.count == 2, "디스플레이마다 레이아웃")
        check(idle.displays.allSatisfy { $0.region.isIdleEdge && $0.region.isVisible && $0.region.rect == $0.bounds },
              "유휴: 모든 화면 테두리")
        check(idle.displays.allSatisfy { $0.gaze == nil && $0.region.label == nil } && idle.bubble == nil, "유휴: 시선·라벨·말풍선 없음")
        var onlyPrimary = OverlayConfiguration()
        onlyPrimary.idleEdgeOnAllDisplays = false
        let idleOne = OverlayLayoutEngine.layout(OverlayState(), displays: displays, primaryHeight: h, configuration: onlyPrimary)
        check(idleOne.displays[0].region.isVisible && !idleOne.displays[1].region.isVisible, "설정: 주 화면에만 유휴 테두리")

        // 보조 화면(AX 전역 x 1920…, y 0…900)에 대상.
        let targetFrame = CGRect(x: 2100, y: 300, width: 200, height: 30)
        let gaze = GazeSample(time: t, displayID: 1, point: CGPoint(x: 400, y: 500), uncertaintyRadius: 50,
                              confidence: 0.9, calibrationRevision: 1, isFixation: true)
        let audio = AudioLevelSample(time: t, rms: 0.2, isVoice: true, micState: .active)
        let state = OverlayState(gaze: gaze, audioLevel: audio,
                                 agentRegion: .target(frame: targetFrame, label: OverlayStatusLabel.typing))
        let l = OverlayLayoutEngine.layout(state, displays: displays, primaryHeight: h)
        let pad = OverlayConfiguration.default.regionPadding
        check(l.displays[1].region.isVisible && !l.displays[1].region.isIdleEdge, "대상 화면에 라임 영역")
        check(l.displays[1].region.rect == CGRect(x: 180 - pad, y: 300 - pad, width: 200 + 2 * pad, height: 30 + 2 * pad),
              "대상 프레임을 화면 로컬 좌표 + 여백으로")
        check(l.displays[1].region.label == "입력 중", "상태 라벨")
        check(l.displays[1].region.glowWidth < OverlayConfiguration.default.innerGlowWidth, "얇은 입력칸은 글로를 줄여 내용을 가리지 않는다")
        check(!l.displays[0].region.isVisible, "다른 화면 테두리는 사라진다")
        check(l.displays[0].gaze != nil && l.displays[1].gaze == nil, "시선은 시선이 있는 화면에만")
        if let g = l.displays[0].gaze, let badge = l.displays[0].badge {
            check(abs(g.rect.midX - 400) < 0.001 && abs(g.rect.midY - 500) < 0.001, "주 화면 로컬 = AX 전역")
            check(badge.rect.midX > g.rect.midX && badge.rect.midY > g.rect.midY, "배지는 유리 우하단")
            check(badge.mode == .speaking(level: 0.2), "배지 상태")
            check(badge.rect.origin == CGPoint(x: g.rect.minX + badge.offsetFromGlass.x, y: g.rect.minY + badge.offsetFromGlass.y),
                  "배지 위치 = 유리 좌상단 + 붙임 오프셋")
        } else { check(false, "시선 유리·배지가 있어야 한다") }

        // 보조 화면 시선(displayID 불일치여도 점으로 판단).
        let gaze2 = GazeSample(time: t, displayID: 99, point: CGPoint(x: 2000, y: 100), uncertaintyRadius: 50,
                               confidence: 0.9, calibrationRevision: 1, isFixation: true)
        let l2 = OverlayLayoutEngine.layout(OverlayState(gaze: gaze2), displays: displays, primaryHeight: h)
        check(l2.displays[1].gaze.map { abs($0.rect.midX - 80) < 0.001 && abs($0.rect.midY - 100) < 0.001 } == true,
              "보조 화면 로컬 시선 좌표")
        check(l2.displays[1].badge == nil, "음성 표본 없으면 배지 없음")
        let lost = OverlayLayoutEngine.layout(OverlayState(gaze: nil), displays: displays, primaryHeight: h)
        check(lost.displays.allSatisfy { $0.gaze == nil }, "시선 잃음 → 유리 없음")

        // 말풍선 요청.
        let field = UITarget(token: "f", pid: 1, appBundleID: nil, role: "AXTextField", title: nil, frame: targetFrame,
                             isEditable: true, isSecure: false, supportedActions: [], observedAt: t)
        let proposal = ActionProposal(id: UUID(), action: .typeText(target: field, text: "x"), basedOnUtterance: UUID(),
                                      basedOnRevision: 1, rationale: "여기다 이걸 올릴까요?", risk: .medium, expiresAt: t)
        let suggestion = SuggestionCandidate(id: UUID(), target: field, message: "도와드릴까요?", confidence: 0.7,
                                             expiresAt: t, cooldownKey: "k")
        var withBoth = state
        withBoth.pendingApproval = proposal
        withBoth.suggestion = suggestion
        let lb = OverlayLayoutEngine.layout(withBoth, displays: displays, primaryHeight: h)
        check(lb.bubble?.subject == .approval(proposal), "승인 요청이 제안보다 우선")
        check(lb.bubble?.subject.message == "여기다 이걸 올릴까요?", "말풍선 문구")
        check(lb.bubble?.anchorSource == .region && lb.bubble?.displayIndex == 1, "말풍선은 라임 영역을 가리킨다")
        check(lb.displays[1].region.label == "확인 대기", "승인 대기 중 라벨")

        let suggestOnly = OverlayLayoutEngine.layout(OverlayState(suggestion: suggestion), displays: displays, primaryHeight: h)
        check(suggestOnly.bubble?.anchorSource == .target && suggestOnly.bubble?.displayIndex == 1,
              "영역이 유휴면 제안 대상을 가리킨다")
        let noTarget = SuggestionCandidate(id: UUID(), target: nil, message: "쉬었다 할까요?", confidence: 0.7,
                                           expiresAt: t, cooldownKey: "k2")
        let gazeAnchored = OverlayLayoutEngine.layout(OverlayState(gaze: gaze, suggestion: noTarget), displays: displays, primaryHeight: h)
        check(gazeAnchored.bubble?.anchorSource == .gaze, "대상 없으면 시선 유리를 가리킨다")
        let floating = OverlayLayoutEngine.layout(OverlayState(suggestion: noTarget), displays: displays, primaryHeight: h)
        check(floating.bubble?.anchorSource == BubbleRequest.AnchorSource.none && floating.bubble?.anchor == nil, "가리킬 곳이 없으면 꼬리 없는 말풍선")
        let empty = SuggestionCandidate(id: UUID(), target: field, message: "  ", confidence: 0.7, expiresAt: t, cooldownKey: "k3")
        check(OverlayLayoutEngine.layout(OverlayState(suggestion: empty), displays: displays, primaryHeight: h).bubble == nil,
              "빈 문구는 말풍선 없음")
        let blank = ActionProposal(id: UUID(), action: .press(target: field), basedOnUtterance: UUID(), basedOnRevision: 1,
                                   rationale: "", risk: .low, expiresAt: t)
        check(OverlayBubbleSubject.approval(blank).message == "이 작업을 실행할까요?", "근거가 비면 기본 승인 문구")
    }

    await suite("Overlay 말풍선 일정") {
        let t = MonotonicTime(nanoseconds: 1)
        let s = SuggestionCandidate(id: UUID(), target: nil, message: "여기다 이걸 올릴까요?", confidence: 0.8,
                                    expiresAt: t, cooldownKey: "k")
        let anchor = CGRect(x: 10, y: 10, width: 100, height: 30)
        let request = BubbleRequest(subject: .suggestion(s), anchor: anchor, anchorSource: .region, displayIndex: 0)
        let key = BubbleScheduling.Key(request)
        check(BubbleScheduling.decide(current: nil, isShown: false, request: request, dismissedSubjectID: nil,
                                      secondsUntilRegionSettles: 0.4) == .show(after: 0.4), "영역이 도착한 뒤에 나타난다")
        check(BubbleScheduling.decide(current: key, isShown: true, request: request, dismissedSubjectID: nil,
                                      secondsUntilRegionSettles: 0) == .keep, "같은 내용이면 그대로")
        check(BubbleScheduling.decide(current: key, isShown: true, request: nil, dismissedSubjectID: nil,
                                      secondsUntilRegionSettles: 0) == .hide, "요청이 사라지면 숨김")
        check(BubbleScheduling.decide(current: nil, isShown: false, request: request, dismissedSubjectID: s.id,
                                      secondsUntilRegionSettles: 0) == .keep, "이미 답한 말풍선은 다시 띄우지 않는다")
        var moved = request
        moved.anchor = anchor.offsetBy(dx: 200, dy: 0)
        check(BubbleScheduling.decide(current: key, isShown: true, request: moved, dismissedSubjectID: nil,
                                      secondsUntilRegionSettles: 0.5) == .show(after: 0.5), "대상이 옮겨지면 도착 후 다시 배치")
        let revised = SuggestionCandidate(id: s.id, target: nil, message: "여기에 올릴까요?", confidence: 0.8,
                                          expiresAt: t, cooldownKey: "k")
        let revisedRequest = BubbleRequest(subject: .suggestion(revised), anchor: anchor, anchorSource: .region, displayIndex: 0)
        check(BubbleScheduling.decide(current: key, isShown: true, request: revisedRequest, dismissedSubjectID: nil,
                                      secondsUntilRegionSettles: 0) == .updateInPlace, "문구만 바뀌면 제자리 갱신")
        let gazeRequest = BubbleRequest(subject: .suggestion(s), anchor: anchor, anchorSource: .gaze, displayIndex: 0)
        var jitter = gazeRequest
        jitter.anchor = anchor.offsetBy(dx: 7, dy: -4)
        check(BubbleScheduling.decide(current: BubbleScheduling.Key(gazeRequest), isShown: true, request: jitter,
                                      dismissedSubjectID: nil, secondsUntilRegionSettles: 0) == .keep,
              "시선 기준 말풍선은 시선 흔들림을 따라가지 않는다")
    }

    await suite("Overlay 데모 시나리오") {
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let phases = Set(stride(from: 0.0, to: OverlayDemoScript.period, by: 0.5).map(OverlayDemoScript.phase(at:)))
        check(phases == Set(OverlayDemoScript.Phase.allCases), "한 주기에 모든 단계")
        let a = OverlayDemoScript.state(at: 12.5, display: display), b = OverlayDemoScript.state(at: 15.5, display: display)
        check(a.suggestion?.message == "여기다 이걸 올릴까요?", "제안 단계 문구")
        check(a.suggestion?.id == b.suggestion?.id, "같은 단계 안에서 제안 id 고정(말풍선 깜빡임 방지)")
        check(OverlayDemoScript.state(at: 32.5, display: display).suggestion?.id != a.suggestion?.id, "다음 주기엔 새 제안")
        check(OverlayDemoScript.state(at: 16.5, display: display).pendingApproval != nil, "승인 단계")
        check(OverlayDemoScript.state(at: 19, display: display).gaze == nil, "시선 잃음 단계")
        check(OverlayDemoScript.state(at: 19, display: display).audioLevel?.micState == .unavailable, "마이크 사용 불가 단계")
        check(OverlayDemoScript.state(at: 13, display: display).audioLevel?.micState == .muted, "음소거 단계")

        // 데모 화면 기준 말풍선이 메뉴 막대·Dock을 피하고 대상을 가리지 않는다.
        let geometry = DisplayGeometry(id: 1, frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                       visibleFrame: CGRect(x: 0, y: 80, width: 1512, height: 982 - 33 - 80))
        for time in [13.0, 17.0] {
            let state = OverlayDemoScript.state(at: time, display: display)
            let layout = OverlayLayoutEngine.layout(state, displays: [geometry], primaryHeight: 982)
            guard let request = layout.bubble, let anchor = request.anchor else { check(false, "말풍선 요청"); continue }
            let visible = geometry.topLeftVisibleFrame(primaryHeight: 982)
            let placement = OverlayGeometry.placeBubble(size: CGSize(width: 260, height: 84), anchor: anchor, visibleFrame: visible)
            check(visible.contains(placement.bodyFrame) && !placement.bodyFrame.intersects(anchor),
                  "데모 \(time)s 말풍선: 화면 안, 대상 비가림 (\(placement.side?.rawValue ?? "-"))")
        }
    }

    await suite("Overlay 컨트롤러") {
        await MainActor.run {
            let controller = OverlayController()
            check(controller.overlayWindowNumbers.isEmpty && controller.bubbleWindowNumber == nil, "render 전에는 창을 만들지 않는다")
            check(controller.processIdentifier == ProcessInfo.processInfo.processIdentifier, "오버레이 pid 공개")
            check(controller.windowRegistry.isOverlayProcess(ProcessInfo.processInfo.processIdentifier), "AX 적중 제외용 pid 판별")
            check(controller.windowRegistry.snapshot.windowNumbers.isEmpty, "창 번호 목록")
        }
    }
}
