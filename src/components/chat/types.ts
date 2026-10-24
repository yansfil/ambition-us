// 채팅 모듈의 메시지·도구 모양. 서버 라우트(/api/chat)와 클라이언트가 함께 쓴다(타입만, 런타임 코드 없음).
import type { UIDataTypes, UIMessage } from 'ai';
import type { Product } from '@/catalog/types';

export interface PoinTurnMeta {
  markText: string;
  traceId: string;
}

export interface ChatMetadata {
  poin?: PoinTurnMeta;
}

export interface CatalogHit {
  id: string;
  name: string;
  price: number;
  category: string;
  tradeoff: string; // "분위기 최고 / 향 호불호"
  rating: number;
  features: string;
  reviews: string[];
}

export interface SearchCatalogOutput {
  count: number;
  items: CatalogHit[];
  note?: string;
}

export interface ShowProductsOutput {
  products: Product[];
  missing: string[];
  note?: string;
}

export type AddToCartOutput = { ok: true; product: Product } | { ok: false; error: string };

export type CheckoutOutput =
  | { ok: true; orderId: string; total: number; items: { id: string; name: string; price: number }[] }
  | { ok: false; error: string };

export type ChatTools = {
  search_catalog: {
    input: { query?: string; category?: string; maxPrice?: number };
    output: SearchCatalogOutput;
  };
  show_products: {
    input: { productIds: string[]; note?: string };
    output: ShowProductsOutput;
  };
  add_to_cart: {
    input: { productId: string };
    output: AddToCartOutput;
  };
  checkout: {
    input: Record<string, never>;
    output: CheckoutOutput;
  };
};

export type ChatUIMessage = UIMessage<ChatMetadata, UIDataTypes, ChatTools>;

/** 클라이언트 → 서버 요청 body (DefaultChatTransport가 messages와 합쳐 보냄) */
export interface ChatRequestBody {
  messages: ChatUIMessage[];
  cart?: string[];
}

export const POIN_PREFIX = '[poin 레이어 지시]';
