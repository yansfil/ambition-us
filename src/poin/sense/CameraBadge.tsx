'use client';
// 감지 모드가 켜져 있는 동안 상시 노출되는 카메라 배지.
import { t } from '@/i18n';
import { usePoin } from '@/poin/store';

export default function CameraBadge() {
  const status = usePoin((s) => s.senseStatus);
  if (status !== 'on' && status !== 'starting') return null;
  const starting = status === 'starting';

  return (
    <div
      data-poin-layer
      role="status"
      aria-live="polite"
      className="poin-glass flex h-[34px] items-center gap-2 rounded-full px-[13px] text-[13px] font-medium"
    >
      <i
        aria-hidden
        className={`block h-[7px] w-[7px] flex-none rounded-full bg-[#FF453A] shadow-[0_0_0_3px_rgba(255,69,58,0.25)] ${starting ? 'animate-pulse opacity-70' : ''}`}
      />
      {starting ? t.sense.badgeStarting : t.sense.badgeOn}
      <span className="font-normal text-[var(--on-dark-muted)]">{t.sense.badgeNote}</span>
    </div>
  );
}
