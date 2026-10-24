'use client';
// 세션 JSON 내보내기. LogPanel과 Retro가 같은 함수를 쓴다.
import { log } from '@/lib/log';
import { poin } from '@/poin/store';

export function exportSession() {
  const s = poin();
  const payload = {
    sessionId: s.sessionId,
    startedAt: s.startedAt,
    exportedAt: Date.now(),
    settings: s.settings,
    traces: s.traces,
    signals: s.signals,
    logs: log.entries(),
  };
  try {
    const json = JSON.stringify(payload, null, 2);
    const blob = new Blob([json], { type: 'application/json' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = `poin-session-${s.sessionId}.json`;
    a.setAttribute('data-poin-layer', '');
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    log.info('session', '세션 JSON 내보내기', {
      sessionId: s.sessionId,
      traces: s.traces.length,
      signals: s.signals.length,
      logs: payload.logs.length,
      bytes: json.length,
    });
  } catch (err) {
    log.error('session', '세션 JSON 내보내기 실패', err);
  }
}
