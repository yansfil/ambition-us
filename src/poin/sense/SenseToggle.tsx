'use client';
// 상단 컨트롤의 "감지 모드" 토글. 명시적 opt-in: 누르기 전에는 카메라를 건드리지 않는다.
import { t } from '@/i18n';
import { usePoin } from '@/poin/store';

export default function SenseToggle() {
  const enabled = usePoin((s) => s.senseEnabled);
  const status = usePoin((s) => s.senseStatus);
  const setSense = usePoin((s) => s.setSense);

  const on = enabled && status !== 'denied' && status !== 'error';
  const hint =
    status === 'denied' ? `${t.sense.deniedHint}. ${t.sense.deniedHow}`
    : status === 'error' ? `${t.sense.errorHint}. ${t.sense.errorHow}`
    : status === 'starting' ? t.sense.toggleStarting
    : undefined;
  const problem = status === 'denied' || status === 'error';

  return (
    <div className="group relative" data-poin-layer>
      <button
        type="button"
        role="switch"
        aria-checked={on}
        aria-label={t.sense.toggleLabel}
        aria-describedby={problem ? 'poin-sense-hint' : undefined}
        title={hint}
        onClick={() => setSense({ enabled: !enabled })}
        className="chat-glass flex h-[34px] cursor-pointer items-center gap-2 rounded-full px-[13px] text-[13px] font-medium text-[var(--c-text)] outline-none focus-visible:ring-2 focus-visible:ring-[var(--c-pill)]/30"
      >
        <span
          aria-hidden
          className={`relative h-4 w-[26px] flex-none rounded-full transition-colors ${on ? 'bg-[var(--c-pill)]' : 'bg-[rgba(24,24,27,0.18)]'}`}
        >
          <span
            className={`absolute top-[2px] h-3 w-3 rounded-full bg-white shadow-[0_1px_2px_rgba(0,0,0,0.2)] transition-[left] duration-200 ${on ? 'left-[12px]' : 'left-[2px]'}`}
          />
        </span>
        {status === 'starting' && (
          <span aria-hidden className="h-[5px] w-[5px] flex-none animate-pulse rounded-full bg-[var(--poin-amber)]" />
        )}
        {problem && <span aria-hidden className="h-[5px] w-[5px] flex-none rounded-full bg-[var(--c-warn-text)]" />}
        {t.sense.toggleLabel}
      </button>
      {problem && (
        <div
          id="poin-sense-hint"
          role="tooltip"
          className="pointer-events-none absolute right-0 top-[40px] w-max max-w-[240px] rounded-xl border border-[var(--c-line)] bg-white px-3 py-2 text-[12px] leading-snug text-[var(--c-warn-text)] opacity-0 shadow-sm transition-opacity group-hover:opacity-100 group-focus-within:opacity-100"
        >
          {hint}
        </div>
      )}
    </div>
  );
}
