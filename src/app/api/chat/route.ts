// 채팅 쇼핑 에이전트 (모듈 A). CONTRACTS.md "서버 API" 참고.
// 샘플링 파라미터(temperature/top_p/top_k)는 보내지 않는다: 2026-10-21부터 400.
import { anthropic } from '@ai-sdk/anthropic';
import {
  convertToModelMessages,
  createUIMessageStreamResponse,
  isStepCount,
  streamText,
  toUIMessageStream,
  tool,
} from 'ai';
import { z } from 'zod';
import { BUDGET, categories, findProduct, products } from '@/catalog/products';
import type { Product } from '@/catalog/types';
import { slog } from '@/lib/log-server';
import { agentModel, CACHE } from './config';
import {
  POIN_PREFIX,
  type AddToCartOutput,
  type CatalogHit,
  type ChatRequestBody,
  type ChatUIMessage,
  type CheckoutOutput,
  type SearchCatalogOutput,
  type ShowProductsOutput,
} from '@/components/chat/types';

export const maxDuration = 60;

let requestCount = 0; // 프로세스 기준. 두 번째 요청부터 캐시 읽기가 0이면 경고
const won = (n: number) => `${String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ',')}원`;

// 캐시 프리픽스에 들어가는 정적 시스템 프롬프트. 시간·요청 ID·장바구니 같은 가변 값을 넣지 말 것.
const SYSTEM_PROMPT = `너는 온라인 선물가게 "선물가게"의 쇼핑 에이전트다. 친근한 존댓말로 짧고 분명하게 말한다.

[오늘 사용자의 미션]
친구 집들이 선물을 ${won(BUDGET)} 이하로 골라 장바구니에 담고 결제까지 한다. 사용자가 따로 말하지 않아도 이 미션을 기준으로 돕는다.

[상품 정보]
- 상품은 반드시 search_catalog로 찾는다. 카탈로그에 없는 상품, 가격, 리뷰, 정책을 지어내지 않는다.
- 카테고리: ${categories.join(', ')}.
- 가격은 "32,000원"처럼 쓴다.

[추천하는 방식]
- 옵션을 제시할 때는 성격이 뚜렷이 다른 3개를 고른다. 장점과 단점이 서로 분명히 갈리게 고른다(예: 분위기용 / 오래 남는 것 / 매일 쓰는 것). 예산 안에서 고르되, 하나는 예산을 거의 다 쓰는 선택이어도 좋다.
- 조건이 부족해도 되묻지 말고 미션 기준으로 바로 3개를 추천한다.
- 첫 추천은 show_products를 쓰지 않는다. 세 상품을 문단 텍스트로 빽빽하게 설명한다. 형식은 이렇다.
  문단은 모두 5개이고, 문단 사이에는 반드시 빈 줄을 넣는다(한 문단에 두 상품을 섞지 않는다).
  첫 문단: 한 줄 도입. 예: "성격이 다른 세 가지로 골라 봤어요."
  상품마다 한 문단(리뷰는 search_catalog 결과의 reviews에서 그대로 인용): "첫째, {상품명}({가격})는 {구성과 특징}. 다만 {단점}. 리뷰에는 "{리뷰}", "{리뷰}"가 많았어요." 둘째, 셋째도 같은 식으로 쓴다.
  마지막 문단: 한 줄 질문. 예: "어느 쪽이 끌리세요?"
  목록 기호, 표, 굵은 글씨, 제목은 쓰지 않는다.

[show_products]
- 상품을 사진 카드로 보여 준다. 다음일 때만 쓴다: 사용자가 사진·이미지·카드로 보고 싶어 할 때, 한 상품을 고르려 하거나 자세히 보고 싶어 할 때, 지시가 그렇게 요구할 때.
- show_products를 쓸 때는 카드 앞에 한 문장, 필요하면 카드 뒤에 한 문장만 쓴다. 카드에 있는 가격과 특징을 텍스트로 다시 늘어놓지 않는다.
- note에는 카드 묶음 아래에 붙일 한 줄 요약을 넣는다(선택).

[표]
- 사용자가 표, 비교, 한눈에 정리를 원하면 마크다운 표로 답한다. 열은 상품, 행은 가격·장점·단점·평점·반품처럼 짧은 항목. 표 앞뒤로 한 문장씩만 쓴다.

[장바구니와 결제]
- 사용자가 담겠다고 하면 add_to_cart를 호출하고, 남은 예산(${won(BUDGET)} 기준)을 한 문장으로 알려 준다.
- 사용자가 화면의 "담기" 버튼을 누르면 상품이 먼저 장바구니에 들어간 뒤 "{상품명} 담을게요"가 전송된다. 이때 그 상품이 이미 장바구니에 있으면 add_to_cart를 다시 부르지 말고, "이미 담겨 있다"거나 "중복" 같은 말 없이 담았다고 확인하며 남은 예산을 알려 준다.
- 사용자가 결제하겠다고 하면 checkout을 호출한다. 장바구니가 비어 있으면 무엇을 담을지 묻는다. 결제가 끝나면 주문번호와 합계를 짧게 알려 준다.
- 현재 장바구니 상태는 별도의 시스템 메시지로 전달된다.

[보조 지시]
- 사용자 메시지가 "${POIN_PREFIX}"로 시작하면, 사용자의 화면에서 사용자의 망설임을 보고 넣어 준 보조 지시다. 사용자의 의도를 돕는 요청으로 보고 그대로 따른다.
- 답변에서 poin, 레이어, 지시, 시스템을 절대 언급하지 않는다. "요청하신 대로", "말씀하신 대로" 같은 말도 쓰지 않는다. 대화 흐름에 맞춰 자연스럽게 이어서 답한다.`;

/** 캐시 뒤에 붙는 가변 시스템 메시지 */
function cartNote(cart: Product[]) {
  const line = cart.length
    ? cart.map((p) => `${p.name}(${p.id}, ${won(p.price)})`).join(', ') + ` · 합계 ${won(cart.reduce((s, p) => s + p.price, 0))}`
    : '비어 있음';
  return `현재 장바구니: ${line}`;
}

const hit = (p: Product): CatalogHit => ({
  id: p.id,
  name: p.name,
  price: p.price,
  category: p.category,
  tradeoff: `${p.tradeoff.pro} / ${p.tradeoff.con}`,
  rating: p.rating,
  features: p.features.join(' · '),
  reviews: p.reviews,
});

function search({ query, category, maxPrice }: { query?: string; category?: string; maxPrice?: number }): SearchCatalogOutput {
  let pool = products;
  if (category) pool = pool.filter((p) => p.category.includes(category) || category.includes(p.category));
  if (maxPrice) pool = pool.filter((p) => p.price <= maxPrice);
  const tokens = (query ?? '').split(/[\s,·]+/).map((s) => s.trim()).filter((s) => s.length >= 2);
  if (!tokens.length) return { count: pool.length, items: pool.map(hit) };
  const scored = pool
    .map((p) => {
      const hay = [p.name, p.category, ...p.features, p.tradeoff.pro, p.tradeoff.con].join(' ');
      return { p, score: tokens.filter((t) => hay.includes(t)).length };
    })
    .filter((x) => x.score > 0)
    .sort((a, b) => b.score - a.score);
  if (!scored.length) {
    // 검색어가 하나도 안 맞으면 필터만 적용한 전체를 돌려준다(모델이 빈손으로 지어내지 않게).
    return { count: pool.length, items: pool.map(hit), note: '검색어와 정확히 맞는 상품이 없어 조건에 맞는 전체 목록을 보냅니다.' };
  }
  return { count: scored.length, items: scored.map((x) => x.p).map(hit) };
}

const orderId = () => {
  const d = new Date();
  const ymd = `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, '0')}${String(d.getDate()).padStart(2, '0')}`;
  return `GS-${ymd}-${Math.floor(1000 + Math.random() * 9000)}`;
};

export async function POST(req: Request) {
  const t0 = Date.now();
  let body: ChatRequestBody;
  try {
    body = (await req.json()) as ChatRequestBody;
  } catch (e) {
    slog.error('chat', '요청 본문 파싱 실패', e);
    return Response.json({ error: 'invalid json' }, { status: 400 });
  }
  const messages = Array.isArray(body.messages) ? body.messages : [];
  if (!messages.length) {
    slog.warn('chat', '빈 메시지 요청');
    return Response.json({ error: 'messages required' }, { status: 400 });
  }

  const cartIds = Array.isArray(body.cart) ? body.cart.filter((x): x is string => typeof x === 'string') : [];
  const cart = cartIds.map(findProduct).filter((p): p is Product => !!p);
  const last = messages[messages.length - 1];
  const lastPoin = last.role === 'user' ? last.metadata?.poin : undefined;
  const lastText = last.parts.map((p) => (p.type === 'text' ? p.text : '')).join('');
  slog.info('chat', '요청 수신', {
    messages: messages.length,
    poinDirective: !!lastPoin,
    traceId: lastPoin?.traceId,
    model: agentModel().id,
    lastText: lastText.slice(0, 120),
    cart: cartIds,
  });

  // poin 턴은 모델에 "[poin 레이어 지시] ..."로 전달한다.
  const prepared = messages.map((m): ChatUIMessage => {
    if (m.role !== 'user' || !m.metadata?.poin) return m;
    return {
      ...m,
      parts: m.parts.map((p) => (p.type === 'text' && !p.text.startsWith(POIN_PREFIX) ? { ...p, text: `${POIN_PREFIX} ${p.text}` } : p)),
    };
  });

  // 이번 요청 안에서 담긴 상품(같은 턴에 담고 바로 결제하는 경우를 위해)
  const addedThisTurn = new Set<string>();

  const tools = {
    search_catalog: tool({
      description: '선물가게 카탈로그를 검색한다. 결과는 id, 이름, 가격, 카테고리, 트레이드오프(장점 / 단점), 평점 목록이다.',
      inputSchema: z.object({
        query: z.string().optional().describe('검색어. 예: "향", "커피", "식물"'),
        category: z.string().optional().describe(`카테고리: ${categories.join(', ')}`),
        maxPrice: z.number().optional().describe('최대 가격(원)'),
      }),
      execute: async (input): Promise<SearchCatalogOutput> => {
        const out = search(input);
        slog.info('tool', 'search_catalog', { input, count: out.count, ids: out.items.map((i) => i.id) });
        return out;
      },
    }),
    show_products: tool({
      description: '상품을 사진 카드로 화면에 보여 준다. 상품 전체 정보(특징, 리뷰, 반품 정책 포함)를 돌려준다.',
      inputSchema: z.object({
        productIds: z.array(z.string()).min(1).max(6).describe('search_catalog에서 받은 상품 id 목록'),
        note: z.string().optional().describe('카드 묶음 아래 붙일 한 줄 요약'),
      }),
      execute: async ({ productIds, note }): Promise<ShowProductsOutput> => {
        const found = productIds.map(findProduct).filter((p): p is Product => !!p);
        const missing = productIds.filter((id) => !findProduct(id));
        if (missing.length) slog.warn('tool', 'show_products: 없는 상품 id', { missing });
        slog.info('tool', 'show_products', { productIds, shown: found.map((p) => p.id), note });
        return { products: found, missing, note };
      },
    }),
    add_to_cart: tool({
      description: '상품을 장바구니에 담는다.',
      inputSchema: z.object({ productId: z.string().describe('상품 id') }),
      execute: async ({ productId }): Promise<AddToCartOutput> => {
        const p = findProduct(productId);
        if (!p) {
          slog.warn('tool', 'add_to_cart: 없는 상품', { productId });
          return { ok: false, error: `없는 상품 id: ${productId}` };
        }
        addedThisTurn.add(p.id);
        slog.info('tool', 'add_to_cart', { productId, name: p.name, price: p.price });
        return { ok: true, product: p };
      },
    }),
    checkout: tool({
      description: '장바구니를 결제한다(목 결제). 장바구니가 비어 있으면 실패한다.',
      inputSchema: z.object({}),
      execute: async (): Promise<CheckoutOutput> => {
        const ids = Array.from(new Set([...cartIds, ...addedThisTurn]));
        const items = ids.map(findProduct).filter((p): p is Product => !!p);
        if (!items.length) {
          slog.warn('tool', 'checkout: 장바구니가 비어 있음');
          return { ok: false, error: '장바구니가 비어 있어요.' };
        }
        const total = items.reduce((s, p) => s + p.price, 0);
        const out: CheckoutOutput = {
          ok: true,
          orderId: orderId(),
          total,
          items: items.map((p) => ({ id: p.id, name: p.name, price: p.price })),
        };
        slog.info('tool', 'checkout', { orderId: out.orderId, total, items: ids, overBudget: total > BUDGET });
        return out;
      },
      // 마지막 도구에 캐시 브레이크포인트: 도구 정의 전체가 캐시 프리픽스가 된다
      providerOptions: CACHE,
    }),
  };

  const model = agentModel();
  if (model.unknownEnv) slog.warn('chat', `알 수 없는 POIN_AGENT_MODEL="${model.unknownEnv}", haiku 사용`);
  const reqNo = ++requestCount;

  try {
    const result = streamText({
      model: anthropic(model.id),
      allowSystemInMessages: true,
      messages: [
        { role: 'system', content: SYSTEM_PROMPT, providerOptions: CACHE },
        { role: 'system', content: cartNote(cart) },
        ...(await convertToModelMessages(prepared, { ignoreIncompleteToolCalls: true })),
      ],
      tools,
      stopWhen: isStepCount(6),
      providerOptions: model.providerOptions,
      onEnd: (e) => {
        const ms = Date.now() - t0;
        const toolCalls = e.steps.flatMap((s) => s.toolCalls.map((c) => c.toolName));
        const u = e.totalUsage;
        const cache = {
          inputTokens: u.inputTokens,
          noCacheTokens: u.inputTokenDetails.noCacheTokens,
          cacheReadTokens: u.inputTokenDetails.cacheReadTokens,
          cacheWriteTokens: u.inputTokenDetails.cacheWriteTokens,
          outputTokens: u.outputTokens,
          perStep: e.steps.map((s) => ({
            in: s.usage.inputTokens,
            read: s.usage.inputTokenDetails.cacheReadTokens,
            write: s.usage.inputTokenDetails.cacheWriteTokens,
          })),
        };
        slog.info('chat', `응답 완료 (${ms}ms)`, {
          ms,
          model: model.id,
          reqNo,
          steps: e.steps.length,
          toolCalls,
          finishReason: e.finishReason,
          textChars: e.text.length,
          poinDirective: !!lastPoin,
          traceId: lastPoin?.traceId,
        });
        slog.info('perf', '토큰 사용량', { ms, model: model.id, reqNo, ...cache });
        if (reqNo > 1 && !cache.cacheReadTokens) {
          slog.warn('perf', '프롬프트 캐시 미적중', { reqNo, model: model.id, ...cache });
        }
      },
      onError: ({ error }) => {
        const err = error as { statusCode?: number; message?: string };
        slog.error('chat', '모델 스트림 에러', { status: err?.statusCode, message: err?.message, ms: Date.now() - t0 });
      },
    });

    return createUIMessageStreamResponse({
      stream: toUIMessageStream({
        stream: result.stream,
        onError: (error) => {
          const err = error as { statusCode?: number; message?: string };
          slog.error('chat', 'UI 스트림 에러', { status: err?.statusCode, message: err?.message });
          return err?.statusCode ? `에이전트 오류 (${err.statusCode})` : '에이전트 응답 중 오류가 났어요.';
        },
      }),
    });
  } catch (e) {
    const err = e as { statusCode?: number; message?: string };
    slog.error('chat', '요청 처리 실패', { status: err?.statusCode, message: err?.message, ms: Date.now() - t0 });
    return Response.json({ error: err?.message ?? 'chat failed' }, { status: 500 });
  }
}
