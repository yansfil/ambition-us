// 채팅 에이전트 모델 설정. 모델 전환은 이 파일 한 곳에서만 한다.
// POIN_AGENT_MODEL=haiku|sonnet (기본 haiku). 샘플링 파라미터는 넣지 말 것(400).
import type { streamText } from 'ai';

type ProviderOptions = NonNullable<Parameters<typeof streamText>[0]['providerOptions']>;

export type AgentModelKey = 'haiku' | 'sonnet';

export const AGENT_MODELS: Record<AgentModelKey, { id: string; providerOptions: ProviderOptions }> = {
  // Haiku 5.5는 server-side fallbacks를 지원하지 않는다.
  haiku: { id: 'claude-haiku-5-5', providerOptions: { anthropic: { effort: 'low' } } },
  // 예비: Haiku 품질이 부족할 때 전환
  sonnet: {
    id: 'claude-sonnet-5-5',
    providerOptions: { anthropic: { fallbacks: 'default', effort: 'low', thinking: { type: 'between_tools' } } },
  },
};

export function agentModel() {
  const raw = (process.env.POIN_AGENT_MODEL ?? 'haiku').toLowerCase();
  const key: AgentModelKey = raw === 'sonnet' ? 'sonnet' : 'haiku';
  return { key, unknownEnv: raw !== 'sonnet' && raw !== 'haiku' ? raw : undefined, ...AGENT_MODELS[key] };
}

/** 캐시 브레이크포인트. 캐시 프리픽스(도구 → 시스템)에는 가변 값을 넣지 않는다. */
export const CACHE = { anthropic: { cacheControl: { type: 'ephemeral' as const } } };
