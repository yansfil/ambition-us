'use client';
// 신호 스트림(접이식, 기본 접힘): 최근 신호 30개를 필터 적용해 시간순 한 줄씩.
import { useMemo, useState } from 'react';
import { t } from '@/i18n';
import { usePoin } from '@/poin/store';
import type { Signal } from '@/poin/types';
import { mmss } from './format';
import { Label, Section } from './ui';

function brief(data: Signal['data']) {
  const parts = Object.entries(data).map(([k, v]) => {
    const s = typeof v === 'string' ? `"${v}"` : typeof v === 'number' ? String(Math.round(v * 100) / 100) : JSON.stringify(v);
    return `${k}=${s}`;
  });
  const line = parts.join(' ');
  return line.length > 60 ? `${line.slice(0, 59)}…` : line;
}

export default function SignalStream() {
  const [open, setOpen] = useState(false);
  const signals = usePoin((s) => s.signals);
  const filters = usePoin((s) => s.settings.filters);
  const startedAt = usePoin((s) => s.startedAt);
  const ts = t.panel.stream;

  const recent = useMemo(() => {
    if (!open) return [];
    const out: Signal[] = [];
    for (let i = signals.length - 1; i >= 0 && out.length < 30; i--) {
      if (filters[signals[i].kind] !== false) out.push(signals[i]);
    }
    return out.reverse();
  }, [open, signals, filters]);

  return (
    <Section>
      <button type="button" onClick={() => setOpen((o) => !o)} className="text-left">
        <Label left={`${open ? '▾' : '▸'} ${ts.label}`} right={open ? ts.count(recent.length) : t.panel.toggleOpen} />
      </button>
      {open && (
        <div className="flex max-h-[160px] flex-col gap-0.5 overflow-y-auto font-mono text-[10.5px] leading-[1.45] text-[var(--on-dark-muted)] [scrollbar-width:thin]">
          {recent.length === 0 && <span>{ts.empty}</span>}
          {recent.map((s) => (
            <div key={s.id} className="truncate" title={JSON.stringify(s.data)}>
              <span className="tabular-nums">{mmss(s.t - startedAt)}</span>{' '}
              <span className="text-[var(--on-dark)]">{`${s.kind}.${s.type}`}</span> {brief(s.data)}
            </div>
          ))}
        </div>
      )}
    </Section>
  );
}
