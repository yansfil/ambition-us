// 순간 감지 룰 검증. 실행: node scripts/test-detector.ts
// 합성 신호 시퀀스로 세 룰의 발화/미발화를 확인한다.
import type { ChatTurn, Signal } from '../src/poin/types';
import type { DetectInput } from '../src/poin/moments/detector';

// 확장자 붙은 경로는 tsc가 막으므로(allowImportingTsExtensions 꺼짐) 동적 import로 불러온다.
const detectorUrl = new URL('../src/poin/moments/detector.ts', import.meta.url).href;
const { detect, PREFETCH_PROGRESS } = (await import(detectorUrl)) as typeof import('../src/poin/moments/detector');

let seq = 0;
const T0 = 1_000_000;
const sig = (t: number, kind: Signal['kind'], type: string, data: Record<string, unknown> = {}): Signal => ({
  id: `s${seq++}`, t: T0 + t, kind, type, data,
});

const base = (over: Partial<DetectInput> = {}): DetectInput => ({
  now: T0 + 20_000,
  signals: [],
  chatContext: [],
  settings: { pauseMs: 4000, dwellMs: 1500 },
  draft: { focused: false, text: '', focusAt: 0, lastInputAt: 0, bursts: 0 },
  nearDecision: null,
  lastDecisionClickAt: 0,
  multiProduct: { messageId: null, productIds: [], multi: false },
  lastFired: {},
  ...over,
});

const recommendation: ChatTurn[] = [
  { role: 'user', text: '집들이 선물 추천해 줘' },
  { role: 'assistant', text: '어떤 분위기를 좋아하세요?' },
  { role: 'user', text: '향이나 분위기 있는 거' },
  { role: 'assistant', text: '세 가지로 골라 봤어요...' },
];

let pass = 0;
let fail = 0;
function check(name: string, input: DetectInput, expect: string | null) {
  const out = detect(input);
  const got = out.hits[0]?.type ?? null;
  const ok = got === expect;
  if (ok) pass++;
  else fail++;
  const detail = out.hits[0] ? ` | ${out.hits[0].rule} | ${out.hits[0].signalsSummary.join(' · ')} | score ${out.hits[0].score.toFixed(2)}` : '';
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}  → ${got ?? '없음'} (기대 ${expect ?? '없음'})${detail}`);
}

// ---------- 룰 1: 요구 모호 ----------
const burstSignals = [
  sig(1000, 'paraverbal', 'delete_burst', { count: 5, deletedText: '인테리어 소품' }),
  sig(4000, 'paraverbal', 'delete_burst', { count: 4, deletedText: '향초' }),
];
check('1a 삭제 버스트 2회 + 정지 6초', base({
  signals: burstSignals,
  draft: { focused: true, text: '집들이 선물로 뭐가 좋', focusAt: T0, lastInputAt: T0 + 14_000, bursts: 2 },
}), 'ambiguous_request');

check('1a 미발화: 버스트 2회지만 정지 2초', base({
  signals: burstSignals,
  draft: { focused: true, text: '집들이 선물로 뭐가 좋', focusAt: T0, lastInputAt: T0 + 18_000, bursts: 2 },
}), null);

check('1b 빈 입력창 포커스 무입력 9초', base({
  draft: { focused: true, text: '', focusAt: T0 + 11_000, lastInputAt: 0, bursts: 0 },
}), 'ambiguous_request');

check('1b 미발화: 빈 입력창 무입력 5초(기준 8초)', base({
  draft: { focused: true, text: '', focusAt: T0 + 15_000, lastInputAt: 0, bursts: 0 },
}), null);

check('1c 초안 + 정지 6.5초 + 버스트 1회', base({
  signals: burstSignals.slice(0, 1),
  draft: { focused: true, text: '선물', focusAt: T0, lastInputAt: T0 + 13_500, bursts: 1 },
}), 'ambiguous_request');

check('1 미발화: 에이전트 답이 2개 이상(추천 후)', base({
  chatContext: recommendation,
  signals: burstSignals,
  draft: { focused: true, text: '음', focusAt: T0, lastInputAt: T0 + 10_000, bursts: 2 },
}), null);

check('1 미발화: 포커스 없음', base({
  signals: burstSignals,
  draft: { focused: false, text: '음', focusAt: T0, lastInputAt: T0 + 10_000, bursts: 2 },
}), null);

check('1 미발화: 같은 정지로 재발화 금지(마지막 발화가 정지 시작 뒤)', base({
  signals: burstSignals,
  draft: { focused: true, text: '음', focusAt: T0, lastInputAt: T0 + 5_000, bursts: 2 },
  lastFired: { ambiguous_request: T0 + 9_000 },
}), null);

check('1 미발화: 10초 디바운스', base({
  signals: burstSignals,
  draft: { focused: true, text: '음', focusAt: T0, lastInputAt: T0 + 14_000, bursts: 2 },
  lastFired: { ambiguous_request: T0 + 13_000 },
}), null);

check('1 미발화: 추천 후(가격 든 답 1개) 빈 입력창 무입력 9.7초', base({
  chatContext: [
    { role: 'user', text: '집들이 선물 추천해 줘' },
    { role: 'assistant', text: '세 가지로 골라 봤어요. 소이 캔들 3종 세트(32,000원), 미니 몬스테라 화분(45,000원), 핸드드립 입문 세트(78,000원)' },
  ],
  draft: { focused: true, text: '', focusAt: T0 + 10_300, lastInputAt: 0, bursts: 0 },
}), null);
check('1 미발화: 화면에 상품 카드가 있음(텍스트에 가격 없음)', base({
  chatContext: [{ role: 'assistant', text: '이 상품들은 어떠세요?' }],
  multiProduct: { messageId: 'm1', productIds: ['p01'], multi: false },
  draft: { focused: true, text: '', focusAt: T0 + 10_300, lastInputAt: 0, bursts: 0 },
}), null);
check('1b 발화: 추천 전 질문만 한 답 1개 + 빈 입력창 무입력 9.7초', base({
  chatContext: [{ role: 'user', text: '선물' }, { role: 'assistant', text: '누구에게 주실 선물인가요?' }],
  draft: { focused: true, text: '', focusAt: T0 + 10_300, lastInputAt: 0, bursts: 0 },
}), 'ambiguous_request');

// ---------- 룰 2: 비교 망설임 ----------
const multi = { messageId: 'm2', productIds: ['p01', 'p02', 'p03'], multi: true };
const osc = sig(15_000, 'cursor', 'oscillation', { a: 'para:m2:1', b: 'para:m2:3', aLabel: '응답 2번째 문단', bLabel: '응답 4번째 문단', count: 4 });
const revisit = sig(16_000, 'cursor', 'dwell', { target: 'para:m2:3', label: '응답 4번째 문단', ms: 2100, visits: 3 });
const scroll = sig(17_000, 'cursor', 'scroll_reverse', { count: 2 });
const price = sig(18_000, 'cursor', 'select', { text: '78,000원', target: 'para:m2:3', price: true });

check('2 왕복 4회 + 스크롤 역주행', base({ chatContext: recommendation, multiProduct: multi, signals: [osc, scroll] }), 'comparison_hesitation');
check('2 재체류 3회 + 가격 선택', base({ chatContext: recommendation, multiProduct: multi, signals: [revisit, price] }), 'comparison_hesitation');
check('2 미발화: 근거 1가지(스크롤 역주행만)', base({ chatContext: recommendation, multiProduct: multi, signals: [scroll] }), null);
check('2 미발화: 상품 여럿 아님', base({ chatContext: recommendation, multiProduct: { ...multi, multi: false }, signals: [osc, scroll, price] }), null);
check('2 미발화: 왕복 2회 + 가격 선택 아닌 일반 선택', base({
  chatContext: recommendation, multiProduct: multi,
  signals: [{ ...osc, data: { ...osc.data, count: 2 } }, { ...price, data: { ...price.data, price: false } }],
}), null);
check('2 미발화: 왕복이 10초 창 밖(+스크롤)', base({
  chatContext: recommendation, multiProduct: multi,
  signals: [{ ...osc, t: T0 + 8_000 }, scroll],
}), null);
check('2 미발화: 마지막 발화 이전 근거는 재사용 안 함', base({
  chatContext: recommendation, multiProduct: multi, signals: [osc, scroll],
  lastFired: { comparison_hesitation: T0 + 17_500 },
}), null);

// ---------- 룰 3: 결정 직전 머뭇 ----------
const near = { target: 'add:p03', label: '담기 · 핸드드립 입문 세트', since: T0 + 17_000 };
const decisionDwell = sig(18_600, 'cursor', 'dwell', { target: 'add:p03', label: '담기 · 핸드드립 입문 세트', ms: 1600, visits: 1, decision: true });
check('3 담기 근처 체류 1.6초 클릭 없음', base({ chatContext: recommendation, nearDecision: near, signals: [decisionDwell] }), 'pre_decision');
check('3 결제 근처 찌푸림 0.5', base({
  chatContext: recommendation,
  nearDecision: { target: 'checkout', label: '결제 버튼', since: T0 + 19_000 },
  signals: [sig(19_500, 'sense', 'brow', { value: 0.5 })],
}), 'pre_decision');
check('3 미발화: 체류 뒤 클릭함', base({ chatContext: recommendation, nearDecision: near, signals: [decisionDwell], lastDecisionClickAt: T0 + 19_000 }), null);
check('3 미발화: 찌푸림 0.3(기준 0.45)', base({
  chatContext: recommendation, nearDecision: near,
  signals: [sig(19_500, 'sense', 'brow', { value: 0.3 })],
}), null);
check('3 미발화: 찌푸림이지만 버튼 근처 아님', base({
  chatContext: recommendation,
  signals: [sig(19_500, 'sense', 'brow', { value: 0.6 })],
}), null);
check('3 미발화: 일반 상품 카드 체류는 결정 아님', base({
  chatContext: recommendation,
  signals: [sig(18_600, 'cursor', 'dwell', { target: 'product:p03', ms: 1800, visits: 1 })],
}), null);

// ---------- 진행도(prefetch 기준 0.6 전후) ----------
function checkProgress(name: string, input: DetectInput, type: keyof ReturnType<typeof detect>['progress'], expectPrefetch: boolean) {
  const out = detect(input);
  const p = out.progress[type];
  const hit = out.hits.some((h) => h.type === type);
  const ok = (p >= PREFETCH_PROGRESS) === expectPrefetch && !hit;
  if (ok) pass++;
  else fail++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  진행도 ${name}  → ${p.toFixed(3)} (prefetch ${p >= PREFETCH_PROGRESS ? '함' : '안 함'}, 기대 ${expectPrefetch ? '함' : '안 함'}${hit ? ', 그런데 확정됨' : ''})`);
}

const osc2 = { ...osc, data: { ...osc.data, count: 2 } };
const dwell1 = { ...revisit, data: { ...revisit.data, visits: 1 } };
checkProgress('2 왕복 2/3 + 역주행 → 0.83', base({ chatContext: recommendation, multiProduct: multi, signals: [osc2, scroll] }), 'comparison_hesitation', true);
checkProgress('2 왕복 2/3 + 체류 1/2 → 0.58', base({ chatContext: recommendation, multiProduct: multi, signals: [osc2, dwell1] }), 'comparison_hesitation', false);
checkProgress('2 역주행만 → 0.50', base({ chatContext: recommendation, multiProduct: multi, signals: [scroll] }), 'comparison_hesitation', false);
checkProgress('2 상품 여럿 아님 → 0', base({ chatContext: recommendation, multiProduct: { ...multi, multi: false }, signals: [osc2, scroll] }), 'comparison_hesitation', false);
checkProgress('1 초안+버스트1+정지 1.4초 → 0.617', base({
  signals: burstSignals.slice(0, 1),
  draft: { focused: true, text: '선물', focusAt: T0, lastInputAt: T0 + 18_600, bursts: 1 },
}), 'ambiguous_request', true);
checkProgress('1 초안+버스트1+정지 1.0초 → 0.583', base({
  signals: burstSignals.slice(0, 1),
  draft: { focused: true, text: '선물', focusAt: T0, lastInputAt: T0 + 19_000, bursts: 1 },
}), 'ambiguous_request', false);
checkProgress('1 빈 입력 무입력 5초 → 0.625', base({
  draft: { focused: true, text: '', focusAt: T0 + 15_000, lastInputAt: 0, bursts: 0 },
}), 'ambiguous_request', true);
checkProgress('1 빈 입력 무입력 4.6초 → 0.575', base({
  draft: { focused: true, text: '', focusAt: T0 + 15_400, lastInputAt: 0, bursts: 0 },
}), 'ambiguous_request', false);
checkProgress('3 담기 근처 0.9초/1.5초 → 0.60', base({
  chatContext: recommendation, nearDecision: { ...near, since: T0 + 19_100 },
}), 'pre_decision', true);
checkProgress('3 담기 근처 0.85초/1.5초 → 0.567', base({
  chatContext: recommendation, nearDecision: { ...near, since: T0 + 19_150 },
}), 'pre_decision', false);
checkProgress('3 근처지만 클릭 뒤 → 0', base({
  chatContext: recommendation, nearDecision: { ...near, since: T0 + 17_000 }, lastDecisionClickAt: T0 + 18_000,
}), 'pre_decision', false);

console.log(`\n${pass} 통과 / ${fail} 실패`);
if (fail) process.exit(1);
