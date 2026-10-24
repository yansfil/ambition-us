// 입력창 반언어 신호: 타이핑 속도, 삭제 버스트, 초안 스냅샷, 포커스 후 무입력, 전송 전 정지, 비운 초안.
// 문서 전역 이벤트 위임. 입력창은 [data-poin-target="input"].
import { log } from '@/lib/log';
import { live } from '../live';
import { poin, usePoin } from '../store';
import { collector, inputEl, isInputEl } from './state';
import { onNewSignals } from './subscribe';

const TYPING_WINDOW_MS = 10_000;
const BURST_GAP_MS = 1500;
const BURST_MIN_COUNT = 3;
const BURST_MIN_CHARS = 4;
const TYPING_STREAK_END_MS = 1200;

interface DeleteGroup {
  count: number;
  chars: number;
  text: string;
  pos: number;
  lastAt: number;
}

/** 두 문자열의 차이: 지운 부분과 넣은 부분 */
export function diffText(prev: string, next: string) {
  let p = 0;
  const max = Math.min(prev.length, next.length);
  while (p < max && prev[p] === next[p]) p++;
  let s = 0;
  while (s < max - p && prev[prev.length - 1 - s] === next[next.length - 1 - s]) s++;
  return { pos: p, deleted: prev.slice(p, prev.length - s), inserted: next.slice(p, next.length - s) };
}

export function installInputCollector(): () => void {
  const d = collector.draft;
  const inserts: { t: number; n: number }[] = [];
  let prevValue = inputEl()?.value ?? '';
  let group: DeleteGroup | null = null;
  let draftPeak = '';
  let streakChars = 0;
  let lastInsertAt = 0;
  let sawInputSinceFocus = false;
  let focusIdleEmitted = false;
  const paused = () => poin().settings.paused;
  const resyncTimers = new Set<ReturnType<typeof setTimeout>>();
  // A가 입력창 값을 코드로 바꾸면(input 이벤트 없음) 잠시 뒤 기준값을 DOM에서 다시 읽는다
  const resyncSoon = () => {
    const id = setTimeout(() => {
      resyncTimers.delete(id);
      prevValue = inputEl()?.value ?? '';
      d.text = prevValue;
    }, 50);
    resyncTimers.add(id);
  };

  const push = poin().pushSignal;

  function closeGroup(reason: string) {
    const g = group;
    group = null;
    if (!g || paused()) return;
    push({ kind: 'verbal', type: 'draft_snapshot', data: { text: d.text, deleted: g.text } });
    if (g.count >= BURST_MIN_COUNT || g.chars >= BURST_MIN_CHARS) {
      d.bursts += 1;
      live.deleteBursts = d.bursts;
      push({ kind: 'paraverbal', type: 'delete_burst', data: { count: g.count, deletedText: g.text } });
      log.info('signal', `삭제 버스트 ${d.bursts}번째 (${g.count}회, ${g.chars}자)`, { deletedText: g.text, reason });
    }
  }

  function onFocusIn(e: FocusEvent) {
    if (!isInputEl(e.target)) return;
    const now = Date.now();
    d.focused = true;
    d.focusAt = now;
    d.text = e.target.value;
    prevValue = e.target.value;
    sawInputSinceFocus = false;
    focusIdleEmitted = false;
  }

  function onFocusOut(e: FocusEvent) {
    if (!isInputEl(e.target)) return;
    d.focused = false;
    live.pauseMs = 0;
    live.focusIdleMs = 0;
  }

  function onCompositionEnd(e: CompositionEvent) {
    if (!isInputEl(e.target) || paused()) return;
    countInsert((e.data ?? '').length);
  }

  function countInsert(n: number) {
    if (n <= 0) return;
    const now = Date.now();
    inserts.push({ t: now, n });
    streakChars += n;
    lastInsertAt = now;
  }

  function onInput(e: Event) {
    if (!isInputEl(e.target) || paused()) return;
    const el = e.target;
    const ie = e as InputEvent;
    const now = Date.now();
    const next = el.value;
    const { pos, deleted, inserted } = diffText(prevValue, next);

    // 타이핑 속도: 조합 중 글자는 compositionend에서 센다
    if (ie.inputType === 'insertText' && !ie.isComposing) countInsert((ie.data ?? '').length);

    if (deleted.length > inserted.length && deleted.length > 0) {
      if (group && now - group.lastAt > BURST_GAP_MS) closeGroup('간격');
      if (!group) group = { count: 0, chars: 0, text: '', pos, lastAt: now };
      group.count += 1;
      group.chars += deleted.length - inserted.length;
      group.text = pos < group.pos ? deleted + group.text : group.text + deleted;
      group.pos = Math.min(group.pos, pos);
      group.lastAt = now;
    }

    if (next.trim().length > draftPeak.trim().length) draftPeak = next;
    if (!next && prevValue.trim().length >= 2) {
      closeGroup('비움');
      push({ kind: 'paraverbal', type: 'compose_abandon', data: { text: draftPeak } });
      log.info('signal', '초안을 지워 비움', { text: draftPeak });
    }

    prevValue = next;
    d.text = next;
    d.lastInputAt = now;
    sawInputSinceFocus = true;
  }

  // 메시지 전송(A가 push) → 전송 전 정지 + 초안 단위 리셋
  const offSignals = onNewSignals((s) => {
    if (s.type !== 'message_sent') return;
    closeGroup('전송');
    const now = Date.now();
    if (d.lastInputAt) {
      const ms = Math.max(0, s.t - d.lastInputAt);
      push({ kind: 'paraverbal', type: 'pause_before_send', data: { ms } });
    }
    log.info('signal', '전송으로 초안 카운터 리셋', { bursts: d.bursts });
    d.bursts = 0;
    live.deleteBursts = 0;
    d.text = '';
    d.lastInputAt = 0;
    d.focusAt = d.focused ? now : 0;
    draftPeak = '';
    prevValue = '';
    sawInputSinceFocus = false;
    focusIdleEmitted = true; // 전송 직후 무입력은 "포커스 후 무입력"이 아니다
    resyncSoon();
  });

  // poin이 초안을 채우면(A가 값 변경, input 이벤트 없음) 기준값을 다시 맞춘다
  const offDraft = usePoin.subscribe((st, prev) => {
    if (st.draftFill === prev.draftFill) return;
    resyncSoon();
  });

  const tick = setInterval(() => {
    const now = Date.now();
    while (inserts.length && now - inserts[0].t > TYPING_WINDOW_MS) inserts.shift();
    live.typingCpm = Math.round(inserts.reduce((a, b) => a + b.n, 0) * (60_000 / TYPING_WINDOW_MS));
    if (paused()) return;

    if (group && now - group.lastAt > BURST_GAP_MS) closeGroup('간격');

    if (streakChars && now - lastInsertAt > TYPING_STREAK_END_MS) {
      if (streakChars >= 5) push({ kind: 'paraverbal', type: 'typing', data: { cpm: live.typingCpm } });
      streakChars = 0;
    }

    if (d.focused) {
      live.pauseMs = d.lastInputAt ? now - d.lastInputAt : 0;
      live.focusIdleMs = sawInputSinceFocus ? 0 : now - d.focusAt;
      const { pauseMs } = poin().settings;
      if (!sawInputSinceFocus && !focusIdleEmitted && live.focusIdleMs >= pauseMs) {
        focusIdleEmitted = true;
        push({ kind: 'paraverbal', type: 'focus_idle', data: { ms: live.focusIdleMs, empty: !d.text.trim() } });
      }
    }
  }, 250);

  // 이미 포커스된 상태로 설치되면 반영
  const el = inputEl();
  if (el && document.activeElement === el) {
    d.focused = true;
    d.focusAt = Date.now();
    d.text = el.value;
  }

  document.addEventListener('focusin', onFocusIn, true);
  document.addEventListener('focusout', onFocusOut, true);
  document.addEventListener('input', onInput, true);
  document.addEventListener('compositionend', onCompositionEnd, true);
  log.info('signal', '입력 수집기 설치');

  return () => {
    document.removeEventListener('focusin', onFocusIn, true);
    document.removeEventListener('focusout', onFocusOut, true);
    document.removeEventListener('input', onInput, true);
    document.removeEventListener('compositionend', onCompositionEnd, true);
    clearInterval(tick);
    resyncTimers.forEach(clearTimeout);
    offSignals();
    offDraft();
    log.info('signal', '입력 수집기 해제');
  };
}
