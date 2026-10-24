'use client';
// 상단 컨트롤 알약 "장바구니 N" + 목록 팝오버 + 결제하기. props 없음.
import { useEffect, useRef, useState } from 'react';
import { BUDGET } from '@/catalog/products';
import { t } from '@/i18n';
import { log } from '@/lib/log';
import { usePoin } from '@/poin/store';
import { cartTotal, useCart } from './cartStore';

export default function CartPill() {
  const items = useCart((s) => s.items);
  const order = useCart((s) => s.order);
  const chatBusy = usePoin((s) => s.chatBusy);
  const [open, setOpen] = useState(false);
  const root = useRef<HTMLDivElement>(null);
  const total = cartTotal(items);
  const isOpen = open && items.length > 0;

  useEffect(() => {
    if (!isOpen) return;
    const onDown = (e: PointerEvent) => {
      if (root.current && !root.current.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setOpen(false);
    };
    document.addEventListener('pointerdown', onDown);
    document.addEventListener('keydown', onKey);
    return () => {
      document.removeEventListener('pointerdown', onDown);
      document.removeEventListener('keydown', onKey);
    };
  }, [isOpen]);

  const checkout = () => {
    const send = useCart.getState().sendBridge;
    setOpen(false);
    if (!send) {
      log.warn('chat', '결제 버튼: 채팅 전송 함수가 아직 없음');
      return;
    }
    log.info('chat', '결제 버튼 클릭', { items: items.map((p) => p.id), total });
    send(t.chat.checkoutMessage);
  };

  return (
    <div ref={root} className="relative">
      <button
        type="button"
        onClick={() => items.length && setOpen((v) => !v)}
        className="chat-glass flex h-[34px] items-center gap-2 rounded-full px-[13px] text-[13px] font-medium text-[var(--c-text)]"
      >
        {t.chat.cart}
        <b className="grid h-[18px] min-w-[18px] place-items-center rounded-full bg-[var(--c-pill)] px-1 text-[11px] font-semibold text-white">
          {items.length}
        </b>
      </button>
      {isOpen && (
        <div className="chat-glass absolute right-0 top-[42px] w-[280px] rounded-[20px] p-4 text-[13px] shadow-[0_22px_40px_-18px_rgba(70,20,40,0.45)]">
          <ul className="flex flex-col gap-2">
            {items.map((p) => (
              <li key={p.id} className="flex items-center gap-2">
                <span aria-hidden className="grid size-7 place-items-center rounded-[9px] text-[15px]" style={{ background: `linear-gradient(160deg, ${p.tint[0]}, ${p.tint[1]})` }}>
                  {p.emoji}
                </span>
                <span className="min-w-0 flex-1 truncate">{p.name}</span>
                <span className="text-[var(--c-muted)]">{t.chat.won(p.price)}</span>
                {!order && (
                  <button type="button" onClick={() => useCart.getState().remove(p.id)} className="text-[11.5px] text-[var(--c-faint)] hover:text-[var(--c-text)]">
                    {t.chat.cartRemove}
                  </button>
                )}
              </li>
            ))}
          </ul>
          <div className="mt-3 flex justify-between border-t border-[var(--c-line)] pt-3 font-semibold">
            <span>{t.chat.cartTotal}</span>
            <span>{t.chat.won(total)}</span>
          </div>
          <div className="mt-1 text-right text-[12px] text-[var(--c-muted)]">
            {total <= BUDGET ? t.chat.budgetLeft(BUDGET - total) : t.chat.budgetOver(total - BUDGET)}
          </div>
          {order ? (
            <div className="mt-3 rounded-full bg-[var(--c-soft)] py-2 text-center font-semibold text-[var(--c-muted)]">
              {t.chat.ordered} · {order.orderId}
            </div>
          ) : (
            <button
              type="button"
              data-poin-target="checkout"
              disabled={chatBusy}
              onClick={checkout}
              className="mt-3 w-full rounded-full bg-[var(--c-pill)] py-2 font-semibold text-white disabled:opacity-40"
            >
              {t.chat.checkout}
            </button>
          )}
        </div>
      )}
    </div>
  );
}
