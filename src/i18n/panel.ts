// panel 모듈 UI 문구. 이 파일은 해당 모듈 담당만 수정한다. 영어 전환 시 en/panel.ts를 같은 키로 추가.
export const panel = {
  title: 'poin 로그',
  pause: '일시정지',
  resume: '재개',
  pausedBadge: '일시정지됨',
  export: '내보내기',
  collapse: '` 접기',
  collapsedPill: 'poin 로그 · `',

  // 실시간 계기판
  gauge: {
    typing: '타이핑',
    pause: '정지',
    deleteBurst: '삭제 버스트',
    focusIdle: '포커스 대기',
    cursor: '커서',
    dwell: '체류',
    oscillation: '왕복',
    scrollReverse: '스크롤 역주행',
    cpm: (n: number) => `${n} 타/분`,
    sec: (ms: number) => `${(ms / 1000).toFixed(1)}초`,
    times: (n: number) => `${n}회`,
    none: '없음',
  },
  target: {
    input: '입력창',
    mission: '미션 카드',
    checkout: '결제 버튼',
    message: '에이전트 응답',
    para: (i: number) => `응답 ${i + 1}번째 문단`,
  },

  // 감지 모드
  sense: {
    head: '머리 상하 · 좌우',
    nod: '끄덕',
    shake: '젓기',
    brow: '찌푸림',
    gaze: '시선',
    fps: 'fps',
    noFace: '얼굴을 찾는 중',
    denied: '카메라 권한이 거부되어 감지 모드를 쓸 수 없어요.',
    error: '감지 모드를 시작하지 못했어요. 시스템 로그를 확인해 주세요.',
    gazeRegion: {
      left: '왼쪽',
      center: '가운데',
      right: '오른쪽',
      up: '위쪽',
      down: '아래쪽',
      unknown: '모름',
    },
  },

  // 순간 트레이스
  traces: {
    label: '순간 트레이스',
    empty1: '아직 포착된 순간이 없어요.',
    empty2: '신호는 계속 모으고 있어요.',
    rowSignal: '신호',
    rowMoment: '순간',
    rowInfer: '추론',
    rowIntervene: '개입',
    rowReaction: '반응',
    rowOutcome: '결과',
    inferring: '추론 중…',
    confidence: '확신도',
    ms: (n: number) => `${n}ms`,
    shown: '표시함',
    nearCursor: '커서 옆',
    notShown: '개입 안 함',
    error: '오류',
    waiting: '기다리는 중',
    remaining: (s: number) => `${s}초 남음`,
    after: (ms: number) => `${(ms / 1000).toFixed(1)}초 만에`,
    noSignals: '표시할 신호 없음 (필터)',
  },
  moment: {
    ambiguous_request: '요구 모호',
    comparison_hesitation: '비교 망설임',
    pre_decision: '결정 직전 머뭇',
  },
  via: {
    alt1: (label?: string) => `⌥1 ${label ?? '수락'}`,
    alt2: (label?: string) => `⌥2 ${label ?? '수락'}`,
    click1: (label?: string) => `클릭 · ${label ?? '수락'}`,
    click2: (label?: string) => `클릭 · ${label ?? '수락'}`,
    nod: '끄덕 → 수락',
    shake: '젓기 → 거절',
    esc: 'Esc → 거절',
    click_decline: '클릭 → 거절',
    timeout: (sec: number) => `${sec}초 무응답`,
  },

  // 신호 스트림 · 시스템 로그
  stream: {
    label: '신호 스트림',
    empty: '아직 신호가 없어요.',
    count: (n: number) => `최근 ${n}개`,
  },
  system: {
    label: '시스템 로그',
    empty: '경고나 오류가 없어요.',
    count: (n: number) => `${n}건`,
  },
  toggleOpen: '펼치기',
  toggleClose: '접기',

  // 컨트롤
  ctrl: {
    threshold: '확신도 임계',
    dwell: '체류',
    pause: '정지',
    resetCooldown: '쿨다운 초기화',
    endSession: '세션 끝내기',
  },
  filter: {
    verbal: '언어',
    paraverbal: '반언어',
    cursor: '커서',
    sense: '카메라',
    system: '시스템',
  },

  // 회고
  retro: {
    kicker: (dur: string) => `poin 세션 회고 · ${dur}`,
    duration: (ms: number) => {
      const s = Math.max(0, Math.round(ms / 1000));
      const m = Math.floor(s / 60);
      return m > 0 ? `${m}분 ${s % 60}초` : `${s}초`;
    },
    titleA: 'poin이 ',
    titleB: '의 순간을 알아챘고,',
    titleC: '그중 ',
    titleD: '을 받아들이셨어요',
    times: (n: number) => `${n}번`,
    titleEmpty: '이번 세션에서는 poin이 조용히 지켜보기만 했어요',
    sub: (shown: number, low: number) =>
      low > 0 ? `개입은 ${shown}번, ${low}번은 확신이 낮아 조용히 지나갔어요.` : `개입은 ${shown}번이었어요.`,
    subOther: (n: number) => ` 다른 ${n}번은 쿨다운·한도·오류로 건너뛰었어요.`,
    subEmpty: '신호는 모았지만 개입할 만한 순간은 없었어요.',
    notShown: '개입 안 함',
    noReaction: '반응 없음',
    inferring: '추론 중 종료',
    legendAccept: '● 수락',
    legendDecline: '○ 거절',
    legendNone: '◌ 개입 안 함 · 무응답',
    export: '세션 JSON 내보내기',
    newSession: '새 세션 시작',
  },
} as const;
