'use client';
// show_products 결과 카드 그리드. DOM 규약(CONTRACTS.md): product:/add: 타깃, data-poin-label, data-poin-price.
import type { Product } from '@/catalog/types';
import { BUDGET, discountPct, stockState } from '@/catalog/products';
import { t } from '@/i18n';
import { cn } from '@/lib/utils';
import { useCart } from './cartStore';

interface Props {
  products: Product[];
  note?: string;
  onAdd: (p: Product) => void;
}

export default function ProductCards({ products, note, onAdd }: Props) {
  const single = products.length === 1;
  const cols = single ? 'grid-cols-1 max-w-[300px]' : products.length === 2 ? 'grid-cols-2' : 'grid-cols-3';
  return (
    <div className="flex flex-col gap-2">
      <div className={cn('grid gap-3', cols)}>
        {products.map((p) => (
          <ProductCard key={p.id} p={p} single={single} onAdd={onAdd} />
        ))}
      </div>
      {note && <p className="text-[13px] text-[var(--c-muted)]">{note}</p>}
    </div>
  );
}

function ProductCard({ p, single, onAdd }: { p: Product; single: boolean; onAdd: (p: Product) => void }) {
  const inCart = useCart((s) => s.items.some((x) => x.id === p.id));
  const left = BUDGET - p.price;
  const stock = stockState(p);
  const soldOut = stock === 'out';
  const pct = discountPct(p);
  return (
    <div
      data-poin-target={`product:${p.id}`}
      data-poin-label={t.chat.cardLabel(p.name)}
      className="group relative overflow-hidden rounded-[22px] border border-[var(--c-line2)] bg-white shadow-[0_1px_0_rgba(0,0,0,0.03),0_14px_30px_-18px_rgba(70,20,40,0.35)] transition-[transform,box-shadow] duration-200 hover:-translate-y-0.5 hover:shadow-[0_22px_40px_-18px_rgba(70,20,40,0.45)]"
    >
      <div
        className={cn('relative grid place-items-center', single ? 'h-[124px] text-[44px]' : 'h-[88px] text-[36px]')}
        style={{ background: `linear-gradient(160deg, ${p.tint[0]}, ${p.tint[1]})` }}
      >
        <span aria-hidden className={cn(soldOut && 'opacity-40 grayscale')}>{p.emoji}</span>
        {(soldOut || stock === 'low') && (
          <span
            className={cn(
              'absolute left-[9px] top-[9px] rounded-full px-2 py-[3px] text-[10.5px] font-semibold',
              soldOut ? 'bg-[var(--c-pill)] text-white' : 'bg-white/90 text-[var(--c-warn-text)]',
            )}
          >
            {soldOut ? t.chat.soldOut : t.chat.stockLeft(p.stock)}
          </span>
        )}
        {pct > 0 && !soldOut && (
          <span className="absolute right-[9px] top-[9px] rounded-full bg-white/90 px-2 py-[3px] text-[10.5px] font-semibold text-[var(--c-warn-text)]">
            {t.chat.discount(pct)}
          </span>
        )}
      </div>
      <div className="px-[14px] pb-[14px] pt-3">
        <div className="text-[14px] font-semibold tracking-[-0.01em]">{p.name}</div>
        <div className="mt-0.5 text-[14px] text-[var(--c-muted)]">
          <span data-poin-price>{t.chat.won(p.price)}</span>
          {pct > 0 && <s className="ml-1 text-[12px] text-[var(--c-faint)]">{t.chat.won(p.listPrice!)}</s>}
          <span className="text-[12.5px]"> · {left >= 0 ? t.chat.budgetLeft(left) : t.chat.budgetOver(-left)}</span>
        </div>
        <div className={cn('mt-[3px] text-[12px]', p.shipDays >= 4 ? 'text-[var(--c-warn-text)]' : 'text-[var(--c-muted)]')}>
          {t.chat.arrival(p.shipDays)}
          {p.giftWrap && <span className="text-[var(--c-faint)]"> · {t.chat.giftWrap}</span>}
        </div>
        {single && <div className="mt-[7px] text-[12px] leading-[1.5] text-[var(--c-muted)]">{p.features.join(' · ')}</div>}
        <div className="mt-[7px] text-[12px] leading-[1.5] text-[var(--c-muted)]">
          {p.tradeoff.pro} · <em className="not-italic text-[var(--c-warn-text)]">{p.tradeoff.con}</em>
        </div>
        {p.options?.length ? <div className="mt-[3px] truncate text-[12px] text-[var(--c-muted)]">{t.chat.optionsLine(p.options)}</div> : null}
        <div className="mt-[5px] truncate text-[12px] text-[var(--c-faint)]">
          {t.chat.rating(p.rating)} · “{p.reviews[0]}”{single ? ` · ${p.returnPolicy}` : ''}
        </div>
        <button
          type="button"
          data-poin-target={`add:${p.id}`}
          data-poin-label={t.chat.addLabel(p.name)}
          disabled={inCart || soldOut}
          onClick={() => onAdd(p)}
          className={cn(
            'mt-[11px] w-full rounded-full py-2 text-[13px] font-semibold transition-colors',
            inCart || soldOut ? 'cursor-default bg-[var(--c-soft)] text-[var(--c-faint)]' : 'bg-[var(--c-soft)] hover:bg-[var(--c-pill)] hover:text-white',
          )}
        >
          {soldOut ? t.chat.soldOut : inCart ? `${t.chat.added} ✓` : t.chat.add}
        </button>
      </div>
    </div>
  );
}
