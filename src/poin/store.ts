'use client';
// poin 공용 상태. React에 보여야 하는 것만 여기 둔다.
// 초당 수십 번 바뀌는 계기판 값은 live.ts(비반응 객체)에 둔다.
import { create } from 'zustand';
import { log } from '@/lib/log';
import type {
  ActiveChip, ChatTurn, MomentType, PoinSettings, SenseStatus, Signal, Trace,
} from './types';

const SIGNAL_RING = 400;

export interface PoinState {
  sessionId: string;
  startedAt: number;
  settings: PoinSettings;
  signals: Signal[]; // 최신이 뒤
  traces: Trace[]; // 최신이 앞
  activeChip: ActiveChip | null;
  interventionsShown: number;
  cooldownUntil: Partial<Record<MomentType, number>>;
  senseEnabled: boolean;
  senseStatus: SenseStatus;
  chatContext: ChatTurn[];
  chatBusy: boolean;
  /** poin → 채팅: 입력창 초안 채우기 요청 */
  draftFill: { text: string; nonce: number; traceId: string } | null;
  /** poin → 채팅: 지금 바로 poin 턴 보내기 요청 */
  pendingTurn: { directive: string; markText: string; nonce: number; traceId: string } | null;
  sessionEnded: boolean;

  pushSignal: (s: Omit<Signal, 'id' | 't'> & { t?: number }) => Signal;
  addTrace: (t: Trace) => void;
  updateTrace: (id: string, patch: Partial<Trace>) => void;
  setActiveChip: (c: ActiveChip | null) => void;
  incInterventions: () => void;
  setCooldown: (m: MomentType, until: number) => void;
  resetCooldowns: () => void;
  setSettings: (p: Partial<PoinSettings>) => void;
  setSense: (p: { enabled?: boolean; status?: SenseStatus }) => void;
  setChatContext: (c: ChatTurn[]) => void;
  setChatBusy: (b: boolean) => void;
  requestDraftFill: (text: string, traceId: string) => void;
  requestTurn: (directive: string, markText: string, traceId: string) => void;
  consumeDraftFill: () => void;
  consumeTurn: () => void;
  endSession: () => void;
  resetSession: () => void;
}

const defaultSettings: PoinSettings = {
  threshold: 0.6,
  dwellMs: 1500,
  pauseMs: 4000,
  cooldownMs: 45_000,
  maxInterventions: 4,
  chipTimeoutMs: 8000,
  filters: { verbal: true, paraverbal: true, cursor: true, sense: true, system: true },
  paused: false,
};

let seq = 0;
export const uid = (p: string) => `${p}_${Date.now().toString(36)}_${(seq++).toString(36)}`;

const fresh = () => ({
  sessionId: uid('sess'),
  startedAt: Date.now(),
  signals: [] as Signal[],
  traces: [] as Trace[],
  activeChip: null,
  interventionsShown: 0,
  cooldownUntil: {},
  chatContext: [] as ChatTurn[],
  chatBusy: false,
  draftFill: null,
  pendingTurn: null,
  sessionEnded: false,
});

export const usePoin = create<PoinState>((set, get) => ({
  ...fresh(),
  settings: defaultSettings,
  senseEnabled: false,
  senseStatus: 'off',

  pushSignal: (s) => {
    const sig: Signal = { id: uid('sig'), t: s.t ?? Date.now(), kind: s.kind, type: s.type, data: s.data };
    if (get().settings.paused) return sig;
    set((st) => {
      const next = st.signals.length >= SIGNAL_RING ? st.signals.slice(-SIGNAL_RING + 1) : st.signals.slice();
      next.push(sig);
      return { signals: next };
    });
    log.debug('signal', `${sig.kind}.${sig.type}`, sig.data);
    return sig;
  },
  addTrace: (t) => set((st) => ({ traces: [t, ...st.traces] })),
  updateTrace: (id, patch) =>
    set((st) => ({ traces: st.traces.map((t) => (t.id === id ? { ...t, ...patch } : t)) })),
  setActiveChip: (c) => {
    const prev = get().activeChip;
    if (c && prev) log.warn('chip', '이미 칩이 떠 있는데 새 칩을 띄우려 함', { prev: prev.traceId, next: c.traceId });
    set({ activeChip: c });
  },
  incInterventions: () => set((st) => ({ interventionsShown: st.interventionsShown + 1 })),
  setCooldown: (m, until) => set((st) => ({ cooldownUntil: { ...st.cooldownUntil, [m]: until } })),
  resetCooldowns: () => {
    log.info('control', '쿨다운 초기화');
    set({ cooldownUntil: {}, interventionsShown: 0 });
  },
  setSettings: (p) => {
    log.info('control', '설정 변경', p);
    set((st) => ({ settings: { ...st.settings, ...p } }));
  },
  setSense: (p) =>
    set((st) => ({
      senseEnabled: p.enabled ?? st.senseEnabled,
      senseStatus: p.status ?? st.senseStatus,
    })),
  setChatContext: (c) => set({ chatContext: c }),
  setChatBusy: (b) => set({ chatBusy: b }),
  requestDraftFill: (text, traceId) => set({ draftFill: { text, nonce: Date.now(), traceId } }),
  requestTurn: (directive, markText, traceId) =>
    set({ pendingTurn: { directive, markText, nonce: Date.now(), traceId } }),
  consumeDraftFill: () => set({ draftFill: null }),
  consumeTurn: () => set({ pendingTurn: null }),
  endSession: () => {
    log.info('session', '세션 종료', { traces: get().traces.length });
    set({ sessionEnded: true, activeChip: null });
  },
  resetSession: () => {
    log.info('session', '새 세션 시작');
    set({ ...fresh() });
  },
}));

/** 비 React 코드(신호 수집기, 감지 루프)에서 쓰는 단축 접근 */
export const poin = () => usePoin.getState();
