// 패널 공용 작은 조각들 (시안 v4의 .sec / .g / .lbl / .pill)
import type { ReactNode } from 'react';

export const Section = ({ children, className = '' }: { children: ReactNode; className?: string }) => (
  <div className={`flex flex-col gap-2 border-t border-[var(--hair-dark)] px-4 py-2.5 ${className}`}>{children}</div>
);

export const Label = ({ left, right }: { left: ReactNode; right?: ReactNode }) => (
  <div className="flex justify-between text-[10.5px] font-medium text-[var(--on-dark-muted)]">
    <span>{left}</span>
    {right !== undefined && <span className="tabular-nums">{right}</span>}
  </div>
);

export function GaugeRow({ label, ratio, value }: { label: string; ratio: number; value: string }) {
  const pct = Math.max(0, Math.min(1, Number.isFinite(ratio) ? ratio : 0)) * 100;
  return (
    <div className="grid grid-cols-[62px_1fr_56px] items-center gap-[9px] whitespace-nowrap text-[var(--on-dark-muted)]">
      <span className="overflow-hidden text-ellipsis">{label}</span>
      <div className="h-1 overflow-hidden rounded-full bg-white/[.08]">
        <i className="poin-heat block h-full rounded-full transition-[width] duration-100" style={{ width: `${pct}%` }} />
      </div>
      <span className="text-right font-medium tabular-nums text-[var(--on-dark)]">{value}</span>
    </div>
  );
}

export function TextRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="grid grid-cols-[62px_1fr] items-center gap-[9px] whitespace-nowrap text-[var(--on-dark-muted)]">
      <span>{label}</span>
      <span className="overflow-hidden text-ellipsis font-medium text-[var(--on-dark)]">{value}</span>
    </div>
  );
}

export function Pill({ on, onClick, children, title }: { on?: boolean; onClick?: () => void; children: ReactNode; title?: string }) {
  return (
    <button
      type="button"
      title={title}
      onClick={onClick}
      aria-pressed={on}
      className={`rounded-full px-[9px] py-[3px] text-[11px] transition-colors ${
        on ? 'bg-[rgba(245,140,2,.18)] text-[var(--poin-amber)]' : 'bg-white/[.06] text-[var(--on-dark-muted)] hover:bg-white/[.1]'
      }`}
    >
      {children}
    </button>
  );
}

export function ToolButton({ onClick, children, title }: { onClick: () => void; children: ReactNode; title?: string }) {
  return (
    <button
      type="button"
      title={title}
      onClick={onClick}
      className="text-[11px] text-[var(--on-dark-muted)] transition-colors hover:text-[var(--on-dark)]"
    >
      {children}
    </button>
  );
}
