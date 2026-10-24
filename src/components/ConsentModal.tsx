'use client';
// 첫 방문 동의. 동의 전에는 poin 신호 읽기를 멈춰 둔다. 선택은 이 브라우저에 기억한다.
import { useEffect, useState, useSyncExternalStore } from 'react';
import { t } from '@/i18n';
import { log } from '@/lib/log';
import { usePoin } from '@/poin/store';

const KEY = 'poin-consent-v1';

function read(): string | null {
  try {
    return localStorage.getItem(KEY);
  } catch {
    return null;
  }
}

function write(v: 'yes' | 'no') {
  try {
    localStorage.setItem(KEY, v);
  } catch {
    // 저장이 막혀 있으면 이번 탭에서만 유지된다.
  }
}

const noop = () => () => {};

export default function ConsentModal() {
  // 서버 렌더에서는 'yes'로 보고 모달을 그리지 않는다(하이드레이션 불일치 방지).
  const stored = useSyncExternalStore(noop, () => read() ?? 'unset', () => 'yes');
  const [chosen, setChosen] = useState<'yes' | 'no' | null>(null);
  const setSettings = usePoin((s) => s.setSettings);
  const open = stored === 'unset' && chosen === null;

  useEffect(() => {
    if (stored === 'yes') return;
    setSettings({ paused: true });
    if (stored === 'no') log.info('session', '동의 거절 상태로 시작: poin 일시정지');
  }, [stored, setSettings]);

  if (!open) return null;

  const choose = (v: 'yes' | 'no') => {
    write(v);
    setSettings({ paused: v === 'no' });
    log.info('session', v === 'yes' ? '동의함' : '동의 거절: poin 일시정지');
    setChosen(v);
  };

  return (
    <div data-poin-layer className="fixed inset-0 z-[80] grid place-items-center bg-black/20 backdrop-blur-md">
      <div role="dialog" aria-modal="true" className="poin-glass w-[min(560px,calc(100vw-32px))] rounded-[28px] p-8 shadow-2xl">
        <div className="flex items-center gap-2 text-[13px] text-[var(--on-dark-muted)]">
          <span className="poin-orb" />
          poin
        </div>
        <h2 className="mt-3 text-[24px] font-semibold tracking-[-0.02em]">{t.consent.title}</h2>
        <p className="mt-2 text-[14px] leading-relaxed text-[var(--on-dark-muted)]">{t.consent.lead}</p>
        <ul className="mt-5 flex flex-col gap-2.5 text-[14px] leading-relaxed">
          {t.consent.items.map((it) => (
            <li key={it} className="flex gap-2.5">
              <span className="mt-[9px] h-1 w-1 flex-none rounded-full bg-[var(--poin-amber)]" />
              {it}
            </li>
          ))}
        </ul>
        <div className="mt-7 flex gap-2.5">
          <button autoFocus onClick={() => choose('yes')} className="rounded-full bg-[#F2F2F2] px-5 py-2.5 text-[14px] font-semibold text-[#1A1A1A]">
            {t.consent.accept}
          </button>
          <button onClick={() => choose('no')} className="rounded-full bg-white/10 px-5 py-2.5 text-[14px] font-semibold">
            {t.consent.decline}
          </button>
        </div>
      </div>
    </div>
  );
}
