// AI SDK v7 x Claude 5.5 호환 스파이크. 실행: node --env-file=.env.local scripts/spike-models.mjs
import { anthropic } from '@ai-sdk/anthropic';
import { streamText, generateText, Output, isStepCount } from 'ai';
import { z } from 'zod';

async function agentSpike() {
  const t0 = Date.now();
  const result = streamText({
    model: anthropic('claude-sonnet-5-5'),
    system: '너는 쇼핑 도우미다. 반드시 search_catalog 도구를 한 번 쓰고 한 문장으로 답하라.',
    prompt: '집들이 선물 추천해 줘',
    tools: {
      search_catalog: {
        description: '카탈로그 검색',
        inputSchema: z.object({ query: z.string() }),
        execute: async ({ query }) => [{ id: 'p1', name: '소이 캔들', price: 32000, query }],
      },
    },
    stopWhen: isStepCount(3),
    providerOptions: { anthropic: { fallbacks: 'default', effort: 'low' } },
  });
  let text = '';
  for await (const chunk of result.textStream) text += chunk;
  const steps = await result.steps;
  const calls = steps.flatMap((s) => s.toolCalls.map((c) => c.toolName));
  console.log('[agent] PASS', { ms: Date.now() - t0, toolCalls: calls, text: text.slice(0, 80), warnings: (await result.warnings)?.length ?? 0 });
}

async function inferSpike(run) {
  const t0 = Date.now();
  const { output, warnings } = await generateText({
    model: anthropic('claude-haiku-5-5'),
    system: '너는 사용자의 망설임을 해석한다. 한국어로.',
    prompt: '신호: 첫 메시지를 3번 썼다 지움, 전송 전 6초 정지. 대화: 없음.',
    output: Output.object({
      schema: z.object({
        intentHypothesis: z.string(),
        confidence: z.number(),
        rationale: z.string(),
        prompt: z.string(),
      }),
    }),
    providerOptions: { anthropic: { thinking: { type: 'disabled' }, effort: 'low' } },
  });
  console.log(`[infer#${run}] PASS`, { ms: Date.now() - t0, conf: output.confidence, prompt: output.prompt, warnings: warnings?.length ?? 0 });
}

try { await agentSpike(); } catch (e) { console.log('[agent] FAIL', e?.statusCode, e?.message?.slice(0, 300)); }
for (let i = 1; i <= 3; i++) {
  try { await inferSpike(i); } catch (e) { console.log(`[infer#${i}] FAIL`, e?.statusCode, e?.message?.slice(0, 300)); }
}
