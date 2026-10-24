'use client';
// 커서 따라다니기: rAF + 스무딩, transform만 쓰고 React 리렌더 없이 ref로 움직인다.
import { useEffect, type RefObject } from 'react';
import { live } from '../live';

export interface FollowOptions {
  offsetX: number;
  offsetY: number;
  smoothing: number; // 0..1, 프레임마다 목표로 다가가는 비율
  flip?: boolean; // 뷰포트 끝이면 위/왼쪽으로 뒤집기
  margin?: number;
  /** 뒤집힘 상태가 바뀔 때(모서리 둥글기 조정 등) */
  onFlip?: (flipX: boolean, flipY: boolean) => void;
  /** 매 프레임 보일지 여부(창 안 + 커서 움직임 있음) 알림 */
  onVisible?: (visible: boolean) => void;
}

export function useFollowCursor(ref: RefObject<HTMLElement | null>, opts: FollowOptions, active = true) {
  const { offsetX, offsetY, smoothing, flip = false, margin = 8, onFlip, onVisible } = opts;
  useEffect(() => {
    if (!active) return;
    let raf = 0;
    let x = NaN;
    let y = NaN;
    let inWindow = true;
    let moved = live.cursor.x !== 0 || live.cursor.y !== 0;
    let lastFlip = '';
    let lastVisible: boolean | null = null;

    const onOut = (e: MouseEvent) => { if (!e.relatedTarget) inWindow = false; };
    const onOver = () => { inWindow = true; };
    const onMove = () => { moved = true; inWindow = true; };
    document.addEventListener('mouseout', onOut);
    document.addEventListener('mouseover', onOver);
    document.addEventListener('mousemove', onMove, { passive: true });

    const frame = () => {
      raf = requestAnimationFrame(frame);
      const el = ref.current;
      if (!el) return;
      const visible = moved && inWindow;
      if (visible !== lastVisible) {
        lastVisible = visible;
        el.style.opacity = visible ? '1' : '0';
        onVisible?.(visible);
      }
      const cx = live.cursor.x;
      const cy = live.cursor.y;
      let tx = cx + offsetX;
      let ty = cy + offsetY;
      let fx = false;
      let fy = false;
      if (flip) {
        const w = el.offsetWidth;
        const h = el.offsetHeight;
        if (tx + w > innerWidth - margin) { tx = cx - offsetX - w; fx = true; }
        if (ty + h > innerHeight - margin) { ty = cy - offsetY - h; fy = true; }
        tx = Math.max(margin, tx);
        ty = Math.max(margin, ty);
        const key = `${fx}${fy}`;
        if (key !== lastFlip) {
          lastFlip = key;
          onFlip?.(fx, fy);
        }
      }
      if (Number.isNaN(x) || !visible) {
        x = tx;
        y = ty;
      } else {
        x += (tx - x) * smoothing;
        y += (ty - y) * smoothing;
      }
      el.style.transform = `translate3d(${x.toFixed(1)}px, ${y.toFixed(1)}px, 0)`;
    };
    raf = requestAnimationFrame(frame);
    return () => {
      cancelAnimationFrame(raf);
      document.removeEventListener('mouseout', onOut);
      document.removeEventListener('mouseover', onOver);
      document.removeEventListener('mousemove', onMove);
    };
  }, [ref, active, offsetX, offsetY, smoothing, flip, margin, onFlip, onVisible]);
}
