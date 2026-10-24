'use client';
// 감지 모드 섹션 (시안 04). 썸네일은 D의 SenseThumb, 오른쪽은 pitch/yaw 미니 그래프와 제스처·찌푸림·시선·fps.
import { useId } from 'react';
import { t } from '@/i18n';
import SenseThumb from '@/poin/sense/SenseThumb';
import { usePoin } from '@/poin/store';
import { useLiveSample } from './useLiveSample';
import { Section } from './ui';

const W = 150;
const H = 26;
const RANGE = 30; // ±30도를 그래프 높이에 맞춘다

function toPath(hist: number[]) {
  if (hist.length < 2) return '';
  const step = W / Math.max(1, hist.length - 1);
  return hist
    .map((v, i) => {
      const y = H / 2 - (Math.max(-RANGE, Math.min(RANGE, v)) / RANGE) * (H / 2 - 2);
      return `${i === 0 ? 'M' : 'L'}${(i * step).toFixed(1)} ${y.toFixed(1)}`;
    })
    .join(' ');
}

function HeadGraph({ pitch, yaw }: { pitch: number[]; yaw: number[] }) {
  const gid = `hg${useId().replace(/:/g, '')}`;
  return (
    <svg width={W} height={H} viewBox={`0 0 ${W} ${H}`} className="block max-w-full" aria-hidden>
      <defs>
        <linearGradient id={gid} x1="0" x2="1">
          <stop offset="0" stopColor="#F55702" />
          <stop offset="1" stopColor="#EEAECA" />
        </linearGradient>
      </defs>
      <path d={`M0 ${H / 2} L${W} ${H / 2}`} stroke="rgba(255,255,255,.25)" strokeDasharray="2 3" />
      <path d={toPath(pitch)} fill="none" stroke={`url(#${gid})`} strokeOpacity={0.45} strokeWidth={1.1} strokeLinejoin="round" />
      <path d={toPath(yaw)} fill="none" stroke={`url(#${gid})`} strokeWidth={1.6} strokeLinejoin="round" />
    </svg>
  );
}

export default function SenseSection() {
  const status = usePoin((st) => st.senseStatus);
  const ts = t.panel.sense;

  if (status === 'denied' || status === 'error') {
    return (
      <Section>
        <div className="leading-[1.55] text-[var(--c-warn-text)] brightness-150">{status === 'denied' ? ts.denied : ts.error}</div>
      </Section>
    );
  }
  if (status !== 'on') return null;
  return <SenseOn />;
}

function SenseOn() {
  const sample = useLiveSample(100);
  const s = sample.sense;
  const ts = t.panel.sense;
  const recent = s.gesture !== 'none' && s.gestureAt > 0 && sample.now - s.gestureAt < 1500;

  return (
    <Section>
      <div className="grid grid-cols-[80px_1fr] items-center gap-2.5">
        <div className="relative h-[62px] overflow-hidden rounded-xl bg-[linear-gradient(160deg,#4A3A44,#2B2530)]">
          <SenseThumb />
        </div>
        <div className="flex min-w-0 flex-col gap-[5px] text-[var(--on-dark-muted)]">
          <HeadGraph pitch={s.pitchHistory} yaw={s.yawHistory} />
          <span className="flex items-center gap-1.5 whitespace-nowrap">
            {ts.head}
            {recent && (
              <span className="poin-heat rounded-full px-[7px] py-px text-[10.5px] font-bold text-[#1A1A1A]">
                {s.gesture === 'nod' ? ts.nod : ts.shake}
              </span>
            )}
          </span>
          <span className="whitespace-nowrap tabular-nums">
            {ts.brow} <b className="font-medium text-[var(--on-dark)]">{s.brow.toFixed(2)}</b> · {ts.gaze}{' '}
            <b className="font-medium text-[var(--on-dark)]">{s.faceFound ? ts.gazeRegion[s.gaze] : ts.noFace}</b>
          </span>
          <span className="tabular-nums">
            <b className="font-medium text-[var(--on-dark)]">{Math.round(s.fps)}</b> {ts.fps}
          </span>
        </div>
      </div>
    </Section>
  );
}
