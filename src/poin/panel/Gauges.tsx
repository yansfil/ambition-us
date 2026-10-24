'use client';
// 실시간 계기판 (시안 01~05 상단 섹션). live를 100ms마다 샘플링한다.
import { t } from '@/i18n';
import { usePoin } from '@/poin/store';
import { targetFallback } from './format';
import { useLiveSample } from './useLiveSample';
import { GaugeRow, Section, TextRow } from './ui';

export default function Gauges() {
  const s = useLiveSample(100);
  const pauseMs = usePoin((st) => st.settings.pauseMs);
  const g = t.panel.gauge;
  const cursor = s.cursorTargetLabel ?? targetFallback(s.cursorTarget) ?? g.none;

  return (
    <Section>
      <GaugeRow label={g.typing} ratio={s.typingCpm / 300} value={g.cpm(Math.round(s.typingCpm))} />
      <GaugeRow label={g.pause} ratio={s.pauseMs / pauseMs} value={g.sec(s.pauseMs)} />
      {s.deleteBursts > 0 && <GaugeRow label={g.deleteBurst} ratio={s.deleteBursts / 5} value={g.times(s.deleteBursts)} />}
      {s.focusIdleMs > 0 && <GaugeRow label={g.focusIdle} ratio={s.focusIdleMs / 10_000} value={g.sec(s.focusIdleMs)} />}
      <TextRow label={g.cursor} value={cursor} />
      {s.dwellMs > 0 && <GaugeRow label={g.dwell} ratio={s.dwellMs / 10_000} value={g.sec(s.dwellMs)} />}
      {s.oscillations > 0 && <GaugeRow label={g.oscillation} ratio={s.oscillations / 6} value={g.times(s.oscillations)} />}
      {s.scrollReversals > 0 && <GaugeRow label={g.scrollReverse} ratio={s.scrollReversals / 5} value={g.times(s.scrollReversals)} />}
    </Section>
  );
}
