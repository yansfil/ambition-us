// 패널·회고 공용 표시 도우미. 문구는 i18n에서만 가져온다.
import { t } from '@/i18n';
import type { InterventionOption, Reaction, Trace } from '@/poin/types';

export const momentName = (tr: Trace) => t.panel.moment[tr.moment.type] ?? tr.moment.type;

/** 세션 시작 기준 mm:ss */
export function mmss(ms: number) {
  const s = Math.max(0, Math.floor(ms / 1000));
  return `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;
}

function optionLabel(tr: Trace, id: InterventionOption['id']) {
  return tr.infer?.intervention.options.find((o) => o.id === id)?.label;
}

/** 반응 경로를 사람 말로 */
export function viaText(tr: Trace, r: Reaction, chipTimeoutMs: number) {
  const v = t.panel.via;
  switch (r.via) {
    case 'alt1': return v.alt1(optionLabel(tr, 'accept1'));
    case 'alt2': return v.alt2(optionLabel(tr, 'accept2'));
    case 'click1': return v.click1(optionLabel(tr, 'accept1'));
    case 'click2': return v.click2(optionLabel(tr, 'accept2'));
    case 'nod': return v.nod;
    case 'shake': return v.shake;
    case 'esc': return v.esc;
    case 'click_decline': return v.click_decline;
    case 'timeout': return v.timeout(Math.round(chipTimeoutMs / 1000));
    default: return String(r.via);
  }
}

export const isAccepted = (tr: Trace) => tr.reaction?.choice === 'accept1' || tr.reaction?.choice === 'accept2';
export const isDeclined = (tr: Trace) => tr.reaction?.choice === 'decline';

/** 확신도 미달로 건너뛴 순간 */
export const isLowConfidenceSkip = (tr: Trace) =>
  tr.status === 'skipped' && (!!tr.infer || (tr.skipReason ?? '').startsWith('확신도'));

/** data-poin-target 값을 사람이 읽는 이름으로 (B가 label을 못 줄 때의 대체) */
export function targetFallback(target: string | null) {
  if (!target) return null;
  const tg = t.panel.target;
  if (target === 'input') return tg.input;
  if (target === 'mission') return tg.mission;
  if (target === 'checkout') return tg.checkout;
  if (target.startsWith('para:')) {
    const i = Number(target.split(':')[2]);
    return Number.isFinite(i) ? tg.para(i) : tg.message;
  }
  if (target.startsWith('msg:')) return tg.message;
  return target;
}
