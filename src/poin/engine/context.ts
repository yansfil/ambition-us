// 화면(DOM)에서 순간 감지와 추론에 필요한 맥락을 뽑는다.
import type { MultiProductInfo } from '../moments/detector';

const PRICE_RE = /\d{1,3}(?:,\d{3})+\s*원|\d+\s*만\s*원/g;
const HAS_PRICE = /\d{1,3}(?:,\d{3})+\s*원|\d+\s*만\s*원/;
const squash = (s: string) => s.replace(/\s+/g, ' ').trim();

function lastMessage(): HTMLElement | null {
  const msgs = document.querySelectorAll<HTMLElement>('[data-poin-target^="msg:"]');
  return msgs.length ? msgs[msgs.length - 1] : null;
}

const productId = (el: Element) => (el.getAttribute('data-poin-target') ?? '').slice('product:'.length);

/** 최근 에이전트 응답이 상품 여럿(카드 2개 이상 또는 가격 2개 이상)을 다루는지 */
export function multiProductInfo(): MultiProductInfo {
  const anyProductsShown = !!document.querySelector('[data-poin-target^="product:"]');
  const msg = lastMessage();
  if (!msg) return { messageId: null, productIds: [], multi: false, anyProductsShown };
  const messageId = (msg.getAttribute('data-poin-target') ?? '').slice('msg:'.length);
  const ids = [...new Set(Array.from(msg.querySelectorAll('[data-poin-target^="product:"]')).map(productId))];
  const prices = new Set(squash(msg.innerText || msg.textContent || '').match(PRICE_RE) ?? []);
  return { messageId, productIds: ids, multi: ids.length >= 2 || prices.size >= 2, anyProductsShown };
}

/** 화면에 있는 상품 요약 한 줄들(LLM 입력용) */
export function productContext(): string[] {
  const out: string[] = [];
  const seen = new Set<string>();
  const cards = Array.from(document.querySelectorAll<HTMLElement>('[data-poin-target^="product:"]')).reverse();
  for (const c of cards) {
    const id = productId(c);
    if (seen.has(id)) continue;
    seen.add(id);
    const label = (c.getAttribute('data-poin-label') ?? '').replace(/^.*?·\s*/, '') || id;
    const price = squash(c.querySelector('[data-poin-price]')?.textContent ?? '');
    const body = squash(c.innerText || c.textContent || '').slice(0, 120);
    out.push(`[${id}] ${label}${price ? ` ${price}` : ''} | ${body}`);
    if (out.length >= 6) break;
  }
  if (out.length) return out.reverse();
  const msg = lastMessage();
  if (!msg) return [];
  return Array.from(msg.querySelectorAll('p, li, tr'))
    .map((p) => squash(p.textContent ?? ''))
    .filter((s) => HAS_PRICE.test(s))
    .slice(0, 4)
    .map((s) => s.slice(0, 160));
}
