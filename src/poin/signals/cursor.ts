// 커서 신호: 타깃 hover/dwell, 두 타깃 왕복, 스크롤 역주행, 텍스트 선택, 복사, 결정 버튼 근처 체류.
// mousemove는 rAF로 묶고, 신호는 의미 있는 사건 단위로만 push한다.
import { t } from '@/i18n';
import { log } from '@/lib/log';
import { live } from '../live';
import { poin } from '../store';
import { collector } from './state';

const MIN_VISIT_MS = 250; // 이보다 짧게 스친 타깃은 방문으로 안 센다
const HOVER_MIN_MS = 600;
const OSC_WINDOW_MS = 8000;
const SCROLL_WINDOW_MS = 6000;
const SCROLL_MIN_PX = 120;
const SCROLL_INTENT_MS = 700;
const NEAR_PX = 60;
const DECISION_SELECTOR = '[data-poin-target^="add:"],[data-poin-target="checkout"]';

export interface ResolvedTarget {
  target: string;
  label: string;
}

const isDecision = (target: string) => target.startsWith('add:') || target === 'checkout';

function ruleLabel(v: string): string {
  if (v === 'input') return t.poin.target.input;
  if (v === 'mission') return t.poin.target.mission;
  if (v === 'checkout') return t.poin.target.checkout;
  if (v.startsWith('msg:')) return t.poin.target.message;
  if (v.startsWith('product:')) return t.poin.target.product;
  if (v.startsWith('add:')) return t.poin.target.add;
  return v;
}

/** 요소 → poin 타깃. 에이전트 메시지 안에서는 p/li/tr 문단 단위로 쪼갠다. */
export function resolveTarget(el: Element | null): ResolvedTarget | null {
  if (!el) return null;
  const host = el.closest('[data-poin-target]');
  if (!host) return null;
  const v = host.getAttribute('data-poin-target') ?? '';
  if (v.startsWith('msg:')) {
    const block = el.closest('p, li, tr');
    if (block && host.contains(block)) {
      const idx = Array.from(host.querySelectorAll('p, li, tr')).indexOf(block);
      if (idx >= 0) return { target: `para:${v.slice(4)}:${idx}`, label: t.poin.target.paragraph(idx) };
    }
  }
  return { target: v, label: host.getAttribute('data-poin-label') || ruleLabel(v) };
}

export function installCursorCollector(): () => void {
  const push = poin().pushSignal;
  const paused = () => poin().settings.paused;

  let raf = 0;
  let mx = 0;
  let my = 0;
  let cur: { target: string; label: string; enteredAt: number; counted: boolean; dwellEmitted: boolean } | null = null;
  const visits = new Map<string, number>();
  const labels = new Map<string, string>();
  let seq: { target: string; t: number }[] = [];
  let lastOscKey = '';
  let lastOscCount = 0;
  let decisionDwellEmitted = false;

  // ---------- 타깃 추적 ----------
  function leaveCurrent(now: number) {
    if (!cur) return;
    const ms = now - cur.enteredAt;
    if (ms >= HOVER_MIN_MS && !cur.dwellEmitted && !paused()) {
      push({ kind: 'cursor', type: 'hover', data: { target: cur.target, label: cur.label, ms } });
    }
    cur = null;
  }

  function countVisit(now: number) {
    if (!cur || cur.counted) return;
    cur.counted = true;
    visits.set(cur.target, (visits.get(cur.target) ?? 0) + 1);
    if (seq.at(-1)?.target !== cur.target) seq.push({ target: cur.target, t: now });
    seq = seq.filter((s) => now - s.t <= OSC_WINDOW_MS);
    checkOscillation();
  }

  function checkOscillation() {
    const n = seq.length;
    if (n < 3) {
      live.oscillations = 0;
      return;
    }
    const b = seq[n - 1].target;
    const a = seq[n - 2].target;
    let i = n - 1;
    while (i > 0 && seq[i - 1].target === (seq[i].target === b ? a : b)) i--;
    const count = n - 1 - i; // 전환 횟수
    live.oscillations = count >= 2 ? count : 0;
    const key = [a, b].sort().join('|');
    if (count >= 2 && (key !== lastOscKey || count > lastOscCount)) {
      lastOscKey = key;
      lastOscCount = count;
      push({ kind: 'cursor', type: 'oscillation', data: { a, b, aLabel: labels.get(a), bLabel: labels.get(b), count } });
    } else if (key !== lastOscKey) {
      lastOscCount = 0;
    }
  }

  function updateNearDecision(now: number) {
    let best: { el: Element; d: number } | null = null;
    document.querySelectorAll(DECISION_SELECTOR).forEach((el) => {
      if (el.closest('[data-poin-layer]')) return;
      const r = el.getBoundingClientRect();
      if (!r.width && !r.height) return;
      const dx = Math.max(r.left - mx, 0, mx - r.right);
      const dy = Math.max(r.top - my, 0, my - r.bottom);
      const d = Math.hypot(dx, dy);
      if (d <= NEAR_PX && (!best || d < best.d)) best = { el, d };
    });
    const found = best as { el: Element; d: number } | null;
    if (!found) {
      if (collector.nearDecision) log.debug('signal', '결정 버튼 근처 벗어남', { target: collector.nearDecision.target });
      collector.nearDecision = null;
      return;
    }
    const r = resolveTarget(found.el);
    if (!r) return;
    if (collector.nearDecision?.target !== r.target) {
      collector.nearDecision = { target: r.target, label: r.label, since: now };
      decisionDwellEmitted = false;
    }
  }

  function processMove() {
    raf = 0;
    if (paused()) return;
    const now = Date.now();
    const el = document.elementFromPoint(mx, my);
    // poin 레이어(패널 등) 위에서는 타깃 없음으로 본다. 칩·오브는 pointer-events:none이라 여기 안 걸린다.
    const r = el && !el.closest('[data-poin-layer]') ? resolveTarget(el) : null;
    if ((r?.target ?? null) !== (cur?.target ?? null)) {
      leaveCurrent(now);
      if (r) {
        labels.set(r.target, r.label);
        cur = { target: r.target, label: r.label, enteredAt: now, counted: false, dwellEmitted: false };
      }
      live.cursorTarget = r?.target ?? null;
      live.cursorTargetLabel = r?.label ?? null;
      live.dwellMs = 0;
    }
    updateNearDecision(now);
  }

  function onMove(e: MouseEvent) {
    mx = e.clientX;
    my = e.clientY;
    live.cursor.x = mx;
    live.cursor.y = my;
    if (!raf) raf = requestAnimationFrame(processMove);
  }

  function onWindowOut(e: MouseEvent) {
    if (e.relatedTarget) return;
    leaveCurrent(Date.now());
    collector.nearDecision = null;
    live.cursorTarget = null;
    live.cursorTargetLabel = null;
    live.dwellMs = 0;
  }

  function onClick(e: MouseEvent) {
    const el = e.target instanceof Element ? e.target.closest(DECISION_SELECTOR) : null;
    if (!el) return;
    const now = Date.now();
    collector.lastDecisionClickAt = now;
    if (collector.nearDecision) collector.nearDecision.since = now + 1;
    decisionDwellEmitted = false;
    log.info('signal', '결정 버튼 클릭', { target: el.getAttribute('data-poin-target') });
  }

  // ---------- 스크롤 역주행 ----------
  let lastIntentAt = 0;
  const intent = () => { lastIntentAt = Date.now(); };
  const onKey = (e: KeyboardEvent) => {
    if (['PageUp', 'PageDown', 'ArrowUp', 'ArrowDown', 'Home', 'End', ' '].includes(e.key)) intent();
  };
  const scrollState = new WeakMap<object, { pos: number; dir: number; runStart: number; pending: boolean }>();
  let reversals: number[] = [];

  function onScroll(e: Event) {
    if (paused()) return;
    const tgt = e.target;
    let key: object;
    let pos: number;
    if (tgt === document || tgt === document.documentElement || tgt === document.body) {
      key = document;
      pos = window.scrollY;
    } else if (tgt instanceof Element) {
      if (tgt.closest('[data-poin-layer]') || tgt.matches('textarea, input')) return;
      key = tgt;
      pos = tgt.scrollTop;
    } else return;
    const st = scrollState.get(key);
    if (!st) {
      scrollState.set(key, { pos, dir: 0, runStart: pos, pending: false });
      return;
    }
    const delta = pos - st.pos;
    if (!delta) return;
    const dir = Math.sign(delta);
    if (dir !== st.dir) {
      if (st.dir !== 0) st.pending = true;
      st.dir = dir;
      st.runStart = st.pos;
    }
    st.pos = pos;
    const now = Date.now();
    if (st.pending && Math.abs(pos - st.runStart) >= SCROLL_MIN_PX) {
      st.pending = false;
      if (now - lastIntentAt > SCROLL_INTENT_MS) return; // 자동 스크롤(응답 스트리밍)은 제외
      reversals = reversals.filter((r) => now - r <= SCROLL_WINDOW_MS);
      reversals.push(now);
      live.scrollReversals = reversals.length;
      push({ kind: 'cursor', type: 'scroll_reverse', data: { count: reversals.length, dir: dir > 0 ? 'down' : 'up' } });
    }
  }

  // ---------- 선택·복사 ----------
  let selTimer: ReturnType<typeof setTimeout> | null = null;
  let lastSel = '';
  function onSelectionChange() {
    if (selTimer) clearTimeout(selTimer);
    selTimer = setTimeout(() => {
      if (paused()) return;
      const sel = document.getSelection();
      const text = sel?.toString().trim() ?? '';
      if (!text) {
        lastSel = '';
        return;
      }
      if (text === lastSel || !sel || !sel.rangeCount) return;
      lastSel = text;
      const node = sel.anchorNode;
      const el = node instanceof Element ? node : node?.parentElement ?? null;
      if (!el || el.closest('[data-poin-layer]')) return;
      const r = resolveTarget(el);
      const focusEl = sel.focusNode instanceof Element ? sel.focusNode : sel.focusNode?.parentElement ?? null;
      const byAttr =
        !!el.closest('[data-poin-price]') ||
        !!focusEl?.closest('[data-poin-price]') ||
        !!sel.getRangeAt(0).cloneContents().querySelector?.('[data-poin-price]');
      const byText = /\d[\d,]*\s*원/.test(text);
      push({
        kind: 'cursor',
        type: 'select',
        data: { text: text.slice(0, 200), target: r?.target ?? null, label: r?.label ?? null, price: byAttr || byText, priceBy: byAttr ? 'attr' : byText ? 'text' : null },
      });
    }, 400);
  }

  function onCopy() {
    if (paused()) return;
    const text = document.getSelection()?.toString().trim() ?? '';
    if (text) push({ kind: 'cursor', type: 'copy', data: { text: text.slice(0, 200) } });
  }

  // ---------- 주기 점검: 체류 판정 ----------
  const tick = setInterval(() => {
    if (paused()) return;
    const now = Date.now();
    const { dwellMs } = poin().settings;
    if (cur) {
      const ms = now - cur.enteredAt;
      live.dwellMs = ms;
      if (ms >= MIN_VISIT_MS) countVisit(now);
      if (ms >= dwellMs && !cur.dwellEmitted && !isDecision(cur.target)) {
        cur.dwellEmitted = true;
        push({ kind: 'cursor', type: 'dwell', data: { target: cur.target, label: cur.label, ms, visits: visits.get(cur.target) ?? 1 } });
      }
    }
    const near = collector.nearDecision;
    if (near && !decisionDwellEmitted && now - near.since >= dwellMs && near.since > collector.lastDecisionClickAt) {
      decisionDwellEmitted = true;
      push({
        kind: 'cursor',
        type: 'dwell',
        data: { target: near.target, label: near.label, ms: now - near.since, visits: visits.get(near.target) ?? 0, decision: true, over: cur?.target === near.target },
      });
    }
    if (near) live.dwellMs = Math.max(live.dwellMs, now - near.since);
    const before = reversals.length;
    reversals = reversals.filter((r) => now - r <= SCROLL_WINDOW_MS);
    if (reversals.length !== before) live.scrollReversals = reversals.length;
    if (seq.length && now - seq[seq.length - 1].t > OSC_WINDOW_MS) {
      seq = [];
      live.oscillations = 0;
    }
  }, 150);

  document.addEventListener('mousemove', onMove, { passive: true });
  document.addEventListener('mouseout', onWindowOut);
  document.addEventListener('click', onClick, true);
  document.addEventListener('scroll', onScroll, { capture: true, passive: true });
  document.addEventListener('wheel', intent, { capture: true, passive: true });
  document.addEventListener('touchmove', intent, { capture: true, passive: true });
  document.addEventListener('mousedown', intent, true);
  document.addEventListener('keydown', onKey, true);
  document.addEventListener('selectionchange', onSelectionChange);
  document.addEventListener('copy', onCopy, true);
  log.info('signal', '커서 수집기 설치');

  return () => {
    if (raf) cancelAnimationFrame(raf);
    if (selTimer) clearTimeout(selTimer);
    clearInterval(tick);
    document.removeEventListener('mousemove', onMove);
    document.removeEventListener('mouseout', onWindowOut);
    document.removeEventListener('click', onClick, true);
    document.removeEventListener('scroll', onScroll, true);
    document.removeEventListener('wheel', intent, true);
    document.removeEventListener('touchmove', intent, true);
    document.removeEventListener('mousedown', intent, true);
    document.removeEventListener('keydown', onKey, true);
    document.removeEventListener('selectionchange', onSelectionChange);
    document.removeEventListener('copy', onCopy, true);
    log.info('signal', '커서 수집기 해제');
  };
}
