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
/** 응답이 끝난 뒤 이만큼 입력·전송이 없으면 다음 턴을 제안한다 */
export const NEXT_TURN_IDLE_MS = 5_000;
/** 비교 망설임: 왕복 몇 번이면 근거 하나로 친다 */
const OSC_MIN = 2;
/** 스트리밍이 끝난 뒤 이만큼은 커서·스크롤을 근거로 쓰지 않는다(레이아웃 이동·자동 스크롤) */
export const BUSY_SETTLE_MS = 1_500;
const SCROLL_BONUS = 0.1;
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
  /** 화면의 에이전트 메시지 수(chatContext가 늦게 갱신될 때 보완) */
  assistantMessages?: number;
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
  /** 마지막 에이전트 응답 스트리밍이 끝난 시각(chatBusy true→false), 0이면 없음 */
  answerDoneAt?: number;
  /** 순간별 마지막 칩 표시 시각. 다음 턴 제안 우선순위는 "실제로 칩이 뜬" 다른 순간만 본다 */
  lastShown?: Partial<Record<MomentType, number>>;
  /** 응답 스트리밍 구간들(최근 것 몇 개). end가 null이면 지금 스트리밍 중 */
  busyPeriods?: { start: number; end: number | null }[];
  /** 지금 화면의 마지막 에이전트 응답 식별자(새 응답이면 바뀜) */
  answerKey?: string | null;
  /** 다음 턴 제안 후보가 이미 나온 응답 식별자 */
  nextTurnUsedKey?: string | null;
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
  /** 다음 턴 제안이 조건을 채웠지만 다른 룰에 밀림. 엔진은 이 응답의 다음 턴 제안 자격을 소진한다 */
  nextTurnSuppressed: boolean;
}

const sec = (ms: number) => `${(ms / 1000).toFixed(1)}초`;
const clamp01 = (n: number) => Math.max(0, Math.min(1, n));
const isAnswerTarget = (t: unknown) => typeof t === 'string' && (t.startsWith('para:') || t.startsWith('product:'));
const isDecisionTarget = (t: unknown) => typeof t === 'string' && (t.startsWith('add:') || t === 'checkout');
const none = (type: MomentType): RuleEval => ({ type, progress: 0 });
const PRICE_RE = /\d{1,3}(?:,\d{3})+\s*원|\d{4,}\s*원|\d+\s*만\s*(?:\d+\s*천\s*)?원/;

/** t가 스트리밍 중이거나 스트리밍 종료 후 BUSY_SETTLE_MS 안인지 */
export function inBusyWindow(input: DetectInput, t: number): boolean {
  return (input.busyPeriods ?? []).some((p) => t >= p.start && (p.end === null || t <= p.end + BUSY_SETTLE_MS));
}

/** 커서 신호 중 스트리밍 구간 밖에서 난 것만(근거 집계용). 수집은 그대로, 집계에서만 뺀다 */
function cursorEvidence(input: DetectInput, since: number): Signal[] {
  return input.signals.filter((s) => s.t > since && s.kind === 'cursor' && !inBusyWindow(input, s.t));
}

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
  const assistantCount = Math.max(chatContext.filter((c) => c.role === 'assistant').length, input.multiProduct.assistantMessages ?? 0);
  // 응답 생성 중(과 직후)에는 요청이 이미 나간 상태라 요구 모호가 아니다
  if (inBusyWindow(input, now)) return none(type);
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
  const recent = cursorEvidence(input, since);

  // 주 근거 3종(왕복·재방문·가격 선택), 각각 0..1. 하나라도 1이면 발화. 스크롤 역주행은 보조(점수·진행도 가산만).
  const features: { name: string; value: number; line: string; sig: Signal }[] = [];

  const osc = recent
    .filter((s) => s.type === 'oscillation' && s.t > now - OSCILLATION_WINDOW_MS && isAnswerTarget(s.data.a) && isAnswerTarget(s.data.b))
    .pop();
  if (osc) {
    features.push({
      name: '왕복',
      value: Math.min(1, Number(osc.data.count) / OSC_MIN),
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
      // 한 번 체류(읽는 중)는 0.6: prefetch만 시작하고, 다시 읽으면(visits 2) 확정
      value: visits >= 2 ? 1 : 0.6,
      line: visits >= 2 ? `${labelOf(revisit.data.label, revisit.data.target)} 다시 읽음 ${visits}회` : `${labelOf(revisit.data.label, revisit.data.target)} 체류`,
      sig: revisit,
    });
  }
  const scroll = recent.filter((s) => s.type === 'scroll_reverse' && Number(s.data.count) >= 1).pop();
  const scrollLine = scroll ? `스크롤 역주행 ${Number(scroll.data.count)}회` : null;
  const price = recent.filter((s) => s.type === 'select' && s.data.price === true).pop();
  if (price) features.push({ name: '가격 선택', value: 1, line: `"${String(price.data.text).slice(0, 20)}" 선택`, sig: price });

  const full = features.filter((f) => f.value >= 1);
  const rule = features.some((f) => f.name === '가격 선택') ? '긴 응답 다시 읽기 + 가격 선택' : '여러 상품 응답 다시 읽기';

  if (full.length >= 1) {
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
        score: clamp01(0.5 + 0.12 * full.length + (scroll ? SCROLL_BONUS : 0)),
        rule,
        signalsSummary: [...full.map((f) => f.line), ...(scrollLine ? [scrollLine] : [])],
        signals: [...full.map((f) => f.sig), ...(scroll ? [scroll] : [])],
        context: { productIds: [...productIds], messageId: multiProduct.messageId ?? undefined },
      },
    };
  }
  if (!features.length && !scroll) return none(type);
  // 진행도 = 가장 강한 주 근거 + 역주행 보너스. 역주행만으로는 1에 닿지 않는다
  const progress = Math.min(0.99, Math.max(0, ...features.map((f) => f.value)) + (scroll ? SCROLL_BONUS : 0));
  return {
    type,
    progress,
    partial: {
      type, progress, rule,
      have: [...features.map((f) => `${f.name} ${f.value.toFixed(2)}`), ...(scroll ? ['역주행(보조)'] : [])],
      need: `왕복 ${OSC_MIN}회·재방문 2회·가격 선택 중 하나(역주행은 보조)`,
      signalsSummary: [...features.map((f) => f.line), ...(scrollLine ? [scrollLine] : [])],
    },
  };
}

// ---------- 룰 3: 결정 직전 머뭇 ----------
export function rulePreDecision(input: DetectInput): RuleEval {
  const type: MomentType = 'pre_decision';
  const { now, nearDecision, settings, lastDecisionClickAt } = input;
  if (debounced(input, type)) return none(type);
  const since = Math.max(now - DECISION_WINDOW_MS, input.lastFired[type] ?? 0, lastDecisionClickAt);

  const dwell = cursorEvidence(input, since)
    .filter((s) => s.type === 'dwell' && isDecisionTarget(s.data.target) && Number(s.data.ms) >= settings.dwellMs)
    .pop();
  const brow = nearDecision && !inBusyWindow(input, now)
    ? input.signals.filter((s) => s.t > since && s.type === 'brow' && Number(s.data.value) >= BROW_MIN).pop()
    : undefined;

  if (!dwell && !brow) {
    // 스트리밍 중·직후에는 버튼이 커서 밑으로 밀려 온 것일 수 있어 근처 체류를 세지 않는다
    const nearMs = nearDecision && !inBusyWindow(input, now) && nearDecision.since > lastDecisionClickAt && nearDecision.since > (input.lastFired[type] ?? 0)
      ? now - Math.max(nearDecision.since, busySettledAt(input))
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

function busySettledAt(input: DetectInput) {
  const ends = (input.busyPeriods ?? []).map((p) => (p.end === null ? Infinity : p.end + BUSY_SETTLE_MS));
  return ends.length ? Math.max(...ends) : 0;
}

// ---------- 룰 4: 다음 턴 제안 ----------
const OTHER_TYPES: MomentType[] = ['ambiguous_request', 'comparison_hesitation', 'pre_decision'];

export function ruleNextTurn(input: DetectInput): RuleEval {
  const type: MomentType = 'next_turn';
  const { now, draft } = input;
  const doneAt = input.answerDoneAt ?? 0;
  if (!doneAt || debounced(input, type)) return none(type);
  // 응답 하나당 후보 최대 1번(칩이 떴든 보류됐든)
  if (input.answerKey != null && input.answerKey === input.nextTurnUsedKey) return none(type);
  // 응답 하나에 한 번만
  if ((input.lastFired[type] ?? 0) >= doneAt) return none(type);
  // 응답 뒤 다른 순간의 칩이 이미 떴으면 그쪽이 이 응답에 대한 개입이다(게이트에 걸려 안 뜬 후보는 제외)
  if (OTHER_TYPES.some((t) => (input.lastShown?.[t] ?? 0) >= doneAt)) return none(type);
  if (!input.chatContext.some((c) => c.role === 'assistant')) return none(type);
  // 응답 뒤 입력이나 전송이 있었으면 사용자가 이미 다음 턴을 시작했다
  if (draft.lastInputAt >= doneAt || draft.text.trim()) return none(type);
  if (input.signals.some((s) => s.type === 'message_sent' && s.t >= doneAt)) return none(type);

  const idle = now - doneAt;
  const progress = Math.min(1, idle / NEXT_TURN_IDLE_MS);
  const summary = [`응답이 끝난 뒤 ${sec(idle)} 동안 입력 없음`];
  if (draft.focused) summary.push('입력창에 포커스 중');
  const rule = '응답 뒤 무입력';
  if (progress >= 1) {
    return { type, progress: 1, hit: { type, score: 0.5, rule, signalsSummary: summary, signals: [] } };
  }
  return {
    type,
    progress,
    partial: { type, progress, rule, have: [`응답 뒤 ${sec(idle)}`], need: `응답 뒤 ${sec(NEXT_TURN_IDLE_MS)} 무입력`, signalsSummary: summary },
  };
}

/** 네 룰을 모두 돌린다. 여러 개가 동시에 통과하면 점수 순, 다음 턴 제안은 다른 룰이 없을 때만. */
export function detect(input: DetectInput): DetectOutput {
  const evals = [ruleAmbiguous(input), ruleComparison(input), rulePreDecision(input), ruleNextTurn(input)];
  const others = evals.slice(0, 3).flatMap((e) => (e.hit ? [e.hit] : [])).sort((a, b) => b.score - a.score);
  const next = evals[3].hit;
  return {
    hits: others.length ? others : next ? [next] : [],
    nextTurnSuppressed: !!next && others.length > 0,
    partials: evals.flatMap((e) => (e.partial ? [e.partial] : [])),
    progress: {
      ambiguous_request: evals[0].progress,
      comparison_hesitation: evals[1].progress,
      pre_decision: evals[2].progress,
      next_turn: others.length ? 0 : evals[3].progress,
    },
  };
}
