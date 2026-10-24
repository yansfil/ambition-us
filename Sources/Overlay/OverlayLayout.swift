import AgentContracts
import CoreGraphics
import Foundation

/// 오버레이 외형 설정.
public struct OverlayConfiguration: Sendable, Equatable {
    /// 에이전트 영역 색(#B7F56B).
    public var limeRGB: UInt32 = 0xB7F56B
    /// 대상 프레임 바깥으로 띄우는 테두리 여백.
    public var regionPadding: CGFloat = 6
    public var regionCornerRadius: CGFloat = 10
    /// 유휴 상태 화면 테두리의 모서리 반경(내장 디스플레이 둥근 모서리와 비슷하게).
    public var screenEdgeCornerRadius: CGFloat = 12
    public var borderWidth: CGFloat = 3
    public var screenEdgeBorderWidth: CGFloat = 4
    /// 안쪽 글로가 중심 방향으로 번지는 폭.
    public var innerGlowWidth: CGFloat = 22
    public var screenEdgeGlowWidth: CGFloat = 40
    /// 화면 테두리 ↔ 대상 프레임 이동 시간. 말풍선은 이 시간 뒤에 나타난다.
    public var regionAnimationDuration: Double = 0.55
    public var bubbleMaxWidth: CGFloat = 300
    /// macOS 26 Liquid Glass(glassEffect)를 쓴다. false면 ultraThinMaterial.
    public var useLiquidGlass = true
    /// 오버레이 창을 화면 공유·캡처에서 제외한다(NSWindow.sharingType = .none).
    public var excludeFromScreenCapture = true
    /// 유휴 테두리를 모든 디스플레이에 그린다. false면 주 화면에만.
    public var idleEdgeOnAllDisplays = true
    /// 오버레이 창 레벨(rawValue). 기본은 NSWindow.Level.screenSaver(1000).
    public var windowLevel = 1000
    public var suggestionAcceptTitle = "네"
    public var suggestionRejectTitle = "아니요"
    public var approvalAcceptTitle = "실행"
    public var approvalRejectTitle = "취소"

    public init() {}
    public static let `default` = OverlayConfiguration()
}

/// 말풍선이 다루는 대상. 수락·거절 콜백에 그대로 전달된다.
public enum OverlayBubbleSubject: Sendable, Equatable {
    case suggestion(SuggestionCandidate)
    case approval(ActionProposal)

    public var id: UUID {
        switch self {
        case .suggestion(let s): s.id
        case .approval(let p): p.id
        }
    }

    public var isApproval: Bool {
        if case .approval = self { return true }
        return false
    }

    /// 말풍선에 띄울 문구.
    public var message: String {
        switch self {
        case .suggestion(let s):
            return s.message
        case .approval(let p):
            let text = p.rationale.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "이 작업을 실행할까요?" : text
        }
    }

    /// 제안·승인 요청이 가리키는 UI 대상의 AX 전역 프레임.
    public var targetFrame: CGRect? {
        switch self {
        case .suggestion(let s): return s.target?.frame
        case .approval(let p): return p.action.primaryTarget.frame
        }
    }
}

extension AgentAction {
    /// 오버레이가 가리켜야 할 대상(이동이면 목적지).
    public var primaryTarget: UITarget {
        switch self {
        case .typeText(let target, _): target
        case .press(let target): target
        case .move(_, let destination): destination
        case .setValue(let target, _): target
        }
    }
}

// MARK: - 레이아웃 결과

public struct GazeLayout: Sendable, Equatable {
    /// 디스플레이 로컬 좌표.
    public var rect: CGRect
    public var cornerRadius: CGFloat
    public var opacity: Double
}

public struct BadgeLayout: Sendable, Equatable {
    /// 디스플레이 로컬 좌표.
    public var rect: CGRect
    public var mode: VoiceBadgeMode
    /// 유리 좌상단 기준 배지 좌상단 위치. 뷰는 배지를 유리에 붙여 그리므로 애니메이션 중에도 떨어지지 않는다.
    public var offsetFromGlass: CGPoint
}

public struct RegionLayout: Sendable, Equatable {
    /// 디스플레이 로컬 좌표. 숨김 상태여도 마지막으로 그릴 위치를 담는다.
    public var rect: CGRect
    public var cornerRadius: CGFloat
    public var borderWidth: CGFloat
    public var glowWidth: CGFloat
    public var isIdleEdge: Bool
    public var isVisible: Bool
    public var label: String?
    public var labelPosition: StatusLabelPosition
}

public struct DisplayOverlayLayout: Sendable, Equatable {
    public var displayID: UInt32
    public var bounds: CGRect
    /// 이 디스플레이에 시선이 없으면 nil.
    public var gaze: GazeLayout?
    public var badge: BadgeLayout?
    public var region: RegionLayout
}

public struct BubbleRequest: Sendable, Equatable {
    public enum AnchorSource: String, Sendable, Equatable {
        /// 라임 에이전트 영역.
        case region
        /// 제안·승인 요청이 가리키는 UI 대상(라임 영역이 유휴일 때).
        case target
        /// 시선 유리(가리킬 대상이 없을 때). 시선은 계속 흔들리므로 처음 위치에 고정한다.
        case gaze
        case none
    }

    public var subject: OverlayBubbleSubject
    /// AX 전역 좌표의 가리킬 영역(라임 테두리). 없으면 nil.
    public var anchor: CGRect?
    public var anchorSource: AnchorSource
    /// 말풍선을 놓을 디스플레이 인덱스.
    public var displayIndex: Int

    public init(subject: OverlayBubbleSubject, anchor: CGRect?, anchorSource: AnchorSource, displayIndex: Int) {
        self.subject = subject; self.anchor = anchor; self.anchorSource = anchorSource; self.displayIndex = displayIndex
    }
}

public struct OverlayLayout: Sendable, Equatable {
    public var displays: [DisplayOverlayLayout]
    public var bubble: BubbleRequest?
}

public enum OverlayLayoutEngine {
    public static let statusLabelHeight: CGFloat = 20

    /// 상태 하나를 디스플레이별 레이아웃으로 바꾼다. 순수 함수.
    /// - Parameters:
    ///   - displays: Cocoa 전역 좌표의 디스플레이 목록. 첫 번째가 아니어도 되지만 primaryHeight는 주 화면 높이여야 한다.
    ///   - primaryHeight: 주 화면(Cocoa 원점 화면) 높이. AX ↔ Cocoa 변환 기준.
    public static func layout(_ state: OverlayState, displays: [DisplayGeometry], primaryHeight: CGFloat,
                              configuration config: OverlayConfiguration = .default) -> OverlayLayout {
        let topLeftFrames = displays.map { $0.topLeftFrame(primaryHeight: primaryHeight) }

        // 시선이 있는 디스플레이: displayID가 맞으면 그것, 아니면 점을 포함하는 것.
        var gazeDisplay: Int?
        if let gaze = state.gaze {
            gazeDisplay = OverlayGeometry.displayIndex(containing: gaze.point, in: topLeftFrames)
                ?? displays.firstIndex { $0.id == gaze.displayID }
        }

        var targetRect: CGRect?
        var targetDisplay: Int?
        if case .target(let frame, _) = state.agentRegion {
            let padded = OverlayGeometry.paddedTargetRect(frame, padding: config.regionPadding)
            targetRect = padded
            targetDisplay = OverlayGeometry.displayIndex(bestFor: padded, in: topLeftFrames)
        }
        let label = OverlayGeometry.statusLabel(region: state.agentRegion, hasPendingApproval: state.pendingApproval != nil)
        let primaryIndex = displays.firstIndex { $0.frame.origin == .zero } ?? 0

        var result: [DisplayOverlayLayout] = []
        for (index, display) in displays.enumerated() {
            let tl = topLeftFrames[index]
            let bounds = display.localBounds
            let safeTop = display.topLeftVisibleFrame(primaryHeight: primaryHeight).minY - tl.minY

            var gazeLayout: GazeLayout?
            var badgeLayout: BadgeLayout?
            if let gaze = state.gaze, gazeDisplay == index {
                let center = OverlayGeometry.local(gaze.point, inDisplayTopLeftFrame: tl)
                let rect = OverlayGeometry.gazeGlassRect(center: center, uncertaintyRadius: gaze.uncertaintyRadius)
                let radius = OverlayGeometry.gazeGlassCornerRadius(for: rect.size)
                gazeLayout = GazeLayout(rect: rect, cornerRadius: radius,
                                        opacity: OverlayGeometry.gazeOpacity(confidence: gaze.confidence))
                let mode = OverlayGeometry.voiceBadgeMode(for: state.audioLevel)
                if mode != .hidden {
                    let badgeRect = OverlayGeometry.badgeFrame(glass: rect, cornerRadius: radius, bounds: bounds)
                    badgeLayout = BadgeLayout(rect: badgeRect, mode: mode,
                                              offsetFromGlass: CGPoint(x: badgeRect.minX - rect.minX, y: badgeRect.minY - rect.minY))
                }
            }

            let region: RegionLayout
            if let targetRect, let targetDisplay {
                let isHere = targetDisplay == index
                let local = OverlayGeometry.local(targetRect, inDisplayTopLeftFrame: tl)
                region = RegionLayout(
                    rect: isHere ? local : bounds,
                    cornerRadius: isHere ? config.regionCornerRadius : config.screenEdgeCornerRadius,
                    borderWidth: isHere ? config.borderWidth : config.screenEdgeBorderWidth,
                    glowWidth: isHere ? OverlayGeometry.innerGlowWidth(for: local.size, maximum: config.innerGlowWidth)
                                      : config.screenEdgeGlowWidth,
                    isIdleEdge: !isHere, isVisible: isHere, label: isHere ? label : nil,
                    labelPosition: OverlayGeometry.statusLabelPosition(regionRect: local, labelHeight: statusLabelHeight, safeTop: safeTop))
            } else {
                let visible = config.idleEdgeOnAllDisplays || index == primaryIndex
                region = RegionLayout(rect: bounds, cornerRadius: config.screenEdgeCornerRadius,
                                      borderWidth: config.screenEdgeBorderWidth, glowWidth: config.screenEdgeGlowWidth,
                                      isIdleEdge: true, isVisible: visible, label: nil, labelPosition: .insideTop)
            }
            result.append(DisplayOverlayLayout(displayID: display.id, bounds: bounds, gaze: gazeLayout,
                                               badge: badgeLayout, region: region))
        }

        return OverlayLayout(displays: result,
                             bubble: bubbleRequest(state, displays: topLeftFrames, targetRect: targetRect,
                                                   targetDisplay: targetDisplay, gazeDisplay: gazeDisplay,
                                                   primaryIndex: primaryIndex, config: config))
    }

    /// 말풍선 대상: 승인 요청이 제안보다 우선한다. 가리킬 곳은 라임 영역 → 제안 대상 → 시선 유리 순.
    static func bubbleRequest(_ state: OverlayState, displays: [CGRect], targetRect: CGRect?, targetDisplay: Int?,
                              gazeDisplay: Int?, primaryIndex: Int, config: OverlayConfiguration) -> BubbleRequest? {
        guard !displays.isEmpty else { return nil }
        let subject: OverlayBubbleSubject
        if let approval = state.pendingApproval {
            subject = .approval(approval)
        } else if let suggestion = state.suggestion,
                  !suggestion.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            subject = .suggestion(suggestion)
        } else {
            return nil
        }

        if let targetRect, let targetDisplay {
            return BubbleRequest(subject: subject, anchor: targetRect, anchorSource: .region, displayIndex: targetDisplay)
        }
        if let frame = subject.targetFrame {
            let padded = OverlayGeometry.paddedTargetRect(frame, padding: config.regionPadding)
            if let index = OverlayGeometry.displayIndex(bestFor: padded, in: displays) {
                return BubbleRequest(subject: subject, anchor: padded, anchorSource: .target, displayIndex: index)
            }
        }
        if let gaze = state.gaze, let gazeDisplay,
           OverlayGeometry.gazeOpacity(confidence: gaze.confidence) > 0 {
            let rect = OverlayGeometry.gazeGlassRect(center: gaze.point, uncertaintyRadius: gaze.uncertaintyRadius)
            return BubbleRequest(subject: subject, anchor: rect, anchorSource: .gaze, displayIndex: gazeDisplay)
        }
        return BubbleRequest(subject: subject, anchor: nil, anchorSource: .none, displayIndex: primaryIndex)
    }
}

// MARK: - 말풍선 일정

/// 말풍선을 언제 다시 그릴지 정하는 순수 규칙.
public enum BubbleScheduling {
    public struct Key: Sendable, Equatable {
        public var subjectID: UUID
        public var message: String
        /// 시선 기준 말풍선은 anchor 변화를 무시한다(시선 흔들림에 말풍선이 따라 떨지 않게).
        public var anchor: CGRect?
        public var displayIndex: Int

        public init(_ request: BubbleRequest) {
            subjectID = request.subject.id
            message = request.subject.message
            anchor = request.anchorSource == .gaze ? nil : request.anchor
            displayIndex = request.displayIndex
        }
    }

    public enum Decision: Sendable, Equatable {
        /// 바꿀 것이 없다.
        case keep
        /// 숨기고 현재 키를 지운다.
        case hide
        /// 같은 자리에서 문구만 갱신한다.
        case updateInPlace
        /// (보이고 있으면 먼저 숨긴 뒤) 대상 영역 애니메이션이 끝나는 시점에 새로 띄운다.
        case show(after: Double)
    }

    public static func decide(current: Key?, isShown: Bool, request: BubbleRequest?, dismissedSubjectID: UUID?,
                              secondsUntilRegionSettles: Double) -> Decision {
        guard let request, request.subject.id != dismissedSubjectID else {
            return current == nil ? .keep : .hide
        }
        let key = Key(request)
        if key == current { return .keep }
        if isShown, let current, current.subjectID == key.subjectID, current.anchor == key.anchor,
           current.displayIndex == key.displayIndex {
            return .updateInPlace
        }
        return .show(after: max(0, secondsUntilRegionSettles))
    }
}
