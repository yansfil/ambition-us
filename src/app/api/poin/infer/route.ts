// poin 의도 추론: 순간 후보(InferRequest) → 의도 가설 + 칩 문구 + 결과 Effect(InferResult).
// 세 망설임 순간: LLM은 문구와 확신도만 쓴다. 개입 형태(옵션 수, Effect, 에이전트 지시)는 서버가 고정한다.
// 다음 턴 제안: LLM이 행동과 지시문까지 쓰되, 서버가 길이·허용 문자·사용자 원문 인용 여부를 검증하고 어긋나면 기본값으로 바꾼다.
import { anthropic } from '@ai-sdk/anthropic';
import { generateText, Output } from 'ai';
import { z } from 'zod';
import { poin as copy } from '@/i18n/poin';
import { slog } from '@/lib/log-server';
import type { Effect, InferRequest, InferResult, InterventionOption, MomentType } from '@/poin/types';

const MODEL = 'claude-haiku-5-5';

const requestSchema = z.object({
  momentType: z.enum(['ambiguous_request', 'comparison_hesitation', 'pre_decision', 'next_turn']),
  rule: z.string().max(200),
  signalsSummary: z.array(z.string().max(300)).max(20),
  conversation: z
    .array(z.object({ role: z.enum(['user', 'assistant', 'poin']), text: z.string() }))
    .max(20),
  productContext: z.array(z.string().max(400)).max(12).optional(),
});

const baseFields = {
  intentHypothesis: z.string().describe('사용자가 지금 망설이는 이유에 대한 가설 한 문장'),
  confidence: z.number().describe('0~1. 신호가 약하거나 하나뿐이면 0.5 안팎, 여러 신호가 같은 방향이면 높게'),
  evidence: z.array(z.string()).describe('근거로 쓴 신호 요약(입력에 있는 것만)'),
  rationale: z.string().describe('판단 이유 한두 문장'),
  prompt: z.string().describe('칩 질문 한 문장, 25자 안팎, 물음표로 끝남'),
  evidenceLine: z.string().describe('관찰한 사실 한 줄, "~하셨어요" 톤, 20자 안팎'),
};

const outputSchema = z.object({
  ...baseFields,
  accept1Label: z.string().describe('첫 번째 선택지 라벨, 2~6자'),
  accept2Label: z.string().describe('두 번째 선택지 라벨, 2~6자(비교 망설임에서만 쓰임)'),
});

const nextTurnSchema = z.object({
  ...baseFields,
  options: z
    .array(
      z.object({
        label: z.string().describe('선택지 라벨, 2~8자'),
        kind: z.enum(['agent_turn', 'fill_draft']).describe('agent_turn: 에이전트가 바로 그 행동을 함. fill_draft: 사용자가 보낼 다음 질문을 입력창에 채움'),
        directive: z.string().describe('agent_turn일 때 에이전트에게 줄 지시 한두 문장(따옴표·사용자 말 인용 금지). fill_draft면 빈 문자열'),
        draftText: z.string().describe('fill_draft일 때 입력창에 채울 사용자의 다음 질문 한 문장. agent_turn이면 빈 문자열'),
      }),
    )
    .describe('1~2개. 가장 도움이 될 다음 행동 하나를 첫 번째로'),
});

const SYSTEM = `너는 poin이다. 쇼핑 에이전트와 대화하는 사용자의 망설임 순간을 해석해, 대화 중간에 아주 작은 제안 칩 하나를 띄운다.
너는 에이전트가 아니다. 상품을 추천하거나 답을 하지 않는다. 사용자가 다음 턴을 더 낫게 만들도록 짧은 질문 하나만 건넨다.

순간 종류:
- ambiguous_request(요구 모호): 첫 요청을 썼다 지우거나 오래 멈춤. 무엇을 원하는지 아직 정해지지 않았다. 칩은 "추천 전에 몇 가지만 먼저 물어봐도 될지"를 묻는다.
- comparison_hesitation(비교 망설임): 여러 상품을 다룬 긴 응답을 다시 읽고 오간다. 글로는 비교가 어렵다. 칩은 "한눈에 보기 쉽게 정리해 줄지"를 묻는다. 선택지 1은 표 요약, 선택지 2는 사진 카드.
- pre_decision(결정 직전 머뭇): 담기·결제 버튼 앞에서 멈추거나 찌푸린다. 가격이나 반품 같은 걱정이 있을 수 있다. 칩은 그 걱정이 맞는지 묻는다. 선택지 1은 "네".
- next_turn(다음 턴 제안): 에이전트 응답이 끝났는데 사용자가 한동안 아무것도 안 한다. 대화 맥락에서 지금 가장 도움이 될 다음 행동 하나를 골라 먼저 제안한다. 예: "예산 안에서 하나만 골라 드릴까요?", "받는 분 취향 알려 주실래요?", "이걸로 담을까요?"
  options는 1~2개. 에이전트가 바로 할 일이면 kind=agent_turn과 directive(에이전트에게 줄 지시, 명령형 한두 문장, 80자 안팎, 따옴표 없이, 사용자 말을 그대로 옮기지 말 것). 사용자가 직접 물어볼 질문이면 kind=fill_draft와 draftText(사용자 입장의 질문 한 문장, 40자 안팎).

출력 규칙:
- prompt: 질문 한 문장, 25자 안팎, 존댓말, 물음표로 끝낸다. 예: "먼저 두 가지만 짧게 여쭤볼까요?"
- evidenceLine: 관찰한 사실 한 줄, "~하셨어요" 톤. 해석이나 감정 단정 금지. 예: "보내기 전에 잠시 멈추셨어요"
- accept1Label, accept2Label: 2~6자. 예: "좋아요", "표로 요약", "사진과 함께", "네"
- evidence: 입력으로 받은 신호 요약 중 실제로 근거로 쓴 것만. 없는 신호를 만들지 않는다.
- confidence: 신호의 강도와 개수에 비례. 과신하지 않는다. 신호 하나뿐이거나 대화 맥락과 안 맞으면 0.5 아래로.
- 모든 문장은 한국어.`;

/** 순간별 고정 개입 형태. 지시문은 에이전트용 프롬프트라 i18n 대상이 아니다. */
// 지시문에는 사용자 원문(지운 말, 초안)을 넣지 않는다: 에이전트가 따르는 지시라 주입 경로가 된다.
function shape(type: Exclude<MomentType, 'next_turn'>) {
  const d = copy.defaults;
  const turn = (directive: string, markText: string): Effect => ({ kind: 'agent_turn', directive, markText });
  switch (type) {
    case 'ambiguous_request':
      return {
        accept1: turn('아직 상품을 추천하지 마라. 추천 전에 받는 사람의 취향과 피하고 싶은 것, 이 두 가지만 짧게 질문하라. 두 줄 이내.', d.ambiguous_request.accept1Mark),
        accept2: null,
        onDecline: { kind: 'none' } as Effect,
      };
    case 'comparison_hesitation':
      return {
        accept1: turn('직전 추천을 마크다운 표로 요약하라. 열: 상품, 가격, 사용자가 말한 기준에 맞는 점, 예산 여유(미션 예산 대비 남는 금액), 실패 위험. 표 아래 한 줄로만 덧붙인다.', d.comparison_hesitation.accept1Mark),
        accept2: turn('show_products 도구로 직전에 추천한 세 상품을 카드로 다시 보여 주고, 각 상품의 차이를 한 줄로 요약하라.', d.comparison_hesitation.accept2Mark),
        onDecline: { kind: 'none' } as Effect,
      };
    case 'pre_decision':
      return {
        accept1: turn('사용자가 담기 앞에서 망설인 이 상품의 가격 대비 가치와 반품 정책을 짧게 답하라. 세 문장 이내.', d.pre_decision.accept1Mark),
        accept2: null,
        onDecline: turn('지금 보던 상품보다 저렴하고 미션 예산 안인 대안 2개를 show_products 도구로 보여 주고, 각각 한 줄로 차이를 말하라.', d.pre_decision.declineMark),
      };
  }
}

const DEFAULT_NEXT_DIRECTIVE = '지금까지의 대화를 바탕으로 사용자에게 가장 도움이 될 다음 할 일을 하나 제안하라. 두 문장 이내.';
// 지시문·초안 허용 문자: 한글, 영숫자, 공백, 기본 문장부호. 따옴표·괄호류(<>{}[])·백틱·#·줄바꿈 금지
const ALLOWED = /^[가-힣ㄱ-ㅎㅏ-ㅣa-zA-Z0-9 .,?!·:()~%/+-]+$/;
// 지시를 뒤집으려는 표현은 막는다
const BLOCKED = /무시|ignore|system|시스템|프롬프트|prompt|developer|이전 지시|규칙을/i;
// 조건을 바꿔 말하는 건 허용하고, 사용자 문장을 길게 그대로 옮기는 것만 막는다
const QUOTE_WINDOW = 12;
const squash = (s: string) => s.replace(/\s+/g, ' ').trim();

/** 사용자 원문을 QUOTE_WINDOW자 이상 그대로 옮겼는지 */
function quotesUser(text: string, userTexts: string[]) {
  const hay = userTexts.map(squash).join('\n');
  const t = squash(text);
  for (let i = 0; i + QUOTE_WINDOW <= t.length; i++) {
    if (hay.includes(t.slice(i, i + QUOTE_WINDOW))) return true;
  }
  return false;
}

/** 검증 실패 사유 또는 null */
function checkDirective(value: string, userTexts: string[]): string | null {
  const v = squash(value ?? '');
  if (len(v) < 10 || len(v) > 160) return `길이 ${len(v)}`;
  if (!HANGUL.test(v)) return '한글 없음';
  if (!ALLOWED.test(v)) return '허용 안 된 문자';
  if (BLOCKED.test(v)) return '금지 표현';
  if (quotesUser(v, userTexts)) return '사용자 원문 인용';
  return null;
}

function checkDraft(value: string): string | null {
  const v = squash(value ?? '');
  if (len(v) < 4 || len(v) > 60) return `길이 ${len(v)}`;
  if (!HANGUL.test(v)) return '한글 없음';
  if (!ALLOWED.test(v)) return '허용 안 된 문자';
  if (BLOCKED.test(v)) return '금지 표현';
  return null;
}

type NextOut = z.infer<typeof nextTurnSchema>;

/** 다음 턴 제안 옵션 검증. 실패한 옵션은 버린다.
 *  첫 옵션(칩 질문이 가리키는 행동)이 버려지면 질문도 맞지 않으므로 기본 질문 + 기본 옵션을 앞에 둔다. */
function nextTurnOptions(out: NextOut, userTexts: string[], fallbacks: string[]): { options: InterventionOption[]; firstDropped: boolean } {
  const d = copy.defaults.next_turn;
  const options: InterventionOption[] = [];
  const raw = Array.isArray(out.options) ? out.options.slice(0, 2) : [];
  let firstDropped = raw.length === 0;
  raw.forEach((o, i) => {
    const label = checkText(o.label ?? '', 1, 10); // 다음 턴 행동은 "예산 안에서 고르기"처럼 조금 길다
    const drop = (why: string) => {
      fallbacks.push(`options[${i}].${why}`);
      if (i === 0) firstDropped = true;
    };
    if (firstDropped && i > 0 && !options.length) {
      // 첫 옵션이 버려졌으면 아래에서 기본 옵션을 accept1로 넣고, 이 옵션은 accept2가 된다
      options.push(defaultNextOption());
    }
    if (!label || options.some((x) => x.label === label)) {
      drop('label');
      return;
    }
    if (o.kind === 'fill_draft') {
      const why = checkDraft(o.draftText);
      if (why) {
        drop(`draftText(${why})`);
        return;
      }
      options.push({ id: options.length ? 'accept2' : 'accept1', label, effect: { kind: 'fill_draft', text: squash(o.draftText) } });
      return;
    }
    const why = checkDirective(o.directive, userTexts);
    if (why) {
      drop(`directive(${why})`);
      return;
    }
    options.push({
      id: options.length ? 'accept2' : 'accept1',
      label,
      effect: { kind: 'agent_turn', directive: squash(o.directive), markText: d.agentMarkWith(label) },
    });
  });
  if (!options.length) options.push(defaultNextOption());
  return { options, firstDropped };
}

function defaultNextOption(): InterventionOption {
  const d = copy.defaults.next_turn;
  return { id: 'accept1', label: d.accept1, effect: { kind: 'agent_turn', directive: DEFAULT_NEXT_DIRECTIVE, markText: d.agentMark } };
}

const HANGUL = /[가-힣]/;
const len = (s: string) => [...s].length;

function checkText(value: string, min: number, max: number) {
  const v = value.trim().replace(/\s+/g, ' ');
  return v && HANGUL.test(v) && len(v) >= min && len(v) <= max ? v : null;
}

export async function POST(req: Request) {
  let body: InferRequest;
  try {
    const parsed = requestSchema.safeParse(await req.json());
    if (!parsed.success) {
      slog.warn('infer', '추론 요청 형식 오류', { issues: parsed.error.issues.slice(0, 5) });
      return Response.json({ error: 'invalid request', issues: parsed.error.issues.slice(0, 5) }, { status: 400 });
    }
    body = parsed.data;
  } catch {
    slog.warn('infer', '추론 요청 JSON 파싱 실패');
    return Response.json({ error: 'invalid json' }, { status: 400 });
  }

  const conversation = body.conversation.slice(-8).map((c) => `${c.role}: ${c.text.slice(0, 500)}`).join('\n');
  const prompt = [
    `순간 종류: ${body.momentType}`,
    `감지 룰: ${body.rule}`,
    `신호 요약:\n${body.signalsSummary.map((s) => `- ${s}`).join('\n') || '- (없음)'}`,
    `최근 대화:\n${conversation || '(아직 없음)'}`,
    `화면의 상품:\n${(body.productContext ?? []).map((p) => `- ${p}`).join('\n') || '- (없음)'}`,
  ].join('\n\n');

  slog.info('infer', `추론 요청: ${body.momentType} · ${body.rule}`, {
    signals: body.signalsSummary, turns: body.conversation.length, products: body.productContext?.length ?? 0,
  });

  const t0 = Date.now();
  try {
    const providerOptions = { anthropic: { thinking: { type: 'disabled' as const }, effort: 'low' as const } };
    const fallbacks: string[] = [];
    const momentType = body.momentType;
    let result: { output: z.infer<typeof outputSchema> | NextOut; response?: { modelId?: string }; warnings?: unknown[] };
    if (momentType === 'next_turn') {
      result = await generateText({ model: anthropic(MODEL), system: SYSTEM, prompt, output: Output.object({ schema: nextTurnSchema }), providerOptions });
    } else {
      result = await generateText({ model: anthropic(MODEL), system: SYSTEM, prompt, output: Output.object({ schema: outputSchema }), providerOptions });
    }
    const latencyMs = Date.now() - t0;
    const out = result.output;
    const def = copy.defaults[momentType];

    let promptText = checkText(out.prompt, 6, 40) ?? (fallbacks.push('prompt'), def.prompt);
    const evidenceLine = checkText(out.evidenceLine, 4, 40) ?? (fallbacks.push('evidenceLine'), def.evidenceLine);
    let confidence = Number(out.confidence);
    if (!Number.isFinite(confidence)) {
      fallbacks.push('confidence');
      confidence = 0;
    }
    if (confidence > 1 && confidence <= 100) confidence = confidence / 100; // 퍼센트로 답한 경우
    confidence = Math.max(0, Math.min(1, confidence));

    let options: InterventionOption[];
    let onDecline: Effect;
    if (momentType === 'next_turn') {
      const userTexts = body.conversation.filter((c) => c.role === 'user').map((c) => c.text);
      const r = nextTurnOptions(out as NextOut, userTexts, fallbacks);
      options = r.options;
      if (r.firstDropped) promptText = def.prompt; // 질문이 가리키던 행동이 빠졌으니 질문도 기본값으로
      onDecline = { kind: 'none' };
    } else {
      const o = out as z.infer<typeof outputSchema>;
      const s = shape(momentType);
      const label1 = checkText(o.accept1Label, 1, 6) ?? (fallbacks.push('accept1Label'), def.accept1);
      options = [{ id: 'accept1', label: label1, effect: s.accept1 }];
      if (s.accept2) {
        const label2Default = 'accept2' in def ? def.accept2 : def.accept1;
        const label2 = checkText(o.accept2Label, 1, 6) ?? (fallbacks.push('accept2Label'), label2Default);
        options.push({ id: 'accept2', label: label2, effect: s.accept2 });
      }
      onDecline = s.onDecline;
    }

    const evidence = (Array.isArray(out.evidence) ? out.evidence : []).map((e) => String(e).trim()).filter(Boolean).slice(0, 5);
    const response: InferResult = {
      intentHypothesis: out.intentHypothesis?.trim() || '',
      confidence: Math.round(confidence * 100) / 100,
      evidence: evidence.length ? evidence : body.signalsSummary.slice(0, 3),
      rationale: out.rationale?.trim() || '',
      intervention: { prompt: promptText, evidenceLine, options, onDecline },
      latencyMs,
      model: result.response?.modelId ?? MODEL,
    };

    if (fallbacks.length) {
      slog.warn('infer', `추론 문구 검증 실패, 기본값으로 대체: ${fallbacks.join(', ')}`, {
        raw: { prompt: out.prompt, evidenceLine: out.evidenceLine, confidence: out.confidence, rest: 'options' in out ? out.options : { accept1Label: out.accept1Label, accept2Label: out.accept2Label } },
      });
    }
    if (latencyMs > 5000) slog.warn('infer', `추론 ${latencyMs}ms: 5초 초과`);
    slog.info('infer', `추론 완료 (${latencyMs}ms): ${body.momentType} 확신도 ${response.confidence}`, {
      intent: response.intentHypothesis, prompt: promptText, options: options.map((o) => `${o.label}:${o.effect.kind}`), fallbacks, warnings: result.warnings?.length ?? 0,
    });
    return Response.json(response);
  } catch (e) {
    const latencyMs = Date.now() - t0;
    const err = e as { statusCode?: number; message?: string };
    slog.error('infer', `추론 실패 (${latencyMs}ms): ${err?.message?.slice(0, 300) ?? String(e)}`, { status: err?.statusCode });
    return Response.json({ error: 'inference failed', message: err?.message?.slice(0, 300) }, { status: 502 });
  }
}
