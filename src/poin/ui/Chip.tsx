'use client';
// poin 칩: 순간이 오면 커서 오른쪽 아래(+16, +20)에서 커지고, 떠 있는 동안 커서를 따라다닌다.
// 반응은 단축키(⌥1 ⌥2 Esc)·감지 모드 제스처·무응답만. 칩은 pointer-events:none이라 아래 요소를 가리지 않는다.
import { useCallback, useMemo, useRef } from 'react';
import { t } from '@/i18n';
import { usePoin } from '../store';
import type { ActiveChip } from '../types';
import { useFollowCursor } from './follow';

const RADIUS = 20;
const ANCHOR_RADIUS = 6;

export default function Chip() {
  const chip = usePoin((s) => s.activeChip);
  if (!chip) return null;
  return <ChipView key={chip.traceId} chip={chip} />;
}

function ChipView({ chip }: { chip: ActiveChip }) {
  const outer = useRef<HTMLDivElement>(null);
  const inner = useRef<HTMLDivElement>(null);
  const senseOn = usePoin((s) => s.senseStatus === 'on');

  // 커서에 붙은 모서리만 덜 둥글게(뒤집히면 그 모서리로 옮긴다)
  const onFlip = useCallback((fx: boolean, fy: boolean) => {
    const el = inner.current;
    if (!el) return;
    const r = (on: boolean) => `${on ? ANCHOR_RADIUS : RADIUS}px`;
    el.style.borderRadius = `${r(!fx && !fy)} ${r(fx && !fy)} ${r(fx && fy)} ${r(!fx && fy)}`;
    el.style.transformOrigin = `${fy ? 'bottom' : 'top'} ${fx ? 'right' : 'left'}`;
  }, []);
  const follow = useMemo(() => ({ offsetX: 16, offsetY: 20, smoothing: 0.28, flip: true, onFlip }), [onFlip]);
  useFollowCursor(outer, follow);

  const opt1 = chip.options.find((o) => o.id === 'accept1');
  const opt2 = chip.options.find((o) => o.id === 'accept2');
  const multi = !!opt2;

  return (
    <div
      ref={outer}
      data-poin-layer
      role="status"
      aria-live="polite"
      className="pointer-events-none fixed left-0 top-0 z-[60]"
      style={{ opacity: 0, willChange: 'transform' }}
    >
      <style>{`@keyframes poin-chip-timer{from{transform:scaleX(1)}to{transform:scaleX(0)}}`}</style>
      <div
        ref={inner}
        className="poin-glass poin-pop overflow-hidden"
        style={{
          width: 340,
          borderRadius: `${ANCHOR_RADIUS}px ${RADIUS}px ${RADIUS}px ${RADIUS}px`,
          padding: '13px 15px 0',
          boxShadow: '0 26px 50px -16px rgba(90,25,0,.5)',
        }}
      >
        <div className="flex items-center gap-2 text-[12px]" style={{ color: 'var(--on-dark-muted)' }}>
          <span className="poin-orb" />
          <b className="font-semibold" style={{ color: 'var(--on-dark)' }}>{t.poin.brand}</b>
          <span className="truncate">{chip.evidenceLine}</span>
        </div>
        <div className="text-[16px] font-semibold" style={{ letterSpacing: '-0.015em', margin: '8px 0 11px', lineHeight: 1.38 }}>
          {chip.prompt}
        </div>
        <div
          className={`flex items-center text-[12px] ${multi ? 'flex-wrap' : ''}`}
          style={{ gap: 14, rowGap: multi ? 8 : undefined, paddingBottom: 12, color: 'var(--on-dark-muted)' }}
        >
          {opt1 && <Key k={t.poin.kbd.accept1} label={opt1.label} />}
          {opt2 && <Key k={t.poin.kbd.accept2} label={opt2.label} />}
          <Key k={t.poin.kbd.decline} label={t.poin.declineLabel[chip.momentType]} />
          {senseOn && (
            <span className="ml-auto whitespace-nowrap text-[11.5px]" style={{ color: 'var(--poin-amber)' }}>
              {t.poin.senseHint}
            </span>
          )}
        </div>
        <div style={{ height: 2, margin: '0 -15px', background: 'rgba(255,255,255,.08)' }}>
          <i
            className="poin-heat block h-full origin-left rounded-[2px]"
            style={{ animation: `poin-chip-timer ${chip.timeoutMs}ms linear forwards` }}
          />
        </div>
      </div>
    </div>
  );
}

function Key({ k, label }: { k: string; label: string }) {
  return (
    <span className="whitespace-nowrap">
      <kbd className="poin-kbd" style={{ fontFamily: 'inherit', marginRight: 5 }}>{k}</kbd>
      {label}
    </span>
  );
}
