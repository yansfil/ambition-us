import CoreGraphics
import Foundation

/// 카메라 내부 파라미터 근사. 내장 FaceTime 카메라는 화면 베젤 한가운데에 있고 광축이 화면에 수직이다.
public struct CameraIntrinsics: Sendable, Equatable, Codable {
    /// 수평 화각(도). macOS는 `videoFieldOfView`를 주지 않으므로 MacBook 내장 카메라 근사값을 쓴다.
    /// 틀려도 머리 이동 보정의 크기만 조금 달라지고, 화면 매핑 배율은 보정이 흡수한다.
    public var horizontalFOVDegrees: Double

    public init(horizontalFOVDegrees: Double = 68) {
        self.horizontalFOVDegrees = horizontalFOVDegrees
    }

    /// 픽셀 단위 초점 거리.
    public func focalLength(imageWidth: Double) -> Double {
        imageWidth / 2 / tan(horizontalFOVDegrees * .pi / 360)
    }
}

/// Gaze360 시선 각도와 카메라 기하.
///
/// 좌표계
/// - 카메라 좌표(cm): x = 영상 오른쪽, y = 영상 아래, z = 카메라에서 장면 쪽(사용자 쪽).
/// - Gaze360 시선 벡터: g = (−cos p · sin y, −sin p, −cos p · cos y). yaw = pitch = 0이면 눈에서 카메라를 향한다.
///   양의 yaw는 영상 왼쪽, 양의 pitch는 위쪽(저장소 `draw_gaze`: dx = −sin(yaw)cos(pitch), dy = −sin(pitch)).
/// - 눈 좌표계: z_E = 카메라→눈 방향, x_E = 카메라 x축을 z_E에 직교화, y_E = z_E × x_E.
///   CNN은 얼굴 크롭만 보므로 각도는 이 눈 좌표계 기준이다(Gaze360 정의).
/// - 화면 평면: 내장 카메라는 화면 베젤 안에 있으므로 화면은 z = 0 평면이다.
///   결과는 사용자 시점 좌표(cm): X = 사용자 오른쪽(= −카메라 x), Y = 아래, 원점 = 카메라.
///   영상이 좌우 반전돼 있어도 yaw와 눈 위치가 함께 뒤집혀 X 부호만 바뀌므로 보정 회귀가 흡수한다.
public enum GazeGeometry {
    /// Gaze360 규약의 단위 시선 벡터(눈 좌표계).
    public static func gazeVector(yaw: Double, pitch: Double) -> SIMD3<Double> {
        SIMD3(-cos(pitch) * sin(yaw), -sin(pitch), -cos(pitch) * cos(yaw))
    }

    /// 단위 시선 벡터 → (yaw, pitch).
    public static func angles(of g: SIMD3<Double>) -> (yaw: Double, pitch: Double) {
        let n = g / max(length(g), 1e-12)
        return (atan2(-n.x, -n.z), asin(clamp(-n.y, -1, 1)))
    }

    /// 영상 위치(픽셀)와 얼굴 폭(픽셀)으로 추정한 눈 중심의 카메라 좌표(cm).
    public static func eyePosition(pixel: CGPoint, faceWidthPixels: Double, imageSize: CGSize,
                                   intrinsics: CameraIntrinsics, faceWidthCm: Double) -> SIMD3<Double> {
        let f = intrinsics.focalLength(imageWidth: Double(imageSize.width))
        let z = f * faceWidthCm / max(faceWidthPixels, 1)
        let cx = Double(imageSize.width) / 2, cy = Double(imageSize.height) / 2
        return SIMD3((Double(pixel.x) - cx) * z / f, (Double(pixel.y) - cy) * z / f, z)
    }

    /// 눈 좌표계 축(x_E, y_E, z_E).
    static func eyeFrame(eye: SIMD3<Double>) -> (x: SIMD3<Double>, y: SIMD3<Double>, z: SIMD3<Double>) {
        let z = eye / max(length(eye), 1e-12)
        let cameraX = SIMD3<Double>(1, 0, 0)
        var x = cameraX - z * dot(z, cameraX)
        x /= max(length(x), 1e-12)
        let y = cross(z, x)
        return (x, y, z)
    }

    /// 눈 좌표계 시선 → 카메라 좌표 시선.
    public static func cameraDirection(yaw: Double, pitch: Double, eye: SIMD3<Double>) -> SIMD3<Double> {
        let g = gazeVector(yaw: yaw, pitch: pitch)
        let frame = eyeFrame(eye: eye)
        return frame.x * g.x + frame.y * g.y + frame.z * g.z
    }

    /// 시선 광선과 화면 평면(z = 0)의 교점(사용자 시점 cm). 화면 쪽을 보지 않으면 nil.
    public static func screenPlaneIntersection(eye: SIMD3<Double>, yaw: Double, pitch: Double) -> SIMD2<Double>? {
        let d = cameraDirection(yaw: yaw, pitch: pitch, eye: eye)
        // 화면에 거의 평행하거나 반대쪽을 보면 교점이 없다(약 72° 이상).
        guard d.z < -0.3 else { return nil }
        let t = -eye.z / d.z
        let p = eye + d * t
        return SIMD2(-p.x, p.y)
    }

    /// 검사·합성용 역함수: 눈이 화면 평면 위 점(사용자 시점 cm)을 볼 때의 Gaze360 각도.
    public static func angles(lookingFrom eye: SIMD3<Double>, at planePoint: SIMD2<Double>) -> (yaw: Double, pitch: Double) {
        let target = SIMD3<Double>(-planePoint.x, planePoint.y, 0)
        let d = target - eye
        let frame = eyeFrame(eye: eye)
        return angles(of: SIMD3(dot(d, frame.x), dot(d, frame.y), dot(d, frame.z)))
    }

    @inline(__always) static func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { (a * b).sum() }
    @inline(__always) static func length(_ a: SIMD3<Double>) -> Double { dot(a, a).squareRoot() }
    @inline(__always) static func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }
}
