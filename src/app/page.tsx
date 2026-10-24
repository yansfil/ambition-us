'use client';
// 통합 지점. 각 모듈의 진입 컴포넌트만 배치한다(CONTRACTS.md 참고).
import { useEffect } from 'react';
import ChatApp from '@/components/chat/ChatApp';
import CartPill from '@/components/chat/CartPill';
import PoinRuntime from '@/poin/engine/PoinRuntime';
import Companion from '@/poin/ui/Companion';
import Chip from '@/poin/ui/Chip';
import LogPanel from '@/poin/panel/LogPanel';
import Retro from '@/poin/panel/Retro';
import SenseRunner from '@/poin/sense/SenseRunner';
import SenseToggle from '@/poin/sense/SenseToggle';
import CameraBadge from '@/poin/sense/CameraBadge';
import ConsentModal from '@/components/ConsentModal';
import { installClientLogging, log } from '@/lib/log';
import { usePoin } from '@/poin/store';

export default function Home() {
  const sessionId = usePoin((s) => s.sessionId);
  useEffect(() => installClientLogging(sessionId), [sessionId]);
  // E2E(scripts/e2e-aside.mjs)가 상태와 로그를 읽는 개발 전용 창구
  useEffect(() => {
    if (process.env.NODE_ENV !== 'development') return;
    (window as unknown as { __poinTest?: unknown }).__poinTest = {
      getState: () => usePoin.getState(),
      logs: () => log.entries(),
    };
  }, []);

  return (
    <main className="relative h-dvh w-full overflow-hidden bg-white">
      <PoinRuntime />
      <SenseRunner />
      <LogPanel />
      <ChatApp />
      <div className="fixed right-5 top-4 z-[25] flex gap-2">
        <CameraBadge />
        <SenseToggle />
        <CartPill />
      </div>
      <Chip />
      <Companion />
      <Retro />
      <ConsentModal />
    </main>
  );
}
