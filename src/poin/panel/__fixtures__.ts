'use client';
// 패널·회고 시각 확인용 가짜 데이터 (시안 v4의 4개 순간을 재현). 개발 전용, 프로덕션 코드에서 import 금지.
//
// 사용법 (브라우저 콘솔이 아니라 아무 클라이언트 컴포넌트에서 임시로):
//   import { loadPanelFixtures } from '@/poin/panel/__fixtures__';
//   useEffect(() => loadPanelFixtures({ sense: true, end: false }), []);
// 또는 installPanelFixtures() 후 콘솔에서 __poinPanel.load({ end: true }) / __poinPanel.stopLive()
import { log } from '@/lib/log';
import { live } from '@/poin/live';
import { usePoin } from '@/poin/store';
import type { InferResult, MomentCandidate, Signal, SignalKind, Trace } from '@/poin/types';

let n = 0;
const id = (p: string) => `${p}_fx_${(n++).toString(36)}`;

function sig(t: number, kind: SignalKind, type: string, data: Record<string, unknown>): Signal {
  return { id: id('sig'), t, kind, type, data };
}

function infer(p: Partial<InferResult> & Pick<InferResult, 'intentHypothesis' | 'confidence'>): InferResult {
  return {
    evidence: [],
    rationale: '',
    intervention: { prompt: '', evidenceLine: '', options: [], onDecline: { kind: 'none' } },
    latencyMs: 620,
    model: 'claude-haiku-5-5',
    ...p,
  };
}

function moment(t: number, type: MomentCandidate['type'], rule: string, signals: Signal[], signalsSummary: string[]): MomentCandidate {
  return { id: id('mom'), t, type, rule, signals, signalsSummary, anchor: { x: 640, y: 488 } };
}

/** 세션 시작 시각 기준 가짜 traces (최신이 앞) */
export function makeFakeTraces(startedAt: number): Trace[] {
  const at = (s: number) => startedAt + s * 1000;

  const m1Signals = [
    sig(at(10), 'paraverbal', 'delete_burst', { count: 3, deletedText: '인테리어 소품' }),
    sig(at(12), 'paraverbal', 'pause_before_send', { ms: 6200 }),
  ];
  const t1: Trace = {
    id: id('tr'),
    moment: moment(at(12), 'ambiguous_request', '삭제 반복 + 장시간 정지', m1Signals, ['초안 썼다 지움 3회 · 지운 말 "인테리어 소품"', '전송 전 정지 6.2초']),
    status: 'resolved',
    shown: true,
    infer: infer({
      intentHypothesis: '선물 기준이 아직 안 정해짐',
      confidence: 0.78,
      latencyMs: 640,
      intervention: {
        prompt: '먼저 두 가지만 짧게 여쭤볼까요?',
        evidenceLine: '보내기 전에 잠시 멈추셨어요',
        options: [{ id: 'accept1', label: '좋아요', effect: { kind: 'agent_turn', directive: '예산과 취향을 두 질문으로 먼저 물을 것', markText: 'poin이 두 가지 질문을 먼저 하도록 넣었어요' } }],
        onDecline: { kind: 'none' },
      },
    }),
    reaction: { t: at(15), via: 'alt1', choice: 'accept1', afterMs: 2400 },
    outcome: { effect: { kind: 'agent_turn', directive: '', markText: '' }, description: '에이전트에 지시 추가: 예산·취향 두 질문 먼저', turnSummary: '에이전트가 예산과 분위기를 먼저 물음' },
  };

  const m2Signals = [
    sig(at(60), 'cursor', 'oscillation', { a: 'para:m2:1', b: 'para:m2:3', count: 4 }),
    sig(at(62), 'cursor', 'scroll_reverse', { count: 2 }),
    sig(at(64), 'cursor', 'select', { text: '78,000원', target: 'para:m2:3' }),
    sig(at(65), 'paraverbal', 'focus_idle', { ms: 9000 }),
  ];
  const t2: Trace = {
    id: id('tr'),
    moment: moment(at(65), 'comparison_hesitation', '긴 응답 다시 읽기 + 가격 선택', m2Signals, ['1·3번째 문단 왕복 4회', '스크롤 역주행 2회', '"78,000원" 선택', '입력 없음 9초']),
    status: 'resolved',
    shown: true,
    infer: infer({
      intentHypothesis: '글로는 세 개를 비교하기 어려움',
      confidence: 0.74,
      latencyMs: 590,
      intervention: {
        prompt: '한눈에 보기 쉽게 정리해 드릴까요?',
        evidenceLine: '같은 문단을 몇 번 다시 읽으셨어요',
        options: [
          { id: 'accept1', label: '표로 요약', effect: { kind: 'agent_turn', directive: '표로 요약', markText: '' } },
          { id: 'accept2', label: '사진과 함께', effect: { kind: 'agent_turn', directive: '사진 카드로', markText: '' } },
        ],
        onDecline: { kind: 'none' },
      },
    }),
    reaction: { t: at(67), via: 'alt2', choice: 'accept2', afterMs: 1800 },
    outcome: { effect: { kind: 'agent_turn', directive: '', markText: '' }, description: '에이전트에 지시 추가: "세 상품을 사진 카드로 다시 보여 주고 한 줄로 요약할 것"', turnSummary: '다음 응답이 카드로 바뀜' },
  };

  const m3Signals = [
    sig(at(98), 'cursor', 'dwell', { target: 'add:p3', ms: 2800, visits: 2 }),
    sig(at(99), 'sense', 'brow', { value: 0.46 }),
    sig(at(100), 'sense', 'gaze', { region: 'down' }),
  ];
  const t3: Trace = {
    id: id('tr'),
    moment: moment(at(100), 'pre_decision', '담기 앞 정지 + 찌푸림', m3Signals, ['담기 버튼 근처 정지 2.8초', '찌푸림 0.46', '시선 가격 영역']),
    status: 'resolved',
    shown: true,
    infer: infer({
      intentHypothesis: '예산을 거의 다 쓰는 게 걱정',
      confidence: 0.66,
      latencyMs: 610,
      intervention: {
        prompt: '가격이나 반품이 마음에 걸리세요?',
        evidenceLine: '담기 앞에서 머뭇거리셨어요',
        options: [{ id: 'accept1', label: '네', effect: { kind: 'agent_turn', directive: '가격·반품 우려에 답할 것', markText: '' } }],
        onDecline: { kind: 'agent_turn', directive: '5만 원 이하 대안 제시', markText: '' },
      },
    }),
    reaction: { t: at(102), via: 'shake', choice: 'decline', afterMs: 2100 },
    outcome: { effect: { kind: 'agent_turn', directive: '', markText: '' }, description: '에이전트에 지시 추가: 5만 원 이하 대안 제시' },
  };

  const t4: Trace = {
    id: id('tr'),
    moment: moment(at(130), 'comparison_hesitation', '상품 카드 왕복', [sig(at(129), 'cursor', 'oscillation', { a: 'product:p1', b: 'product:p2', count: 3 })], ['상품 카드 왕복 3회']),
    status: 'skipped',
    shown: false,
    infer: infer({ intentHypothesis: '두 상품 사이에서 고민', confidence: 0.41, latencyMs: 2300 }),
    skipReason: '확신도 0.41 < 0.60',
  };

  const t5: Trace = {
    id: id('tr'),
    moment: moment(at(150), 'pre_decision', '결제 버튼 앞 정지', [sig(at(149), 'cursor', 'dwell', { target: 'checkout', ms: 3100, visits: 1 })], ['결제 버튼 근처 정지 3.1초']),
    status: 'inferring',
    shown: false,
  };

  return [t5, t4, t3, t2, t1];
}

/** 가짜 신호 스트림 (시간순) */
export function makeFakeSignals(startedAt: number): Signal[] {
  const out: Signal[] = [];
  const kinds: [SignalKind, string, Record<string, unknown>][] = [
    ['paraverbal', 'typing', { cpm: 64 }],
    ['verbal', 'draft_snapshot', { text: '집들이 선물로 뭐가 좋', deleted: '인테리어 소품' }],
    ['cursor', 'hover', { target: 'mission', ms: 800 }],
    ['cursor', 'dwell', { target: 'product:p3', ms: 2100, visits: 2 }],
    ['sense', 'nod', { confidence: 0.82 }],
    ['verbal', 'message_sent', { text: '향이나 분위기 있는 거, 실용적이면 더 좋고요' }],
    ['cursor', 'scroll_reverse', { count: 2 }],
  ];
  for (let i = 0; i < 45; i++) {
    const [kind, type, data] = kinds[i % kinds.length];
    out.push(sig(startedAt + i * 3500, kind, type, data));
  }
  return out;
}

let liveTimer: number | null = null;

/** live 계기판 값을 흔들어 본다 (100ms 샘플링 확인용) */
export function startFakeLive(sense = false) {
  stopFakeLive();
  let k = 0;
  liveTimer = window.setInterval(() => {
    k++;
    live.typingCpm = 40 + Math.round(30 * Math.abs(Math.sin(k / 20)));
    live.pauseMs = (k * 100) % 7000;
    live.deleteBursts = Math.floor(k / 40) % 4;
    live.focusIdleMs = (k * 100) % 9000;
    live.cursorTarget = k % 60 < 30 ? 'input' : 'para:m2:2';
    live.cursorTargetLabel = null;
    live.dwellMs = (k * 100) % 8000;
    live.oscillations = Math.floor(k / 30) % 5;
    live.scrollReversals = Math.floor(k / 50) % 3;
    if (sense) {
      const s = live.sense;
      s.fps = 24 + (k % 5);
      s.pitch = 12 * Math.sin(k / 3);
      s.yaw = 18 * Math.sin(k / 5);
      s.pitchHistory = [...s.pitchHistory.slice(-89), s.pitch];
      s.yawHistory = [...s.yawHistory.slice(-89), s.yaw];
      s.brow = 0.3 + 0.2 * Math.abs(Math.sin(k / 15));
      s.faceFound = true;
      s.gaze = 'down';
      if (k % 40 === 0) {
        s.gesture = k % 80 === 0 ? 'nod' : 'shake';
        s.gestureAt = Date.now();
      }
    }
  }, 50);
}

export function stopFakeLive() {
  if (liveTimer !== null) window.clearInterval(liveTimer);
  liveTimer = null;
}

/** 스토어에 가짜 데이터를 넣는다. end:true면 회고까지 띄운다. */
export function loadPanelFixtures(opts: { sense?: boolean; end?: boolean; live?: boolean } = {}) {
  const startedAt = Date.now() - 192_000; // 3분 12초 전 시작
  usePoin.setState({
    startedAt,
    traces: makeFakeTraces(startedAt),
    signals: makeFakeSignals(startedAt),
    interventionsShown: 3,
    senseStatus: opts.sense ? 'on' : usePoin.getState().senseStatus,
    sessionEnded: !!opts.end,
  });
  if (opts.live !== false) startFakeLive(!!opts.sense);
  log.warn('perf', '[fixture] 감지 fps < 10 경고 예시', { fps: 8 });
  log.error('infer', '[fixture] 추론 실패 예시', { status: 529, message: 'overloaded' });
}

export function installPanelFixtures() {
  (window as unknown as Record<string, unknown>).__poinPanel = {
    load: loadPanelFixtures,
    startLive: startFakeLive,
    stopLive: stopFakeLive,
  };
}
