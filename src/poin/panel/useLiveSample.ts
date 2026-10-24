'use client';
// live(비반응 객체)를 일정 간격으로 복사해 로컬 상태로 쓴다. live 자체는 React 상태로 옮기지 않는다.
import { useEffect, useState } from 'react';
import { live, type LiveSense } from '@/poin/live';

export interface LiveSample {
  now: number;
  typingCpm: number;
  pauseMs: number;
  deleteBursts: number;
  focusIdleMs: number;
  cursorTarget: string | null;
  cursorTargetLabel: string | null;
  dwellMs: number;
  oscillations: number;
  scrollReversals: number;
  sense: Omit<LiveSense, 'landmarks'>;
}

const ZERO: LiveSample = {
  now: 0, typingCpm: 0, pauseMs: 0, deleteBursts: 0, focusIdleMs: 0,
  cursorTarget: null, cursorTargetLabel: null, dwellMs: 0, oscillations: 0, scrollReversals: 0,
  sense: { fps: 0, pitch: 0, yaw: 0, pitchHistory: [], yawHistory: [], brow: 0, gesture: 'none', gestureAt: 0, gaze: 'unknown', faceFound: false },
};

function snap(): LiveSample {
  const s = live.sense;
  return {
    now: Date.now(),
    typingCpm: live.typingCpm,
    pauseMs: live.pauseMs,
    deleteBursts: live.deleteBursts,
    focusIdleMs: live.focusIdleMs,
    cursorTarget: live.cursorTarget,
    cursorTargetLabel: live.cursorTargetLabel,
    dwellMs: live.dwellMs,
    oscillations: live.oscillations,
    scrollReversals: live.scrollReversals,
    sense: {
      fps: s.fps, pitch: s.pitch, yaw: s.yaw,
      pitchHistory: s.pitchHistory.slice(), yawHistory: s.yawHistory.slice(),
      brow: s.brow, gesture: s.gesture, gestureAt: s.gestureAt, gaze: s.gaze, faceFound: s.faceFound,
    },
  };
}

export function useLiveSample(intervalMs = 100): LiveSample {
  const [sample, setSample] = useState<LiveSample>(ZERO);
  useEffect(() => {
    const id = window.setInterval(() => setSample(snap()), intervalMs);
    return () => window.clearInterval(id);
  }, [intervalMs]);
  return sample;
}

/** 초 단위로만 바뀌면 되는 곳(남은 시간 등)용 시계 */
export function useNow(intervalMs = 250): number {
  const [now, setNow] = useState(0);
  useEffect(() => {
    const id = window.setInterval(() => setNow(Date.now()), intervalMs);
    return () => window.clearInterval(id);
  }, [intervalMs]);
  return now;
}
