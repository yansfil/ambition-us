import AgentContracts
import Darwin

/// mach host time(틱) ↔ `MonotonicTime`(나노초) 변환.
///
/// `AVAudioTime.hostTime`, `CMClockGetHostTimeClock()`(AVCapture 프레임 PTS),
/// `DispatchTime.uptimeNanoseconds`가 모두 같은 `mach_absolute_time` 시계를 쓰므로
/// 이 변환 결과는 시선 파이프라인의 시각과 직접 비교할 수 있다.
public enum HostTime {
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        if info.denom == 0 { return (1, 1) }
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    public static func nanoseconds(fromHostTicks ticks: UInt64) -> UInt64 {
        let (numer, denom) = timebase
        if numer == denom { return ticks }
        let product = ticks.multipliedFullWidth(by: numer)
        guard product.high < denom else { return UInt64.max }
        return denom.dividingFullWidth(product).quotient
    }

    public static func hostTicks(fromNanoseconds nanoseconds: UInt64) -> UInt64 {
        let (numer, denom) = timebase
        if numer == denom { return nanoseconds }
        let product = nanoseconds.multipliedFullWidth(by: denom)
        guard product.high < numer else { return UInt64.max }
        return numer.dividingFullWidth(product).quotient
    }

    public static func now() -> MonotonicTime {
        MonotonicTime(nanoseconds: nanoseconds(fromHostTicks: mach_absolute_time()))
    }
}

/// `mach_absolute_time` 기반 공용 시계.
public struct HostTimeClock: MonotonicClock {
    public init() {}
    public func now() -> MonotonicTime { HostTime.now() }
}

extension MonotonicTime {
    /// 초 단위 오프셋을 더한다. 음수 결과는 0으로 자른다.
    func offset(bySeconds seconds: Double) -> MonotonicTime {
        let delta = (seconds * 1_000_000_000).rounded()
        if delta >= 0 {
            let (sum, overflow) = nanoseconds.addingReportingOverflow(UInt64(min(delta, Double(UInt64.max / 2))))
            return MonotonicTime(nanoseconds: overflow ? UInt64.max : sum)
        }
        let magnitude = UInt64(min(-delta, Double(UInt64.max / 2)))
        return MonotonicTime(nanoseconds: magnitude > nanoseconds ? 0 : nanoseconds - magnitude)
    }

    /// `self - other`(초). 음수가 될 수 있다.
    func seconds(since other: MonotonicTime) -> Double {
        if nanoseconds >= other.nanoseconds {
            return Double(nanoseconds - other.nanoseconds) / 1_000_000_000
        }
        return -Double(other.nanoseconds - nanoseconds) / 1_000_000_000
    }
}
