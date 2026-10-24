'use client';
// 커서 동반자: 노을빛 오브가 커서 오른쪽 아래(+16, +20)에 늘 붙어 다닌다.
// 추론 중이면 오브 주위에 얇은 링이 맥박 친다. 칩이 떠 있으면 칩 머리로 흡수된 것처럼 숨긴다.
import { useRef } from 'react';
import { usePoin } from '../store';
import { useFollowCursor } from './follow';

const FOLLOW = { offsetX: 16, offsetY: 20, smoothing: 0.35 };

export default function Companion() {
  const ref = useRef<HTMLDivElement>(null);
  const chipShown = usePoin((s) => !!s.activeChip);
  const inferring = usePoin((s) => s.traces.some((t) => t.status === 'inferring'));
  useFollowCursor(ref, FOLLOW);

  return (
    <div
      ref={ref}
      data-poin-layer
      aria-hidden
      className="pointer-events-none fixed left-0 top-0 z-[70] transition-opacity duration-150"
      style={{ opacity: 0, willChange: 'transform' }}
    >
      <div
        className="relative transition-[opacity,scale] duration-200"
        style={{ opacity: chipShown ? 0 : 1, scale: chipShown ? '0.4' : '1' }}
      >
        <style>{`@keyframes poin-ring{0%,100%{transform:scale(.85);opacity:.35}50%{transform:scale(1.25);opacity:.9}}`}</style>
        <span className="poin-orb block" style={{ width: 11, height: 11 }} />
        {inferring && (
          <span
            className="absolute rounded-full"
            style={{
              left: -5, top: -5, width: 21, height: 21,
              border: '1px solid rgba(245,120,2,.55)',
              animation: 'poin-ring 1.1s ease-in-out infinite',
            }}
          />
        )}
      </div>
    </div>
  );
}
