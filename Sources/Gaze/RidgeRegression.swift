import Foundation

/// 작은 밀집 행렬용 순수 Swift 선형대수(보정 모델 전용).
enum LinearAlgebra {
    /// 대칭 양의 정부호 행렬 `a`(n×n, 행 우선)에 대해 a·x = b를 rhs마다 푼다. 분해 실패 시 nil.
    static func choleskySolve(_ a: [Double], n: Int, rhs: [[Double]]) -> [[Double]]? {
        precondition(a.count == n * n)
        var l = [Double](repeating: 0, count: n * n)
        for j in 0..<n {
            var diagonal = a[j * n + j]
            for k in 0..<j { diagonal -= l[j * n + k] * l[j * n + k] }
            guard diagonal > 1e-12 else { return nil }
            let ljj = diagonal.squareRoot()
            l[j * n + j] = ljj
            for i in (j + 1)..<max(j + 1, n) {
                var sum = a[i * n + j]
                for k in 0..<j { sum -= l[i * n + k] * l[j * n + k] }
                l[i * n + j] = sum / ljj
            }
        }
        return rhs.map { b in
            var y = [Double](repeating: 0, count: n)
            for i in 0..<n {
                var sum = b[i]
                for k in 0..<i { sum -= l[i * n + k] * y[k] }
                y[i] = sum / l[i * n + i]
            }
            var x = [Double](repeating: 0, count: n)
            for i in stride(from: n - 1, through: 0, by: -1) {
                var sum = y[i]
                for k in (i + 1)..<max(i + 1, n) { sum -= l[k * n + i] * x[k] }
                x[i] = sum / l[i * n + i]
            }
            return x
        }
    }
}

/// 가중 릿지 회귀: min Σ wᵢ‖yᵢ − Wφᵢ‖² + λ·Σwᵢ·Σ_{penalized} w².
enum RidgeRegression {
    struct Solution: Sendable, Equatable {
        var x: [Double]
        var y: [Double]
    }

    static func fit(design rows: [[Double]], targets: [SIMD2<Double>], weights: [Double],
                    lambda: Double, penalized: [Bool]) -> Solution? {
        guard let p = rows.first?.count, p == penalized.count, rows.count == targets.count,
              rows.count == weights.count, !rows.isEmpty else { return nil }
        var a = [Double](repeating: 0, count: p * p)
        var bx = [Double](repeating: 0, count: p)
        var by = [Double](repeating: 0, count: p)
        var totalWeight = 0.0
        for (index, phi) in rows.enumerated() {
            let w = weights[index]
            totalWeight += w
            for i in 0..<p {
                let wi = w * phi[i]
                bx[i] += wi * targets[index].x
                by[i] += wi * targets[index].y
                for j in i..<p { a[i * p + j] += wi * phi[j] }
            }
        }
        for i in 0..<p {
            for j in 0..<i { a[i * p + j] = a[j * p + i] }
            if penalized[i] { a[i * p + i] += lambda * totalWeight }
        }
        guard let solved = LinearAlgebra.choleskySolve(a, n: p, rhs: [bx, by]) else { return nil }
        return Solution(x: solved[0], y: solved[1])
    }

    static func dot(_ a: [Double], _ b: [Double]) -> Double {
        var sum = 0.0
        for i in 0..<min(a.count, b.count) { sum += a[i] * b[i] }
        return sum
    }
}
