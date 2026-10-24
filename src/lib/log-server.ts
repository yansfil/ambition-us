// 서버 로거. 개발에서는 클라이언트 로그와 같은 JSONL 파일에 쓴다: logs/poin-YYYYMMDD.jsonl
// 프로덕션(Vercel 등 읽기 전용 파일시스템)에서는 콘솔에만 찍는다. 호스팅의 런타임 로그로 남는다.
import { appendFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
import type { LogCategory, LogEntry, LogLevel } from './log';

const dir = path.join(process.cwd(), 'logs');
const file = () => path.join(dir, `poin-${new Date().toISOString().slice(0, 10).replace(/-/g, '')}.jsonl`);

const fileLogging = process.env.NODE_ENV === 'development';

export async function writeEntries(entries: LogEntry[]) {
  if (!entries.length || !fileLogging) return;
  await mkdir(dir, { recursive: true });
  await appendFile(file(), entries.map((e) => JSON.stringify(e)).join('\n') + '\n');
}

function emit(level: LogLevel, cat: LogCategory, msg: string, data?: unknown) {
  const e: LogEntry = { t: Date.now(), level, cat, msg, data, src: 'server' };
  const fn = level === 'error' ? console.error : level === 'warn' ? console.warn : console.log;
  fn(`[poin:${cat}] ${msg}`, data === undefined ? '' : JSON.stringify(data));
  void writeEntries([e]).catch((err) => console.error('[poin:runtime] 로그 파일 쓰기 실패', err));
}

export const slog = {
  info: (cat: LogCategory, msg: string, data?: unknown) => emit('info', cat, msg, data),
  warn: (cat: LogCategory, msg: string, data?: unknown) => emit('warn', cat, msg, data),
  error: (cat: LogCategory, msg: string, data?: unknown) =>
    emit('error', cat, msg, data instanceof Error ? { name: data.name, message: data.message, stack: data.stack } : data),
};
