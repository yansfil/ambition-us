// poin 공용 계약. 모듈 간 주고받는 모든 데이터 모양은 여기서만 정의한다.

export type SignalKind = 'verbal' | 'paraverbal' | 'cursor' | 'sense';

/**
 * type 목록 (data 모양은 주석 기준)
 * verbal:     message_sent {text} | draft_snapshot {text, deleted?: string}
 * paraverbal: typing {cpm} | delete_burst {count, deletedText} | pause_before_send {ms}
 *             | focus_idle {ms} | compose_abandon {text}
 * cursor:     hover {target, ms} | dwell {target, ms, visits} | oscillation {a, b, count}
 *             | scroll_reverse {count} | select {text, target} | copy {text}
 * sense:      nod {confidence} | shake {confidence} | brow {value} | gaze {region}
 */
export interface Signal {
  id: string;
  t: number; // performance.now() 기준이 아니라 Date.now()
  kind: SignalKind;
  type: string;
  data: Record<string, unknown>;
}

export type MomentType = 'ambiguous_request' | 'comparison_hesitation' | 'pre_decision' | 'next_turn';

export interface MomentCandidate {
  id: string;
  t: number;
  type: MomentType;
  rule: string; // 사람이 읽는 룰 설명, 예: "삭제 반복 + 장시간 정지"
  signals: Signal[]; // 판단에 쓴 신호
  signalsSummary: string[]; // 패널과 LLM에 보낼 한 줄 요약들
  anchor: { x: number; y: number }; // 감지 시점 커서 위치
  context?: { productIds?: string[]; messageId?: string };
}

/** 개입 결과가 "다음 턴"을 어떻게 바꾸는지 */
export type Effect =
  | { kind: 'fill_draft'; text: string } // 사용자 입력창 초안을 채움
  | { kind: 'agent_turn'; directive: string; markText: string } // 지금 바로 poin 턴을 보내 에이전트 응답을 바꿈
  | { kind: 'none' };

export type ChoiceId = 'accept1' | 'accept2';

export interface InterventionOption {
  id: ChoiceId;
  label: string; // 칩 버튼 문구, 예: "표로 요약"
  effect: Effect;
}

export interface InferRequest {
  momentType: MomentType;
  rule: string;
  signalsSummary: string[];
  conversation: ChatTurn[]; // 최근 대화 (최대 8턴)
  productContext?: string[]; // 화면에 있는 상품 요약 한 줄들
}

export interface InferResult {
  intentHypothesis: string;
  confidence: number; // 0..1
  evidence: string[]; // 근거로 쓴 신호 요약
  rationale: string; // 한두 문장
  intervention: {
    prompt: string; // 칩 질문
    evidenceLine: string; // 칩 상단 근거 한 줄, 예: "보내기 전에 잠시 멈추셨어요"
    options: InterventionOption[]; // 1~2개
    onDecline: Effect;
  };
  latencyMs: number;
  model: string;
}

export type ReactionVia =
  | 'alt1' | 'alt2' | 'click1' | 'click2' | 'nod'
  | 'esc' | 'click_decline' | 'shake'
  | 'timeout';

export interface Reaction {
  t: number;
  via: ReactionVia;
  choice: ChoiceId | 'decline' | 'ignore';
  afterMs: number; // 칩 표시 후 반응까지
}

export interface Trace {
  id: string;
  moment: MomentCandidate;
  status: 'inferring' | 'skipped' | 'shown' | 'resolved' | 'error';
  infer?: InferResult;
  error?: string;
  skipReason?: string; // 예: "확신도 0.41 < 0.60", "쿨다운", "세션 한도 4회"
  shown: boolean;
  reaction?: Reaction;
  outcome?: { effect: Effect; description: string; turnSummary?: string };
}

export interface ActiveChip {
  traceId: string;
  momentType: MomentType;
  prompt: string;
  evidenceLine: string;
  options: InterventionOption[];
  onDecline: Effect;
  anchor: { x: number; y: number }; // 칩이 고정되는 위치(표시 순간의 커서)
  shownAt: number;
  timeoutMs: number;
}

export interface ChatTurn {
  role: 'user' | 'assistant' | 'poin';
  text: string;
}

export interface PoinSettings {
  threshold: number; // 확신도 임계값
  dwellMs: number; // 체류 판정 기준
  pauseMs: number; // 정지 판정 기준
  cooldownMs: number; // 같은 순간 재발 쿨다운
  maxInterventions: number; // 세션당 개입 최대
  chipTimeoutMs: number; // 무응답 자동 소멸
  filters: Record<SignalKind | 'system', boolean>; // 패널 표시 필터
  paused: boolean; // 감지 일시정지
}

export type SenseStatus = 'off' | 'starting' | 'on' | 'denied' | 'error';
