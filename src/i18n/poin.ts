// poin 모듈 UI 문구. 이 파일은 해당 모듈 담당만 수정한다. 영어 전환 시 en/poin.ts를 같은 키로 추가.
export const poin = {
  brand: 'poin',
  kbd: { accept1: '⌥1', accept2: '⌥2', decline: 'Esc' },
  senseHint: '끄덕 ↕ · 젓기 ↔',
  declineLabel: {
    ambiguous_request: '괜찮아요',
    comparison_hesitation: '괜찮아요',
    pre_decision: '아니요',
    next_turn: '괜찮아요',
  },
  momentName: {
    ambiguous_request: '요구 모호',
    comparison_hesitation: '비교 망설임',
    pre_decision: '결정 직전 머뭇',
    next_turn: '다음 턴 제안',
  },

  /** 커서 타깃의 사람이 읽는 이름(data-poin-label이 없을 때) */
  target: {
    input: '입력창',
    mission: '미션 카드',
    checkout: '결제 버튼',
    message: '응답',
    product: '상품 카드',
    add: '담기 버튼',
    paragraph: (i: number) => `응답 ${i + 1}번째 문단`,
  },

  /** 게이트·임계 미달 사유(Trace.skipReason) */
  skip: {
    paused: '일시정지',
    sessionEnded: '세션 종료',
    chipShown: '칩이 이미 떠 있음',
    inferring: '다른 순간 추론 중',
    limit: (n: number) => `세션 한도 ${n}회`,
    cooldown: (sec: number) => `쿨다운 ${sec}초 남음`,
    chatBusy: '응답 생성 중',
    lowConfidence: (c: number, th: number) => `확신도 ${c.toFixed(2)} < ${th.toFixed(2)}`,
  },

  /** 결과 설명(Trace.outcome.description) */
  outcome: {
    agentTurn: (what: string) => `에이전트에 지시 추가: ${what}`,
    fillDraft: (text: string) => `입력창 초안 채움: ${text}`,
    none: '그대로 둠',
    timeout: '무응답, 그대로 둠',
    summary: {
      ambiguous_request: { accept1: '추천 전에 두 가지 먼저 질문', accept2: '추천 전에 두 가지 먼저 질문', decline: '' },
      comparison_hesitation: { accept1: '직전 추천을 표로 요약', accept2: '사진 카드로 다시 보여 주기', decline: '' },
      pre_decision: { accept1: '가격 대비 가치와 반품 정책 답변', accept2: '가격 대비 가치와 반품 정책 답변', decline: '더 저렴한 대안 2개 제시' },
      // 다음 턴 제안은 LLM이 고른 행동이라 고정 요약 없이 markText를 쓴다
      next_turn: { accept1: '', accept2: '', decline: '' },
    },
  },

  /** 추론 결과가 형태 검증을 통과하지 못할 때 쓰는 기본 문구(서버도 사용) */
  defaults: {
    ambiguous_request: {
      prompt: '먼저 두 가지만 짧게 여쭤볼까요?',
      evidenceLine: '보내기 전에 잠시 멈추셨어요',
      accept1: '좋아요',
      accept1Mark: 'poin이 추천 전에 두 가지만 먼저 묻게 했어요',
    },
    comparison_hesitation: {
      prompt: '한눈에 보기 쉽게 정리해 드릴까요?',
      evidenceLine: '같은 문단을 몇 번 다시 읽으셨어요',
      accept1: '표로 요약',
      accept2: '사진과 함께',
      accept1Mark: 'poin이 추천을 표로 정리하게 했어요',
      accept2Mark: 'poin이 사진 카드로 다시 보여 주게 했어요',
    },
    pre_decision: {
      prompt: '가격이나 반품이 마음에 걸리세요?',
      evidenceLine: '담기 앞에서 머뭇거리셨어요',
      accept1: '네',
      accept1Mark: 'poin이 가격과 반품부터 답하게 했어요',
      declineMark: 'poin이 더 저렴한 대안을 보여 주게 했어요',
    },
    next_turn: {
      prompt: '다음 할 일을 하나 제안해 드릴까요?',
      evidenceLine: '답을 보고 잠시 멈추셨어요',
      accept1: '좋아요',
      agentMark: 'poin이 다음 할 일을 제안하게 했어요',
      agentMarkWith: (label: string) => `poin 제안: ${label}`, // 라벨 끝 받침에 따라 조사가 바뀌어 조사 없이
    },
  },
} as const;
