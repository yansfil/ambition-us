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
  stock: '품절' | '얼마 안 남음' | '여유';
  stockLeft?: number; // 얼마 안 남음일 때 남은 수량
  listPrice?: number;
  discountPct?: number;
  arrival: string; // "내일 도착" | "5일 뒤 도착"
  tags: string[];
  options?: string; // "향: 화이트 머스크 / 블랙체리 / 피오니"
  giftWrap?: boolean;
  similar?: string[];
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

export type AddToCartOutput =
  | { ok: true; product: Product; alreadyInCart?: boolean; option?: string }
  | { ok: false; error: string; reason?: 'not_found' | 'out_of_stock' | 'invalid_option'; product?: Product; alternatives?: CatalogHit[] };

export type CheckoutOutput =
  | {
      ok: true;
      orderId: string;
      total: number;
      budget: number;
      overBudget: boolean;
      overBy: number; // 초과액(원), 초과 아니면 0
      items: { id: string; name: string; price: number }[];
    }
  | { ok: false; error: string };

export type ChatTools = {
  search_catalog: {
    input: { query?: string; category?: string; maxPrice?: number; tag?: string; inStockOnly?: boolean };
    output: SearchCatalogOutput;
  };
  show_products: {
    input: { productIds: string[]; note?: string };
    output: ShowProductsOutput;
  };
  add_to_cart: {
    input: { productId: string; option?: string };
    output: AddToCartOutput;
  };
  checkout: {
    input: Record<string, never>;
    output: CheckoutOutput;
  };
};

export type ChatUIMessage = UIMessage<ChatMetadata, UIDataTypes, ChatTools>;


export const POIN_PREFIX = '[poin 레이어 지시]';
