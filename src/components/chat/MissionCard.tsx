'use client';
// 미션 카드(펼침) / 미션 알약(접힘). 둘 다 data-poin-target="mission".
import { t } from '@/i18n';
import { cn } from '@/lib/utils';
import { useCart } from './cartStore';

interface Props {
  expanded: boolean;
  onToggle: () => void;
  className?: string;
}

export default function MissionCard({ expanded, onToggle, className }: Props) {
  const order = useCart((s) => s.order);

  if (!expanded) {
    return (
      <button
        type="button"
        data-poin-target="mission"
        onClick={onToggle}
        className={cn('chat-glass flex items-center gap-2 self-center rounded-full px-[14px] py-[7px] text-[13px]', className)}
      >
        <b className="font-semibold">{order ? t.chat.missionDoneLabel : t.chat.missionPillLabel}</b>
        <span className="text-[var(--c-muted)]">
          {order ? `${order.items.map((i) => i.name).join(', ')} · ${t.chat.won(order.total)}` : t.chat.missionPillText}
        </span>
      </button>
    );
  }

  return (
    <div data-poin-target="mission" className={cn('chat-glass rounded-[22px] px-5 py-4 text-left', className)}>
      <div className="flex justify-between text-[12px] font-medium text-[var(--c-muted)]">
        <span>{t.chat.missionKicker}</span>
        <button type="button" onClick={onToggle} className="hover:text-[var(--c-text)]">
          {t.chat.missionCollapse}
        </button>
      </div>
      <div className="mt-[5px] text-[18px] font-[650] tracking-[-0.015em]">{t.chat.missionTitle}</div>
      <div className="mt-[5px] text-[13px] text-[var(--c-muted)]">{t.chat.missionSub}</div>
    </div>
  );
}
