'use client';
// 세션 회고 (시안 06). sessionEnded일 때만 전체를 흐림 베일로 덮고 가운데 유리 모달을 띄운다.
import { useEffect, useRef, useState, type KeyboardEvent, type ReactNode } from 'react';
import { t } from '@/i18n';
import { usePoin } from '@/poin/store';
import type { Trace } from '@/poin/types';
import { exportSession } from './exportSession';
import { isAccepted, isDeclined, isLowConfidenceSkip, mmss, momentName, viaText } from './format';

const Z = 60;

export default function Retro() {
  const ended = usePoin((s) => s.sessionEnded);
  if (!ended) return null;
  return <RetroView />;
}

const Num = ({ children }: { children: ReactNode }) => (
  <em className="bg-[linear-gradient(90deg,#F58C02,#EEAECA)] bg-clip-text not-italic text-transparent">{children}</em>
);

function nodeKind(tr: Trace): 'ok' | 'no' | 'none' {
  if (isAccepted(tr)) return 'ok';
  if (isDeclined(tr)) return 'no';
  return 'none';
}

function RetroView() {
  const traces = usePoin((s) => s.traces);
  const startedAt = usePoin((s) => s.startedAt);
  const chipTimeoutMs = usePoin((s) => s.settings.chipTimeoutMs);
  const resetSession = usePoin((s) => s.resetSession);
  // 회고가 처음 뜬 시점을 세션 종료 시각으로 본다(스토어에 종료 시각 필드가 없다).
  const [endedAt] = useState(() => Date.now());
  const tr = t.panel.retro;

  const ordered = traces.slice().reverse();
  const n = traces.length;
  const accepted = traces.filter(isAccepted).length;
  const shown = traces.filter((x) => x.shown).length;
  const low = traces.filter(isLowConfidenceSkip).length;
  const other = traces.filter((x) => !x.shown && !isLowConfidenceSkip(x)).length;

  // 베일 뒤 채팅 입력창에 포커스가 남아 계속 타이핑되지 않도록 모달로 포커스를 옮기고 Tab을 가둔다.
  const dialogRef = useRef<HTMLDivElement>(null);
  const firstRef = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    (document.activeElement as HTMLElement | null)?.blur?.();
    firstRef.current?.focus();
  }, []);
  const trapTab = (e: KeyboardEvent<HTMLDivElement>) => {
    if (e.key !== 'Tab') return;
    const btns = dialogRef.current?.querySelectorAll<HTMLButtonElement>('button');
    if (!btns || btns.length === 0) return;
    const first = btns[0];
    const last = btns[btns.length - 1];
    if (e.shiftKey && document.activeElement === first) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && document.activeElement === last) {
      e.preventDefault();
      first.focus();
    }
  };

  const restart = () => {
    resetSession();
    location.reload();
  };

  return (
    <>
      <div
        data-poin-layer
        className="fixed inset-0 bg-[rgba(40,15,30,.18)] backdrop-blur-[14px]"
        style={{ zIndex: Z }}
        aria-hidden
      />
      <div
        data-poin-layer
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        onKeyDown={trapTab}
        className="poin-glass poin-pop fixed left-1/2 top-1/2 max-h-[calc(100dvh-32px)] w-[780px] max-w-[calc(100vw-32px)] -translate-x-1/2 -translate-y-1/2 overflow-y-auto rounded-[30px] px-9 pb-[30px] pt-[34px] shadow-[0_40px_80px_-30px_rgba(60,10,0,.6)]"
        style={{ zIndex: Z + 1, fontFeatureSettings: '"tnum"', transformOrigin: 'center' }}
      >
        <div className="flex items-center gap-[9px] text-[12.5px] text-[var(--on-dark-muted)]">
          <span className="poin-orb" />
          {tr.kicker(tr.duration(endedAt - startedAt))}
        </div>

        <h2 className="mb-1.5 mt-3.5 text-[32px] font-[650] leading-[1.3] tracking-[-.03em]">
          {n === 0 ? (
            tr.titleEmpty
          ) : (
            <>
              {tr.titleA}
              <Num>{tr.times(n)}</Num>
              {tr.titleB}
              <br />
              {tr.titleC}
              <Num>{tr.times(accepted)}</Num>
              {tr.titleD}
            </>
          )}
        </h2>
        <div className="text-[14px] text-[var(--on-dark-muted)]">
          {n === 0 ? tr.subEmpty : `${tr.sub(shown, low)}${other > 0 ? tr.subOther(other) : ''}`}
        </div>

        {n > 0 && (
          <>
            <div className="mb-2.5 mt-[30px] overflow-x-auto pb-1 [scrollbar-width:thin]">
              <div className="relative flex min-w-full gap-3.5">
                <span className="absolute left-1.5 right-1.5 top-1.5 h-px bg-white/[.14]" />
                {ordered.map((x) => (
                  <Node key={x.id} tr={x} at={mmss(x.moment.t - startedAt)} chipTimeoutMs={chipTimeoutMs} />
                ))}
              </div>
            </div>
            <div className="mt-1.5 flex gap-4 text-[11.5px] text-[var(--on-dark-muted)]">
              <span>{tr.legendAccept}</span>
              <span>{tr.legendDecline}</span>
              <span>{tr.legendNone}</span>
            </div>
          </>
        )}

        <div className="mt-[26px] flex gap-2.5">
          <button
            ref={firstRef}
            type="button"
            onClick={exportSession}
            className="rounded-full bg-[#F2F2F2] px-[18px] py-[11px] text-[14px] font-semibold text-[#1A1A1A] hover:bg-white"
          >
            {tr.export}
          </button>
          <button
            type="button"
            onClick={restart}
            className="rounded-full bg-white/[.08] px-[18px] py-[11px] text-[14px] font-semibold text-[var(--on-dark)] hover:bg-white/[.14]"
          >
            {tr.newSession}
          </button>
        </div>
      </div>
    </>
  );
}

function Node({ tr, at, chipTimeoutMs }: { tr: Trace; at: string; chipTimeoutMs: number }) {
  const r = t.panel.retro;
  const kind = nodeKind(tr);
  const desc = tr.shown ? (tr.infer?.intervention.prompt ?? '') : r.notShown;
  let result: string;
  if (tr.reaction) {
    result = viaText(tr, tr.reaction, chipTimeoutMs);
  } else if (tr.status === 'skipped') {
    result = tr.skipReason ?? r.notShown;
  } else if (tr.status === 'error') {
    result = tr.error ?? t.panel.traces.error;
  } else if (tr.status === 'inferring') {
    result = r.inferring;
  } else {
    result = r.noReaction;
  }

  const dot =
    kind === 'ok'
      ? 'bg-[radial-gradient(circle_at_35%_30%,#FFE2C4,#F58C02_45%,#F55702)] shadow-[0_0_12px_2px_rgba(245,110,2,.6)]'
      : kind === 'no'
        ? 'border-[1.5px] border-[#F5F5F5] bg-[#141416]'
        : 'border-[1.5px] border-white/30 bg-[#2A2A2E]';

  return (
    <div className="relative min-w-[150px] flex-1 basis-0 pt-[26px] text-[13px] leading-[1.55] text-[rgba(245,245,245,.86)]">
      <span className={`absolute left-0 top-0 h-[13px] w-[13px] rounded-full ${dot}`} />
      <div className="text-[11px] tabular-nums text-[var(--on-dark-muted)]">{at}</div>
      <div className="my-0.5 font-semibold text-[var(--on-dark)]">{momentName(tr)}</div>
      <div className="line-clamp-2">{desc}</div>
      {tr.outcome?.description && kind !== 'none' && (
        <div className="line-clamp-2 text-[12px] text-[var(--on-dark-muted)]">{tr.outcome.description}</div>
      )}
      <div className={`mt-0.5 text-[12px] ${kind === 'ok' ? 'text-[var(--poin-amber)]' : 'text-[var(--on-dark-muted)]'}`}>
        {result}
      </div>
    </div>
  );
}
