import AgentContracts
import Foundation

/// dBFS 구간을 0...1로 펴는 RMS 정규화.
public struct LevelNormalization: Sendable, Equatable {
    public var floorDB: Double
    public var ceilingDB: Double
    public init(floorDB: Double = -60, ceilingDB: Double = 0) {
        self.floorDB = floorDB
        self.ceilingDB = ceilingDB
    }

    /// 선형 RMS(풀스케일 1.0) → 0...1. floorDB 이하는 0, ceilingDB 이상은 1.
    public func normalize(rms: Double) -> Double {
        guard rms.isFinite, rms > 0, ceilingDB > floorDB else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db - floorDB) / (ceilingDB - floorDB)))
    }
}

public enum SignalMath {
    public static func rms(_ samples: UnsafeBufferPointer<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for sample in samples { sum += Double(sample) * Double(sample) }
        return (sum / Double(samples.count)).squareRoot()
    }

    public static func rms(_ samples: [Float]) -> Double {
        samples.withUnsafeBufferPointer { rms($0) }
    }
}

public struct VADConfiguration: Sendable, Equatable {
    /// 발화 시작 문턱의 하한(정규화 레벨). 0.35 ≈ -39 dBFS.
    public var minOnLevel: Double = 0.35
    /// 발화 종료 문턱의 하한. 0.25 ≈ -45 dBFS.
    public var minOffLevel: Double = 0.25
    /// 잡음 바닥 위로 이만큼 올라야 발화로 본다.
    public var onMargin: Double = 0.15
    public var offMargin: Double = 0.08
    /// 문턱을 이 시간 이상 넘어야 발화 시작.
    public var attack: Double = 0.04
    /// 문턱 아래로 이 시간 이상 머물러야 발화 종료.
    public var hangover: Double = 0.30
    /// 잡음 바닥이 내려갈 때/올라갈 때의 시정수(초).
    public var noiseFallTime: Double = 0.1
    public var noiseRiseTime: Double = 5.0
    public var initialNoiseFloor: Double = 0.1
    public init() {}
}

/// 적응형 잡음 바닥 + 히스테리시스 + hangover를 쓰는 에너지 VAD.
public struct EnergyVAD: Sendable {
    public var configuration: VADConfiguration
    public private(set) var isVoice = false
    public private(set) var noiseFloor: Double
    private var aboveTime: Double = 0
    private var belowTime: Double = 0

    public init(configuration: VADConfiguration = .init()) {
        self.configuration = configuration
        self.noiseFloor = configuration.initialNoiseFloor
    }

    public var onThreshold: Double { max(configuration.minOnLevel, noiseFloor + configuration.onMargin) }
    public var offThreshold: Double { max(configuration.minOffLevel, noiseFloor + configuration.offMargin) }

    /// 정규화 레벨 한 블록(길이 `duration`초)을 넣고 현재 발화 여부를 돌려준다.
    @discardableResult
    public mutating func update(level: Double, duration: Double) -> Bool {
        if isVoice {
            if level < offThreshold {
                belowTime += duration
                if belowTime >= configuration.hangover {
                    isVoice = false
                    aboveTime = 0
                }
            } else {
                belowTime = 0
            }
        } else {
            if level >= onThreshold {
                aboveTime += duration
                if aboveTime >= configuration.attack {
                    isVoice = true
                    belowTime = 0
                }
            } else {
                aboveTime = 0
            }
            // 잡음 바닥은 발화가 아닐 때만 따라간다.
            if !isVoice {
                let tau = level < noiseFloor ? configuration.noiseFallTime : configuration.noiseRiseTime
                noiseFloor += (level - noiseFloor) * min(1, duration / max(tau, 1e-6))
            }
        }
        return isVoice
    }
}

/// 미터 출력: 오버레이용 샘플 + 엔드포인트 판정용 스트림 오프셋.
public struct MeterReading: Sendable, Equatable {
    public let sample: AudioLevelSample
    /// 이 샘플 창이 끝나는 스트림 오프셋(초).
    public let streamOffset: Double
}

/// 10ms 블록 단위로 RMS·VAD를 계산하고 ~30Hz로 묶어 내보낸다.
public struct LevelMeter: Sendable {
    public var normalization: LevelNormalization
    public private(set) var vad: EnergyVAD
    public let emitRateHz: Double
    public let blockDuration: Double
    /// 디지털 무음(샘플이 정확히 0)이 이 시간 이상 이어지면 음소거로 본다.
    public let mutedAfter: Double
    /// 시스템/앱 차원의 입력 음소거(AVAudioApplication 등).
    public var externallyMuted = false

    private var blockSumSquares: Double = 0
    private var blockCount = 0
    private var blockPeak: Float = 0
    private var windowSumSquares: Double = 0
    private var windowCount = 0
    private var nextEmitOffset: Double?
    private var digitalSilence: Double = 0

    public init(normalization: LevelNormalization = .init(), vad: VADConfiguration = .init(),
                emitRateHz: Double = 30, blockDuration: Double = 0.01, mutedAfter: Double = 0.5) {
        self.normalization = normalization
        self.vad = EnergyVAD(configuration: vad)
        self.emitRateHz = max(1, emitRateHz)
        self.blockDuration = max(0.001, blockDuration)
        self.mutedAfter = mutedAfter
    }

    public var micState: AudioLevelSample.MicState {
        externallyMuted || digitalSilence >= mutedAfter ? .muted : .active
    }

    /// - Parameters:
    ///   - startTime: 첫 샘플의 실제 시각.
    ///   - streamOffset: 첫 샘플의 스트림 오프셋(초).
    public mutating func process(samples: UnsafeBufferPointer<Float>, sampleRate: Double,
                                 startTime: MonotonicTime, streamOffset: Double) -> [MeterReading] {
        guard sampleRate > 0, !samples.isEmpty else { return [] }
        let blockSize = max(1, Int((sampleRate * blockDuration).rounded()))
        let period = 1 / emitRateHz
        if nextEmitOffset == nil { nextEmitOffset = streamOffset + period }
        var readings: [MeterReading] = []
        for (index, sample) in samples.enumerated() {
            let value = Double(sample)
            blockSumSquares += value * value
            blockCount += 1
            blockPeak = max(blockPeak, abs(sample))
            guard blockCount >= blockSize else { continue }

            let duration = Double(blockCount) / sampleRate
            let level = normalization.normalize(rms: (blockSumSquares / Double(blockCount)).squareRoot())
            digitalSilence = blockPeak == 0 ? digitalSilence + duration : 0
            vad.update(level: micState == .muted ? 0 : level, duration: duration)
            windowSumSquares += blockSumSquares
            windowCount += blockCount
            blockSumSquares = 0
            blockCount = 0
            blockPeak = 0

            let endSeconds = Double(index + 1) / sampleRate
            let endOffset = streamOffset + endSeconds
            if let due = nextEmitOffset, endOffset + 1e-9 >= due {
                let muted = micState == .muted
                let rms = muted ? 0 : normalization.normalize(rms: (windowSumSquares / Double(max(1, windowCount))).squareRoot())
                let sample = AudioLevelSample(time: startTime.offset(bySeconds: endSeconds), rms: rms,
                                              isVoice: !muted && vad.isVoice, micState: micState)
                readings.append(MeterReading(sample: sample, streamOffset: endOffset))
                windowSumSquares = 0
                windowCount = 0
                let next = due + period
                nextEmitOffset = next < endOffset ? endOffset + period : next
            }
        }
        return readings
    }

    public mutating func process(samples: [Float], sampleRate: Double,
                                 startTime: MonotonicTime, streamOffset: Double) -> [MeterReading] {
        samples.withUnsafeBufferPointer {
            process(samples: $0, sampleRate: sampleRate, startTime: startTime, streamOffset: streamOffset)
        }
    }
}
