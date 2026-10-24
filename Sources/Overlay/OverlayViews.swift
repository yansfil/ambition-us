import AgentContracts
import Observation
import SwiftUI

extension Color {
    init(rgb: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// 디스플레이 한 대의 오버레이 상태. 컨트롤러가 애니메이션 트랜잭션 안에서 값을 바꾼다.
@MainActor
@Observable
final class DisplayOverlayModel {
    var bounds: CGRect
    /// 마지막 시선 유리 위치. 시선을 잃어도 지우지 않고 opacity만 0으로 내려 제자리에서 사라지게 한다.
    var gaze: GazeLayout?
    var gazeOpacity: Double = 0
    /// 모션 감소 모드에서 큰 점프를 크로스페이드로 처리하기 위한 세대 번호.
    var gazeGeneration = 0
    var badge: BadgeLayout?
    var region: RegionLayout
    var regionGeneration = 0
    var reduceMotion = false
    var lime: Color
    var useLiquidGlass: Bool

    init(bounds: CGRect, configuration: OverlayConfiguration) {
        self.bounds = bounds
        self.lime = Color(rgb: configuration.limeRGB)
        self.useLiquidGlass = configuration.useLiquidGlass
        self.region = RegionLayout(rect: bounds, cornerRadius: configuration.screenEdgeCornerRadius,
                                   borderWidth: configuration.screenEdgeBorderWidth,
                                   glowWidth: configuration.screenEdgeGlowWidth,
                                   isIdleEdge: true, isVisible: false, label: nil, labelPosition: .insideTop)
    }
}

/// 디스플레이 전체를 덮는 클릭 통과 오버레이의 루트 뷰.
struct DisplayOverlayView: View {
    let model: DisplayOverlayModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            AgentRegionLayer(region: model.region, lime: model.lime)
                .id(model.regionGeneration)
                .transition(.opacity)

            if let gaze = model.gaze {
                GazeLayer(gaze: gaze, badge: model.badge, lime: model.lime,
                          useLiquidGlass: model.useLiquidGlass, reduceMotion: model.reduceMotion)
                    .opacity(model.gazeOpacity)
                    .id(model.gazeGeneration)
                    .transition(.opacity)
            }
        }
        .frame(width: model.bounds.width, height: model.bounds.height, alignment: .topLeading)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - 시선 유리 + 음성 배지

struct GazeLayer: View {
    let gaze: GazeLayout
    let badge: BadgeLayout?
    let lime: Color
    let useLiquidGlass: Bool
    let reduceMotion: Bool

    var body: some View {
        GazeGlassView(cornerRadius: gaze.cornerRadius, useLiquidGlass: useLiquidGlass)
            .overlay(alignment: .topLeading) {
                // 배지를 유리에 붙여 그린다: 유리가 움직이거나 크기가 바뀌는 동안에도 우하단에 붙어 있다.
                if let badge {
                    VoiceBadgeView(mode: badge.mode, lime: lime, reduceMotion: reduceMotion)
                        .frame(width: badge.rect.width, height: badge.rect.height)
                        .offset(x: badge.offsetFromGlass.x, y: badge.offsetFromGlass.y)
                        .transition(.opacity)
                }
            }
            .frame(width: gaze.rect.width, height: gaze.rect.height)
            .position(x: gaze.rect.midX, y: gaze.rect.midY)
    }
}

/// 사용자 시선 위치를 보여주는 Liquid Glass 둥근 사각형.
/// 아래 내용이 그대로 읽히도록 유리 본체는 옅게 두고 테두리로 영역을 드러낸다.
struct GazeGlassView: View {
    let cornerRadius: CGFloat
    let useLiquidGlass: Bool

    /// 유리 본체 불투명도. 높이면 뒤 내용이 흐려진다.
    static let bodyOpacity = 0.35

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if useLiquidGlass {
                Color.clear.glassEffect(.clear, in: shape)
            } else {
                shape.fill(.ultraThinMaterial)
            }
        }
        .opacity(Self.bodyOpacity)
        .overlay(shape.strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
        .overlay(
            // 위쪽 가장자리 하이라이트로 유리 두께감을 준다.
            shape.strokeBorder(
                LinearGradient(colors: [Color.white.opacity(0.3), .clear], startPoint: .top, endPoint: .center),
                lineWidth: 1.5)
        )
    }
}

/// 시선 유리 우하단에 붙는 녹음 배지.
struct VoiceBadgeView: View {
    let mode: VoiceBadgeMode
    let lime: Color
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            switch mode {
            case .speaking(let level):
                WaveformBars(rms: level, animated: !reduceMotion, color: lime)
            case .silent:
                WaveformBars(rms: 0, animated: false, color: Color.white.opacity(0.7))
            case .muted:
                Image(systemName: "mic.slash.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.orange)
            case .unavailable:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.red)
            case .hidden:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.62)))
        .overlay(Capsule(style: .continuous).strokeBorder(borderColor, lineWidth: 1))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: mode)
    }

    private var borderColor: Color {
        switch mode {
        case .speaking: lime.opacity(0.9)
        case .silent: Color.white.opacity(0.35)
        case .muted: Color.orange.opacity(0.8)
        case .unavailable: Color.red.opacity(0.8)
        case .hidden: .clear
        }
    }
}

/// RMS로 움직이는 막대 파형. 모션 감소면 흔들림 없이 음량만 반영한다.
struct WaveformBars: View {
    let rms: Double
    let animated: Bool
    let color: Color
    var barCount = 5
    var maxHeight: CGFloat = 14

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated)) { context in
            let phase = animated ? context.date.timeIntervalSinceReferenceDate * 9 : 0
            let levels = OverlayGeometry.waveformLevels(rms: rms, barCount: barCount, phase: phase)
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(levels.indices, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(color)
                        .frame(width: 3, height: max(3, maxHeight * levels[index]))
                }
            }
        }
    }
}

// MARK: - 에이전트 영역

struct AgentRegionLayer: View {
    let region: RegionLayout
    let lime: Color

    var body: some View {
        LimeInnerGlowFrame(cornerRadius: region.cornerRadius, borderWidth: region.borderWidth,
                           glowWidth: region.glowWidth, glowOpacity: region.isIdleEdge ? 0.55 : 0.7, lime: lime)
            .overlay(alignment: .topLeading) {
                if let label = region.label {
                    StatusPill(text: label, lime: lime)
                        .offset(x: region.labelPosition == .outsideTop ? 0 : region.borderWidth + 6,
                                y: region.labelPosition == .outsideTop
                                    ? -(OverlayLayoutEngine.statusLabelHeight + 4)
                                    : region.borderWidth + 6)
                        .transition(.opacity)
                }
            }
            .frame(width: max(region.rect.width, 1), height: max(region.rect.height, 1))
            .position(x: region.rect.midX, y: region.rect.midY)
            .opacity(region.isVisible ? 1 : 0)
    }
}

/// 라임 테두리 + 안쪽 글로. 글로는 도형 안으로 잘라내 바깥 그림자/블러가 없고, 중심 쪽으로 옅어진다.
/// 모서리 반경·선 굵기·블러 반경은 SwiftUI가 각각 보간하므로 화면 테두리 ↔ 대상 이동 중에도 모양이 자연스럽게 바뀐다.
struct LimeInnerGlowFrame: View {
    let cornerRadius: CGFloat
    let borderWidth: CGFloat
    let glowWidth: CGFloat
    let glowOpacity: Double
    let lime: Color

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            // 가장자리를 중심으로 두껍게 그린 선을 흐리게 하고 도형 안쪽만 남긴다.
            shape
                .stroke(lime.opacity(glowOpacity), lineWidth: glowWidth * 2)
                .blur(radius: glowWidth * 0.6)
            shape
                .strokeBorder(lime.opacity(glowOpacity * 0.5), lineWidth: borderWidth * 2.5)
                .blur(radius: borderWidth)
            shape
                .strokeBorder(lime, lineWidth: borderWidth)
        }
        .clipShape(shape)
        .compositingGroup()
    }
}

struct StatusPill: View {
    let text: String
    let lime: Color

    var body: some View {
        Text(text)
            .contentTransition(.opacity)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.black.opacity(0.88))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: OverlayLayoutEngine.statusLabelHeight)
            .background(Capsule(style: .continuous).fill(lime))
    }
}
