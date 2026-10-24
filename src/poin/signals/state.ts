// 신호 수집기 내부 상태 중 순간 감지가 읽어야 하는 것. 신호(사건)가 아니라 "지금 상태"라 스토어 밖에 둔다.
import type { DraftState, NearDecision } from '../moments/detector';

export interface CollectorState {
  draft: DraftState;
  nearDecision: NearDecision | null;
  lastDecisionClickAt: number;
}

export const collector: CollectorState = {
  draft: { focused: false, text: '', focusAt: 0, lastInputAt: 0, bursts: 0 },
  nearDecision: null,
  lastDecisionClickAt: 0,
};

/** 입력창 요소 찾기 */
export const inputEl = (): HTMLTextAreaElement | HTMLInputElement | null =>
  document.querySelector<HTMLTextAreaElement | HTMLInputElement>('[data-poin-target="input"]');

export const isInputEl = (el: EventTarget | null): el is HTMLTextAreaElement | HTMLInputElement =>
  el instanceof HTMLElement && el.matches('[data-poin-target="input"]');
