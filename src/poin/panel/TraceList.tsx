'use client';
// 순간 트레이스 (시안 02~05 본문). 최신이 위, 최신 1개는 펼친 카드, 나머지는 한 줄(클릭하면 펼침).
import { useState, type ReactNode } from 'react';
import { t } from '@/i18n';
import { usePoin } from '@/poin/store';
import type { PoinSettings, Trace } from '@/poin/types';
import { mmss, momentName, viaText } from './format';
import { useNow } from './useLiveSample';
import { Label } from './ui';

export default function TraceList() {
  const traces = usePoin((s) => s.traces);
  const startedAt = usePoin((s) => s.startedAt);
  const settings = usePoin((s) => s.settings);
  const shown = usePoin((s) => s.interventionsShown);
  const [open, setOpen] = useState<Record<string, boolean>>({});
  const tt = t.panel.traces;

  return (
    <div className="flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto border-t border-[var(--hair-dark)] px-3 pb-3 pt-2.5 [scrollbar-width:thin]">
      <div className="px-1">
        <Label left={tt.label} right={`${shown} / ${settings.maxInterventions}`} />
      </div>
      {traces.length === 0 && (
        <div className="px-1 pt-1 leading-[1.65] text-[var(--on-dark-muted)]">
          {tt.empty1}
          <br />
          {tt.empty2}
        </div>
      )}
      {traces.map((tr, i) => {
        const expanded = i === 0 || !!open[tr.id];
        const at = mmss(tr.moment.t - startedAt);
        return expanded ? (
          <TraceCard
            key={tr.id}
            tr={tr}
            at={at}
            settings={settings}
            onCollapse={i === 0 ? undefined : () => setOpen((o) => ({ ...o, [tr.id]: false }))}
          />
        ) : (
          <button
            key={tr.id}
            type="button"
            onClick={() => setOpen((o) => ({ ...o, [tr.id]: true }))}
            className="flex items-center justify-between gap-2 rounded-2xl bg-white/[.035] px-3 py-[9px] text-left text-[12px] font-medium text-[var(--on-dark-muted)] hover:bg-white/[.06]"
          >
            <span className="truncate">
              {momentName(tr)}
              {(tr.status === 'skipped' || tr.status === 'error') && ` · ${tt.notShown}`}
            </span>
            <span className="shrink-0 text-[11px] font-normal">{miniRight(tr, settings)}</span>
          </button>
        );
      })}
    </div>
  );
}

function miniRight(tr: Trace, settings: PoinSettings) {
  const tt = t.panel.traces;
  if (tr.reaction) return viaText(tr, tr.reaction, settings.chipTimeoutMs);
  if (tr.status === 'inferring') return tt.inferring;
  if (tr.status === 'error') return tt.error;
  if (tr.status === 'skipped') return tr.skipReason ?? tt.notShown;
  if (tr.status === 'shown') return tt.waiting;
  return '';
}

function Row({ k, children }: { k: string; children: ReactNode }) {
  return (
    <div className="grid grid-cols-[30px_1fr] gap-[7px] leading-[1.5]">
      <span className="text-[var(--on-dark-muted)]">{k}</span>
      <span className="min-w-0 break-words text-[rgba(245,245,245,.86)]">{children}</span>
    </div>
  );
}

const Em = ({ children }: { children: ReactNode }) => (
  <em className="font-semibold not-italic text-[var(--poin-amber)]">{children}</em>
);

function ConfBar({ value, threshold }: { value: number; threshold: number }) {
  return (
    <span className="relative ml-1.5 inline-block h-1 w-[54px] rounded-full bg-white/10 align-[1px]">
      <i className="poin-heat absolute inset-y-0 left-0 rounded-full" style={{ width: `${Math.round(Math.min(1, value) * 100)}%` }} />
      <b className="absolute -top-0.5 h-2 w-[1.5px] rounded-[1px] bg-white" style={{ left: `${Math.round(threshold * 100)}%` }} />
    </span>
  );
}

/** 표시 중 칩의 남은 시간. 매 250ms 다시 그리는 부분을 이 조각으로 가둔다. */
function Waiting({ traceId }: { traceId: string }) {
  const chip = usePoin((s) => (s.activeChip?.traceId === traceId ? s.activeChip : null));
  const now = useNow(250);
  const tt = t.panel.traces;
  if (!chip || now === 0) return <>{tt.waiting}</>;
  const left = Math.max(0, Math.ceil((chip.timeoutMs - (now - chip.shownAt)) / 1000));
  return <>{`${tt.waiting} · ${tt.remaining(left)}`}</>;
}

function filteredSummary(tr: Trace, filters: PoinSettings['filters']) {
  const { signalsSummary, signals } = tr.moment;
  // 요약 줄과 신호가 1:1로 맞을 때만 신호 종류로 거른다. 안 맞으면 그대로 보인다.
  if (signalsSummary.length !== signals.length) return signalsSummary;
  return signalsSummary.filter((_, i) => filters[signals[i].kind] !== false);
}

function TraceCard({ tr, at, settings, onCollapse }: { tr: Trace; at: string; settings: PoinSettings; onCollapse?: () => void }) {
  const tt = t.panel.traces;
  const summary = filteredSummary(tr, settings.filters);
  const inf = tr.infer;

  let intervene: ReactNode = null;
  if (tr.status === 'error') intervene = <span className="text-[#ff8a7a]">{`${tt.error} · ${tr.error ?? ''}`}</span>;
  else if (tr.shown) intervene = <><Em>{tt.shown}</Em>{` · ${tt.nearCursor}`}</>;
  else if (tr.status === 'skipped') intervene = `${tt.notShown} · ${tr.skipReason ?? ''}`;

  let reaction: ReactNode = null;
  if (tr.reaction) {
    reaction = <><Em>{viaText(tr, tr.reaction, settings.chipTimeoutMs)}</Em>{` · ${tt.after(tr.reaction.afterMs)}`}</>;
  } else if (tr.status === 'shown') {
    reaction = <Waiting traceId={tr.id} />;
  }

  return (
    <div className="flex flex-col gap-[7px] rounded-2xl bg-white/[.06] px-3 py-[11px]">
      <div
        className={`flex items-center justify-between text-[12px] font-semibold ${onCollapse ? 'cursor-pointer' : ''}`}
        onClick={onCollapse}
      >
        {momentName(tr)}
        <span className="text-[11px] font-normal tabular-nums text-[var(--on-dark-muted)]">{at}</span>
      </div>
      <Row k={tt.rowSignal}>{summary.length ? summary.join(' · ') : tt.noSignals}</Row>
      <Row k={tt.rowMoment}>{tr.moment.rule}</Row>
      <Row k={tt.rowInfer}>
        {tr.status === 'inferring' && !inf ? (
          <span className="animate-pulse text-[var(--on-dark-muted)]">{tt.inferring}</span>
        ) : inf ? (
          <>
            {inf.intentHypothesis}
            <br />
            <span className="tabular-nums">
              {tt.confidence} <Em>{inf.confidence.toFixed(2)}</Em>
              <ConfBar value={inf.confidence} threshold={settings.threshold} />
              {` · ${tt.ms(Math.round(inf.latencyMs))}`}
            </span>
          </>
        ) : (
          <span className="text-[var(--on-dark-muted)]">-</span>
        )}
      </Row>
      {intervene && <Row k={tt.rowIntervene}>{intervene}</Row>}
      {reaction && <Row k={tt.rowReaction}>{reaction}</Row>}
      {tr.outcome && (
        <Row k={tt.rowOutcome}>
          {tr.outcome.description}
          {tr.outcome.turnSummary && (
            <>
              <br />
              {`→ ${tr.outcome.turnSummary}`}
            </>
          )}
        </Row>
      )}
    </div>
  );
}
