'use client';
// 감지 모드가 켜진 직후 한 번: 고개로 답할 수 있다고 알려 준다.
import { useEffect, useRef, useState } from 'react';
import { t } from '@/i18n';
import { usePoin } from '@/poin/store';

const SHOW_MS = 6000;

export default function SenseCoach() {
  const status = usePoin((s) => s.senseStatus);
  const [visible, setVisible] = useState(false);
  const prev = useRef(status);

  useEffect(() => {
    const was = prev.current;
    prev.current = status;
    if (status !== 'on' || was === 'on') return;
    const show = setTimeout(() => setVisible(true), 0);
    const hide = setTimeout(() => setVisible(false), SHOW_MS);
    return () => {
      clearTimeout(show);
      clearTimeout(hide);
    };
  }, [status]);

  if (!visible || status !== 'on') return null;
  return (
    <div data-poin-layer className="pointer-events-none fixed left-1/2 top-16 z-[65] -translate-x-1/2">
      <div className="poin-glass poin-pop flex items-center gap-2.5 rounded-full px-4 py-2.5 text-[13.5px] font-medium shadow-xl">
        <span className="poin-orb" />
        {t.sense.coachReady}
      </div>
    </div>
  );
}
