'use client';
// 운영 로그 패널 (시안 v4 .panel). 모든 화면 왼쪽에 고정, 기본 펼침, ` 키로 접기/펼치기.
import { useEffect, useState } from 'react';
import { t } from '@/i18n';
import { log } from '@/lib/log';
import { usePoin } from '@/poin/store';
import Controls from './Controls';
import { exportSession } from './exportSession';
import Gauges from './Gauges';
import SenseSection from './SenseSection';
import SignalStream from './SignalStream';
import SystemLog from './SystemLog';
import TraceList from './TraceList';
import { ToolButton } from './ui';

// 채팅보다 위, 칩(시안 z 20)·커서 오브(31)·회고(60)보다 아래
const Z = 15;

function isTypingTarget(el: EventTarget | null) {
  if (!(el instanceof HTMLElement)) return false;
  if (el.isContentEditable) return true;
  const tag = el.tagName;
  if (tag === 'TEXTAREA' || tag === 'SELECT') return true;
  if (tag === 'INPUT') {
    const type = (el as HTMLInputElement).type;
    return !['range', 'checkbox', 'radio', 'button', 'submit'].includes(type);
  }
  return false;
}

export default function LogPanel() {
  const [open, setOpen] = useState(true);
  const paused = usePoin((s) => s.settings.paused);
  const setSettings = usePoin((s) => s.setSettings);
  const tp = t.panel;

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.code !== 'Backquote' || e.isComposing || e.altKey || e.metaKey || e.ctrlKey) return;
      if (isTypingTarget(e.target) || isTypingTarget(document.activeElement)) return;
      e.preventDefault();
      setOpen((o) => !o);
      log.info('control', '로그 패널 토글 (` 키)');
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  const togglePause = () => setSettings({ paused: !paused });

  if (!open) {
    return (
      <button
        type="button"
        data-poin-layer
        onClick={() => setOpen(true)}
        className="poin-glass fixed bottom-4 left-4 flex items-center gap-2 rounded-full px-3.5 py-[7px] text-[12px] font-medium shadow-[0_20px_40px_-20px_rgba(40,10,30,.6)]"
        style={{ zIndex: Z }}
      >
        <span className="poin-orb" />
        {tp.collapsedPill}
        {paused && <span className="text-[var(--on-dark-muted)]">{` · ${tp.pausedBadge}`}</span>}
      </button>
    );
  }

  return (
    <aside
      data-poin-layer
      className="poin-glass fixed bottom-4 left-4 top-4 flex w-[270px] flex-col overflow-hidden rounded-[24px] text-[11.5px] shadow-[0_30px_60px_-30px_rgba(40,10,30,.6)]"
      style={{ zIndex: Z, fontFeatureSettings: '"tnum"' }}
    >
      <div className="flex items-center justify-between px-4 pb-3 pt-3.5">
        <b className="flex items-center gap-2 text-[13px] font-semibold">
          <span className={`poin-orb ${paused ? 'opacity-40 grayscale' : ''}`} />
          {tp.title}
        </b>
        <div className="flex gap-2.5">
          <ToolButton onClick={togglePause}>
            {paused ? <span className="text-[var(--poin-amber)]">{tp.resume}</span> : tp.pause}
          </ToolButton>
          <ToolButton onClick={exportSession}>{tp.export}</ToolButton>
          <ToolButton onClick={() => setOpen(false)}>{tp.collapse}</ToolButton>
        </div>
      </div>
      <Gauges />
      <SenseSection />
      <TraceList />
      <SignalStream />
      <SystemLog />
      <Controls />
    </aside>
  );
}
