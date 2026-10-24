'use client';
// show_products 결과 카드 그리드. DOM 규약(CONTRACTS.md): product:/add: 타깃, data-poin-label, data-poin-price.
import type { Product } from '@/catalog/types';
import { BUDGET } from '@/catalog/products';
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
  return (
    <div
      data-poin-target={`product:${p.id}`}
      data-poin-label={t.chat.cardLabel(p.name)}
      className="group relative overflow-hidden rounded-[22px] border border-[var(--c-line2)] bg-white shadow-[0_1px_0_rgba(0,0,0,0.03),0_14px_30px_-18px_rgba(70,20,40,0.35)] transition-[transform,box-shadow] duration-200 hover:-translate-y-0.5 hover:shadow-[0_22px_40px_-18px_rgba(70,20,40,0.45)]"
    >
      <div
        className={cn('grid place-items-center', single ? 'h-[124px] text-[44px]' : 'h-[88px] text-[36px]')}
        style={{ background: `linear-gradient(160deg, ${p.tint[0]}, ${p.tint[1]})` }}
      >
        <span aria-hidden>{p.emoji}</span>
      </div>
      <div className="px-[14px] pb-[14px] pt-3">
        <div className="text-[14px] font-semibold tracking-[-0.01em]">{p.name}</div>
        <div className="mt-0.5 text-[14px] text-[var(--c-muted)]">
          <span data-poin-price>{t.chat.won(p.price)}</span>
          <span className="text-[12.5px]"> · {left >= 0 ? t.chat.budgetLeft(left) : t.chat.budgetOver(-left)}</span>
        </div>
        {single && <div className="mt-[7px] text-[12px] leading-[1.5] text-[var(--c-muted)]">{p.features.join(' · ')}</div>}
        <div className="mt-[7px] text-[12px] leading-[1.5] text-[var(--c-muted)]">
          {p.tradeoff.pro} · <em className="not-italic text-[var(--c-warn-text)]">{p.tradeoff.con}</em>
        </div>
        <div className="mt-[5px] truncate text-[12px] text-[var(--c-faint)]">
          {t.chat.rating(p.rating)} · “{p.reviews[0]}”{single ? ` · ${p.returnPolicy}` : ''}
        </div>
        <button
          type="button"
          data-poin-target={`add:${p.id}`}
          data-poin-label={t.chat.addLabel(p.name)}
          disabled={inCart}
          onClick={() => onAdd(p)}
          className={cn(
            'mt-[11px] w-full rounded-full py-2 text-[13px] font-semibold transition-colors',
            inCart ? 'cursor-default bg-[var(--c-soft)] text-[var(--c-faint)]' : 'bg-[var(--c-soft)] hover:bg-[var(--c-pill)] hover:text-white',
          )}
        >
          {inCart ? `${t.chat.added} ✓` : t.chat.add}
        </button>
      </div>
    </div>
  );
}
