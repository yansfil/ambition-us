// 스토어에 새로 들어온 신호만 콜백으로 넘긴다(링버퍼라 길이 비교 대신 마지막으로 본 id 기준).
import { usePoin } from '../store';
import type { Signal } from '../types';

export function onNewSignals(cb: (s: Signal) => void): () => void {
  let lastId: string | null = usePoin.getState().signals.at(-1)?.id ?? null;
  return usePoin.subscribe((st, prev) => {
    if (st.signals === prev.signals) return;
    const list = st.signals;
    let i = list.length - 1;
    while (i >= 0 && list[i].id !== lastId) i--;
    const fresh = list.slice(i + 1);
    lastId = list.at(-1)?.id ?? lastId;
    fresh.forEach(cb);
  });
}
