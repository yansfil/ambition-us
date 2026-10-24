import AgentContracts
import CoreGraphics
import Foundation

/// 시선과 음성을 실제 시각 기준으로 결합한다.
///
/// - 시선 샘플은 `bufferWindow`(기본 10초) 링 버퍼에 시각순으로 보관한다.
/// - 지시어 단어마다 `[start - lead, end + lag]` 창과 겹치는 안정된 응시를 골라 그 좌표의 UI 요소를 결합한다.
/// - 같은 (utteranceID, revision)은 한 번만 계산하고 같은 결과를 돌려준다. 새 revision은 처음부터 다시 계산한다.
/// - 보정 revision이 바뀌면 이전 revision 샘플을 모두 버린다. 늦게 도착한 이전 revision 샘플도 거부한다.
public actor AttentionFuser: AttentionFusing {
    public let configuration: FusionConfiguration
    public let lexicon: DeicticLexicon

    private let resolver: any UITargetResolving
    private let clock: any MonotonicClock

    private var gaze: TimeRingBuffer<GazeSample>
    private var nonverbalCues: TimeRingBuffer<NonverbalCue>
    private var paralinguisticCues: TimeRingBuffer<ParalinguisticCue>

    private var calibrationRevision: Int?
    private var calibrationChangedAt: MonotonicTime?

    private struct PointKey: Hashable {
        let x: Int
        let y: Int
    }

    private struct CachedTarget {
        let target: UITarget?
        let resolvedAt: MonotonicTime
    }

    private var targetCache: [PointKey: CachedTarget] = [:]

    private struct AnalysisKey: Hashable {
        let utteranceID: UUID
        let revision: Int
    }

    private var analysisCache: [AnalysisKey: FusionAnalysis] = [:]
    private var analysisOrder: [AnalysisKey] = []
    private var inFlight: [AnalysisKey: Task<FusionAnalysis, Never>] = [:]

    private var counters = FusionStats()

    public init(resolver: any UITargetResolving, clock: any MonotonicClock,
                configuration: FusionConfiguration = FusionConfiguration(), lexicon: DeicticLexicon = .korean) {
        self.resolver = resolver
        self.clock = clock
        self.configuration = configuration
        self.lexicon = lexicon
        gaze = TimeRingBuffer(capacity: configuration.gazeCapacity)
        nonverbalCues = TimeRingBuffer(capacity: configuration.cueCapacity)
        paralinguisticCues = TimeRingBuffer(capacity: configuration.cueCapacity)
    }

    public func stats() -> FusionStats { counters }

    public func currentCalibrationRevision() -> Int? { calibrationRevision }

    // MARK: - 수신

    public func ingest(_ sample: GazeSample) async {
        guard sample.confidence.isFinite, sample.uncertaintyRadius.isFinite,
              sample.point.x.isFinite, sample.point.y.isFinite else {
            counters.rejectedInvalidSamples += 1
            return
        }
        let now = clock.now()
        if sample.time < now.receded(by: configuration.maxSampleAge) {
            counters.rejectedStaleSamples += 1
            return
        }
        if sample.time > now.advanced(by: configuration.maxFutureSkew) {
            counters.rejectedFutureSamples += 1
            return
        }
        if let current = calibrationRevision {
            if sample.calibrationRevision < current {
                counters.rejectedCalibrationSamples += 1
                return
            }
            if sample.calibrationRevision > current {
                // 이전 보정의 좌표는 새 보정과 섞을 수 없다.
                gaze.removeAll()
                calibrationRevision = sample.calibrationRevision
                calibrationChangedAt = sample.time
                counters.calibrationResets += 1
            }
        } else {
            calibrationRevision = sample.calibrationRevision
        }
        if gaze.insert(sample) { counters.droppedOverflowSamples += 1 }
        counters.acceptedSamples += 1
        evict(now: now)
    }

    public func ingest(_ cue: NonverbalCue) async {
        let now = clock.now()
        guard acceptsCue(at: cue.time, confidence: cue.confidence, now: now) else { return }
        nonverbalCues.insert(cue)
        evict(now: now)
    }

    public func ingest(_ cue: ParalinguisticCue) async {
        let now = clock.now()
        guard acceptsCue(at: cue.time, confidence: cue.confidence, now: now) else { return }
        paralinguisticCues.insert(cue)
        evict(now: now)
    }

    // MARK: - 결합

    public func context(for update: TranscriptUpdate) async -> AttentionContext {
        await analysis(for: update).context
    }

    /// `context(for:)`와 같은 계산에 지시어별 역할·이유·응시점을 더해 돌려준다.
    public func analysis(for update: TranscriptUpdate) async -> FusionAnalysis {
        let key = AnalysisKey(utteranceID: update.utteranceID, revision: update.revision)
        if let cached = analysisCache[key] {
            counters.analysisCacheHits += 1
            return cached
        }
        if let running = inFlight[key] {
            counters.analysisCacheHits += 1
            return await running.value
        }
        let now = clock.now()
        evict(now: now)
        let snapshot = Snapshot(now: now, samples: gaze.elements, calibrationRevision: calibrationRevision,
                                calibrationChangedAt: calibrationChangedAt, nonverbal: nonverbalCues.elements,
                                paralinguistic: paralinguisticCues.elements)
        let task = Task { await self.compute(update, snapshot) }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        counters.analysesComputed += 1
        // 계산 중 보정이 바뀌었으면 고정하지 않는다(다음 요청에서 새 보정 기준으로 다시 계산).
        if calibrationRevision == snapshot.calibrationRevision {
            store(result, for: key)
        }
        return result
    }

    // MARK: - 계산

    private struct Snapshot: Sendable {
        let now: MonotonicTime
        let samples: [GazeSample]
        let calibrationRevision: Int?
        let calibrationChangedAt: MonotonicTime?
        let nonverbal: [NonverbalCue]
        let paralinguistic: [ParalinguisticCue]
    }

    private struct TimeSpan {
        let lower: MonotonicTime
        let upper: MonotonicTime
        func contains(_ time: MonotonicTime) -> Bool { time >= lower && time <= upper }
    }

    private func compute(_ update: TranscriptUpdate, _ snapshot: Snapshot) async -> FusionAnalysis {
        var deictics: [ResolvedDeictic] = []
        for match in lexicon.matches(in: update.words) {
            deictics.append(await resolve(match, snapshot))
        }
        let span = utteranceSpan(update, snapshot)
        let (gazedTarget, dwell) = await dictationTarget(in: span, snapshot)
        let paralinguistic = snapshot.paralinguistic.filter { cue in
            if let id = cue.utteranceID { return id == update.utteranceID }
            return span.contains(cue.time)
        }
        let nonverbal = snapshot.nonverbal.filter { span.contains($0.time) }
        let context = AttentionContext(utterance: update, bindings: deictics.map(\.binding), gazedTarget: gazedTarget,
                                       paralinguistic: paralinguistic, nonverbal: nonverbal)
        return FusionAnalysis(context: context, deictics: deictics, gazedTargetDwell: dwell,
                              calibrationRevision: snapshot.calibrationRevision)
    }

    private struct Candidate {
        var target: UITarget?
        /// Σ 신뢰도 × 시간가중치 × 지속시간
        var evidence: Double
        /// Σ 시간가중치 × 지속시간
        var weightedTime: Double
        var longestFixation: Double
        var bestSegmentEvidence: Double
        var point: CGPoint
        var uncertainty: Double
    }

    private func resolve(_ match: DeicticMatch, _ snapshot: Snapshot) async -> ResolvedDeictic {
        let c = configuration
        let word = match.word
        let window = EvidenceWindow(word: word, configuration: c)
        let windowSpan = TimeSpan(lower: window.lowerTime, upper: window.upperTime)

        func unbound(_ outcome: BindingOutcome, count: Int = 0, point: CGPoint? = nil, radius: Double? = nil) -> ResolvedDeictic {
            ResolvedDeictic(match: match, binding: DeicticBinding(word: word, target: nil, confidence: 0),
                            outcome: outcome, point: point, uncertaintyRadius: radius, sampleCount: count)
        }

        if windowSpan.upper < snapshot.now.receded(by: c.bufferWindow) {
            return unbound(.stale)
        }

        let margin = c.segmentationMargin
        let maxGap = c.maxSampleGap.fusionSeconds
        let raw = snapshot.samples.timeSlice(from: windowSpan.lower.receded(by: margin),
                                             through: windowSpan.upper.advanced(by: margin))
        let usable = FixationAnalyzer.timed(raw, maxGap: maxGap).filter { isUsable($0.sample, snapshot) }
        let inWindowCount = usable.count { windowSpan.contains($0.sample.time) }
        if inWindowCount == 0 {
            if let changedAt = snapshot.calibrationChangedAt, windowSpan.lower < changedAt {
                return unbound(.calibrationChanged)
            }
            return unbound(.noGaze)
        }

        let minFixation = c.minFixationDuration.fusionSeconds
        let segments = FixationAnalyzer.segments(usable, radius: c.fixationRadius, maxGap: maxGap)
            .filter { $0.duration + 1e-9 >= minFixation }

        // 같은 UI 요소에 떨어진 응시 조각은 합쳐서 경쟁시킨다.
        var candidates: [String: Candidate] = [:]
        var order: [String] = []
        for (index, segment) in segments.enumerated() {
            var evidence = 0.0
            var weighted = 0.0
            for member in segment.members where windowSpan.contains(member.sample.time) {
                let w = window.weight(at: member.sample.time)
                weighted += w * member.dt
                evidence += w * member.dt * member.sample.confidence
            }
            guard evidence > 0 else { continue }
            let target = await resolveTarget(at: segment.centroid)
            let key = target?.token ?? "unresolved#\(index)"
            if var existing = candidates[key] {
                existing.evidence += evidence
                existing.weightedTime += weighted
                existing.longestFixation = max(existing.longestFixation, segment.duration)
                if evidence > existing.bestSegmentEvidence {
                    existing.bestSegmentEvidence = evidence
                    existing.point = segment.centroid
                    existing.uncertainty = segment.uncertaintyRadius
                    existing.target = target
                }
                candidates[key] = existing
            } else {
                candidates[key] = Candidate(target: target, evidence: evidence, weightedTime: weighted,
                                            longestFixation: segment.duration, bestSegmentEvidence: evidence,
                                            point: segment.centroid, uncertainty: segment.uncertaintyRadius)
                order.append(key)
            }
        }
        guard let firstKey = order.first, var winner = candidates[firstKey] else {
            return unbound(.noStableFixation, count: inWindowCount)
        }
        var total = 0.0
        for key in order {
            let candidate = candidates[key]!
            total += candidate.evidence
            // 동점이면 먼저 본 쪽(order가 시간순).
            if candidate.evidence > winner.evidence { winner = candidate }
        }

        let meanConfidence = winner.evidence / max(winner.weightedTime, 1e-9)
        let coverage = winner.weightedTime / max(window.maxWeightedTime, 1e-9)
        let coverageFactor = min(1, coverage / max(c.fullCoverageFraction, 1e-9))
        let dominance = winner.evidence / max(total, 1e-9)
        let stability = min(1, winner.longestFixation / max(c.stableFixationDuration.fusionSeconds, 1e-9))
        let confidence = min(1, max(0, meanConfidence * coverageFactor * dominance * stability))

        guard let target = winner.target else {
            return unbound(.unresolvedTarget, count: inWindowCount, point: winner.point, radius: winner.uncertainty)
        }
        guard confidence >= c.minBindingConfidence else {
            return unbound(.lowConfidence(confidence), count: inWindowCount, point: winner.point, radius: winner.uncertainty)
        }
        return ResolvedDeictic(match: match, binding: DeicticBinding(word: word, target: target, confidence: confidence),
                               outcome: .bound, point: winner.point, uncertaintyRadius: winner.uncertainty,
                               sampleCount: inWindowCount)
    }

    /// 발화 동안(첫 단어 전 dictationLead 포함) 가장 오래 응시한 편집 가능 요소.
    private func dictationTarget(in span: TimeSpan, _ snapshot: Snapshot) async -> (UITarget?, Duration?) {
        let c = configuration
        let margin = c.segmentationMargin
        let maxGap = c.maxSampleGap.fusionSeconds
        let raw = snapshot.samples.timeSlice(from: span.lower.receded(by: margin), through: span.upper.advanced(by: margin))
        let usable = FixationAnalyzer.timed(raw, maxGap: maxGap).filter { isUsable($0.sample, snapshot) }
        let minFixation = c.minFixationDuration.fusionSeconds
        let segments = FixationAnalyzer.segments(usable, radius: c.fixationRadius, maxGap: maxGap)
            .filter { $0.duration + 1e-9 >= minFixation }

        var dwell: [String: (target: UITarget, seconds: Double, last: MonotonicTime)] = [:]
        for segment in segments {
            let inside = segment.members.reduce(0.0) { span.contains($1.sample.time) ? $0 + $1.dt : $0 }
            guard inside > 0, let target = await resolveTarget(at: segment.centroid), target.isEditable,
                  c.allowSecureDictationTarget || !target.isSecure else { continue }
            if let existing = dwell[target.token] {
                dwell[target.token] = (target, existing.seconds + inside, max(existing.last, segment.lastTime))
            } else {
                dwell[target.token] = (target, inside, segment.lastTime)
            }
        }
        var best: (target: UITarget, seconds: Double, last: MonotonicTime)?
        for entry in dwell.values {
            guard let current = best else { best = entry; continue }
            if entry.seconds > current.seconds || (entry.seconds == current.seconds && entry.last > current.last) {
                best = entry
            }
        }
        guard let best, best.seconds + 1e-9 >= c.minDictationDwell.fusionSeconds else { return (nil, nil) }
        return (best.target, .seconds(best.seconds))
    }

    private func utteranceSpan(_ update: TranscriptUpdate, _ snapshot: Snapshot) -> TimeSpan {
        let c = configuration
        if let start = update.words.map(\.start).min(),
           let end = update.words.map({ max($0.start, $0.end) }).max() {
            return TimeSpan(lower: start.receded(by: c.dictationLead), upper: end.advanced(by: c.lag))
        }
        return TimeSpan(lower: snapshot.now.receded(by: c.untimedFallbackWindow), upper: snapshot.now)
    }

    private func isUsable(_ sample: GazeSample, _ snapshot: Snapshot) -> Bool {
        sample.confidence >= configuration.minSampleConfidence
            && sample.calibrationRevision == snapshot.calibrationRevision
    }

    // MARK: - UI 요소 캐시

    private func resolveTarget(at point: CGPoint) async -> UITarget? {
        let grid = max(configuration.targetCacheGrid, 0.5)
        let clampLimit = 1e9
        let key = PointKey(x: Int(min(max((Double(point.x) / grid).rounded(), -clampLimit), clampLimit)),
                           y: Int(min(max((Double(point.y) / grid).rounded(), -clampLimit), clampLimit)))
        let ttl = configuration.targetCacheTTL.fusionSeconds
        if let cached = targetCache[key], clock.now().seconds(since: cached.resolvedAt) <= ttl {
            counters.targetCacheHits += 1
            return cached.target
        }
        counters.resolverCalls += 1
        let target = await resolver.target(at: point)
        let now = clock.now()
        targetCache[key] = CachedTarget(target: target, resolvedAt: now)
        if targetCache.count > configuration.targetCacheCapacity {
            pruneTargetCache(now: now, ttl: ttl)
        }
        return target
    }

    private func pruneTargetCache(now: MonotonicTime, ttl: Double) {
        targetCache = targetCache.filter { now.seconds(since: $0.value.resolvedAt) <= ttl }
        let overflow = targetCache.count - max(1, configuration.targetCacheCapacity)
        guard overflow > 0 else { return }
        let oldest = targetCache.sorted { $0.value.resolvedAt < $1.value.resolvedAt }.prefix(overflow)
        for entry in oldest { targetCache[entry.key] = nil }
    }

    // MARK: - 정리

    private func store(_ result: FusionAnalysis, for key: AnalysisKey) {
        if analysisCache[key] == nil { analysisOrder.append(key) }
        analysisCache[key] = result
        let capacity = max(1, configuration.analysisCacheCapacity)
        while analysisOrder.count > capacity {
            analysisCache[analysisOrder.removeFirst()] = nil
        }
    }

    private func acceptsCue(at time: MonotonicTime, confidence: Double, now: MonotonicTime) -> Bool {
        guard confidence.isFinite,
              time >= now.receded(by: configuration.bufferWindow),
              time <= now.advanced(by: configuration.maxFutureSkew) else {
            counters.rejectedCues += 1
            return false
        }
        return true
    }

    private func evict(now: MonotonicTime) {
        let cutoff = now.receded(by: configuration.bufferWindow)
        gaze.removeOlder(than: cutoff)
        nonverbalCues.removeOlder(than: cutoff)
        paralinguisticCues.removeOlder(than: cutoff)
    }
}

extension Array where Element: Timestamped {
    /// 시각순 정렬 배열에서 [lower, upper] 구간을 이진 탐색으로 자른다.
    func timeSlice(from lower: MonotonicTime, through upper: MonotonicTime) -> [Element] {
        guard lower <= upper, !isEmpty else { return [] }
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if self[mid].time < lower { lo = mid + 1 } else { hi = mid }
        }
        var result: [Element] = []
        var i = lo
        while i < count, self[i].time <= upper {
            result.append(self[i])
            i += 1
        }
        return result
    }
}
