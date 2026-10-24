// poin 엔진: 순간 후보 → 게이트 → 추론 → 칩 → 반응 → 결과(Effect).
// React 밖에서 돈다. PoinRuntime이 install/uninstall만 한다.
import { t } from '@/i18n';
import { log } from '@/lib/log';
import { live } from '../live';
import { detect, PREFETCH_PROGRESS, type RuleHit, type RulePartial } from '../moments/detector';
import { installCursorCollector } from '../signals/cursor';
import { installInputCollector } from '../signals/input';
import { collector } from '../signals/state';
import { onNewSignals } from '../signals/subscribe';
import { poin, uid, usePoin } from '../store';
import type {
  ActiveChip, ChoiceId, Effect, InferRequest, InferResult, MomentCandidate, MomentType, Reaction, ReactionVia, Trace,
} from '../types';
import { applyReaction, BACKOFF_COOLDOWN_MS, type Streaks } from './backoff';
import { multiProductInfo, productContext } from './context';

const TICK_MS = 500;
const INFER_TIMEOUT_MS = 8000;
const INFER_SLOW_MS = 5000;
const GESTURE_GRACE_MS = 600;
const KNOWN_SIGNALS = new Set([
  'message_sent', 'draft_snapshot', 'typing', 'delete_burst', 'pause_before_send', 'focus_idle', 'compose_abandon',
  'hover', 'dwell', 'oscillation', 'scroll_reverse', 'select', 'copy', 'nod', 'shake', 'brow', 'gaze',
]);

const momentName = (m: MomentType) => t.poin.momentName[m];

let lastFired: Partial<Record<MomentType, number>> = {};
let inferringId: string | null = null;
let chipTimer: ReturnType<typeof setTimeout> | null = null;
let lastPartialKey = '';
let endedLogged = false;
/** 세션이 바뀌거나 엔진이 해제되면 올린다. 이전 세대의 비동기 추론 결과는 버린다 */
let generation = 0;
/** 마지막 에이전트 응답이 끝난 시각(다음 턴 제안 룰) */
let answerDoneAt = 0;
/** 순간 종류별 연속 거절·무응답 수(백오프) */
let declineStreaks: Streaks = {};
/** 순간별 마지막 칩 표시 시각 */
let lastShown: Partial<Record<MomentType, number>> = {};
/** 응답 스트리밍 구간(최근 몇 개). 커서·스크롤 근거에서 제외할 때 쓴다 */
let busyPeriods: { start: number; end: number | null }[] = [];
/** 다음 턴 제안 후보가 이미 나온 응답 */
let nextTurnUsedKey: string | null = null;
let lastAnswerKey: string | null = null;

// ---------- prefetch 상태 ----------
const PREFETCH_TTL_MS = 8000;
const PREFETCH_PER_MIN = 3;
const MOMENT_TYPES: MomentType[] = ['ambiguous_request', 'comparison_hesitation', 'pre_decision', 'next_turn'];
interface Prefetch {
  type: MomentType;
  startedAt: number;
  progress: number;
  promise: Promise<InferResult | null>;
  result: InferResult | null | undefined; // undefined = 응답 대기 중, null = 실패
  discard: ReturnType<typeof setTimeout> | null;
}
let prefetches: Partial<Record<MomentType, Prefetch>> = {};
let prefetchStarts: Partial<Record<MomentType, number[]>> = {};
const freshStats = () => ({ started: 0, hit: 0, hitAfterWait: 0, miss: 0, failed: 0, discarded: 0 });
let pstats = freshStats();
/** 엔진 내부 메타데이터(InferResult는 공용 타입이라 건드리지 않는다) */
const traceMeta = new Map<string, { prefetched: boolean; waitMs: number; confirmToShowMs?: number }>();
export const getTraceMeta = (traceId: string) => traceMeta.get(traceId);

// ---------- 게이트 ----------
function gate(type: MomentType, phase: 'pre' | 'post' | 'prefetch'): string | null {
  const st = poin();
  const now = Date.now();
  if (st.settings.paused) return t.poin.skip.paused;
  if (st.sessionEnded) return t.poin.skip.sessionEnded;
  if (st.activeChip) {
    if (phase === 'post') log.warn('chip', '칩 중복: 추론 중에 다른 칩이 떠 있음', { current: st.activeChip.traceId });
    return t.poin.skip.chipShown;
  }
  if (phase === 'pre' && inferringId) return t.poin.skip.inferring;
  if (st.interventionsShown >= st.settings.maxInterventions) {
    if (phase === 'post') log.warn('chip', '세션 한도 초과 시도', { shown: st.interventionsShown, max: st.settings.maxInterventions });
    return t.poin.skip.limit(st.settings.maxInterventions);
  }
  const until = st.cooldownUntil[type];
  if (until && until > now) return t.poin.skip.cooldown(Math.ceil((until - now) / 1000));
  if (st.chatBusy) return t.poin.skip.chatBusy;
  return null;
}

function skip(traceId: string, reason: string, extra?: Partial<Trace>) {
  poin().updateTrace(traceId, { status: 'skipped', skipReason: reason, ...extra });
}

// ---------- 감지 루프 ----------
function tick() {
  const st = poin();
  if (st.sessionEnded) {
    if (!endedLogged) log.info('moment', '세션 종료: 순간 감지 중단');
    endedLogged = true;
    return;
  }
  endedLogged = false;
  const now = Date.now();
  const mp = multiProductInfo();
  // 응답 식별자: 마지막 에이전트 메시지 id(없으면 assistant 턴 수)
  const answerKey = mp.messageId ?? String(st.chatContext.filter((c) => c.role === 'assistant').length);
  lastAnswerKey = answerKey;
  const out = detect({
    now,
    signals: st.signals,
    chatContext: st.chatContext,
    settings: { pauseMs: st.settings.pauseMs, dwellMs: st.settings.dwellMs },
    draft: collector.draft,
    nearDecision: collector.nearDecision,
    lastDecisionClickAt: collector.lastDecisionClickAt,
    multiProduct: mp,
    lastFired,
    answerDoneAt,
    lastShown,
    busyPeriods,
    answerKey,
    nextTurnUsedKey,
  });

  const partialKey = out.partials.map((p) => `${p.type}:${p.have.map((h) => h.replace(/[\d.]+초/, '')).join(',')}`).join('|');
  if (partialKey !== lastPartialKey) {
    lastPartialKey = partialKey;
    for (const p of out.partials) log.debug('moment', `${momentName(p.type)} 근거 일부: ${p.have.join(', ')} (필요: ${p.need})`);
  }

  if (out.nextTurnSuppressed && nextTurnUsedKey !== answerKey) {
    nextTurnUsedKey = answerKey;
    log.info('moment', `다음 턴 제안 생략: 같은 시점에 ${out.hits.map((h) => momentName(h.type)).join(', ')}이(가) 우선`);
  }
  for (const hit of out.hits) handleHit(hit, now);
  for (const p of out.partials) {
    if (p.progress >= PREFETCH_PROGRESS && !out.hits.some((h) => h.type === p.type)) maybePrefetch(p, now);
  }
}

// ---------- prefetch: 룰이 확정되기 전에 추론을 미리 호출 ----------
function maybePrefetch(partial: RulePartial, now: number) {
  const { type } = partial;
  if (prefetches[type]) return; // 종류별 진행 중(또는 보관 중) 최대 1개
  if (inferringId) return;
  if (gate(type, 'prefetch')) return; // 게이트에 걸리는 상태면 미리 부르지도 않는다
  const starts = (prefetchStarts[type] ?? []).filter((t0) => now - t0 < 60_000);
  prefetchStarts[type] = starts;
  if (starts.length >= PREFETCH_PER_MIN) return;
  starts.push(now);

  const req = buildRequest(type, partial.rule, partial.signalsSummary);
  const p: Prefetch = { type, startedAt: now, progress: partial.progress, promise: Promise.resolve(null), result: undefined, discard: null };
  p.promise = fetchInfer(req)
    .then((r) => {
      p.result = r;
      log.debug('infer', `prefetch 응답 도착: ${momentName(type)} (${Date.now() - p.startedAt}ms)`, { confidence: r.confidence });
      return r;
    })
    .catch((e: unknown) => {
      p.result = null;
      pstats.failed++;
      if (prefetches[type] === p) {
        delete prefetches[type];
        if (p.discard) clearTimeout(p.discard);
      }
      log.warn('infer', `prefetch 실패, 버림: ${momentName(type)} · ${errMessage(e)}`);
      return null;
    });
  p.discard = setTimeout(() => {
    if (prefetches[type] !== p) return;
    delete prefetches[type];
    pstats.discarded++;
    log.info('infer', `prefetch 폐기: ${momentName(type)} (${PREFETCH_TTL_MS / 1000}초 안에 확정 안 됨)`);
  }, PREFETCH_TTL_MS);
  prefetches[type] = p;
  pstats.started++;
  log.info('infer', `prefetch 시작: ${momentName(type)} (진행도 ${partial.progress.toFixed(2)})`, { rule: partial.rule, summary: partial.signalsSummary });
}

/** 확정 시점에 쓸 prefetch 결과를 꺼낸다. 없거나 못 쓰면 null(사유 로그). */
async function takePrefetch(type: MomentType, traceId: string, confirmAt: number): Promise<{ result: InferResult; waitMs: number } | null> {
  const p = prefetches[type];
  if (!p) {
    pstats.miss++;
    log.info('infer', `prefetch 미적중: 진행 중인 prefetch 없음`, { traceId, type });
    return null;
  }
  delete prefetches[type];
  if (p.discard) clearTimeout(p.discard);
  const age = confirmAt - p.startedAt;
  if (age > PREFETCH_TTL_MS) {
    pstats.miss++;
    log.info('infer', `prefetch 미적중: 요청이 ${age}ms 전에 시작돼 ${PREFETCH_TTL_MS / 1000}초 초과`, { traceId, type });
    return null;
  }
  if (p.result) {
    pstats.hit++;
    log.info('infer', `prefetch 재사용 적중: ${momentName(type)} (요청 ${age}ms 전 시작, 대기 0ms)`, { traceId, prefetched: true, waitMs: 0 });
    return { result: p.result, waitMs: 0 };
  }
  const r = await p.promise;
  const waitMs = Date.now() - confirmAt;
  if (r) {
    pstats.hitAfterWait++;
    log.info('infer', `prefetch 대기 후 적중: ${momentName(type)} (확정 뒤 ${waitMs}ms 대기)`, { traceId, prefetched: true, waitMs });
    return { result: r, waitMs };
  }
  pstats.miss++;
  log.info('infer', `prefetch 미적중: prefetch 실패, 새로 호출`, { traceId, type, waitMs });
  return null;
}

function handleHit(hit: RuleHit, now: number) {
  lastFired = { ...lastFired, [hit.type]: now };
  if (hit.type === 'next_turn') nextTurnUsedKey = lastAnswerKey;
  const moment: MomentCandidate = {
    id: uid('mom'),
    t: now,
    type: hit.type,
    rule: hit.rule,
    signals: hit.signals,
    signalsSummary: hit.signalsSummary,
    anchor: { x: live.cursor.x, y: live.cursor.y },
    context: hit.context,
  };
  const traceId = uid('trace');
  log.info('moment', `후보: ${momentName(hit.type)} · ${hit.rule}`, { traceId, score: hit.score, summary: hit.signalsSummary });

  const reason = gate(hit.type, 'pre');
  if (reason) {
    poin().addTrace({ id: traceId, moment, status: 'skipped', skipReason: reason, shown: false });
    log.info('moment', `개입 보류: ${momentName(hit.type)} · ${reason}`, { traceId });
    return;
  }
  poin().addTrace({ id: traceId, moment, status: 'inferring', shown: false });
  void infer(traceId, moment);
}

// ---------- 추론 ----------
function validResult(r: unknown): r is InferResult {
  const x = r as InferResult;
  return !!x && typeof x.confidence === 'number' && !!x.intervention && typeof x.intervention.prompt === 'string'
    && Array.isArray(x.intervention.options) && x.intervention.options.length > 0 && !!x.intervention.onDecline;
}

function errMessage(e: unknown) {
  return e instanceof Error ? e.message : String(e);
}

function buildRequest(type: MomentType, rule: string, signalsSummary: string[]): InferRequest {
  return {
    momentType: type,
    rule,
    signalsSummary,
    conversation: poin().chatContext.slice(-8),
    productContext: productContext(),
  };
}

/** /api/poin/infer 호출. 실패·시간 초과·형태 불일치는 throw */
async function fetchInfer(req: InferRequest): Promise<InferResult> {
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), INFER_TIMEOUT_MS);
  try {
    const res = await fetch('/api/poin/infer', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(req),
      signal: ac.signal,
    });
    if (!res.ok) {
      const body = await res.text().catch(() => '');
      throw new Error(`HTTP ${res.status}: ${body.slice(0, 200)}`);
    }
    const result: unknown = await res.json();
    if (!validResult(result)) throw new Error('추론 응답 형태가 계약과 다름');
    return result;
  } catch (e) {
    if (ac.signal.aborted) throw new Error(`시간 초과 ${INFER_TIMEOUT_MS}ms`);
    throw e;
  } finally {
    clearTimeout(timer);
  }
}

async function infer(traceId: string, moment: MomentCandidate) {
  inferringId = traceId;
  const confirmAt = Date.now();
  const gen = generation;
  const stale = () => {
    if (gen === generation) return false;
    log.info('infer', '세션이 바뀌어 추론 결과를 버림', { traceId });
    return true;
  };
  try {
    let result: InferResult;
    const pre = await takePrefetch(moment.type, traceId, confirmAt);
    if (pre) {
      result = pre.result;
      traceMeta.set(traceId, { prefetched: true, waitMs: pre.waitMs });
    } else {
      const end = log.time('infer', `추론: ${momentName(moment.type)}`);
      try {
        result = await fetchInfer(buildRequest(moment.type, moment.rule, moment.signalsSummary));
      } catch (e) {
        end({ traceId, ok: false });
        throw e;
      }
      const ms = end({ traceId, confidence: result.confidence, model: result.model, serverMs: result.latencyMs });
      if (ms > INFER_SLOW_MS) log.warn('infer', `추론 ${ms}ms: 5초 초과`, { traceId });
      traceMeta.set(traceId, { prefetched: false, waitMs: ms });
    }
    if (stale()) return;

    const { threshold } = poin().settings;
    if (result.confidence < threshold) {
      const reason = t.poin.skip.lowConfidence(result.confidence, threshold);
      skip(traceId, reason, { infer: result });
      log.info('infer', `개입 안 함: ${reason}`, { traceId, intent: result.intentHypothesis, prefetched: !!pre });
      return;
    }
    const reason = gate(moment.type, 'post');
    if (reason) {
      skip(traceId, reason, { infer: result });
      log.info('chip', `추론 후 개입 보류: ${reason}`, { traceId });
      return;
    }
    showChip(traceId, moment.type, result, confirmAt);
  } catch (e) {
    if (stale()) return;
    const message = errMessage(e);
    poin().updateTrace(traceId, { status: 'error', error: message });
    log.error('infer', `추론 실패: ${message}`, { traceId });
  } finally {
    if (inferringId === traceId) inferringId = null;
  }
}

// ---------- 칩 ----------
function showChip(traceId: string, type: MomentType, result: InferResult, confirmAt: number) {
  const st = poin();
  const now = Date.now();
  const chip: ActiveChip = {
    traceId,
    momentType: type,
    prompt: result.intervention.prompt,
    evidenceLine: result.intervention.evidenceLine,
    options: result.intervention.options,
    onDecline: result.intervention.onDecline,
    anchor: { x: live.cursor.x, y: live.cursor.y },
    shownAt: now,
    timeoutMs: st.settings.chipTimeoutMs,
  };
  st.setActiveChip(chip);
  lastShown = { ...lastShown, [type]: now };
  st.incInterventions();
  st.setCooldown(type, now + st.settings.cooldownMs);
  st.updateTrace(traceId, { status: 'shown', shown: true, infer: result });
  if (chipTimer) clearTimeout(chipTimer);
  chipTimer = setTimeout(() => respond('timeout'), chip.timeoutMs);
  const meta = traceMeta.get(traceId);
  const confirmToShowMs = now - confirmAt;
  if (meta) meta.confirmToShowMs = confirmToShowMs;
  log.info('chip', `칩 표시: ${momentName(type)} · "${chip.prompt}" (확정→표시 ${confirmToShowMs}ms${meta?.prefetched ? ', prefetch' : ''})`, {
    traceId, confidence: result.confidence, options: chip.options.map((o) => o.label), shown: st.interventionsShown + 1,
    prefetched: meta?.prefetched ?? false, waitMs: meta?.waitMs, confirmToShowMs,
  });
}

// ---------- 반응 ----------
const CHOICE: Record<ReactionVia, ChoiceId | 'decline' | 'ignore'> = {
  alt1: 'accept1', click1: 'accept1', nod: 'accept1',
  alt2: 'accept2', click2: 'accept2',
  esc: 'decline', click_decline: 'decline', shake: 'decline',
  timeout: 'ignore',
};

function describe(type: MomentType, choice: Reaction['choice'], effect: Effect): string {
  if (choice === 'ignore') return t.poin.outcome.timeout;
  if (effect.kind === 'none') return t.poin.outcome.none;
  if (effect.kind === 'fill_draft') return t.poin.outcome.fillDraft(effect.text);
  const summary = t.poin.outcome.summary[type][choice];
  return t.poin.outcome.agentTurn(summary || effect.markText);
}

/** 칩에 대한 반응 처리. 단축키·제스처·무응답만 들어온다(클릭 반응은 쓰지 않음). */
export function respond(via: ReactionVia): boolean {
  const st = poin();
  const chip = st.activeChip;
  if (!chip) return false;
  const choice = CHOICE[via];
  const option = choice === 'accept1' || choice === 'accept2' ? chip.options.find((o) => o.id === choice) : undefined;
  if ((choice === 'accept1' || choice === 'accept2') && !option) {
    log.debug('reaction', `옵션 없음: ${choice}`, { traceId: chip.traceId });
    return false;
  }
  const now = Date.now();
  const effect: Effect = choice === 'decline' ? chip.onDecline : choice === 'ignore' ? { kind: 'none' } : option!.effect;
  if (chipTimer) clearTimeout(chipTimer);
  chipTimer = null;
  st.setActiveChip(null);

  const reaction: Reaction = { t: now, via, choice, afterMs: now - chip.shownAt };
  log.info('reaction', `반응: ${via} → ${choice} (${reaction.afterMs}ms)`, { traceId: chip.traceId });

  if (effect.kind === 'fill_draft') st.requestDraftFill(effect.text, chip.traceId);
  else if (effect.kind === 'agent_turn') st.requestTurn(effect.directive, effect.markText, chip.traceId);

  const description = describe(chip.momentType, choice, effect);
  st.updateTrace(chip.traceId, { status: 'resolved', reaction, outcome: { effect, description } });
  log.info('outcome', description, { traceId: chip.traceId, effect: effect.kind });

  const b = applyReaction(declineStreaks, chip.momentType, choice, now);
  declineStreaks = b.streaks;
  if (b.cooldownUntil) {
    st.setCooldown(chip.momentType, b.cooldownUntil);
    log.info('moment', `백오프: ${momentName(chip.momentType)} ${Math.round(BACKOFF_COOLDOWN_MS / 60_000)}분 (연속 거절 ${b.streak}회)`, { traceId: chip.traceId });
  }
  return true;
}

function onKeyDown(e: KeyboardEvent) {
  if (!poin().activeChip) return;
  if (e.isComposing || e.keyCode === 229) return;
  let via: ReactionVia | null = null;
  if (e.altKey && e.code === 'Digit1') via = 'alt1';
  else if (e.altKey && e.code === 'Digit2') via = 'alt2';
  else if (e.key === 'Escape' && !e.altKey) via = 'esc';
  if (!via) return;
  if (respond(via)) {
    e.preventDefault();
    e.stopPropagation();
  }
}

function clearPrefetches() {
  for (const type of MOMENT_TYPES) {
    const p = prefetches[type];
    if (p?.discard) clearTimeout(p.discard);
  }
  prefetches = {};
}

function logPrefetchSummary() {
  const hits = pstats.hit + pstats.hitAfterWait;
  const confirmed = hits + pstats.miss;
  const rate = confirmed ? Math.round((hits / confirmed) * 100) : 0;
  log.info('infer', `prefetch 요약: 확정 ${confirmed}건 중 적중 ${hits}건(즉시 ${pstats.hit}, 대기 후 ${pstats.hitAfterWait}) · 적중률 ${rate}% · 시작 ${pstats.started} · 실패 ${pstats.failed} · 폐기 ${pstats.discarded}`, pstats);
}

// ---------- 설치 ----------
export function installEngine(): () => void {
  const offInput = installInputCollector();
  const offCursor = installCursorCollector();
  const warnedTypes = new Set<string>();

  const offSignals = onNewSignals((s) => {
    if (!KNOWN_SIGNALS.has(s.type) && !warnedTypes.has(s.type)) {
      warnedTypes.add(s.type);
      log.warn('signal', `알 수 없는 신호 타입: ${s.kind}.${s.type}`);
    }
    if (s.kind !== 'sense' || (s.type !== 'nod' && s.type !== 'shake')) return;
    const chip = poin().activeChip;
    if (!chip) return;
    if (s.t < chip.shownAt + GESTURE_GRACE_MS) {
      log.debug('reaction', `칩 표시 직후 제스처 무시: ${s.type}`);
      return;
    }
    respond(s.type === 'nod' ? 'nod' : 'shake');
  });

  // 칩이 바깥에서 지워지거나(세션 종료) 세션이 바뀌면 타이머·상태 정리
  const offStore = usePoin.subscribe((st, prev) => {
    if (prev.activeChip && !st.activeChip && chipTimer) {
      clearTimeout(chipTimer);
      chipTimer = null;
    }
    if (st.sessionEnded && !prev.sessionEnded) logPrefetchSummary();
    if (!prev.chatBusy && st.chatBusy && !busyPeriods.some((p) => p.end === null)) {
      busyPeriods = [...busyPeriods.slice(-4), { start: Date.now(), end: null }];
    }
    if (prev.chatBusy && !st.chatBusy) {
      const end = Date.now();
      // 열린 구간은 모두 닫는다(리마운트로 겹쳐 열렸어도 영구히 열린 채 남지 않게)
      busyPeriods = busyPeriods.map((p) => (p.end === null ? { ...p, end } : p));
      answerDoneAt = Date.now();
      log.debug('moment', '응답 끝: 다음 턴 제안 대기 시작');
    }
    if (st.sessionId !== prev.sessionId) {
      generation++;
      lastFired = {};
      answerDoneAt = 0;
      declineStreaks = {};
      lastShown = {};
      busyPeriods = [];
      nextTurnUsedKey = null;
      inferringId = null;
      clearPrefetches();
      pstats = freshStats();
      prefetchStarts = {};
      traceMeta.clear();
      log.info('moment', '새 세션: 룰 디바운스·prefetch 초기화');
    }
  });

  // 스트리밍 도중에 설치(리마운트)되면 열린 구간으로 시작한다
  if (poin().chatBusy && !busyPeriods.some((p) => p.end === null)) {
    busyPeriods = [...busyPeriods.slice(-4), { start: Date.now(), end: null }];
  }

  window.addEventListener('keydown', onKeyDown, true);
  const loop = setInterval(tick, TICK_MS);
  log.info('runtime', 'poin 엔진 설치');

  return () => {
    generation++;
    inferringId = null;
    clearInterval(loop);
    window.removeEventListener('keydown', onKeyDown, true);
    if (chipTimer) clearTimeout(chipTimer);
    chipTimer = null;
    clearPrefetches();
    offSignals();
    offStore();
    offCursor();
    offInput();
    log.info('runtime', 'poin 엔진 해제');
  };
}
