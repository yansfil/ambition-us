import AVFAudio
import AgentContracts
import CoreMedia
import Foundation
import Speech
import Synchronization

/// 탭 콜백이 보내는 출력.
struct TapSinks: Sendable {
    var level: @Sendable (AudioLevelSample) -> Void
    var readings: @Sendable ([MeterReading]) -> Void
    var analyzer: AsyncStream<AnalyzerInput>.Continuation?
}

/// 오디오 탭 스레드에서 버퍼 하나를 처리한다. 마이크 스트림 하나가 링·미터·전사기를 모두 먹인다.
///
/// 1. `AVAudioTime.hostTime` → `MonotonicTime`(입력 지연 보정).
/// 2. 모노 다운믹스 → `AudioBufferRing.append`로 스트림 구간 배정.
/// 3. `LevelMeter`로 RMS·VAD(~30Hz).
/// 4. 분석기 형식으로 변환해 `AnalyzerInput(bufferStartTime: 누적 프레임)`으로 넘긴다.
final class TapProcessor: Sendable {
    private struct State {
        var meter: LevelMeter
        var analyzerFormat: AVAudioFormat?
        var converter: AVAudioConverter?
        var converterSource: AVAudioFormat?
        var analyzerFramesOut: Int64 = 0
        var inputLatency: Double = 0
        var muted = false
    }

    /// 변환기 입력 블록에 버퍼를 한 번만 넘기는 상자.
    private final class OneShot: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func take() -> AVAudioPCMBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }

    let ring: AudioBufferRing
    private let sinks: TapSinks
    private let state: Mutex<State>

    init(ring: AudioBufferRing, meter: LevelMeter, analyzerFormat: AVAudioFormat?, sinks: TapSinks) {
        self.ring = ring
        self.sinks = sinks
        self.state = Mutex(State(meter: meter, analyzerFormat: analyzerFormat))
    }

    func setInputLatency(_ seconds: Double) {
        state.withLock { $0.inputLatency = max(0, seconds.isFinite ? seconds : 0) }
    }

    /// 앱 차원 음소거. 미터는 muted를 내고 전사기에는 무음을 넣는다(타임라인 유지).
    func setMuted(_ muted: Bool) {
        state.withLock {
            $0.muted = muted
            $0.meter.externallyMuted = muted
        }
    }

    func finishAnalyzerInput() {
        sinks.analyzer?.finish()
    }

    func process(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        let frames = Int(buffer.frameLength)
        let rate = buffer.format.sampleRate
        guard frames > 0, rate > 0 else { return }
        let mono = Self.monoSamples(buffer)
        let latency = state.withLock { $0.inputLatency }
        let duration = Double(frames) / rate
        let host = when.isHostTimeValid
            ? MonotonicTime(nanoseconds: HostTime.nanoseconds(fromHostTicks: when.hostTime))
            : HostTime.now().offset(bySeconds: -duration)
        let start = host.offset(bySeconds: -latency)
        let range = ring.append(frameCount: frames, sampleRate: rate, hostTime: start,
                                monoSamples: mono.isEmpty ? nil : mono)
        let (readings, input) = state.withLock { state -> ([MeterReading], AnalyzerInput?) in
            let readings = mono.isEmpty ? [] : state.meter.process(samples: mono, sampleRate: rate, startTime: start,
                                                                  streamOffset: range.start)
            let input = Self.convert(buffer, streamStart: range.start, state: &state)
            return (readings, input)
        }
        for reading in readings { sinks.level(reading.sample) }
        if !readings.isEmpty { sinks.readings(readings) }
        if let input { sinks.analyzer?.yield(input) }
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, streamStart: Double, state: inout State) -> AnalyzerInput? {
        guard let target = state.analyzerFormat, target.sampleRate > 0 else { return nil }
        if state.converter == nil || state.converterSource.map({ !$0.isEqual(buffer.format) }) ?? true {
            let converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.downmix = true
            state.converter = converter
            state.converterSource = buffer.format
            // 장치가 바뀌어 변환기를 새로 만들면 스트림 타임라인에 다시 맞춘다(뒤로 가지는 않는다).
            state.analyzerFramesOut = max(state.analyzerFramesOut, Int64((streamStart * target.sampleRate).rounded()))
        }
        guard let converter = state.converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        let feeder = OneShot(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if let next = feeder.take() {
                inputStatus.pointee = .haveData
                return next
            }
            inputStatus.pointee = .noDataNow
            return nil
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        if state.muted { silence(output) }
        let startTime = CMTime(value: state.analyzerFramesOut, timescale: CMTimeScale(target.sampleRate.rounded()))
        state.analyzerFramesOut += Int64(output.frameLength)
        return AnalyzerInput(buffer: output, bufferStartTime: startTime)
    }

    static func silence(_ buffer: AVAudioPCMBuffer) {
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for audioBuffer in list {
            if let data = audioBuffer.mData { memset(data, 0, Int(audioBuffer.mDataByteSize)) }
        }
    }

    /// 채널 평균 모노 샘플(Float32/Int16 지원).
    static func monoSamples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return [] }
        let interleaved = buffer.format.isInterleaved
        let scale = 1 / Float(channels)
        var mono = [Float](repeating: 0, count: frames)
        if let data = buffer.floatChannelData {
            for channel in 0..<(interleaved ? 1 : channels) {
                let pointer = data[channel]
                if interleaved {
                    for frame in 0..<frames {
                        var sum: Float = 0
                        for c in 0..<channels { sum += pointer[frame * channels + c] }
                        mono[frame] = sum * scale
                    }
                } else {
                    for frame in 0..<frames { mono[frame] += pointer[frame] * scale }
                }
            }
        } else if let data = buffer.int16ChannelData {
            let unit = scale / 32768
            for channel in 0..<(interleaved ? 1 : channels) {
                let pointer = data[channel]
                if interleaved {
                    for frame in 0..<frames {
                        var sum: Float = 0
                        for c in 0..<channels { sum += Float(pointer[frame * channels + c]) }
                        mono[frame] = sum * unit
                    }
                } else {
                    for frame in 0..<frames { mono[frame] += Float(pointer[frame]) * unit }
                }
            }
        } else {
            return []
        }
        return mono
    }
}

/// AVAudioEngine 입력 탭. 액터 밖(비격리) 코드에서 탭 블록을 만들어 오디오 스레드 호출이
/// 액터 격리 검사에 걸리지 않게 한다.
final class MicrophoneCapture {
    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private var tap: TapProcessor?
    private let compensateInputLatency: Bool

    init(compensateInputLatency: Bool) {
        self.compensateInputLatency = compensateInputLatency
    }

    /// 현재 입력 장치의 자연 형식. 장치가 없으면 nil.
    var inputFormat: AVAudioFormat? {
        let format = engine.inputNode.outputFormat(forBus: 0)
        return format.sampleRate > 0 && format.channelCount > 0 ? format : nil
    }

    func start(tap: TapProcessor, onConfigurationChange: @escaping @Sendable () -> Void) throws {
        self.tap = tap
        try installAndStart()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                          object: engine, queue: nil) { _ in
            onConfigurationChange()
        }
    }

    /// 장치·형식 변경 뒤 다시 건다. 스트림 타임라인은 링에서 이어진다.
    func restart() throws {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        try installAndStart()
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        tap = nil
    }

    private func installAndStart() throws {
        guard let tap else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechInputError.noInputDevice }
        tap.setInputLatency(compensateInputLatency ? input.presentationLatency : 0)
        let bufferSize = AVAudioFrameCount(max(256, (format.sampleRate * 0.05).rounded()))
        input.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: Self.tapBlock(for: tap))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw SpeechInputError.engineStartFailed(error.localizedDescription)
        }
    }

    private static func tapBlock(for tap: TapProcessor) -> AVAudioNodeTapBlock {
        { @Sendable buffer, when in tap.process(buffer, when: when) }
    }
}

enum MicrophonePermission {
    static func ensureGranted() async throws {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return
        case .denied:
            throw SpeechInputError.microphonePermissionDenied
        case .undetermined:
            guard await AVAudioApplication.requestRecordPermission() else {
                throw SpeechInputError.microphonePermissionDenied
            }
        @unknown default:
            return
        }
    }
}
