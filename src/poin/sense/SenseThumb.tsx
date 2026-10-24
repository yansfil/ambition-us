'use client';
// 패널 감지 섹션의 80×62 미리보기. 로컬 video 프레임을 좌우 반전·어둡게 그리고 랜드마크를 점으로 얹는다.
// 그린 이미지는 이 캔버스에만 존재한다. 읽어 내거나(toDataURL 등) 어디로 보내지 않는다.
import { useEffect, useRef } from 'react';
import { t } from '@/i18n';
import { live } from '@/poin/live';
import { getSenseVideo } from './video';

const W = 80;
const H = 62;
const FRAME_MS = 1000 / 15;

export default function SenseThumb() {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const labelRef = useRef<HTMLSpanElement>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    const ctx = canvas?.getContext('2d');
    if (!canvas || !ctx) return;
    const dpr = Math.min(2, window.devicePixelRatio || 1);
    canvas.width = W * dpr;
    canvas.height = H * dpr;

    let raf = 0;
    let last = 0;
    let lastLabel = '';
    const setLabel = (text: string) => {
      if (text === lastLabel || !labelRef.current) return;
      lastLabel = text;
      labelRef.current.textContent = text;
      labelRef.current.style.display = text ? '' : 'none';
    };

    const draw = (now: number) => {
      raf = requestAnimationFrame(draw);
      if (now - last < FRAME_MS) return;
      last = now;
      try {
        ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
        const g = ctx.createLinearGradient(0, 0, W * 0.6, H);
        g.addColorStop(0, '#4A3A44');
        g.addColorStop(1, '#2B2530');
        ctx.fillStyle = g;
        ctx.fillRect(0, 0, W, H);

        const v = getSenseVideo();
        if (!v || v.readyState < 2 || !v.videoWidth) {
          setLabel(v ? t.sense.thumbSearching : t.sense.thumbOff);
          return;
        }
        // cover 맞춤 + 좌우 반전(거울처럼)
        const scale = Math.max(W / v.videoWidth, H / v.videoHeight);
        const dw = v.videoWidth * scale;
        const dh = v.videoHeight * scale;
        const dx = (W - dw) / 2;
        const dy = (H - dh) / 2;
        ctx.save();
        ctx.translate(W, 0);
        ctx.scale(-1, 1);
        ctx.drawImage(v, dx, dy, dw, dh);
        ctx.restore();
        ctx.fillStyle = 'rgba(20, 20, 22, 0.55)';
        ctx.fillRect(0, 0, W, H);

        const s = live.sense;
        if (s.faceFound && s.landmarks) {
          ctx.fillStyle = '#F5AA64';
          for (const p of s.landmarks) {
            const x = W - (dx + p.x * dw);
            const y = dy + p.y * dh;
            ctx.beginPath();
            ctx.arc(x, y, 0.7, 0, Math.PI * 2);
            ctx.fill();
          }
          setLabel('');
        } else {
          setLabel(t.sense.thumbSearching);
        }
      } catch {
        // 그리기 실패는 미리보기만 비울 뿐 앱에 영향 없음
      }
    };
    raf = requestAnimationFrame(draw);
    return () => cancelAnimationFrame(raf);
  }, []);

  return (
    <div
      data-poin-layer
      className="relative h-[62px] w-[80px] flex-none overflow-hidden rounded-[12px]"
      role="img"
      aria-label={t.sense.thumbAria}
    >
      <canvas ref={canvasRef} className="absolute inset-0 h-full w-full" />
      <span
        ref={labelRef}
        className="absolute inset-x-0 bottom-[5px] text-center text-[9px] leading-none text-[var(--on-dark-muted)]"
      >
        {t.sense.thumbOff}
      </span>
    </div>
  );
}
