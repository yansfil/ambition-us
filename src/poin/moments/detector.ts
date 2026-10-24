// 순간 감지 룰. 순수 함수만 둔다: DOM·스토어·별칭 import 없음.
// `node scripts/test-detector.ts`로 바로 실행되도록 런타임 import가 하나도 없어야 한다(type import만 허용).
// 여기 문자열(rule, signalsSummary)은 패널 표시와 LLM 입력을 겸하는 관찰 기록이라 i18n 대상에서 뺐다.
import type { ChatTurn, MomentType, Signal } from '../types';

export const RULE_DEBOUNCE_MS = 10_000;
/** 진행도가 이 값 이상이면 엔진이 추론을 미리 호출한다(prefetch) */
export const PREFETCH_PROGRESS = 0.6;
const COMPARISON_WINDOW_MS = 15_000;
const OSCILLATION_WINDOW_MS = 10_000;
const DECISION_WINDOW_MS = 3_000;
const BROW_MIN = 0.45;

/** 입력창 초안 상태(신호 수집기가 유지). 시간 기반 룰(정지)은 신호가 아니라 이 상태로 판단한다. */
export interface DraftState {
  focused: boolean;
  text: string;
  focusAt: number; // 마지막 포커스 시각, 0이면 없음
  lastInputAt: number; // 마지막 입력 시각, 0이면 없음
  bursts: number; // 현재 초안의 삭제 버스트 수
}

/** 결정 버튼(담기/결제) 근처 상태 */
export interface NearDecision {
  target: string;
  label: string;
  since: number;
}

/** 최근 에이전트 응답이 상품 여럿을 다루는지(런타임이 DOM에서 계산) */
export interface MultiProductInfo {
  messageId: string | null;
  productIds: string[];
  multi: boolean;
  /** 화면 어디든 상품 카드가 이미 있는지(에이전트가 추천을 시작했는지) */
  anyProductsShown?: boolean;
}

export interface DetectInput {
  now: number;
  signals: Signal[];
  chatContext: ChatTurn[];
  settings: { pauseMs: number; dwellMs: number };
  draft: DraftState;
  nearDecision: NearDecision | null;
  lastDecisionClickAt: number;
  multiProduct: MultiProductInfo;
  /** 룰별 마지막 발화 시각. 디바운스와 "같은 근거 재사용 금지"에 쓴다 */
  lastFired: Partial<Record<MomentType, number>>;
}

export interface RuleHit {
  type: MomentType;
  score: number; // 0..1, 룰 내부 강도(추론 확신도와 별개)
  rule: string;
  signalsSummary: string[];
  signals: Signal[];
  context?: { productIds?: string[]; messageId?: string };
}

/** 룰을 통과하진 못했지만 근거가 일부 모인 상태. 디버그 로그와 prefetch 요청에 쓴다 */
export interface RulePartial {
  type: MomentType;
  progress: number; // 0..1
  have: string[];
  need: string;
  rule: string; // 지금 가장 가까운 룰 변형
  signalsSummary: string[]; // 지금까지 모인 근거(prefetch 요청용)
}

export interface RuleEval {
  type: MomentType;
  progress: number; // 0..1, 통과하면 1
  hit?: RuleHit;
  partial?: RulePartial;
}

export interface DetectOutput {
  hits: RuleHit[];
  partials: RulePartial[];
  progress: Record<MomentType, number>;
}

const sec = (ms: number) => `${(ms / 1000).toFixed(1)}초`;
const clamp01 = (n: number) => Math.max(0, Math.min(1, n));
const isAnswerTarget = (t: unknown) => typeof t === 'string' && (t.startsWith('para:') || t.startsWith('product:'));
const isDecisionTarget = (t: unknown) => typeof t === 'string' && (t.startsWith('add:') || t === 'checkout');
const none = (type: MomentType): RuleEval => ({ type, progress: 0 });
const PRICE_RE = /\d{1,3}(?:,\d{3})+\s*원|\d+\s*만\s*원/;

/** 에이전트가 이미 상품을 다뤘는지: 가격이 든 assistant 턴, 또는 화면의 상품 카드 */
export function agentRecommended(input: DetectInput): boolean {
  if (input.multiProduct.multi || input.multiProduct.productIds.length || input.multiProduct.anyProductsShown) return true;
  return input.chatContext.some((c) => c.role === 'assistant' && PRICE_RE.test(c.text));
}

function debounced(input: DetectInput, type: MomentType) {
  const last = input.lastFired[type];
  return last !== undefined && input.now - last < RULE_DEBOUNCE_MS;
}

function lastSentAt(signals: Signal[]) {
  for (let i = signals.length - 1; i >= 0; i--) if (signals[i].type === 'message_sent') return signals[i].t;
  return 0;
}

function labelOf(label: unknown, target: unknown) {
  if (typeof label === 'string' && label) return label;
  return String(target ?? '');
}

// ---------- 룰 1: 요구 모호 ----------
export function ruleAmbiguous(input: DetectInput): RuleEval {
  const type: MomentType = 'ambiguous_request';
  const { now, draft, settings, chatContext } = input;
  const assistantCount = chatContext.filter((c) => c.role === 'assistant').length;
  // 요구 모호는 추천 전에만. 추천 뒤의 빈 입력창 무입력은 비교 망설임에 가깝다(여기서는 무시).
  if (assistantCount > 1 || agentRecommended(input) || !draft.focused || debounced(input, type)) return none(type);

  const idleSince = Math.max(draft.lastInputAt, draft.focusAt);
  // 같은 정지로 두 번 발화하지 않는다: 정지가 마지막 발화 뒤에 시작됐어야 한다
  if (!idleSince || idleSince <= (input.lastFired[type] ?? 0)) return none(type);

  const idle = now - idleSince;
  const text = draft.text.trim();
  const p = settings.pauseMs;
  const draftSignals = input.signals.filter(
    (s) => s.t > lastSentAt(input.signals) && ['delete_burst', 'draft_snapshot', 'focus_idle', 'compose_abandon'].includes(s.type),
  );
  const deleted = draftSignals
    .filter((s) => s.type === 'delete_burst')
    .map((s) => String(s.data.deletedText ?? '').trim())
    .filter(Boolean);
  const extra: string[] = [];
  if (deleted.length) extra.push(`지운 말 ${deleted.slice(-3).map((d) => `"${d}"`).join(', ')}`);
  if (text) extra.push(`현재 초안 "${text.slice(0, 40)}"`);

  // 세 변형 각각의 진행도. 통과 조건은 진행도 1과 같다.
  const variants = [
    {
      rule: '삭제 반복 + 장시간 정지',
      progress: 0.5 * Math.min(1, draft.bursts / 2) + 0.5 * Math.min(1, idle / p),
      lines: [`초안 썼다 지움 ${draft.bursts}회`, `입력 멈춤 ${sec(idle)}`],
      score: 0.55 + 0.1 * Math.min(3, draft.bursts - 1) + 0.05 * Math.min(3, idle / p - 1),
    },
    {
      rule: '빈 입력창 앞 장시간 무입력',
      progress: text ? 0 : Math.min(1, idle / (p * 2)),
      lines: [`빈 입력창에 포커스한 채 ${sec(idle)} 무입력`, ...(draft.bursts ? [`초안 썼다 지움 ${draft.bursts}회`] : [])],
      score: 0.5 + 0.05 * Math.min(4, idle / (p * 2) - 1) + (draft.bursts ? 0.1 : 0),
    },
    {
      rule: '초안 수정 후 전송 전 정지',
      progress: text ? 0.5 * Math.min(1, draft.bursts) + 0.5 * Math.min(1, idle / (p * 1.5)) : 0,
      lines: [`초안 썼다 지움 ${draft.bursts}회`, `전송 전 정지 ${sec(idle)}`],
      score: 0.5 + 0.1 * Math.min(3, draft.bursts) + 0.05 * Math.min(3, idle / (p * 1.5) - 1),
    },
  ];
  const done = variants.find((v) => v.progress >= 1);
  if (done) {
    return {
      type,
      progress: 1,
      hit: { type, score: clamp01(done.score), rule: done.rule, signalsSummary: [...done.lines, ...extra], signals: draftSignals.slice(-8) },
    };
  }
  const best = variants.reduce((a, b) => (b.progress > a.progress ? b : a));
  if (best.progress <= 0) return none(type);
  const have: string[] = [];
  if (draft.bursts) have.push(`삭제 버스트 ${draft.bursts}`);
  if (idle >= 1000) have.push(`정지 ${sec(idle)}`);
  return {
    type,
    progress: best.progress,
    partial: {
      type, progress: best.progress, have, rule: best.rule, signalsSummary: [...best.lines, ...extra],
      need: '삭제 2회+정지, 빈 입력 장시간 무입력, 또는 초안+정지 1.5배+삭제',
    },
  };
}

// ---------- 룰 2: 비교 망설임 ----------
export function ruleComparison(input: DetectInput): RuleEval {
  const type: MomentType = 'comparison_hesitation';
  const { now, multiProduct } = input;
  if (!multiProduct.multi || debounced(input, type)) return none(type);
  const since = Math.max(now - COMPARISON_WINDOW_MS, input.lastFired[type] ?? 0);
  const recent = input.signals.filter((s) => s.t > since && s.kind === 'cursor');

  // 근거 4종, 각각 0..1. 1이면 그 근거 충족.
  const features: { name: string; value: number; line: string; sig: Signal }[] = [];

  const osc = recent
    .filter((s) => s.type === 'oscillation' && s.t > now - OSCILLATION_WINDOW_MS && isAnswerTarget(s.data.a) && isAnswerTarget(s.data.b))
    .pop();
  if (osc) {
    features.push({
      name: '왕복',
      value: Math.min(1, Number(osc.data.count) / 3),
      line: `${labelOf(osc.data.aLabel, osc.data.a)}·${labelOf(osc.data.bLabel, osc.data.b)} 사이 왕복 ${Number(osc.data.count)}회`,
      sig: osc,
    });
  }
  const revisit = recent
    .filter((s) => s.type === 'dwell' && isAnswerTarget(s.data.target))
    .sort((a, b) => Number(a.data.visits) - Number(b.data.visits))
    .pop();
  if (revisit) {
    const visits = Number(revisit.data.visits);
    features.push({
      name: '재체류',
      value: Math.min(1, visits / 2),
      line: visits >= 2 ? `${labelOf(revisit.data.label, revisit.data.target)} 다시 읽음 ${visits}회` : `${labelOf(revisit.data.label, revisit.data.target)} 체류`,
      sig: revisit,
    });
  }
  const scroll = recent.filter((s) => s.type === 'scroll_reverse' && Number(s.data.count) >= 1).pop();
  if (scroll) features.push({ name: '역주행', value: 1, line: `스크롤 역주행 ${Number(scroll.data.count)}회`, sig: scroll });
  const price = recent.filter((s) => s.type === 'select' && s.data.price === true).pop();
  if (price) features.push({ name: '가격 선택', value: 1, line: `"${String(price.data.text).slice(0, 20)}" 선택`, sig: price });

  const full = features.filter((f) => f.value >= 1);
  const rule = features.some((f) => f.name === '가격 선택') ? '긴 응답 다시 읽기 + 가격 선택' : '여러 상품 응답 다시 읽기';

  if (full.length >= 2) {
    const productIds = new Set(multiProduct.productIds);
    for (const f of full) {
      for (const k of ['a', 'b', 'target'] as const) {
        const v = f.sig.data[k];
        if (typeof v === 'string' && v.startsWith('product:')) productIds.add(v.slice('product:'.length));
      }
    }
    return {
      type,
      progress: 1,
      hit: {
        type,
        score: clamp01(0.45 + 0.15 * full.length),
        rule,
        signalsSummary: full.map((f) => f.line),
        signals: full.map((f) => f.sig),
        context: { productIds: [...productIds], messageId: multiProduct.messageId ?? undefined },
      },
    };
  }
  if (!features.length) return none(type);
  // 진행도 = 가장 강한 근거 두 개의 평균(2가지 충족이면 1)
  const top = features.map((f) => f.value).sort((a, b) => b - a);
  const progress = ((top[0] ?? 0) + (top[1] ?? 0)) / 2;
  return {
    type,
    progress,
    partial: {
      type, progress, rule,
      have: features.map((f) => (f.value >= 1 ? f.name : `${f.name} ${f.value.toFixed(2)}`)),
      need: '왕복 3회·재체류 2회·역주행·가격 선택 중 2가지 이상',
      signalsSummary: features.map((f) => f.line),
    },
  };
}

// ---------- 룰 3: 결정 직전 머뭇 ----------
export function rulePreDecision(input: DetectInput): RuleEval {
  const type: MomentType = 'pre_decision';
  const { now, nearDecision, settings, lastDecisionClickAt } = input;
  if (debounced(input, type)) return none(type);
  const since = Math.max(now - DECISION_WINDOW_MS, input.lastFired[type] ?? 0, lastDecisionClickAt);

  const dwell = input.signals
    .filter((s) => s.t > since && s.type === 'dwell' && isDecisionTarget(s.data.target) && Number(s.data.ms) >= settings.dwellMs)
    .pop();
  const brow = nearDecision
    ? input.signals.filter((s) => s.t > since && s.type === 'brow' && Number(s.data.value) >= BROW_MIN).pop()
    : undefined;

  if (!dwell && !brow) {
    const nearMs = nearDecision && nearDecision.since > lastDecisionClickAt && nearDecision.since > (input.lastFired[type] ?? 0)
      ? now - nearDecision.since
      : 0;
    if (!nearDecision || nearMs <= 0) return none(type);
    const progress = Math.min(0.99, nearMs / settings.dwellMs);
    return {
      type,
      progress,
      partial: {
        type, progress, rule: '결정 버튼 앞 정지',
        have: [`${nearDecision.label} 근처 ${sec(nearMs)}`],
        need: `버튼 근처 체류 ${sec(settings.dwellMs)} 이상 또는 찌푸림`,
        signalsSummary: [`${nearDecision.label} 근처 정지 ${sec(nearMs)} · 클릭 없음`],
      },
    };
  }

  const target = String((dwell?.data.target ?? nearDecision?.target) || '');
  const label = String((dwell?.data.label ?? nearDecision?.label) || target);
  const summary: string[] = [];
  const signals: Signal[] = [];
  let score = 0.5;
  if (dwell) {
    summary.push(`${label} 근처 정지 ${sec(Number(dwell.data.ms))} · 클릭 없음`);
    signals.push(dwell);
    score += 0.1;
  }
  if (brow) {
    if (!dwell) summary.push(`${label} 근처`);
    summary.push(`찌푸림 ${Number(brow.data.value).toFixed(2)}`);
    signals.push(brow);
    score += 0.15;
  }
  const gaze = input.signals.filter((s) => s.t > now - DECISION_WINDOW_MS && s.type === 'gaze').pop();
  if (gaze) summary.push(`시선 ${String(gaze.data.region)}`);

  const rule = dwell && brow ? '결정 버튼 앞 정지 + 찌푸림' : dwell ? '결정 버튼 앞 정지' : '결정 버튼 근처 찌푸림';
  const productIds = target.startsWith('add:') ? [target.slice('add:'.length)] : undefined;
  return {
    type,
    progress: 1,
    hit: { type, score: clamp01(score), rule, signalsSummary: summary, signals, context: productIds ? { productIds } : undefined },
  };
}

/** 세 룰을 모두 돌린다. 여러 개가 동시에 통과하면 점수 순. */
export function detect(input: DetectInput): DetectOutput {
  const evals = [ruleAmbiguous(input), ruleComparison(input), rulePreDecision(input)];
  return {
    hits: evals.flatMap((e) => (e.hit ? [e.hit] : [])).sort((a, b) => b.score - a.score),
    partials: evals.flatMap((e) => (e.partial ? [e.partial] : [])),
    progress: {
      ambiguous_request: evals[0].progress,
      comparison_hesitation: evals[1].progress,
      pre_decision: evals[2].progress,
    },
  };
}
