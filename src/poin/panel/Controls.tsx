'use client';
// 하단 컨트롤 (시안 .ctrl): 슬라이더 3개, 필터 알약, 쿨다운 초기화, 세션 끝내기.
import { useState } from 'react';
import { t } from '@/i18n';
import { usePoin } from '@/poin/store';
import type { PoinSettings } from '@/poin/types';
import { Pill } from './ui';

interface SliderProps {
  label: string;
  value: number;
  min: number;
  max: number;
  step: number;
  format: (v: number) => string;
  onCommit: (v: number) => void;
}

/** 시안 모양의 트랙 위에 투명한 네이티브 range를 겹친다. 드래그 중에는 로컬 값만 바꾸고 놓을 때 커밋한다. */
function Slider({ label, value, min, max, step, format, onCommit }: SliderProps) {
  const [draft, setDraft] = useState<number | null>(null);
  const v = draft ?? value;
  const p = ((v - min) / (max - min)) * 100;
  const commit = () => {
    if (draft !== null && draft !== value) onCommit(draft);
    setDraft(null);
  };
  return (
    <label className="grid grid-cols-[62px_1fr_36px] items-center gap-[9px] whitespace-nowrap">
      <span>{label}</span>
      <span className="relative block h-[13px]">
        <span className="absolute inset-x-0 top-[5px] h-[3px] rounded-full bg-white/[.12]">
          <span className="absolute inset-y-0 left-0 rounded-full bg-white/50" style={{ width: `${p}%` }} />
          <i
            className="pointer-events-none absolute -top-[5px] h-[13px] w-[13px] rounded-full bg-white shadow-[0_2px_6px_rgba(0,0,0,.4)]"
            style={{ left: `calc(${p}% - 6px)` }}
          />
        </span>
        <input
          type="range"
          min={min}
          max={max}
          step={step}
          value={v}
          aria-label={label}
          onChange={(e) => setDraft(Math.round(Number(e.target.value) * 100) / 100)}
          onPointerUp={commit}
          onKeyUp={commit}
          onBlur={commit}
          className="absolute inset-0 h-full w-full cursor-pointer opacity-0"
        />
      </span>
      <span className="text-right font-medium tabular-nums text-[var(--on-dark)]">{format(v)}</span>
    </label>
  );
}

const FILTER_KEYS = ['verbal', 'paraverbal', 'cursor', 'sense', 'system'] as const;

export default function Controls() {
  const settings = usePoin((s) => s.settings);
  const setSettings = usePoin((s) => s.setSettings);
  const resetCooldowns = usePoin((s) => s.resetCooldowns);
  const endSession = usePoin((s) => s.endSession);
  const tc = t.panel.ctrl;
  const sec = t.panel.gauge.sec;

  const toggleFilter = (k: (typeof FILTER_KEYS)[number]) => {
    const filters: PoinSettings['filters'] = { ...settings.filters, [k]: !settings.filters[k] };
    setSettings({ filters });
  };

  return (
    <div className="flex flex-col gap-[9px] border-t border-[var(--hair-dark)] px-4 pb-3.5 pt-3 text-[var(--on-dark-muted)]">
      <Slider
        label={tc.threshold}
        value={settings.threshold}
        min={0.3}
        max={0.9}
        step={0.05}
        format={(v) => v.toFixed(2)}
        onCommit={(threshold) => setSettings({ threshold })}
      />
      <Slider
        label={tc.dwell}
        value={settings.dwellMs}
        min={500}
        max={4000}
        step={100}
        format={sec}
        onCommit={(dwellMs) => setSettings({ dwellMs })}
      />
      <Slider
        label={tc.pause}
        value={settings.pauseMs}
        min={1000}
        max={10000}
        step={500}
        format={sec}
        onCommit={(pauseMs) => setSettings({ pauseMs })}
      />
      <div className="flex flex-wrap gap-[5px]">
        {FILTER_KEYS.map((k) => (
          <Pill key={k} on={settings.filters[k]} onClick={() => toggleFilter(k)}>
            {t.panel.filter[k]}
          </Pill>
        ))}
      </div>
      <div className="flex flex-wrap gap-[5px]">
        <Pill onClick={resetCooldowns}>{tc.resetCooldown}</Pill>
        <Pill onClick={endSession}>{tc.endSession}</Pill>
      </div>
    </div>
  );
}
