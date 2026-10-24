import AgentContracts
import AXControl
import CoreGraphics
import Foundation

func axChecks() async {
    await suite("AXControl") {
        coordinateChecks()
        scalingChecks()
        tokenRegistryChecks()
        semanticsChecks()
        validationChecks()
        treeChecks()
        keyChecks()
        miscChecks()
        captureExclusionChecks()
    }
}

/// 화면 캡처에서 Gaze 자신의 오버레이 창을 빼는 규칙(실제 캡처는 하지 않는다).
private func captureExclusionChecks() {
    let own: Int32 = 100
    check(ScreenCapture.shouldExclude(windowNumber: 7, ownerPID: 999, ownPID: own, excludeOwnProcess: false, registry: [7]),
          "오버레이 레지스트리에 있는 창은 항상 제외")
    check(ScreenCapture.shouldExclude(windowNumber: 8, ownerPID: own, ownPID: own, excludeOwnProcess: true, registry: []),
          "자기 프로세스 창은 기본 제외")
    check(!ScreenCapture.shouldExclude(windowNumber: 8, ownerPID: 999, ownPID: own, excludeOwnProcess: true, registry: [7]),
          "다른 앱 창은 캡처")
    let registryCapture = ScreenCapture(excludedWindowNumbers: { [42, 43] })
    check(registryCapture.excludedWindowNumbers?() == [42, 43], "캡처가 레지스트리 스냅샷을 읽음")
}

private func near(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 1e-6) -> Bool { abs(a - b) <= eps }
private func near(_ a: CGPoint, _ b: CGPoint, _ eps: CGFloat = 1e-6) -> Bool { near(a.x, b.x, eps) && near(a.y, b.y, eps) }
private func near(_ a: CGRect, _ b: CGRect, _ eps: CGFloat = 1e-6) -> Bool {
    near(a.origin, b.origin, eps) && near(a.width, b.width, eps) && near(a.height, b.height, eps)
}

private func coordinateChecks() {
    let h: CGFloat = 1000
    let ax = CGRect(x: 100, y: 50, width: 200, height: 100)
    let cocoa = CoordinateConversion.cocoaRect(fromAX: ax, primaryScreenHeight: h)
    check(near(cocoa, CGRect(x: 100, y: 850, width: 200, height: 100)), "AX 좌상단 사각형 → Cocoa 좌하단 사각형")
    check(near(CoordinateConversion.axRect(fromCocoa: cocoa, primaryScreenHeight: h), ax), "Cocoa → AX 사각형 왕복")
    check(near(CoordinateConversion.cocoaPoint(fromAX: CGPoint(x: 10, y: 0), primaryScreenHeight: h), CGPoint(x: 10, y: 1000)),
          "AX 원점 y=0은 Cocoa y=화면 높이")
    let p = CGPoint(x: 333, y: 777)
    check(near(CoordinateConversion.axPoint(fromCocoa: CoordinateConversion.cocoaPoint(fromAX: p, primaryScreenHeight: h),
                                            primaryScreenHeight: h), p), "점 좌표 왕복")
    // 주 화면 위쪽 보조 모니터(AX y 음수)도 같은 식으로 변환된다.
    let upper = CoordinateConversion.cocoaRect(fromAX: CGRect(x: 0, y: -1080, width: 1920, height: 1080), primaryScreenHeight: h)
    check(near(upper, CGRect(x: 0, y: 1000, width: 1920, height: 1080)), "위쪽 보조 모니터 변환")

    let window = CGRect(x: 497, y: 45, width: 561, height: 200)
    let local = CoordinateConversion.windowLocal(fromGlobal: CGPoint(x: 600, y: 100), windowFrame: window)
    check(near(local, CGPoint(x: 103, y: 55)), "전역 → 창 기준 좌표")
    check(near(CoordinateConversion.global(fromWindowLocal: local, windowFrame: window), CGPoint(x: 600, y: 100)), "창 기준 → 전역 왕복")
}

private func scalingChecks() {
    let policy = ScreenshotScalingPolicy.claudeMaximum
    // 5K 화면: 긴 변 한도가 먼저 걸린다.
    let fiveK = policy.targetPixelSize(forNativePixels: CGSize(width: 5120, height: 2880))
    check(fiveK == CGSize(width: 2576, height: 1449), "5K → 2576x1449 (실제 \(fiveK))")
    // 16인치 MacBook Pro 레티나: 총 픽셀 한도가 걸린다.
    let mbp = policy.targetPixelSize(forNativePixels: CGSize(width: 3456, height: 2234))
    check(max(mbp.width, mbp.height) <= 2576 && mbp.width * mbp.height <= 3_750_000, "MBP 레티나 축소 결과가 한도 안 (\(mbp))")
    check(abs(mbp.width / mbp.height - 3456.0 / 2234.0) < 0.002, "축소 후 종횡비 유지")
    check(policy.fits(mbp), "축소 결과는 정책을 만족")
    check(policy.targetPixelSize(forNativePixels: CGSize(width: 1280, height: 800)) == CGSize(width: 1280, height: 800),
          "작은 이미지는 확대하지 않음")
    let portrait = policy.targetPixelSize(forNativePixels: CGSize(width: 2000, height: 6000))
    check(portrait.height <= 2576 && portrait.width * portrait.height <= 3_750_000, "세로로 긴 이미지도 긴 변 기준 축소")
    check(!policy.fits(CGSize(width: 2577, height: 10)), "긴 변 2577px은 한도 초과")

    // 레티나 1728x1117pt 화면을 2408x1556px로 줄여 보낸 경우의 좌표 매핑.
    let geometry = ScreenshotGeometry(sourceRect: CGRect(x: 100, y: 200, width: 1000, height: 500),
                                      imageSize: CGSize(width: 2000, height: 1000))
    check(near(geometry.pixelsPerPointX, 2) && near(geometry.pixelsPerPointY, 2), "포인트당 픽셀 = 2")
    check(near(geometry.globalPoint(fromImagePixel: CGPoint(x: 500, y: 300)), CGPoint(x: 350, y: 350)), "픽셀 → 전역 좌표")
    check(near(geometry.imagePixel(fromGlobal: CGPoint(x: 350, y: 350)), CGPoint(x: 500, y: 300)), "전역 좌표 → 픽셀")
    check(near(geometry.globalRect(fromImagePixelRect: CGRect(x: 0, y: 0, width: 200, height: 100)),
               CGRect(x: 100, y: 200, width: 100, height: 50)), "zoom 픽셀 영역 → 전역 영역")
    check(near(geometry.imagePixelRect(fromGlobal: CGRect(x: 100, y: 200, width: 100, height: 50)),
               CGRect(x: 0, y: 0, width: 200, height: 100)), "전역 영역 → 픽셀 영역")
    check(geometry.containsImagePixel(CGPoint(x: 1999, y: 999)) && !geometry.containsImagePixel(CGPoint(x: 2000, y: 0)),
          "이미지 경계 판정")
    check(near(geometry.clampedGlobalPoint(fromImagePixel: CGPoint(x: -50, y: 5000)), CGPoint(x: 100, y: 699.5)),
          "이미지 밖 좌표는 가장자리로 붙임")

    let mbpGeometry = ScreenshotGeometry(sourceRect: CGRect(x: 0, y: 0, width: 1728, height: 1117), imageSize: mbp)
    let roundTrip = mbpGeometry.globalPoint(fromImagePixel: mbpGeometry.imagePixel(fromGlobal: CGPoint(x: 864, y: 558.5)))
    check(near(roundTrip, CGPoint(x: 864, y: 558.5), 1e-9), "비정수 배율 매핑 왕복")
}

private struct FakeElement: Hashable { let id: Int }

private func tokenRegistryChecks() {
    let registry = TokenRegistry<FakeElement>(capacity: 4, prefix: "t")
    let a = registry.register(FakeElement(id: 1), pid: 10, role: "AXButton", frame: CGRect(x: 0, y: 0, width: 10, height: 10))
    let again = registry.register(FakeElement(id: 1), pid: 10, role: "AXButton", frame: CGRect(x: 5, y: 0, width: 10, height: 10))
    check(a == again, "같은 요소는 같은 token")
    check(registry.entry(for: a)?.frame?.minX == 5, "재등록하면 메타데이터 갱신")
    check(a.hasPrefix("t-10-"), "token에 접두어·pid 포함 (\(a))")
    let b = registry.register(FakeElement(id: 2), pid: 10, role: "AXTextField", frame: nil)
    check(a != b, "다른 요소는 다른 token")
    check(registry.entry(for: b)?.element == FakeElement(id: 2), "token으로 요소 되찾기")
    check(registry.token(for: FakeElement(id: 2)) == b, "요소로 token 찾기")
    check(registry.entry(for: "t-10-999") == nil, "모르는 token은 nil")

    let c = registry.register(FakeElement(id: 3), pid: 20, role: "AXLink", frame: nil)
    let d = registry.register(FakeElement(id: 4), pid: 20, role: "AXLink", frame: nil)
    _ = registry.entry(for: a)  // a를 최근 사용으로 만든다.
    let e = registry.register(FakeElement(id: 5), pid: 20, role: "AXLink", frame: nil)
    check(registry.count == 4, "용량 초과 시 내보냄 (count \(registry.count))")
    check(registry.entry(for: b) == nil, "가장 오래 안 쓴 token(b)부터 내보냄")
    check(registry.entry(for: a) != nil && registry.entry(for: e) != nil, "최근 사용·새 token은 유지")

    check(registry.removeAll(pid: 20) == 3, "pid 단위 무효화 개수")
    check(registry.entry(for: c) == nil && registry.entry(for: d) == nil, "무효화된 token은 nil")
    check(registry.count == 1, "다른 pid token은 유지")
    registry.remove(token: a)
    check(registry.count == 0 && registry.token(for: FakeElement(id: 1)) == nil, "개별 제거 후 역색인도 제거")
}

private func semanticsChecks() {
    check(AXSemantics.isSecure(role: "AXTextField", subrole: "AXSecureTextField"), "비밀번호 필드 판정")
    check(!AXSemantics.isSecure(role: "AXTextField", subrole: "AXSearchField"), "검색 필드는 비밀번호 아님")
    check(AXSemantics.isEditable(role: "AXTextArea", subrole: nil, valueSettable: true, selectedTextSettable: false), "글상자 편집 가능")
    check(AXSemantics.isEditable(role: "AXTextField", subrole: nil, valueSettable: false, selectedTextSettable: true),
          "AXSelectedText만 설정 가능해도 편집 가능")
    check(!AXSemantics.isEditable(role: "AXCheckBox", subrole: nil, valueSettable: true, selectedTextSettable: false),
          "체크박스 값 설정은 글자 편집이 아님")
    check(!AXSemantics.isEditable(role: "AXTextField", subrole: nil, valueSettable: false, selectedTextSettable: false),
          "읽기 전용 글상자는 편집 불가")

    check(AXSemantics.label(title: nil, description: "검색", value: "고양이", placeholder: nil, help: nil, isSecure: false) == "검색",
          "이름은 설명이 값보다 우선")
    check(AXSemantics.label(title: "  ", description: nil, value: "줄1\n줄2\t끝", placeholder: nil, help: nil, isSecure: false)
          == "줄1 줄2 끝", "빈 제목은 건너뛰고 공백 정리")
    check(AXSemantics.label(title: nil, description: nil, value: "hunter2", placeholder: nil, help: nil, isSecure: true) == nil,
          "비밀번호 값은 이름으로 쓰지 않음")
    check(AXSemantics.label(title: String(repeating: "가", count: 300), description: nil, value: nil, placeholder: nil,
                            help: nil, isSecure: false, maxLength: 10)?.count == 10, "긴 이름 자르기")

    check(AXSemantics.humanizedRole("AXTextField") == "text field", "역할 이름 사람말로")
    check(AXSemantics.humanizedRole("AXMenuBarItem") == "menu bar item", "여러 단어 역할")
    check(AXSemantics.humanizedAction("AXScrollUpByPage") == "scroll up by page", "동작 이름 사람말로")
    check(AXSemantics.secondaryActions(["AXPress", "AXShowMenu", "AXScrollToVisible"]) == ["AXShowMenu"], "보조 동작에서 기본·잡음 제외")

    check(AXSemantics.shouldPromote(childRole: "AXStaticText", childActions: [], parentRole: "AXButton", parentActions: ["AXPress"]),
          "버튼 안 글자는 버튼으로 올림")
    check(!AXSemantics.shouldPromote(childRole: "AXStaticText", childActions: [], parentRole: "AXGroup", parentActions: []),
          "수동 부모로는 올리지 않음")
    check(!AXSemantics.shouldPromote(childRole: "AXTextField", childActions: [], parentRole: "AXButton", parentActions: ["AXPress"]),
          "입력칸은 올리지 않음")

    check(AXSemantics.insertionVerified(before: "banana", after: "bananaa", inserted: "a"), "삽입 후 등장 횟수 증가 = 확인")
    check(!AXSemantics.insertionVerified(before: "hello", after: "hello", inserted: "lo"), "값이 그대로면 미확인")
    check(!AXSemantics.insertionVerified(before: "x", after: nil, inserted: "y"), "읽기 실패는 미확인")
    check(AXSemantics.insertionVerified(before: nil, after: "안녕", inserted: "안녕"), "이전 값을 몰라도 새 값에 있으면 확인")
    check(AXSemantics.valueMatches(expected: "0.5", actual: "0.50", role: "AXSlider"), "숫자 역할은 수치 비교")
    check(!AXSemantics.valueMatches(expected: "0.5", actual: "0.50", role: "AXTextField"), "글상자는 문자열 비교")

    check(ChromiumAccessibility.kind(bundleID: "com.tinyspeck.slackmacgap", frameworkNames: ["Electron Framework.framework"]) == .electron,
          "Electron 감지")
    check(ChromiumAccessibility.kind(bundleID: "com.google.Chrome", frameworkNames: []) == .chromium, "Chrome 감지")
    check(ChromiumAccessibility.kind(bundleID: "com.apple.TextEdit", frameworkNames: ["Sparkle.framework"]) == .native, "일반 앱")
    check(ChromiumAccessibility.attributesToEnable(for: .electron) == ["AXManualAccessibility"], "Electron은 AXManualAccessibility")
    check(ChromiumAccessibility.attributesToEnable(for: .chromium) == ["AXManualAccessibility", "AXEnhancedUserInterface"],
          "Chromium은 AXEnhancedUserInterface를 마지막 수단으로")
    check(ChromiumAccessibility.attributesToEnable(for: .native).isEmpty, "일반 앱은 건드리지 않음")
}

private func makeTarget(pid: Int32 = 42, role: String = "AXButton", frame: CGRect, secure: Bool = false) -> UITarget {
    UITarget(token: "ax-\(pid)-1", pid: pid, appBundleID: "com.example", role: role, title: "OK", frame: frame,
             isEditable: false, isSecure: secure, supportedActions: ["AXPress"], observedAt: MonotonicTime(nanoseconds: 1))
}

private func validationChecks() {
    let frame = CGRect(x: 100, y: 100, width: 80, height: 30)
    let target = makeTarget(frame: frame)
    check(TargetValidation.validate(expected: target, live: LiveElementState(pid: 42, role: "AXButton", subrole: nil,
                                                                            frame: frame.offsetBy(dx: 5, dy: -3))) == nil,
          "조금 움직인 요소는 통과")
    check(TargetValidation.validate(expected: target, live: LiveElementState(pid: 43, role: "AXButton", subrole: nil, frame: frame))?.code
          == .elementStale, "pid가 바뀌면 stale")
    check(TargetValidation.validate(expected: target, live: LiveElementState(pid: 42, role: "AXLink", subrole: nil, frame: frame))?.code
          == .elementStale, "role이 바뀌면 stale")
    check(TargetValidation.validate(expected: target, live: LiveElementState(pid: 42, role: "AXButton", subrole: nil,
                                                                            frame: frame.offsetBy(dx: 0, dy: 200)))?.code
          == .elementMoved, "크게 움직이면 element_moved")
    check(TargetValidation.validate(expected: target, live: LiveElementState(pid: 42, role: "AXButton", subrole: nil,
                                                                            frame: CGRect(x: 100, y: 100, width: 80, height: 300)))?.code
          == .elementMoved, "크기가 크게 바뀌면 element_moved")
    check(TargetValidation.validate(expected: target, live: LiveElementState(pid: 42, role: "AXButton", subrole: nil, frame: nil)) == nil,
          "현재 프레임을 못 읽으면 pid·role만 확인")
    let unknownFrame = makeTarget(frame: .zero)
    check(TargetValidation.validate(expected: unknownFrame, live: LiveElementState(pid: 42, role: "AXButton", subrole: nil,
                                                                                  frame: CGRect(x: 900, y: 900, width: 5, height: 5))) == nil,
          "관찰 당시 프레임이 없으면 위치 비교 생략")

    let windows = [
        HitTestFallback.WindowInfo(ownerPID: 1, layer: 1000, bounds: CGRect(x: 0, y: 0, width: 2000, height: 2000), alpha: 1),
        HitTestFallback.WindowInfo(ownerPID: 2, layer: 0, bounds: CGRect(x: 0, y: 0, width: 100, height: 100), alpha: 0),
        HitTestFallback.WindowInfo(ownerPID: 3, layer: 0, bounds: CGRect(x: 500, y: 500, width: 100, height: 100), alpha: 1),
        HitTestFallback.WindowInfo(ownerPID: 4, layer: 0, bounds: CGRect(x: 0, y: 0, width: 800, height: 800), alpha: 1),
    ]
    check(HitTestFallback.candidatePIDs(at: CGPoint(x: 50, y: 50), windows: windows, excludedPIDs: [1]) == [4],
          "오버레이·투명 창을 건너뛰고 아래 창 선택")
    check(HitTestFallback.candidatePIDs(at: CGPoint(x: 550, y: 550), windows: windows, excludedPIDs: [1]) == [3, 4],
          "앞에 있는 창부터 후보 나열")
    check(HitTestFallback.candidatePIDs(at: CGPoint(x: 1500, y: 1500), windows: windows, excludedPIDs: [1]).isEmpty,
          "덮는 창이 없으면 후보 없음")
    let dup = windows + [HitTestFallback.WindowInfo(ownerPID: 3, layer: 0, bounds: CGRect(x: 0, y: 0, width: 900, height: 900), alpha: 1)]
    check(HitTestFallback.candidatePIDs(at: CGPoint(x: 550, y: 550), windows: dup, excludedPIDs: [1]) == [3, 4], "같은 앱 창은 한 번만")
}

/// 검사용 가짜 접근성 트리.
private final class FakeNode {
    let info: AXNodeInfo
    let children: [FakeNode]
    init(_ info: AXNodeInfo, _ children: [FakeNode] = []) {
        self.info = info
        self.children = children
    }
}

private func walker() -> AXTreeWalker<FakeNode> {
    AXTreeWalker<FakeNode>(info: { $0.info }, children: { $0.children })
}

private func treeChecks() {
    let tree = FakeNode(AXNodeInfo(role: "AXWindow", subrole: "AXStandardWindow", roleDescription: "standard window", title: "메모",
                                   frame: CGRect(x: 497, y: 45, width: 561, height: 200)), [
        FakeNode(AXNodeInfo(role: "AXScrollArea", roleDescription: "scroll area",
                            actions: ["AXScrollUpByPage", "AXScrollDownByPage", "AXScrollToVisible"]), [
            FakeNode(AXNodeInfo(role: "AXTextArea", roleDescription: "text entry area", value: "첫 줄\n둘째 줄",
                                frame: CGRect(x: 497, y: 70, width: 545, height: 175), isValueSettable: true, isFocused: true)),
        ]),
        // 이름 없는 묶음은 줄을 만들지 않고 자식을 끌어올린다.
        FakeNode(AXNodeInfo(role: "AXGroup"), [
            FakeNode(AXNodeInfo(role: "AXButton", roleDescription: "button", title: "확인",
                                frame: CGRect(x: 900, y: 210, width: 60, height: 24), actions: ["AXPress"])),
            FakeNode(AXNodeInfo(role: "AXTextField", subrole: "AXSecureTextField", roleDescription: "secure text field",
                                descriptionText: "암호", value: "hunter2", isValueSettable: true)),
            FakeNode(AXNodeInfo(role: "AXButton", title: "숨김", isHidden: true)),
            FakeNode(AXNodeInfo(role: "AXCheckBox", title: "저장", isEnabled: false)),
        ]),
    ])

    let result = walker().walk(root: tree, limits: AppStateLimits())
    check(result.nodes.map(\.index) == Array(0..<result.nodes.count), "색인은 0부터 연속")
    check(result.nodes.count == 6, "숨김·이름 없는 묶음 제외 후 6줄 (실제 \(result.nodes.count))")
    check(!result.truncation.truncated, "한도 안이면 잘림 없음")

    let text = AppStateFormatter.treeText(appName: "Stickies", bundleID: "com.apple.Stickies", pid: 20518, windowTitle: "메모",
                                          nodes: result.nodes.map { ($0.index, $0.depth, $0.info) }, focusedIndex: 2,
                                          truncation: result.truncation)
    let expected = """
    App=com.apple.Stickies (pid 20518)
    Window: "메모", App: Stickies.

    0 standard window - 메모
    \t1 scroll area, Secondary Actions: scroll up by page, scroll down by page
    \t\t2 text entry area (settable) - 첫 줄 둘째 줄
    \t3 button - 확인
    \t4 secure text field (settable) (secure) - 암호
    \t5 check box (disabled) - 저장

    The focused UI element is 2 text entry area (settable) - 첫 줄 둘째 줄.
    """
    check(text == expected, "Orca 형식 트리 텍스트")
    if text != expected { print(text) }
    check(!text.contains("hunter2"), "비밀번호 값은 트리에 나오지 않음")

    let framed = AppStateFormatter.line(index: 3, info: result.nodes[3].info, limits: AppStateLimits(includeFramesInText: true))
    check(framed == "3 button - 확인 [900,210 60x24]", "프레임 표시 옵션")

    // 개수 한도
    let wide = FakeNode(AXNodeInfo(role: "AXList", title: "목록"),
                        (0..<50).map { FakeNode(AXNodeInfo(role: "AXStaticText", value: "항목 \($0)")) })
    let limited = walker().walk(root: wide, limits: AppStateLimits(maxNodes: 10))
    check(limited.nodes.count == 10 && limited.truncation.maxNodesReached, "개수 한도에서 멈춤")
    let childLimited = walker().walk(root: wide, limits: AppStateLimits(maxChildrenPerNode: 5))
    check(childLimited.nodes.count == 6 && childLimited.truncation.omittedChildren == 45, "자식 수 한도")
    let limitedText = AppStateFormatter.treeText(appName: "X", bundleID: nil, pid: 1, windowTitle: nil,
                                                 nodes: childLimited.nodes.map { ($0.index, $0.depth, $0.info) },
                                                 focusedIndex: nil, truncation: childLimited.truncation)
    check(limitedText.contains("… truncated: 45 children omitted"), "잘림 표시")

    // 깊이 한도
    var deep = FakeNode(AXNodeInfo(role: "AXButton", title: "바닥"))
    for i in 0..<10 { deep = FakeNode(AXNodeInfo(role: "AXSplitGroup", title: "층 \(i)"), [deep]) }
    let shallow = walker().walk(root: deep, limits: AppStateLimits(maxDepth: 3))
    check(shallow.nodes.count == 4 && shallow.truncation.maxDepthReached, "깊이 한도에서 멈춤")
    check(shallow.nodes.last?.depth == 3, "들여쓰기 깊이 기록")

    // 스냅샷에서 시선 좌표로 요소 찾기
    let frames: [(Int, CGRect)] = [(0, CGRect(x: 0, y: 0, width: 500, height: 500)), (1, CGRect(x: 100, y: 100, width: 50, height: 20)),
                                   (2, .zero)]
    let elements = frames.map { index, frame in
        AppStateElement(index: index, depth: index, target: makeTarget(role: "AXButton", frame: frame))
    }
    let snapshot = AppStateSnapshot(pid: 42, appName: "X", bundleID: nil, windowTitle: nil, windowFrame: nil, treeText: "",
                                    elements: elements, focusedIndex: nil, truncation: AppStateTruncation(),
                                    capturedAt: MonotonicTime(nanoseconds: 0))
    check(snapshot.element(at: CGPoint(x: 120, y: 110))?.index == 1, "가장 작은 포함 요소 선택")
    check(snapshot.element(at: CGPoint(x: 400, y: 400))?.index == 0, "바깥 요소 선택")
    check(snapshot.element(at: CGPoint(x: 900, y: 900)) == nil, "포함 요소 없음")
}

private func keyChecks() {
    check(KeyComboParser.parse("cmd+shift+p") == KeyCombo(keyCode: 35, modifiers: [.command, .shift]), "cmd+shift+p")
    check(KeyComboParser.parse("CmdOrCtrl+A") == KeyCombo(keyCode: 0, modifiers: [.command]), "Orca CmdOrCtrl+A")
    check(KeyComboParser.parse("ctrl+a") == KeyCombo(keyCode: 0, modifiers: [.control]), "xdotool ctrl+a")
    check(KeyComboParser.parse("Return") == KeyCombo(keyCode: 36), "Return")
    check(KeyComboParser.parse("Page_Down") == KeyCombo(keyCode: 121), "Page_Down")
    check(KeyComboParser.parse("BackSpace") == KeyCombo(keyCode: 51), "BackSpace")
    check(KeyComboParser.parse("Delete") == KeyCombo(keyCode: 117), "xdotool Delete = 앞으로 지우기")
    check(KeyComboParser.parse("F5") == KeyCombo(keyCode: 96), "F5")
    check(KeyComboParser.parse("super+space") == KeyCombo(keyCode: 49, modifiers: [.command]), "super = command")
    check(KeyComboParser.parse("ctrl++") == KeyCombo(keyCode: 24, modifiers: [.control, .shift]), "ctrl++ = ctrl+shift+=")
    check(KeyComboParser.parse("hyper+a") == nil && KeyComboParser.parse("ctrl+nosuchkey") == nil, "모르는 이름은 nil")
    check(KeyComboParser.parseSequence("ctrl+a Delete")?.count == 2, "공백 구분 연속 조합")
    check(KeyModifiers([.command, .option]).cgFlags == [.maskCommand, .maskAlternate], "수식 키 → CGEventFlags")

    check(TypingSegment.segments(for: "ab\ncd\te") == [.text("ab"), .key(.returnKey), .text("cd"), .key(.tab), .text("e")],
          "줄바꿈·탭은 실제 키로")
    let long = String(repeating: "가", count: 45)
    let chunks = TypingSegment.segments(for: long)
    check(chunks == [.text(String(repeating: "가", count: 20)), .text(String(repeating: "가", count: 20)),
                     .text(String(repeating: "가", count: 5))], "UTF-16 20단위로 나눔")
    let emoji = String(repeating: "👍🏽", count: 7)  // 문자 하나가 UTF-16 4단위
    let emojiChunks = TypingSegment.segments(for: emoji)
    let rejoined = emojiChunks.compactMap { if case .text(let s) = $0 { s } else { nil } }.joined()
    check(rejoined == emoji && emojiChunks.allSatisfy { if case .text(let s) = $0 { s.utf16.count <= 20 } else { false } },
          "이모지 문자를 쪼개지 않고 나눔")
}

private func miscChecks() {
    let error = AXControlError(.secureFieldRejected, "no")
    check(error.reason == "secure_field_rejected: no", "reason 형식")
    check(AXControlError.code(fromReason: error.reason) == .secureFieldRejected, "reason에서 코드 되읽기")
    check(AXControlError.code(fromReason: "free text") == nil, "형식 밖 reason")
    check(PermissionStatus.settingsURL(for: .screenRecording).absoluteString.hasSuffix("Privacy_ScreenCapture"), "화면 기록 설정 주소")
    let status = PermissionStatus(accessibility: true, screenRecording: false, postEvents: true)
    check(status.missing == [.screenRecording] && !status.allGranted, "빠진 권한 목록")
    let clock = AXUptimeClock()
    let t1 = clock.now(), t2 = clock.now()
    check(t2 >= t1, "단조 시계")
}
