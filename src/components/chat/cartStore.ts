'use client';
// 채팅 모듈 전용 카트. 상품은 id 기준 한 개씩만 담긴다(선물 데모라 수량 없음, 중복 담기는 무시).
import { create } from 'zustand';
import type { Product } from '@/catalog/types';
import { log } from '@/lib/log';

export interface PlacedOrder {
  orderId: string;
  total: number;
  items: { id: string; name: string; price: number }[];
}

interface CartState {
  items: Product[];
  order: PlacedOrder | null;
  /** ChatApp이 등록하는 전송 함수. CartPill처럼 채팅 밖 컴포넌트가 채팅으로 말을 보낼 때 쓴다. */
  sendBridge: ((text: string) => void) | null;
  add: (p: Product, via: 'card' | 'tool') => boolean;
  remove: (id: string) => void;
  placeOrder: (o: PlacedOrder) => void;
  reset: () => void;
  setSendBridge: (fn: ((text: string) => void) | null) => void;
}

export const useCart = create<CartState>((set, get) => ({
  items: [],
  order: null,
  sendBridge: null,
  add: (p, via) => {
    if (get().items.some((x) => x.id === p.id)) {
      log.debug('chat', '카트: 이미 담긴 상품', { id: p.id, via });
      return false;
    }
    const items = [...get().items, p];
    set({ items });
    log.info('chat', '카트 담기', { id: p.id, name: p.name, price: p.price, via, count: items.length, total: items.reduce((s, x) => s + x.price, 0) });
    return true;
  },
  remove: (id) => {
    const items = get().items.filter((x) => x.id !== id);
    set({ items });
    log.info('chat', '카트 빼기', { id, count: items.length });
  },
  placeOrder: (o) => {
    set({ order: o });
    log.info('chat', '결제 완료', o);
  },
  reset: () => set({ items: [], order: null }),
  setSendBridge: (fn) => set({ sendBridge: fn }),
}));

export const cartTotal = (items: Product[]) => items.reduce((s, p) => s + p.price, 0);
