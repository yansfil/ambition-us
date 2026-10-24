import AgentContracts
import CoreGraphics
import Foundation

/// 최근 얼굴 위치(보정 전·중 자세 안내용). 좌표는 카메라 영상 정규화 좌표(좌상단 원점, 좌우 반전 없음).
public struct HeadPositionStatus: Sendable, Equatable {
    public var time: MonotonicTime
    public var faceCenter: CGPoint
    /// 얼굴 상자 폭(영상 폭 비율).
    public var faceWidth: Double
    /// 얼굴 폭으로 추정한 카메라까지 거리(cm, 근사).
    public var distanceCm: Double
    public var headPose: HeadPose?

    public init(time: MonotonicTime, faceCenter: CGPoint, faceWidth: Double, distanceCm: Double, headPose: HeadPose?) {
        self.time = time; self.faceCenter = faceCenter; self.faceWidth = faceWidth; self.distanceCm = distanceCm
        self.headPose = headPose
    }

    /// 얼굴 측정값 → 상태. 거리 = 얼굴 폭(cm) / (2·tan(화각/2)·정규화 폭).
    public init(face: FaceMeasurement, intrinsics: CameraIntrinsics = .init(), faceWidthCm: Double = 16) {
        let width = max(Double(face.boundingBox.width), 1e-4)
        let distance = faceWidthCm / (2 * tan(intrinsics.horizontalFOVDegrees * .pi / 360) * width)
        self.init(time: face.time, faceCenter: CGPoint(x: face.boundingBox.midX, y: face.boundingBox.midY),
                  faceWidth: width, distanceCm: distance, headPose: face.headPose)
    }

    /// 사용자에게 거울처럼 보이는 가로 위치(0 = 화면 왼쪽).
    public var mirroredX: Double { 1 - Double(faceCenter.x) }
}

public enum HeadPositionGuidance {
    public enum Issue: Sendable, Equatable {
        case noFace
        case tooFar(distanceCm: Double)
        case tooClose(distanceCm: Double)
        /// 사용자 기준 방향으로 옮겨야 한다.
        case moveLeft, moveRight
        /// 얼굴이 영상 위/아래에 치우침(화면 각도 조절).
        case faceTooHigh, faceTooLow
        case faceTurned
    }

    public struct Configuration: Sendable, Equatable {
        public var minimumDistanceCm = 42.0
        public var maximumDistanceCm = 78.0
        /// |얼굴 중심 x − 0.5| 허용치.
        public var horizontalTolerance = 0.15
        public var verticalRange: ClosedRange<Double> = 0.22...0.65
        public var maximumHeadAngle = 0.35
        /// 이보다 오래된 상태는 얼굴 없음으로 본다(초).
        public var staleAfter = 0.7
        public init() {}
    }

    public static func evaluate(_ status: HeadPositionStatus?, now: MonotonicTime,
                                configuration: Configuration = .init()) -> [Issue] {
        guard let status, now.seconds(since: status.time) <= configuration.staleAfter else { return [.noFace] }
        var issues: [Issue] = []
        if status.distanceCm > configuration.maximumDistanceCm {
            issues.append(.tooFar(distanceCm: status.distanceCm))
        } else if status.distanceCm < configuration.minimumDistanceCm {
            issues.append(.tooClose(distanceCm: status.distanceCm))
        }
        // 영상은 반전되지 않았다: 얼굴이 영상 오른쪽이면 사용자는 자기 왼쪽에 치우쳐 있으니 오른쪽으로 옮긴다.
        let dx = Double(status.faceCenter.x) - 0.5
        if dx > configuration.horizontalTolerance { issues.append(.moveRight) }
        if dx < -configuration.horizontalTolerance { issues.append(.moveLeft) }
        let y = Double(status.faceCenter.y)
        if y < configuration.verticalRange.lowerBound { issues.append(.faceTooHigh) }
        if y > configuration.verticalRange.upperBound { issues.append(.faceTooLow) }
        if let pose = status.headPose,
           abs(pose.yaw) > configuration.maximumHeadAngle || abs(pose.pitch) > configuration.maximumHeadAngle {
            issues.append(.faceTurned)
        }
        return issues
    }

    public static func message(for issue: Issue) -> String {
        switch issue {
        case .noFace: "얼굴이 보이지 않습니다. 카메라를 정면으로 바라보세요."
        case .tooFar(let d): "조금 더 가까이 앉으세요 (지금 약 \(Int(d.rounded()))cm, 권장 50–70cm)."
        case .tooClose(let d): "조금 뒤로 물러나세요 (지금 약 \(Int(d.rounded()))cm, 권장 50–70cm)."
        case .moveLeft: "왼쪽으로 조금 옮겨 화면 가운데 앞에 앉으세요."
        case .moveRight: "오른쪽으로 조금 옮겨 화면 가운데 앞에 앉으세요."
        case .faceTooHigh: "얼굴이 카메라 위쪽에 치우쳐 있습니다. 화면을 조금 뒤로 젖혀 주세요."
        case .faceTooLow: "얼굴이 카메라 아래쪽에 치우쳐 있습니다. 화면을 조금 앞으로 세워 주세요."
        case .faceTurned: "고개를 화면 정면으로 향해 주세요."
        }
    }

    /// 가장 중요한 안내 한 줄(없으면 nil).
    public static func primaryMessage(_ issues: [Issue]) -> String? {
        issues.first.map(message(for:))
    }
}
