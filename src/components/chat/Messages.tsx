'use client';
// 메시지 한 개 렌더: 사용자 말풍선 / poin 표식 / 에이전트 본문(+도구 파트).
import { MessageResponse } from '@/components/ai-elements/message';
import type { Product } from '@/catalog/types';
import { t } from '@/i18n';
import { cn } from '@/lib/utils';
import PoinMark from './PoinMark';
import ProductCards from './ProductCards';
import type { ChatUIMessage } from './types';

type Part = ChatUIMessage['parts'][number];

interface Props {
  message: ChatUIMessage;
  streaming: boolean; // 이 메시지가 지금 스트리밍 중인지
  onAdd: (p: Product) => void;
}

export default function MessageView({ message, streaming, onAdd }: Props) {
  if (message.role === 'user') {
    const text = message.parts.map((p) => (p.type === 'text' ? p.text : '')).join('');
    const poinMeta = message.metadata?.poin;
    if (poinMeta) return <PoinMark text={poinMeta.markText} hint={t.chat.poinMarkHint} />;
    return (
      <div className="max-w-[580px] self-end whitespace-pre-wrap rounded-[20px_20px_6px_20px] bg-[var(--c-pill)] px-4 py-[10px] text-[15px] leading-[1.62] tracking-[-0.005em] text-white">
        {text}
      </div>
    );
  }
  if (message.role !== 'assistant') return null;

  return (
    <div data-poin-target={`msg:${message.id}`} className="flex flex-col gap-3">
      {message.parts.map((part, i) => (
        <PartView key={partKey(part, i)} part={part} streaming={streaming} onAdd={onAdd} />
      ))}
    </div>
  );
}

const partKey = (part: Part, i: number) => ('toolCallId' in part ? part.toolCallId : `${part.type}-${i}`);

function PartView({ part, streaming, onAdd }: { part: Part; streaming: boolean; onAdd: (p: Product) => void }) {
  switch (part.type) {
    case 'text':
      if (!part.text.trim()) return null;
      return (
        <MessageResponse className="chat-md" controls={false} isAnimating={streaming && part.state === 'streaming'}>
          {part.text}
        </MessageResponse>
      );

    case 'tool-search_catalog':
      if (part.state === 'output-available') return <StatusLine text={t.chat.searched(part.output.count)} />;
      if (part.state === 'output-error') return <StatusLine text={t.chat.toolFailed} tone="error" />;
      return <StatusLine text={t.chat.searching} busy />;

    case 'tool-show_products':
      if (part.state === 'output-available') {
        if (!part.output.products.length) return null;
        return <ProductCards products={part.output.products} note={part.output.note} onAdd={onAdd} />;
      }
      if (part.state === 'output-error') return <StatusLine text={t.chat.toolFailed} tone="error" />;
      return <StatusLine text={t.chat.preparingCards} busy />;

    case 'tool-add_to_cart':
      if (part.state === 'output-available') {
        return part.output.ok ? (
          <StatusLine text={t.chat.addedToCart(part.output.product.name)} tone="ok" />
        ) : (
          <StatusLine text={part.output.error} tone="error" />
        );
      }
      if (part.state === 'output-error') return <StatusLine text={t.chat.toolFailed} tone="error" />;
      return <StatusLine text={t.chat.addingToCart} busy />;

    case 'tool-checkout':
      if (part.state === 'output-available') {
        const o = part.output;
        if (!o.ok) return <StatusLine text={`${t.chat.orderFailed} · ${o.error}`} tone="error" />;
        return (
          <div className="max-w-[360px] rounded-[22px] border border-[var(--c-line2)] bg-white px-5 py-4 shadow-[0_14px_30px_-18px_rgba(70,20,40,0.35)]">
            <div className="flex items-center gap-2 text-[15px] font-semibold">
              <span className="grid size-5 place-items-center rounded-full bg-[var(--c-pill)] text-[11px] text-white">✓</span>
              {t.chat.orderDoneTitle}
            </div>
            <div className="mt-1 text-[12px] text-[var(--c-faint)]">{t.chat.orderNo(o.orderId)}</div>
            <ul className="mt-3 flex flex-col gap-1 text-[13.5px]">
              {o.items.map((it) => (
                <li key={it.id} className="flex justify-between gap-4">
                  <span>{it.name}</span>
                  <span className="text-[var(--c-muted)]">{t.chat.won(it.price)}</span>
                </li>
              ))}
            </ul>
            <div className="mt-3 flex justify-between border-t border-[var(--c-line2)] pt-3 text-[14px] font-semibold">
              <span>{t.chat.orderTotal}</span>
              <span>{t.chat.won(o.total)}</span>
            </div>
            {o.overBudget && <div className="mt-1 text-right text-[12px] text-[var(--c-warn-text)]">{t.chat.budgetOver(o.overBy)}</div>}
          </div>
        );
      }
      if (part.state === 'output-error') return <StatusLine text={t.chat.toolFailed} tone="error" />;
      return <StatusLine text={t.chat.checkingOut} busy />;

    default:
      return null;
  }
}

export function StatusLine({ text, busy, tone }: { text: string; busy?: boolean; tone?: 'ok' | 'error' }) {
  return (
    <div
      className={cn(
        'flex items-center gap-2 text-[12.5px]',
        tone === 'error' ? 'text-[var(--c-warn-text)]' : tone === 'ok' ? 'text-[var(--c-muted)]' : 'text-[var(--c-faint)]',
      )}
    >
      {busy ? <Dots /> : tone === 'ok' ? <span aria-hidden>✓</span> : tone === 'error' ? <span aria-hidden>!</span> : <span aria-hidden>·</span>}
      <span>{text}</span>
    </div>
  );
}

export function Dots() {
  return (
    <span className="inline-flex items-center gap-[3px]" aria-hidden>
      {[0, 150, 300].map((d) => (
        <span key={d} className="chat-dot size-[5px] rounded-full bg-current" style={{ animationDelay: `${d}ms` }} />
      ))}
    </span>
  );
}
