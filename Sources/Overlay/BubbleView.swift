import AgentContracts
import Observation
import SwiftUI

extension OverlayGeometry {
    /// 둥근 몸체와 꼬리를 한 붓으로 그린 말풍선 윤곽(컨테이너 로컬 좌상단 좌표).
    /// 몸체와 꼬리가 겹치지 않는 단일 경로라 유리 효과·테두리에 이음새가 생기지 않는다.
    public static func bubblePath(body: CGRect, tailTip: CGPoint?, tailEdge: BubbleTailEdge?,
                                  cornerRadius: CGFloat = BubbleMetrics.cornerRadius,
                                  tailBaseWidth: CGFloat = BubbleMetrics.tailBaseWidth) -> CGPath {
        let r = max(0, min(cornerRadius, body.width / 2, body.height / 2))
        let half = tailBaseWidth / 2
        let path = CGMutablePath()
        let edge = tailTip == nil ? nil : tailEdge

        func along(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { clamp(v, lo + r + half, hi - r - half) }

        path.move(to: CGPoint(x: body.minX + r, y: body.minY))
        if edge == .top, let tip = tailTip {
            let x = along(tip.x, body.minX, body.maxX)
            path.addLine(to: CGPoint(x: x - half, y: body.minY))
            path.addLine(to: CGPoint(x: tip.x, y: tip.y))
            path.addLine(to: CGPoint(x: x + half, y: body.minY))
        }
        path.addLine(to: CGPoint(x: body.maxX - r, y: body.minY))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.minY + r), radius: r)
        if edge == .trailing, let tip = tailTip {
            let y = along(tip.y, body.minY, body.maxY)
            path.addLine(to: CGPoint(x: body.maxX, y: y - half))
            path.addLine(to: CGPoint(x: tip.x, y: tip.y))
            path.addLine(to: CGPoint(x: body.maxX, y: y + half))
        }
        path.addLine(to: CGPoint(x: body.maxX, y: body.maxY - r))
        path.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.maxX - r, y: body.maxY), radius: r)
        if edge == .bottom, let tip = tailTip {
            let x = along(tip.x, body.minX, body.maxX)
            path.addLine(to: CGPoint(x: x + half, y: body.maxY))
            path.addLine(to: CGPoint(x: tip.x, y: tip.y))
            path.addLine(to: CGPoint(x: x - half, y: body.maxY))
        }
        path.addLine(to: CGPoint(x: body.minX + r, y: body.maxY))
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY - r), radius: r)
        if edge == .leading, let tip = tailTip {
            let y = along(tip.y, body.minY, body.maxY)
            path.addLine(to: CGPoint(x: body.minX, y: y + half))
            path.addLine(to: CGPoint(x: tip.x, y: tip.y))
            path.addLine(to: CGPoint(x: body.minX, y: y - half))
        }
        path.addLine(to: CGPoint(x: body.minX, y: body.minY + r))
        path.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.minX + r, y: body.minY), radius: r)
        path.closeSubpath()
        return path
    }
}

struct BubbleShape: Shape {
    var body: CGRect
    var tailTip: CGPoint?
    var tailEdge: BubbleTailEdge?

    func path(in rect: CGRect) -> Path {
        Path(OverlayGeometry.bubblePath(body: body, tailTip: tailTip, tailEdge: tailEdge))
    }
}

/// 말풍선 패널 하나의 표시 상태.
@MainActor
@Observable
final class BubbleModel {
    var subject: OverlayBubbleSubject?
    var message = ""
    var acceptTitle = ""
    var rejectTitle = ""
    var placement = BubblePlacement(side: nil, bodyFrame: .zero, tailTip: nil)
    var isShown = false
    var reduceMotion = false
    var useLiquidGlass = true
    var lime: Color = Color(rgb: 0xB7F56B)
    var onAccept: () -> Void = {}
    var onReject: () -> Void = {}
}

enum BubbleStyle {
    static let messageFont = Font.system(size: 13, weight: .medium)
    static let buttonFont = Font.system(size: 12, weight: .semibold)
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 12
    static let spacing: CGFloat = 10
}

/// 말풍선 본문(메시지 + 수락/거절). 크기 측정에도 같은 뷰를 쓴다.
struct BubbleContent: View {
    let message: String
    let acceptTitle: String
    let rejectTitle: String
    let lime: Color
    var width: CGFloat?
    var onAccept: () -> Void = {}
    var onReject: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: BubbleStyle.spacing) {
            Text(message)
                .font(BubbleStyle.messageFont)
                .foregroundStyle(Color.white)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: width == nil ? nil : .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if width != nil { Spacer(minLength: 0) }
                Button(rejectTitle, action: onReject)
                    .buttonStyle(BubbleButtonStyle(prominent: false, lime: lime))
                Button(acceptTitle, action: onAccept)
                    .buttonStyle(BubbleButtonStyle(prominent: true, lime: lime))
            }
        }
        .padding(.horizontal, BubbleStyle.horizontalPadding)
        .padding(.vertical, BubbleStyle.verticalPadding)
        .frame(width: width)
    }
}

struct BubbleButtonStyle: ButtonStyle {
    let prominent: Bool
    let lime: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BubbleStyle.buttonFont)
            .foregroundStyle(prominent ? Color.black.opacity(0.88) : Color.white)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(
                Capsule(style: .continuous)
                    .fill(prominent ? lime : Color.white.opacity(0.16))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(prominent ? 0 : 0.25), lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule(style: .continuous))
    }
}

/// 말풍선 패널의 루트 뷰. 패널 크기 = 몸체+꼬리 컨테이너 크기.
struct BubbleRootView: View {
    let model: BubbleModel

    var body: some View {
        let placement = model.placement
        let body = placement.localBodyFrame
        let shape = BubbleShape(body: body, tailTip: placement.localTailTip, tailEdge: placement.tailEdge)
        let container = placement.containerFrame.size

        ZStack(alignment: .topLeading) {
            Group {
                if model.useLiquidGlass {
                    Color.clear.glassEffect(.regular.tint(Color.black.opacity(0.35)), in: shape)
                } else {
                    shape.fill(.ultraThinMaterial)
                        .overlay(shape.fill(Color.black.opacity(0.35)))
                }
            }
            .overlay(shape.stroke(model.lime.opacity(0.9), lineWidth: 1.2))

            BubbleContent(message: model.message, acceptTitle: model.acceptTitle, rejectTitle: model.rejectTitle,
                          lime: model.lime, width: body.width,
                          onAccept: model.onAccept, onReject: model.onReject)
                .frame(width: body.width, height: body.height)
                .offset(x: body.minX, y: body.minY)
        }
        .frame(width: container.width, height: container.height, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
        .scaleEffect(model.isShown || model.reduceMotion ? 1 : 0.86, anchor: scaleAnchor(container: container))
        .opacity(model.isShown ? 1 : 0)
        .ignoresSafeArea()
    }

    /// 꼬리 끝에서 커지듯 나타나게 한다.
    private func scaleAnchor(container: CGSize) -> UnitPoint {
        guard let tip = model.placement.localTailTip, container.width > 0, container.height > 0 else { return .center }
        return UnitPoint(x: tip.x / container.width, y: tip.y / container.height)
    }
}
