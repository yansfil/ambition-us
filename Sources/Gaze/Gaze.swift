import AgentContracts
import CoreGraphics
import Foundation

// Gaze 모듈 구성
//
//  카메라 프레임 ─▶ VisionGazeSource (AVCaptureSession + Vision 얼굴 랜드마크)
//                    └▶ FaceMeasurement ─▶ GazeEstimator (랜드마크 / 이후 L2CS-Net CoreML)
//                                            └▶ GazeFeatures
//  GazeEngine (스레드 안전 래퍼)
//    └▶ GazePipeline (순수 값 타입, 테스트 가능)
//         CalibrationStore(디스플레이별 릿지 회귀) ─▶ OneEuroFilter2D ─▶ FixationDetector(I-VT)
//         ─▶ AttentionCueDetector(dwell/revisit) + HeadGestureDetector(nod/shake)
//    └▶ AsyncStream<GazeSample>, AsyncStream<NonverbalCue>
//
//  BeamGazeSource / MouseGazeSource는 화면 좌표를 직접 받는 경로로 같은 후처리를 공유한다.

/// `DispatchTime.uptimeNanoseconds`(= mach_absolute_time) 기반 기본 시계.
public struct GazeUptimeClock: MonotonicClock {
    public init() {}
    public func now() -> MonotonicTime { MonotonicTime(nanoseconds: DispatchTime.now().uptimeNanoseconds) }
}

public enum GazeSourceError: Error, Sendable, Equatable, CustomStringConvertible {
    case cameraPermissionDenied
    case cameraUnavailable
    /// .app 번들에 NSCameraUsageDescription이 없으면 TCC가 프로세스를 종료시키므로 미리 막는다.
    case missingCameraUsageDescription
    case sessionConfigurationFailed(String)
    case sdkUnavailable(String)

    public var description: String {
        switch self {
        case .cameraPermissionDenied: "카메라 권한이 거부되었습니다."
        case .cameraUnavailable: "사용 가능한 카메라가 없습니다."
        case .missingCameraUsageDescription: "Info.plist에 NSCameraUsageDescription이 없습니다."
        case .sessionConfigurationFailed(let reason): "캡처 세션 구성 실패: \(reason)"
        case .sdkUnavailable(let name): "\(name) SDK가 아직 통합되지 않았습니다."
        }
    }
}

extension MonotonicTime {
    var seconds: Double { Double(nanoseconds) / 1_000_000_000 }

    /// 부호 있는 초 단위 차이(self - earlier).
    func seconds(since earlier: MonotonicTime) -> Double {
        (Double(nanoseconds) - Double(earlier.nanoseconds)) / 1_000_000_000
    }

    func adding(seconds delta: Double) -> MonotonicTime {
        let shifted = Double(nanoseconds) + delta * 1_000_000_000
        return MonotonicTime(nanoseconds: UInt64(max(0, shifted.rounded())))
    }
}

extension CGPoint {
    func distance(to other: CGPoint) -> Double {
        Double(hypot(x - other.x, y - other.y))
    }
}

@inline(__always)
func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
    min(max(value, lower), upper)
}
