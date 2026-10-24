// 거절 적응(백오프). 순수 함수: scripts/test-detector.ts가 Node로 바로 불러 쓴다(런타임 import 금지).
import type { MomentType, Reaction } from '../types';

export const BACKOFF_STREAK = 2; // 같은 종류에서 연속 거절·무응답이 이만큼이면
export const BACKOFF_COOLDOWN_MS = 120_000; // 그 종류만 쿨다운을 이만큼으로

export type Streaks = Partial<Record<MomentType, number>>;

export interface BackoffResult {
  streaks: Streaks;
  streak: number;
  /** 백오프에 걸렸으면 새 쿨다운 끝 시각, 아니면 null */
  cooldownUntil: number | null;
}

/** 반응 하나를 반영한다. 수락이면 연속 카운트를 리셋, 거절·무응답이면 늘린다. */
export function applyReaction(streaks: Streaks, type: MomentType, choice: Reaction['choice'], now: number): BackoffResult {
  if (choice === 'accept1' || choice === 'accept2') {
    return { streaks: { ...streaks, [type]: 0 }, streak: 0, cooldownUntil: null };
  }
  const streak = (streaks[type] ?? 0) + 1;
  return {
    streaks: { ...streaks, [type]: streak },
    streak,
    cooldownUntil: streak >= BACKOFF_STREAK ? now + BACKOFF_COOLDOWN_MS : null,
  };
}
