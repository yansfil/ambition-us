import AgentContracts
import Foundation
import SpeechInput

// 마이크 없이 합성 데이터로 SpeechInput 순수 로직을 검사한다.

private struct LinearClock: StreamClock {
    let base: Double
    func monotonicTime(atStreamOffset offset: Double) -> MonotonicTime? { at(base + offset) }
}

private struct FakeAlignmentService: RemoteAlignmentService {
    let offsets: [ClipWordOffset]
    func wordOffsets(for input: RemoteAlignmentInput) async throws -> [ClipWordOffset] { offsets }
}

private func at(_ seconds: Double) -> MonotonicTime {
    MonotonicTime(nanoseconds: UInt64((seconds * 1_000_000_000).rounded()))
}

private func secondsOf(_ time: MonotonicTime) -> Double { Double(time.nanoseconds) / 1_000_000_000 }

private func near(_ time: MonotonicTime?, _ seconds: Double, _ tolerance: Double = 0.0005) -> Bool {
    guard let time else { return false }
    return abs(secondsOf(time) - seconds) <= tolerance
}

private func near(_ value: Double?, _ expected: Double, _ tolerance: Double = 1e-6) -> Bool {
    guard let value else { return false }
    return abs(value - expected) <= tolerance
}

private func sine(seconds: Double, amplitude: Float, rate: Double = 16_000, frequency: Double = 220) -> [Float] {
    (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / rate)) }
}

private func noise(seconds: Double, amplitude: Float, rate: Double = 16_000, seed: UInt64 = 7) -> [Float] {
    var state = seed
    return (0..<Int(seconds * rate)).map { _ in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return amplitude * (Float(state >> 40) / Float(1 << 24) * 2 - 1)
    }
}

/// 100ms 덩어리로 나눠 미터에 넣는다. 첫 샘플의 실제 시각은 `base`초.
private func meterRun(_ signal: [Float], base: Double, rate: Double = 16_000,
                      meter: inout LevelMeter) -> [MeterReading] {
    var readings: [MeterReading] = []
    let chunk = Int(rate / 10)
    var index = 0
    while index < signal.count {
        let slice = Array(signal[index..<min(signal.count, index + chunk)])
        let offset = Double(index) / rate
        readings += meter.process(samples: slice, sampleRate: rate, startTime: at(base + offset), streamOffset: offset)
        index += chunk
    }
    return readings
}

private func word(_ text: String, _ start: Double, _ end: Double, confidence: Double = 0.9) -> WordTiming {
    WordTiming(word: text, start: at(start), end: at(end), confidence: confidence)
}

private func segment(_ text: String, _ start: Double, _ end: Double, final: Bool,
                     _ tokens: [(String, Double, Double)]) -> TranscriberSegment {
    TranscriberSegment(range: StreamTimeRange(start: start, end: end), text: text,
                       tokens: tokens.map { TimedToken(text: $0.0, range: StreamTimeRange(start: $0.1, end: $0.2)) },
                       isFinal: final)
}

func speechChecks() async {
    await suite("SpeechInput") {
        hostTimeChecks()
        levelChecks()
        voiceActivityChecks()
        await ringChecks()
        segmenterChecks()
        assemblerChecks()
        paralinguisticChecks()
        await geminiStubChecks()
        await replayChecks()
    }
}

/// 선택 검사: `GAZE_SPEECH_REPLAY=<오디오 파일>`이면 실제 SpeechTranscriber(ko-KR)로 파일을 흘려 본다.
/// 마이크는 쓰지 않지만 음성 인식 자산이 필요하다. 기본 실행에서는 건너뛴다.
private func replayChecks() async {
    guard let path = ProcessInfo.processInfo.environment["GAZE_SPEECH_REPLAY"], !path.isEmpty else { return }
    do {
        let result = try await SpeechFileReplay.run(fileURL: URL(fileURLWithPath: path))
        print("  info locale=\(result.resolvedLocale?.identifier ?? "-") segments=\(result.segments.count) "
              + "updates=\(result.updates.count) cues=\(result.cues.map(\.kind.rawValue))")
        for update in result.updates {
            let words = update.words.map {
                String(format: "%@[%.2f-%.2f]", $0.word, secondsOf($0.start) - secondsOf(result.hostBase),
                       secondsOf($0.end) - secondsOf(result.hostBase))
            }
            print("  info rev\(update.revision) final=\(update.isFinal) text=\"\(update.text)\" "
                  + "stable=\"\(update.stablePrefix)\" words=\(words.joined(separator: " "))")
        }
        if ProcessInfo.processInfo.environment["GAZE_SPEECH_REPLAY_TOKENS"] != nil {
            for segment in result.segments {
                let tokens = segment.tokens.map { token in
                    "\"\(token.text)\"" + (token.range.map { String(format: "[%.2f-%.2f]", $0.start, $0.end) } ?? "[-]")
                }
                print(String(format: "  info seg final=%@ [%.2f-%.2f] ", segment.isFinal ? "Y" : "N",
                             segment.range.start, segment.range.end) + tokens.joined(separator: " "))
            }
        }
        let finals = result.updates.filter(\.isFinal)
        check(!finals.isEmpty, "재생: 최종 리비전이 나옴")
        check(result.segments.contains { $0.tokens.contains { $0.range != nil } }, "재생: run에 audioTimeRange가 있음")
        let words = finals.flatMap(\.words)
        check(!words.isEmpty && zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start },
              "재생: 단어 시각이 순서대로")
        // host tick 반올림(<42ns)을 감안해 1ms 여유.
        check(words.allSatisfy { secondsOf($0.start) >= secondsOf(result.hostBase) - 0.001 },
              "재생: 단어 시각이 버퍼 host time 기준")
        check(result.levels.contains { $0.isVoice }, "재생: VAD가 음성을 잡음")
    } catch {
        check(false, "재생 실패: \(error)")
    }
}

private func hostTimeChecks() {
    let ticks = HostTime.hostTicks(fromNanoseconds: 1_000_000_000)
    let back = HostTime.nanoseconds(fromHostTicks: ticks)
    check(abs(Int64(back) - 1_000_000_000) < 1_000, "host tick ↔ 나노초 왕복")
    let clock = HostTimeClock()
    let first = clock.now()
    check(clock.now() >= first, "HostTimeClock 단조 증가")
}

private func levelChecks() {
    let normalization = LevelNormalization()
    check(normalization.normalize(rms: 1.0) == 1, "RMS 정규화: 0 dBFS → 1")
    check(normalization.normalize(rms: 2.0) == 1, "RMS 정규화: 풀스케일 초과는 1로 자름")
    check(near(normalization.normalize(rms: 0.001), 0), "RMS 정규화: -60 dBFS → 0")
    check(near(normalization.normalize(rms: pow(10, -30.0 / 20)), 0.5), "RMS 정규화: -30 dBFS → 0.5")
    check(normalization.normalize(rms: 0) == 0 && normalization.normalize(rms: .nan) == 0, "RMS 정규화: 0·NaN → 0")
    check(near(SignalMath.rms(sine(seconds: 1, amplitude: 1)), 1 / 2.0.squareRoot(), 1e-3), "사인파 RMS = 진폭/√2")

    // 잡음 1초 → 음성(-23 dBFS RMS) 1초 → 잡음 1.5초.
    let signal = noise(seconds: 1, amplitude: 0.0005) + sine(seconds: 1, amplitude: 0.1)
        + noise(seconds: 1.5, amplitude: 0.0005, seed: 11)
    var meter = LevelMeter()
    let readings = meterRun(signal, base: 50, meter: &meter)
    check((104...106).contains(readings.count), "레벨 샘플 ~30Hz 스로틀 (3.5초 → \(readings.count)개)")
    check(readings.filter { $0.streamOffset < 0.95 }.allSatisfy { !$0.sample.isVoice }, "VAD: 앞 잡음 구간은 무음")
    check(readings.filter { (1.1...2.0).contains($0.streamOffset) }.allSatisfy { $0.sample.isVoice }, "VAD: 음성 구간 검출")
    check(readings.filter { $0.streamOffset > 2.45 }.allSatisfy { !$0.sample.isVoice }, "VAD: hangover 뒤 무음 복귀")
    let voiced = readings.filter { (1.2...1.9).contains($0.streamOffset) }.map(\.sample.rms)
    let expected = normalization.normalize(rms: 0.1 / 2.0.squareRoot())
    check(voiced.allSatisfy { abs($0 - expected) < 0.02 }, "음성 구간 정규화 RMS ≈ \(String(format: "%.3f", expected))")
    check(readings.filter { $0.streamOffset < 0.95 }.allSatisfy { $0.sample.rms < 0.05 }, "잡음 구간 RMS ≈ 0")
    check(readings.allSatisfy { near($0.sample.time, 50 + $0.streamOffset, 1e-6) }, "레벨 샘플 시각 = 버퍼 host time + 오프셋")
    check(readings.allSatisfy { $0.sample.micState == .active }, "마이크 상태 active")

    var muteMeter = LevelMeter()
    let silent = meterRun([Float](repeating: 0, count: 16_000), base: 0, meter: &muteMeter)
    check(silent.first?.sample.micState == .active && silent.last?.sample.micState == .muted,
          "디지털 무음 0.5초 이상이면 muted")
    check(silent.last?.sample.rms == 0 && silent.last?.sample.isVoice == false, "muted면 rms 0, 음성 아님")
}

private func voiceActivityChecks() {
    // 잡음 0.5 → 음성 1.0 → 쉼 0.75 → 음성 0.6 → 잡음 1.5초.
    let signal = noise(seconds: 0.5, amplitude: 0.0005) + sine(seconds: 1.0, amplitude: 0.1)
        + noise(seconds: 0.75, amplitude: 0.0005, seed: 3) + sine(seconds: 0.6, amplitude: 0.1)
        + noise(seconds: 1.5, amplitude: 0.0005, seed: 5)
    var meter = LevelMeter()
    let readings = meterRun(signal, base: 200, meter: &meter)
    var tracker = VoiceActivityTracker()
    var detector = ParalinguisticDetector()
    var events: [VoiceActivityTracker.Event] = []
    var cues: [ParalinguisticCue] = []
    for reading in readings {
        for event in tracker.ingest(reading) {
            events.append(event)
            cues += detector.ingest(event, utteranceID: nil)
        }
    }
    let starts = events.compactMap { event -> VoiceActivityTracker.Pause?? in
        if case .voiceStarted(_, _, let pause) = event { return .some(pause) } else { return nil }
    }
    let endpoints = events.compactMap { event -> Double? in
        if case .endpoint(let offset, _) = event { return offset } else { return nil }
    }
    check(starts.count == 2, "음성 시작 2번")
    if starts.count == 2, let pause = starts[1] {
        check(abs(pause.duration - 0.75) < 0.08, "쉼 길이 추정 ≈ 0.75초 (\(String(format: "%.3f", pause.duration)))")
        check(near(pause.start, 201.5, 0.06), "쉼 시작 시각 ≈ 실제 소리 끝")
    } else {
        check(false, "두 번째 음성 시작에 쉼 정보")
    }
    check(endpoints.count == 1, "endpoint는 마지막 무음에서 한 번만 (\(endpoints.count))")
    check(near(endpoints.first, 3.15, 0.06), "endpoint 오프셋 = 마지막 음성(hangover 포함)")

    let pauses = cues.filter { $0.kind == .longPause }
    check(pauses.count == 1 && near(pauses.first?.time, 201.5, 0.06), "에너지 기반 longPause 1개")
}

private func ringChecks() async {
    // 48kHz, 0.1초 버퍼. 세 번째 버퍼(host 10.2초)가 빠졌다.
    let ring = AudioBufferRing()
    let hosts = [10.0, 10.1, 10.3, 10.4]
    for (index, host) in hosts.enumerated() {
        ring.append(frameCount: 4_800, sampleRate: 48_000, hostTime: at(host),
                    monoSamples: [Float](repeating: Float(index), count: 4_800))
    }
    check(near(ring.streamEnd, 0.4), "스트림 끝 = 받은 프레임 길이")
    check(near(ring.monotonicTime(atStreamOffset: 0.05), 10.05), "오프셋 → 실제 시각 (첫 버퍼)")
    check(near(ring.monotonicTime(atStreamOffset: 0.25), 10.35), "빠진 버퍼 뒤에도 host time 기준으로 매핑")
    check(near(ring.monotonicTime(atStreamOffset: 0.45), 10.55), "기록 범위 밖은 마지막 앵커에서 외삽")
    check(near(ring.streamOffset(at: at(10.35)), 0.25, 1e-6), "실제 시각 → 오프셋 역변환")
    check(near(ring.streamOffset(at: at(10.25)), 0.2, 1e-6), "빠진 구간 시각은 경계로 붙임")

    let clip = ring.clip(StreamTimeRange(start: 0.15, end: 0.35))
    check(near(clip?.streamStart, 0.15, 1e-9) && near(clip?.duration, 0.2, 1e-9), "클립 구간(표본 경계 정확)")
    check(clip?.samples.first == 1 && clip?.samples.last == 3, "클립 샘플 내용")
    check(clip.map { $0.wavData().count == 44 + $0.samples.count * 2 } ?? false, "WAV 인코딩 길이")

    // 클립 상대 오프셋(0.05~0.15초) → 스트림 0.20~0.30 → host 10.30~10.40.
    let offsets = [ClipWordOffset(word: "이거", start: 0.05, end: 0.15, confidence: 0.9)]
    let mapped = RemoteWordAligner.map(offsets, clipStreamStart: 0.15, clipDuration: 0.2, clock: ring)
    check(mapped.count == 1 && near(mapped.first?.start, 10.30) && near(mapped.first?.end, 10.40),
          "클립 상대 오프셋 → MonotonicTime")

    let request = AlignmentRequest(utteranceID: UUID(), text: "이거", streamRange: StreamTimeRange(start: 0.15, end: 0.35),
                                   hypotheses: [AlignedWord(word: "이거", range: StreamTimeRange(start: 0.0, end: 0.1),
                                                            confidence: 0.7, isEstimated: false)])
    let remote = RemoteWordAligner(service: FakeAlignmentService(offsets: offsets), ring: ring, padding: 0)
    let remoteWords = (try? await remote.align(request)) ?? []
    check(remoteWords.count == 1 && near(remoteWords.first?.start, 10.30), "원격 정렬기: 링 클립 → 실제 시각")

    let local = TranscriberRunAligner(clock: ring)
    let stub = RemoteWordAligner(service: GeminiTranscribeAlignmentService(apiKeyProvider: { nil }), ring: ring)
    let fallbackWords = (try? await FallbackWordAligner(primary: stub, fallback: local).align(request)) ?? []
    check(fallbackWords.count == 1 && near(fallbackWords.first?.start, 10.0), "원격 실패 시 로컬 run 정렬로 대체")
}

private func segmenterChecks() {
    let tokens = [
        TimedToken(text: "이거", range: StreamTimeRange(start: 0.0, end: 0.4), confidence: 0.9),
        TimedToken(text: "를 ", range: StreamTimeRange(start: 0.4, end: 0.6), confidence: 0.7),
        TimedToken(text: "저기", range: StreamTimeRange(start: 0.7, end: 1.0)),
        TimedToken(text: "로 옮겨", range: StreamTimeRange(start: 1.0, end: 1.6)),
        TimedToken(text: ".", range: nil),
    ]
    let words = WordSegmenter.words(from: tokens, fallbackRange: StreamTimeRange(start: 0, end: 1.6),
                                    defaultConfidence: 0.9)
    check(words.map(\.word) == ["이거를", "저기로", "옮겨"], "run → 어절 묶기, 문장부호 제거 (\(words.map(\.word)))")
    if words.count == 3 {
        check(near(words[0].range.start, 0.0) && near(words[0].range.end, 0.6), "여러 run에 걸친 어절 구간 합치기")
        check(near(words[1].range.end, 1.2) && near(words[2].range.start, 1.2), "run 안 여러 어절은 글자 수 비례로 나누기")
        check(near(words[0].confidence, 0.8) && words[1].isEstimated && !words[0].isEstimated, "run 신뢰도 평균·추정 표시")
    }
    // 맞닿은 run이 앞 무음까지 덮으면 VAD 음성 시작으로 단어 시작을 옮긴다(끝은 유지).
    let voice = VoiceActivityMap(ranges: [StreamTimeRange(start: 0, end: 0.33), StreamTimeRange(start: 1.22, end: 1.95)])
    let snapped = voice.snappingStarts(of: [
        AlignedWord(word: "음", range: StreamTimeRange(start: 0, end: 0.36), confidence: 0.9, isEstimated: false),
        AlignedWord(word: "이", range: StreamTimeRange(start: 0.36, end: 1.32), confidence: 0.9, isEstimated: false),
        AlignedWord(word: "파일을", range: StreamTimeRange(start: 1.32, end: 1.98), confidence: 0.9, isEstimated: false),
    ])
    check(near(snapped[0].range.start, 0) && near(snapped[1].range.start, 1.22) && near(snapped[1].range.end, 1.32)
          && near(snapped[2].range.start, 1.32), "단어 시작을 VAD 음성 시작으로 보정")
    check(VoiceActivityMap().snappingStarts(of: snapped) == snapped, "음성 구간 정보가 없으면 그대로")

    let untimed = WordSegmenter.words(from: [TimedToken(text: "열어 줘", range: nil)],
                                      fallbackRange: StreamTimeRange(start: 2.0, end: 3.0), defaultConfidence: 0.9)
    check(untimed.count == 2 && near(untimed.first?.range.start, 2.0) && near(untimed.last?.range.end, 3.0)
          && untimed.allSatisfy(\.isEstimated), "시각 없는 run은 결과 구간 안에서 보간")
}

private func assemblerChecks() {
    var assembler = TranscriptAssembler(clock: LinearClock(base: 100))
    var all: [TranscriptUpdate] = []
    func feed(_ updates: [AssembledUpdate]) -> [TranscriptUpdate] {
        let plain = updates.map(\.update)
        all += plain
        return plain
    }

    let r1 = feed(assembler.ingest(segment("이거", 0, 0.6, final: false, [("이거", 0.1, 0.5)]), now: 0.7))
    check(r1.count == 1 && r1[0].revision == 1 && r1[0].text == "이거" && r1[0].stablePrefix.isEmpty && !r1[0].isFinal,
          "volatile → 리비전 1")
    check(r1.first?.words.first.map { near($0.start, 100.1) && near($0.end, 100.5) } ?? false,
          "단어 시각 = run audioTimeRange → 링 시각")
    let id = r1.first?.utteranceID

    let r2 = feed(assembler.ingest(segment("이거 저기로", 0, 1.2, final: false,
                                           [("이거", 0.1, 0.5), (" 저기로", 0.6, 1.1)]), now: 1.3))
    check(r2.count == 1 && r2[0].revision == 2 && r2[0].text == "이거 저기로" && r2[0].utteranceID == id,
          "새 volatile은 교체(append 아님)")

    let r3 = feed(assembler.ingest(segment("이거 저기로", 0, 1.2, final: true,
                                           [("이거", 0.1, 0.5), (" 저기로", 0.6, 1.1)]), now: 1.4))
    check(r3.count == 1 && r3[0].revision == 3 && r3[0].stablePrefix == "이거 저기로" && !r3[0].isFinal,
          "확정 결과 → stablePrefix")

    let r4 = feed(assembler.ingest(segment("옮겨", 1.2, 1.7, final: false, [(" 옮겨", 1.3, 1.6)]), now: 1.8))
    check(r4.count == 1 && r4[0].text == "이거 저기로 옮겨" && r4[0].stablePrefix == "이거 저기로"
          && r4[0].words.count == 3, "확정 + volatile 이어 붙이기, stablePrefix는 접두사")

    let r5 = feed(assembler.endpoint(at: 1.9, now: 2.5))
    check(r5.isEmpty, "endpoint 뒤 volatile이 남으면 확정을 기다림")

    let r6 = feed(assembler.ingest(segment("옮겨", 1.2, 2.0, final: true, [(" 옮겨", 1.3, 1.6)]), now: 2.6))
    check(r6.count == 1 && r6[0].revision == 5 && r6[0].isFinal && r6[0].stablePrefix == r6[0].text
          && r6[0].utteranceID == id, "endpoint까지 확정되면 최종 리비전 하나")
    check(r6.first?.words.last.map { $0.word == "옮겨" && near($0.start, 101.3) } ?? false, "최종 단어 시각")

    let late = feed(assembler.ingest(segment("옮겨", 1.2, 2.0, final: true, [(" 옮겨", 1.3, 1.6)]), now: 2.7))
    check(late.isEmpty, "닫힌 구간에 늦게 온 결과는 버림(중복 명령 방지)")

    let n1 = feed(assembler.ingest(segment("닫아", 2.0, 3.4, final: false, [("닫아", 3.0, 3.3)]), now: 3.5))
    check(n1.count == 1 && n1[0].revision == 1 && n1[0].utteranceID != id, "새 발화는 새 ID, 리비전 1부터")
    _ = feed(assembler.endpoint(at: 3.5, now: 3.6))
    check(feed(assembler.tick(now: 4.0, voiceActive: false)).isEmpty, "확정 대기 중")
    let forced = feed(assembler.tick(now: 5.2, voiceActive: false))
    check(forced.count == 1 && forced[0].isFinal && forced[0].text == "닫아" && forced[0].revision == 2,
          "확정이 늦으면 시간 초과로 강제 종료")

    let revisions = all.filter { $0.utteranceID == id }.map(\.revision)
    check(revisions == [1, 2, 3, 4, 5], "같은 발화 리비전 단조 증가 \(revisions)")
    check(all.allSatisfy { $0.text.hasPrefix($0.stablePrefix) }, "stablePrefix는 항상 text의 접두사")

    var store = TranscriptRevisionStore()
    for update in all { store.apply(update) }
    check(store.utterances.map(\.text) == ["이거 저기로 옮겨", "닫아"], "저장소: 발화별 최신 리비전만(교체)")
    if let id, let stale = all.first(where: { $0.utteranceID == id && $0.revision == 2 }) {
        check(!store.apply(stale) && store.latest(id)?.revision == 5, "늦게 온 낮은 리비전 무시")
    }

    // endpoint 뒤 새 말이 같은 volatile 결과에 섞여 들어온 경우: 토큰 시각으로 가른다.
    var split = TranscriptAssembler(clock: LinearClock(base: 0))
    _ = split.ingest(segment("이거 열어", 0, 1.0, final: false, [("이거", 0.1, 0.4), (" 열어", 0.5, 0.9)]), now: 1.0)
    _ = split.endpoint(at: 1.0, now: 1.7)
    let mixed = split.ingest(segment("이거 열어 닫아", 0, 2.6, final: false,
                                     [("이거", 0.1, 0.4), (" 열어", 0.5, 0.9), (" 닫아", 2.2, 2.5)]), now: 2.7).map(\.update)
    check(mixed.count == 2 && mixed[0].isFinal && mixed[0].text == "이거 열어" && mixed[1].text == "닫아"
          && mixed[1].revision == 1 && mixed[0].utteranceID != mixed[1].utteranceID,
          "endpoint 경계를 넘는 결과는 앞 발화 종료 + 새 발화로 분리")

    // 거친 volatile run(뒤 무음까지 덮음)은 시작 시각 기준으로 endpoint 앞 발화에 남는다.
    var coarse = TranscriptAssembler(clock: LinearClock(base: 0))
    let c1 = coarse.ingest(segment("음", 0, 1.1, final: false, [("음", 0, 1.1)]), now: 1.1).map(\.update)
    _ = coarse.endpoint(at: 0.57, now: 1.5)
    let c2 = coarse.ingest(segment("음.", 0, 1.2, final: false, [("음.", 0, 1.2)]), now: 1.6).map(\.update)
    let c3 = coarse.ingest(segment("음.", 0, 1.2, final: true, [("음.", 0, 1.2)]), now: 1.7).map(\.update)
    check(c2.count == 1 && !c2[0].isFinal && c2[0].utteranceID == c1.first?.utteranceID,
          "거친 run은 endpoint를 넘어도 같은 발화의 수정")
    check(c3.count == 1 && c3[0].isFinal && c3[0].text == "음." && c3[0].utteranceID == c1.first?.utteranceID,
          "확정 결과로 같은 발화를 닫음(중복 발화 없음)")

    // 무음 환각 방지: VAD 음성 구간과 겹치지 않는 결과로는 새 발화를 열지 않는다.
    var pipeline = SpeechPipeline(clock: LinearClock(base: 0))
    var gateMeter = LevelMeter()
    let gateSignal = noise(seconds: 0.5, amplitude: 0.0005) + sine(seconds: 1.0, amplitude: 0.1)
        + noise(seconds: 2.5, amplitude: 0.0005, seed: 9)
    for reading in meterRun(gateSignal, base: 0, meter: &gateMeter) { _ = pipeline.process(reading) }
    let ghost = pipeline.ingest(segment("감.", 3.2, 3.9, final: false, [("감.", 3.2, 3.9)]), now: 4.0)
    check(ghost.updates.isEmpty, "음성 구간 밖 결과(무음 환각)는 버림")
    let real = pipeline.ingest(segment("열어", 0.5, 1.6, final: true, [("열어", 0.6, 1.4)]), now: 4.0)
    check(real.updates.count == 1 && real.updates[0].update.isFinal, "음성 구간과 겹치는 결과는 받음(보류 endpoint로 바로 종료)")
    check(pipeline.ingest(segment(".", 3.2, 3.9, final: true, [(".", 3.2, 3.9)]), now: 4.1).updates.isEmpty,
          "문장부호만 있는 결과는 빈 것으로 취급")

    // 짧은 명령: 전사 결과보다 endpoint가 먼저 온 경우.
    var short = TranscriptAssembler(clock: LinearClock(base: 0))
    check(short.endpoint(at: 0.8, now: 1.4).isEmpty, "발화 전 endpoint는 보류")
    let shortUpdates = short.ingest(segment("열어", 0, 1.0, final: true, [("열어", 0.2, 0.6)]), now: 1.6).map(\.update)
    check(shortUpdates.count == 1 && shortUpdates[0].isFinal && shortUpdates[0].text == "열어",
          "보류된 endpoint로 늦게 온 확정 결과를 바로 종료")
}

private func paralinguisticChecks() {
    var detector = ParalinguisticDetector()
    let first = UUID()
    let update = TranscriptUpdate(utteranceID: first, revision: 3, text: "음 이거 그 파일 열어", stablePrefix: "음 이거 그 파일 열어",
                                  words: [word("음", 10.0, 10.4), word("이거", 11.4, 11.8), word("그", 12.0, 12.2),
                                          word("파일", 12.7, 13.1), word("열어", 13.2, 13.6)], isFinal: true)
    let cues = detector.ingest(update)
    let fillers = cues.filter { $0.kind == .filler }
    check(fillers.contains { near($0.time, 10.0) }, "간투사 '음' 검출")
    check(fillers.contains { near($0.time, 12.0) }, "뒤에 쉼이 있는 '그'는 간투사")
    check(cues.contains { $0.kind == .longPause && near($0.time, 10.4) }, "단어 간격 1초 → longPause")
    check(cues.contains { $0.kind == .hesitation }, "간투사 + 긴 쉼 → hesitation")
    check(cues.allSatisfy { $0.utteranceID == first }, "cue에 발화 ID")
    check(detector.ingest(update).isEmpty, "같은 리비전 재입력 시 중복 cue 없음")

    var plain = ParalinguisticDetector()
    let deictic = TranscriptUpdate(utteranceID: UUID(), revision: 1, text: "그 파일 열어", stablePrefix: "그 파일 열어",
                                   words: [word("그", 20.0, 20.15), word("파일", 20.2, 20.6), word("열어", 20.7, 21.0)],
                                   isFinal: true)
    check(plain.ingest(deictic).isEmpty, "지시어 '그 파일'은 간투사 아님")

    var rate = ParalinguisticDetector()
    let slowing = TranscriptUpdate(
        utteranceID: UUID(), revision: 2, text: "이거를 저기로 옮겨 주고 그다음에 이걸 닫아 줘", stablePrefix: "",
        words: [word("이거를", 30.0, 30.4), word("저기로", 30.45, 30.85), word("옮겨", 30.9, 31.2), word("주고", 31.25, 31.55),
                word("그다음에", 32.0, 33.0), word("이걸", 33.4, 34.0), word("닫아", 34.4, 35.0), word("줘", 35.4, 36.0)],
        isFinal: false)
    check(!rate.ingest(slowing).contains { $0.kind == .speechRateDrop }, "volatile 리비전(추정 시각)으로는 속도 판단 안 함")
    let slowingFinal = TranscriptUpdate(utteranceID: slowing.utteranceID, revision: 3, text: slowing.text,
                                        stablePrefix: slowing.text, words: slowing.words, isFinal: true)
    check(rate.ingest(slowingFinal).contains { $0.kind == .speechRateDrop && near($0.time, 32.0) }, "말 속도 저하 검출")
    var steady = ParalinguisticDetector()
    let even = TranscriptUpdate(
        utteranceID: UUID(), revision: 1, text: "이거를 저기로 옮겨 주고 저거를 여기로 옮겨 줘", stablePrefix: "",
        words: [word("이거를", 40.0, 40.5), word("저기로", 40.6, 41.1), word("옮겨", 41.2, 41.5), word("주고", 41.6, 41.9),
                word("저거를", 42.0, 42.5), word("여기로", 42.6, 43.1), word("옮겨", 43.2, 43.5), word("줘", 43.6, 43.8)],
        isFinal: true)
    check(!steady.ingest(even).contains { $0.kind == .speechRateDrop }, "일정한 속도면 속도 저하 없음")

    // 전사기가 지운 간투사: 첫 단어 직전, 단어와 안 겹치는 짧은 음성 구간.
    var vocal = ParalinguisticDetector()
    _ = vocal.ingest(.voiceStopped(.init(start: at(50.0), end: at(50.3), startOffset: 0, endOffset: 0.3)), utteranceID: nil)
    let vocalCues = vocal.ingest(TranscriptUpdate(utteranceID: UUID(), revision: 1, text: "이거 열어", stablePrefix: "이거 열어",
                                                  words: [word("이거", 51.0, 51.4), word("열어", 51.5, 51.9)], isFinal: true))
    check(vocalCues.contains { $0.kind == .filler && near($0.time, 50.0) && $0.confidence < 0.5 },
          "단어 없는 짧은 음성 구간 → 낮은 신뢰도 filler")
}

private func geminiStubChecks() async {
    let json = Data("""
    {"words":[{"word":"이거","start":"0.420s","end":0.71,"confidence":0.93},{"text":"열어","startOffset":0.8,"endOffset":"1.1s"}]}
    """.utf8)
    let parsed = try? GeminiTranscribeAlignmentService.parseWordOffsets(json)
    check(parsed?.count == 2 && near(parsed?.first?.start, 0.42) && near(parsed?.last?.end, 1.1)
          && parsed?.first?.confidence == 0.93, "Gemini 단어 오프셋 응답 해석")
    var invalidRejected = false
    do { _ = try GeminiTranscribeAlignmentService.parseWordOffsets(Data("nope".utf8)) } catch { invalidRejected = true }
    check(invalidRejected, "잘못된 응답 거부")

    let fakeKey = "test-placeholder-not-a-key"
    let service = GeminiTranscribeAlignmentService(apiKeyProvider: { fakeKey })
    check(!String(describing: service).contains(fakeKey) && service.model == "gemini-3.5-transcribe",
          "설명 문자열에 키를 넣지 않음, 기본 모델명")
    let input = RemoteAlignmentInput(clip: AudioClip(streamStart: 0, sampleRate: 16_000, samples: [0]), transcript: "이거",
                                     languageCode: "ko-KR")
    var missing = false
    do { _ = try await GeminiTranscribeAlignmentService(apiKeyProvider: { nil }).wordOffsets(for: input) } catch {
        missing = (error as? RemoteAlignmentError) == .missingCredentials
    }
    check(missing, "키 없으면 missingCredentials")
}
