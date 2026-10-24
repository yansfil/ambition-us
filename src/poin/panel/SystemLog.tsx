'use client';
// 시스템 로그: log.subscribe로 warn/error만 모아 개수 배지 + 펼치면 최근 20개.
import { useState, useSyncExternalStore } from 'react';
import { t } from '@/i18n';
import { log, type LogEntry } from '@/lib/log';
import { usePoin } from '@/poin/store';
import { mmss } from './format';
import { Label, Section } from './ui';

const KEEP = 200;
interface Snap { entries: LogEntry[]; total: number }
const EMPTY: Snap = { entries: [], total: 0 };
const isSys = (e: LogEntry) => e.level === 'warn' || e.level === 'error';

// 모듈 로드 시점부터 영구 구독해 패널이 접혀 있는 동안의 경고도 놓치지 않는다.
let cache: Snap = EMPTY;
const notify = new Set<() => void>();
if (typeof window !== 'undefined') {
  const initial = log.entries().filter(isSys).slice(-KEEP);
  cache = { entries: initial, total: initial.length };
  log.subscribe((e) => {
    if (!isSys(e)) return;
    cache = { entries: [...cache.entries.slice(-(KEEP - 1)), e], total: cache.total + 1 };
    notify.forEach((fn) => fn());
  });
}
const subscribe = (fn: () => void) => {
  notify.add(fn);
  return () => {
    notify.delete(fn);
  };
};
const getSnapshot = () => cache;
const getServerSnapshot = () => EMPTY;

export default function SystemLog() {
  const { entries, total: count } = useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot);
  const visible = usePoin((s) => s.settings.filters.system);
  const startedAt = usePoin((s) => s.startedAt);
  const [open, setOpen] = useState(false);
  const ts = t.panel.system;
  if (!visible) return null;

  const errors = entries.filter((e) => e.level === 'error').length;
  const recent = open ? entries.slice(-20).reverse() : [];

  return (
    <Section>
      <button type="button" onClick={() => setOpen((o) => !o)} className="text-left">
        <Label
          left={`${open ? '▾' : '▸'} ${ts.label}`}
          right={
            count > 0 ? (
              <span
                className={`rounded-full px-[7px] py-px text-[10px] font-bold ${
                  errors > 0 ? 'bg-[#ff453a] text-white' : 'poin-heat text-[#1A1A1A]'
                }`}
              >
                {ts.count(count)}
              </span>
            ) : (
              ts.count(0)
            )
          }
        />
      </button>
      {open && (
        <div className="flex max-h-[160px] flex-col gap-1 overflow-y-auto text-[10.5px] leading-[1.45] [scrollbar-width:thin]">
          {recent.length === 0 && <span className="text-[var(--on-dark-muted)]">{ts.empty}</span>}
          {recent.map((e, i) => (
            <div key={`${e.t}-${i}`} className="break-words" title={e.data !== undefined ? JSON.stringify(e.data) : undefined}>
              <span className="tabular-nums text-[var(--on-dark-muted)]">{mmss(e.t - startedAt)}</span>{' '}
              <span className={e.level === 'error' ? 'text-[#ff8a7a]' : 'text-[var(--poin-amber)]'}>{`${e.level}·${e.cat}`}</span>{' '}
              <span className="text-[rgba(245,245,245,.86)]">{e.msg}</span>
            </div>
          ))}
        </div>
      )}
    </Section>
  );
}
