import AgentContracts

// Fusion 모듈: 시선(GazeSample)과 음성(WordTiming)을 실제 시각 기준으로 결합한다.
//
// - `AttentionFuser`        : `AttentionFusing` 구현 actor. 링 버퍼, 지시어 결합(역할 포함), 받아쓰기 대상 선택,
//                             위치 있는 비언어 단서의 UI 요소 token 해석.
// - `DeicticLexicon`        : 한국어 지시어 사전(이거/이쪽/이 파일 …)과 조사 기반 역할(source/destination).
// - `FusionConfiguration`   : 선행(lead)/후행(lag) 창, 신뢰도 임계값, 캐시 크기 등.
// - `FixationAnalyzer`      : 응시(fixation) 구간 분할과 증거 가중치 계산(순수 함수).

// MARK: - 시간 계산 보조

extension Duration {
    /// 음수는 0으로 자른 나노초.
    var fusionNanoseconds: UInt64 {
        let c = components
        guard c.seconds >= 0 else { return 0 }
        let ns = Double(c.seconds) * 1e9 + Double(c.attoseconds) / 1e9
        guard ns > 0 else { return 0 }
        return UInt64(min(ns, Double(UInt64.max / 4)))
    }

    var fusionSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

extension MonotonicTime {
    func advanced(by duration: Duration) -> MonotonicTime {
        advanced(byNanoseconds: duration.fusionNanoseconds)
    }

    func receded(by duration: Duration) -> MonotonicTime {
        receded(byNanoseconds: duration.fusionNanoseconds)
    }

    func advanced(byNanoseconds delta: UInt64) -> MonotonicTime {
        let (sum, overflow) = nanoseconds.addingReportingOverflow(delta)
        return MonotonicTime(nanoseconds: overflow ? .max : sum)
    }

    func receded(byNanoseconds delta: UInt64) -> MonotonicTime {
        MonotonicTime(nanoseconds: nanoseconds >= delta ? nanoseconds - delta : 0)
    }

    /// `self - reference`를 부호 있는 초로 돌려준다.
    func seconds(since reference: MonotonicTime) -> Double {
        if nanoseconds >= reference.nanoseconds {
            return Double(nanoseconds - reference.nanoseconds) / 1e9
        }
        return -Double(reference.nanoseconds - nanoseconds) / 1e9
    }
}
