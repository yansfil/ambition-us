# poin 데모: 모듈 계약

모듈 4개(A 채팅, B poin 엔진, C 패널·회고, D 감지 모드)가 병렬로 구현된다. 서로의 파일은 수정하지 않고, 아래 계약으로만 만난다. 시각 기준은 `design/board.html`(시안 v4)이다.

## 공용 파일 (오케스트레이터 소유, 수정 금지)

| 파일 | 내용 |
|---|---|
| `src/poin/types.ts` | Signal, MomentCandidate, InferRequest/Result, Effect, Trace, ActiveChip, PoinSettings |
| `src/poin/store.ts` | zustand 스토어 `usePoin`, 비 React 접근 `poin()`, `uid()` |
| `src/poin/live.ts` | 초당 수십 번 바뀌는 계기판 값(비반응 객체). React 상태에 넣지 말 것 |
| `src/lib/log.ts` / `src/lib/log-server.ts` | 클라이언트 `log.*`, 서버 `slog.*`. 둘 다 `logs/poin-YYYYMMDD.jsonl`로 모임 |
| `src/styles/poin.css` | 토큰과 프리미티브: `.poin-glass` `.poin-orb` `.poin-kbd` `.poin-heat` `.chat-glass` `.poin-pop` |
| `src/catalog/types.ts` | `Product` |
| `src/app/page.tsx`, `src/app/layout.tsx` | 통합 배치 |

## 진입 컴포넌트 (default export, props 없음)

- A: `src/components/chat/ChatApp.tsx`, `src/components/chat/CartPill.tsx`
- B: `src/poin/engine/PoinRuntime.tsx`(화면 없음: 신호 수집·순간 감지·추론·반응 처리 마운트), `src/poin/ui/Companion.tsx`, `src/poin/ui/Chip.tsx`
- C: `src/poin/panel/LogPanel.tsx`, `src/poin/panel/Retro.tsx`
- D: `src/poin/sense/SenseRunner.tsx`(화면 없음), `src/poin/sense/SenseToggle.tsx`, `src/poin/sense/CameraBadge.tsx`, `src/poin/sense/SenseThumb.tsx`(C의 패널이 import)

## 문구

UI 한글은 컴포넌트에 직접 쓰지 않는다. 모듈별 파일에만 추가: A `src/i18n/chat.ts`, B `src/i18n/poin.ts`, C `src/i18n/panel.ts`, D `src/i18n/sense.ts`. 사용은 `import { t } from '@/i18n'` 후 `t.chat.xxx`. LLM 프롬프트 문자열은 i18n 대상이 아니다.

## DOM 규약 (B의 커서 수집기가 읽음, A가 붙임)

| 요소 | 속성 |
|---|---|
| 입력창 textarea | `data-poin-target="input"` |
| 미션 카드 | `data-poin-target="mission"` |
| 에이전트 메시지 래퍼 | `data-poin-target="msg:{messageId}"` (안의 `p`, `li`, `tr`은 B가 문단 인덱스로 해석: `para:{messageId}:{index}`) |
| 상품 카드 | `data-poin-target="product:{productId}"` + `data-poin-label="상품 카드 · {상품명}"` |
| 담기 버튼 | `data-poin-target="add:{productId}"` + `data-poin-label="담기 · {상품명}"` |
| 결제 버튼 | `data-poin-target="checkout"` |
| 가격 텍스트 | `data-poin-price` (선택 신호에서 가격 선택을 구분) |
| poin 레이어 요소 전체 | `data-poin-layer` (커서 수집기가 무시) |

## 흐름

1. **신호**: B가 문서 전역 이벤트로 수집해 `poin().pushSignal()`. 단, 메시지 전송은 A가 `pushSignal({kind:'verbal', type:'message_sent', data:{text}})`로 알린다. D는 `nod`/`shake`/`brow`/`gaze`를 push하고 `live.sense`를 갱신한다.
2. **순간**: B의 momentDetector(룰)가 후보를 만들고 Trace(`status:'inferring'`)를 추가한다. 쿨다운·세션 한도·칩 중복·일시정지면 `skipped`로 남긴다(로그 포함).
3. **추론**: B가 `POST /api/poin/infer`(InferRequest → InferResult). 확신도 < `settings.threshold`면 `skipped`, `skipReason:"확신도 0.41 < 0.60"`. 룰 진행도 0.6 이상이면 같은 종류로 미리 호출(prefetch)해 두고, 확정 시 8초 이내 결과면 재사용한다(종류별 동시 1개, 분당 3회, 실패 시 평소 경로).
4. **칩**: B가 `setActiveChip`. 칩도 오브처럼 커서 오른쪽 아래(+16, +20)를 계속 따라다닌다. 화면 끝이면 위/왼쪽으로 뒤집기. 칩이 떠 있는 동안 오브는 칩 머리로 흡수된 것처럼 숨김. 칩은 `pointer-events:none`(클릭 반응 없음).
5. **반응**: 단축키와 제스처만. `⌥1`(e.code Digit1 + altKey), `⌥2`, `Esc`, D의 `nod`(=accept1)·`shake`(=decline), 8초 무응답(`timeout`). `e.isComposing`이면 무시, 처리 시 `preventDefault`. 입력창 포커스 중에도 동작.
6. **결과**: B가 Effect를 적용한다.
   - `fill_draft` → `requestDraftFill(text, traceId)` → A가 입력창에 채우고 포커스, `consumeDraftFill()`
   - `agent_turn` → `requestTurn(directive, markText, traceId)` → A가 즉시 poin 턴을 보낸다: `sendMessage({ text: directive, metadata: { poin: { markText, traceId } } })`. 이 메시지는 사용자 말풍선이 아니라 poin 표식(`.poin-glass` 알약, 시안 05)으로 그린다. 응답이 끝나면 A가 `updateTrace(traceId, { outcome: { ...기존, turnSummary } })`.
7. **세션 종료**: A가 결제(목) 성공 시 `endSession()` → C의 Retro 표시.

## 서버 API

- `POST /api/chat` (A): body `{ messages: UIMessage[] }`. 모델 `claude-sonnet-5-5`. poin 메타데이터가 붙은 메시지는 모델에 `[poin 레이어 지시] ...`로 전달.
- `POST /api/poin/infer` (B): InferRequest → InferResult. 모델 `claude-haiku-5-5`.
- `POST /api/log` (공용, 완성됨).

## AI SDK v7 확인된 사용법 (scripts/spike-models.mjs로 실측 PASS)

```ts
import { anthropic } from '@ai-sdk/anthropic';
import { streamText, generateText, Output, isStepCount, convertToModelMessages,
         createUIMessageStreamResponse, toUIMessageStream } from 'ai';
// 에이전트: streamText({ model: anthropic('claude-sonnet-5-5'), system, messages: await convertToModelMessages(messages),
//   tools: { name: { description, inputSchema: z.object(...), execute } }, stopWhen: isStepCount(5),
//   providerOptions: { anthropic: { fallbacks: 'default', effort: 'low' } } })
//   return createUIMessageStreamResponse({ stream: toUIMessageStream({ stream: result.stream }) })
// 추론: generateText({ model: anthropic('claude-haiku-5-5'), system, prompt, output: Output.object({ schema }),
//   providerOptions: { anthropic: { thinking: { type: 'disabled' }, effort: 'low' } } }) → { output }
```

- `temperature`/`top_p`/`top_k`는 보내지 말 것(2026-10-21부터 모든 모델 400).
- Sonnet 5.5는 강제 tool_choice가 400. 기본 auto만 쓴다.
- 실측 지연: 에이전트 도구 1회 포함 약 17초, Haiku 추론 2~3.3초. 칩 타이밍과 로딩 표시는 이걸 전제로.
- 문서: `node_modules/ai/docs/`, `node_modules/@ai-sdk/anthropic/docs/05-anthropic.mdx`. 학습 기억보다 이 문서를 믿을 것.
- Next.js 16이다. 낯선 동작은 `node_modules/next/dist/docs/` 확인.

## 로깅 규칙 (모든 모듈)

정상 흐름은 `info`, 이상 징후는 `warn`, 실패는 `error`로 남긴다. 사용자가 "지금 왜 칩이 안 떴지?"를 로그만 보고 답할 수 있어야 한다.

- 판단 분기마다 이유를 남긴다: 후보 생성/기각 이유, 임계 미달, 쿨다운, 한도, 일시정지
- 외부 호출은 `log.time`으로 지연을 남기고, 실패 시 상태 코드와 메시지를 남긴다
- 불변식 위반은 `warn`: 칩 중복, 세션 한도 초과 시도, 추론 5초 초과, 감지 fps < 10, 알 수 없는 신호 타입
- 개인 입력 원문은 로그에 남겨도 된다(로컬 데모). 단 카메라 영상·이미지는 절대 남기지 않는다(수치만)
