import CoreGraphics
import Foundation

/// One Euro filter 매개변수(Casiez et al., CHI 2012).
/// 느릴 때는 `minCutoff`로 떨림을 줄이고, 빠를 때는 `beta`·속도만큼 차단 주파수를 올려 지연을 줄인다.
public struct OneEuroParameters: Sendable, Equatable {
    /// 정지 시 차단 주파수(Hz).
    public var minCutoff: Double
    /// 속도 계수(입력 단위/초 당 Hz). 화면 포인트 기준.
    public var beta: Double
    /// 미분 신호 차단 주파수(Hz).
    public var derivativeCutoff: Double

    public init(minCutoff: Double = 0.8, beta: Double = 0.004, derivativeCutoff: Double = 1.0) {
        self.minCutoff = minCutoff; self.beta = beta; self.derivativeCutoff = derivativeCutoff
    }

    static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * max(cutoff, 1e-6))
        return 1 / (1 + tau / dt)
    }
}

/// 1차원 One Euro filter. 시각은 초 단위, 단조 증가해야 한다(같거나 이전 시각은 이전 출력 유지).
public struct OneEuroFilter: Sendable {
    public var parameters: OneEuroParameters
    private var previous: Double?
    private var previousDerivative = 0.0
    private var previousTime = 0.0

    public init(parameters: OneEuroParameters = .init()) {
        self.parameters = parameters
    }

    public mutating func reset() {
        previous = nil
        previousDerivative = 0
    }

    public mutating func filter(_ value: Double, at time: Double) -> Double {
        guard let prev = previous else {
            previous = value; previousTime = time; previousDerivative = 0
            return value
        }
        let dt = time - previousTime
        guard dt > 1e-6 else { return prev }
        let aD = OneEuroParameters.alpha(cutoff: parameters.derivativeCutoff, dt: dt)
        let derivative = aD * ((value - prev) / dt) + (1 - aD) * previousDerivative
        let cutoff = parameters.minCutoff + parameters.beta * abs(derivative)
        let a = OneEuroParameters.alpha(cutoff: cutoff, dt: dt)
        let result = a * value + (1 - a) * prev
        previous = result; previousDerivative = derivative; previousTime = time
        return result
    }
}

/// 2차원 One Euro filter. 두 축에 같은 속도 크기를 써서 대각선 이동에서도 축별 지연이 갈라지지 않게 한다.
public struct OneEuroFilter2D: Sendable {
    public var parameters: OneEuroParameters
    private var previous: SIMD2<Double>?
    private var previousDerivative = SIMD2<Double>(0, 0)
    private var previousTime = 0.0

    public init(parameters: OneEuroParameters = .init()) {
        self.parameters = parameters
    }

    public var isPrimed: Bool { previous != nil }

    public mutating func reset() {
        previous = nil
        previousDerivative = SIMD2(0, 0)
    }

    public mutating func filter(_ point: CGPoint, at time: Double) -> CGPoint {
        let value = SIMD2<Double>(Double(point.x), Double(point.y))
        guard let prev = previous else {
            previous = value; previousTime = time; previousDerivative = SIMD2(0, 0)
            return point
        }
        let dt = time - previousTime
        guard dt > 1e-6 else { return CGPoint(x: prev.x, y: prev.y) }
        let aD = OneEuroParameters.alpha(cutoff: parameters.derivativeCutoff, dt: dt)
        let derivative = aD * ((value - prev) / dt) + (1 - aD) * previousDerivative
        let cutoff = parameters.minCutoff + parameters.beta * simdLength(derivative)
        let a = OneEuroParameters.alpha(cutoff: cutoff, dt: dt)
        let result = a * value + (1 - a) * prev
        previous = result; previousDerivative = derivative; previousTime = time
        return CGPoint(x: result.x, y: result.y)
    }
}
