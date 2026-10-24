// 클라이언트 구조화 로거. 정상/비정상 동작을 모두 남겨 나중에 재구성할 수 있게 한다.
// - 콘솔: [poin:카테고리] 메시지
// - 메모리 링버퍼: 로그 패널 "시스템" 필터와 세션 JSON 내보내기에 사용
// - 서버: 2초마다 /api/log 로 묶어 보냄 → logs/poin-YYYYMMDD.jsonl (서버 로그와 같은 파일)

export type LogLevel = 'debug' | 'info' | 'warn' | 'error';
export type LogCategory =
  | 'session' | 'chat' | 'tool' | 'signal' | 'moment' | 'infer' | 'chip'
  | 'reaction' | 'outcome' | 'sense' | 'control' | 'perf' | 'runtime';

export interface LogEntry {
  t: number;
  level: LogLevel;
  cat: LogCategory;
  msg: string;
  data?: unknown;
  src: 'client' | 'server';
}

const RING = 2000;
const buffer: LogEntry[] = [];
const outbox: LogEntry[] = [];
const listeners = new Set<(e: LogEntry) => void>();
const isBrowser = typeof window !== 'undefined';

// 디버그 신호는 양이 많아 서버로는 보내지 않는다(메모리에는 남김).
const shouldShip = (e: LogEntry) => e.level !== 'debug';

function emit(level: LogLevel, cat: LogCategory, msg: string, data?: unknown) {
  const e: LogEntry = { t: Date.now(), level, cat, msg, data: safe(data), src: 'client' };
  buffer.push(e);
  if (buffer.length > RING) buffer.shift();
  if (shouldShip(e)) outbox.push(e);
  listeners.forEach((l) => l(e));
  if (level !== 'debug' || (isBrowser && (window as unknown as { POIN_DEBUG?: boolean }).POIN_DEBUG)) {
    const fn = level === 'error' ? console.error : level === 'warn' ? console.warn : console.log;
    fn(`[poin:${cat}] ${msg}`, data ?? '');
  }
}

function safe(data: unknown): unknown {
  if (data === undefined) return undefined;
  if (data instanceof Error) return { name: data.name, message: data.message, stack: data.stack };
  try {
    JSON.stringify(data);
    return data;
  } catch {
    return String(data);
  }
}

export const log = {
  debug: (cat: LogCategory, msg: string, data?: unknown) => emit('debug', cat, msg, data),
  info: (cat: LogCategory, msg: string, data?: unknown) => emit('info', cat, msg, data),
  warn: (cat: LogCategory, msg: string, data?: unknown) => emit('warn', cat, msg, data),
  error: (cat: LogCategory, msg: string, data?: unknown) => emit('error', cat, msg, data),
  /** 구간 측정: const end = log.time('infer', '추론'); ... end({ok:true}) */
  time: (cat: LogCategory, msg: string) => {
    const t0 = performance.now();
    return (data?: Record<string, unknown>) => {
      const ms = Math.round(performance.now() - t0);
      emit('info', cat, `${msg} (${ms}ms)`, { ...data, ms });
      return ms;
    };
  },
  entries: () => buffer.slice(),
  subscribe: (fn: (e: LogEntry) => void) => {
    listeners.add(fn);
    return () => listeners.delete(fn);
  },
};

async function flush() {
  if (!outbox.length) return;
  const batch = outbox.splice(0, outbox.length);
  try {
    await fetch('/api/log', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(batch), keepalive: true });
  } catch {
    // 서버가 죽어도 앱은 계속 돈다. 메모리 버퍼에는 남아 있다.
  }
}

let installed = false;
/** 앱 시작 시 한 번 호출: 전역 에러 포착 + 주기적 전송 */
export function installClientLogging(sessionId: string) {
  if (!isBrowser || installed) return;
  installed = true;
  window.addEventListener('error', (ev) => emit('error', 'runtime', ev.message, { file: ev.filename, line: ev.lineno, col: ev.colno, stack: ev.error?.stack }));
  window.addEventListener('unhandledrejection', (ev) => emit('error', 'runtime', 'unhandled rejection', safe(ev.reason)));
  window.addEventListener('pagehide', () => void flush());
  setInterval(() => void flush(), 2000);
  emit('info', 'session', '세션 시작', { sessionId, ua: navigator.userAgent, w: innerWidth, h: innerHeight });
}
