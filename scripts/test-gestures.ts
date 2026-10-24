// 감지 모드 판정 로직 검증. 카메라 없이 합성 pitch/yaw/blendshape 시퀀스를 넣는다.
// 실행: node scripts/test-gestures.ts  (Node 26 타입 제거 실행)
// tsconfig에 allowImportingTsExtensions가 없어 정적 `.ts` import 대신 동적 import를 쓴다(tsc는 타입만 본다).

type GesturesMod = typeof import('../src/poin/sense/gestures');
type GazeMod = typeof import('../src/poin/sense/gaze');

const G = (await import(new URL('../src/poin/sense/gestures.ts', import.meta.url).href)) as GesturesMod;
const Z = (await import(new URL('../src/poin/sense/gaze.ts', import.meta.url).href)) as GazeMod;

const FPS = 30;
const DT = 1000 / FPS;
let failures = 0;
let passes = 0;

function check(name: string, ok: boolean, detail: string) {
  if (ok) passes++;
  else failures++;
  console.log(`${ok ? 'PASS' : 'FAIL'}  ${name}  (${detail})`);
}

// 결정적 잡음
let seed = 7;
const rnd = () => {
  seed = (seed * 1103515245 + 12345) % 2147483648;
  return seed / 2147483648 - 0.5;
};

interface Frame { pitch: number; yaw: number; brow?: number }

/** 보정(1.5초 + 여유) 후 시퀀스를 넣고 이벤트를 모은다. 중립 자세는 일부러 0이 아닌 값. */
function run(seq: (t: number) => Frame, durationMs: number, opts: { neutral?: Frame } = {}) {
  const tr = G.createGestureTracker();
  const n = opts.neutral ?? { pitch: -6, yaw: 4, brow: 0.12 };
  let t = 0;
  for (; t < 1700; t += DT) {
    tr.update({ t, pose: { pitch: n.pitch + rnd() * 0.8, yaw: n.yaw + rnd() * 0.8 }, browDown: (n.brow ?? 0) + rnd() * 0.02 });
  }
  const t0 = t;
  const gestures: { t: number; type: string; confidence: number }[] = [];
  const browEdges: { t: number; value: number }[] = [];
  const brows: number[] = [];
  for (; t < t0 + durationMs; t += DT) {
    const f = seq(t - t0);
    const out = tr.update({
      t,
      pose: { pitch: n.pitch + f.pitch, yaw: n.yaw + f.yaw },
      browDown: (n.brow ?? 0) + (f.brow ?? 0),
    });
    if (out.gesture) gestures.push({ t: Math.round(t - t0), ...out.gesture });
    if (out.browEdge) browEdges.push({ t: Math.round(t - t0), value: out.browEdge.value });
    brows.push(out.brow);
  }
  return { tr, gestures, browEdges, brows };
}

const sin = (amp: number, hz: number, ms: number) => amp * Math.sin(2 * Math.PI * hz * (ms / 1000));
const fmt = (gs: { type: string; t: number; confidence: number }[]) =>
  gs.length ? gs.map((g) => `${g.type}@${g.t}ms c=${g.confidence}`).join(', ') : '없음';

// 1. 보정
{
  const r = run(() => ({ pitch: 0, yaw: 0 }), 100);
  const b = r.tr.baseline;
  check('보정: 1.5초 후 중립 자세 기준점', !!b && Math.abs(b.pitch + 6) < 0.5 && Math.abs(b.yaw - 4) < 0.5 && Math.abs(b.brow - 0.12) < 0.02,
    b ? `pitch=${b.pitch.toFixed(2)} yaw=${b.yaw.toFixed(2)} brow=${b.brow.toFixed(3)}` : '보정 안 됨');
}

// 2. 끄덕임: pitch ±10°, 2Hz, 1.2초
{
  const r = run((ms) => (ms < 1200 ? { pitch: sin(10, 2, ms) + rnd(), yaw: rnd() * 1.5 } : { pitch: rnd(), yaw: rnd() }), 2500);
  check('끄덕임 → nod 1회', r.gestures.length === 1 && r.gestures[0].type === 'nod', fmt(r.gestures));
}

// 3. 젓기: yaw ±12°, 2Hz
{
  const r = run((ms) => (ms < 1200 ? { pitch: rnd() * 1.5, yaw: sin(12, 2, ms) + rnd() } : { pitch: rnd(), yaw: rnd() }), 2500);
  check('젓기 → shake 1회', r.gestures.length === 1 && r.gestures[0].type === 'shake', fmt(r.gestures));
}

// 4. 가만히 5초
{
  const r = run(() => ({ pitch: rnd() * 1.2, yaw: rnd() * 1.2 }), 5000);
  check('가만히 → 제스처 없음', r.gestures.length === 0, fmt(r.gestures));
}

// 5. 말하며 살짝 움직임: pitch ±3° 3Hz, yaw ±2.5° 1.7Hz, 잡음
{
  const r = run((ms) => ({ pitch: sin(3, 3, ms) + rnd() * 1.5, yaw: sin(2.5, 1.7, ms) + rnd() * 1.5 }), 8000);
  check('말하며 살짝 움직임 → 제스처 없음', r.gestures.length === 0, fmt(r.gestures));
}

// 6. 한 번 내려다보고 유지(방향 전환 0~1회)
{
  const r = run((ms) => ({ pitch: -Math.min(15, ms / 60) + rnd(), yaw: rnd() }), 3000);
  check('내려다보고 유지 → 제스처 없음', r.gestures.length === 0, fmt(r.gestures));
}

// 7. 대각선 흔들림(두 축 모두 큼) → 보조축이 조용하지 않음
{
  const r = run((ms) => ({ pitch: sin(10, 2, ms), yaw: sin(10, 2, ms + 60) }), 3000);
  check('대각선 흔들림 → 제스처 없음', r.gestures.length === 0, fmt(r.gestures));
}

// 8. 진폭 부족 끄덕임(±3°, 범위 6° < 8°)
{
  const r = run((ms) => ({ pitch: sin(3, 2, ms), yaw: rnd() * 0.5 }), 3000);
  check('작은 끄덕임(6°) → 제스처 없음', r.gestures.length === 0, fmt(r.gestures));
}

// 9. 쿨다운·재무장: 4초 내내 끄덕임 → 한 동작이므로 1회. 끄덕임-멈춤-끄덕임 → 2회, 간격 ≥ 1초
{
  const r = run((ms) => ({ pitch: sin(10, 2, ms) + rnd(), yaw: rnd() }), 4000);
  check('계속 끄덕임(한 동작) → nod 1회', r.gestures.length === 1 && r.gestures[0].type === 'nod', fmt(r.gestures));
  const r2 = run((ms) => (ms < 900 || (ms >= 1900 && ms < 2800) ? { pitch: sin(10, 2, ms) + rnd(), yaw: rnd() } : { pitch: rnd(), yaw: rnd() }), 4000);
  const gaps = r2.gestures.slice(1).map((g, i) => g.t - r2.gestures[i].t);
  check('끄덕-멈춤-끄덕 → nod 2회, 간격 ≥ 1초', r2.gestures.length === 2 && gaps.every((g) => g >= 1000), `${fmt(r2.gestures)} / 간격 ${gaps.join(',')}ms`);
  const r3 = run((ms) => (ms < 900 ? { pitch: sin(10, 2, ms) + rnd(), yaw: rnd() } : ms < 1300 ? { pitch: rnd(), yaw: rnd() } : ms < 2200 ? { pitch: rnd(), yaw: sin(12, 2, ms) + rnd() } : { pitch: rnd(), yaw: rnd() }), 3500);
  check('끄덕 → 곧바로 젓기 → nod, shake 순서', r3.gestures.map((g) => g.type).join(',') === 'nod,shake', fmt(r3.gestures));
}

// 10. 찌푸림: 상승 → 엣지 1회, 0.35~0.45 사이 출렁임 → 추가 없음, 내려갔다 다시 상승 → 2회째
{
  const raw = (ms: number) => {
    // 기준점 대비 증가분(browSpan 0.5 → 정규화 = 증가분/0.5)
    if (ms < 500) return 0;
    if (ms < 1500) return 0.3; // 0.6
    if (ms < 2500) return 0.2; // 0.4: 히스테리시스 안
    if (ms < 3000) return 0.3;
    if (ms < 4000) return 0.05; // 0.1: 재무장
    if (ms < 5000) return 0.35; // 0.7: 두 번째 엣지
    return 0;
  };
  const r = run((ms) => ({ pitch: rnd() * 0.5, yaw: rnd() * 0.5, brow: raw(ms) + rnd() * 0.01 }), 6000);
  const max = Math.max(...r.brows);
  check('찌푸림 상승·하강 → 엣지 정확히 2회', r.browEdges.length === 2 && r.browEdges[0].t >= 500 && r.browEdges[0].t < 1500 && r.browEdges[1].t >= 4000,
    `엣지 ${r.browEdges.map((e) => `${e.t}ms v=${e.value}`).join(', ') || '없음'} / 최대 ${max}`);
  check('찌푸림 값 범위 0..1', r.brows.every((b) => b >= 0 && b <= 1), `min ${Math.min(...r.brows)} max ${max}`);
  check('찌푸림 중 제스처 없음', r.gestures.length === 0, fmt(r.gestures));
}

// 11. 얼굴 놓침: 끄덕임 중간에 lost()가 들어오면 공백을 건너 이어 붙이지 않는다(대조군: lost 없음 → 발화)
{
  const trial = (withLost: boolean) => {
    const tr = G.createGestureTracker();
    let t = 0;
    for (; t < 1700; t += DT) tr.update({ t, pose: { pitch: 0, yaw: 0 }, browDown: 0 });
    let fired = 0;
    for (let k = 0; k < 9; k++, t += DT) if (tr.update({ t, pose: { pitch: sin(10, 2, k * DT), yaw: 0 }, browDown: 0 }).gesture) fired++;
    if (withLost) tr.lost();
    for (let k = 0; k < 12; k++, t += DT) if (tr.update({ t, pose: { pitch: sin(10, 2, k * DT), yaw: 0 }, browDown: 0 }).gesture) fired++;
    return fired;
  };
  const a = trial(true), b = trial(false);
  check('얼굴 놓침 → 창 초기화(이어 붙여 판정 안 함)', a === 0 && b === 1, `lost 있음 ${a}회 / 대조군 ${b}회`);
}

// 11b. 보정 중 얼굴 놓침 → 보정을 처음부터(공백 앞뒤 자세를 섞지 않음)
{
  const tr = G.createGestureTracker();
  let t = 0;
  for (; t < 1000; t += DT) tr.update({ t, pose: { pitch: 20, yaw: 20 }, browDown: 0.4 });
  tr.lost();
  t += 5000;
  const tAfter = t;
  for (; t < tAfter + 1600; t += DT) tr.update({ t, pose: { pitch: -5, yaw: 3 }, browDown: 0.1 });
  const b = tr.baseline;
  check('보정 중 놓침 → 재보정', !!b && Math.abs(b.pitch + 5) < 0.01 && Math.abs(b.yaw - 3) < 0.01, b ? `pitch=${b.pitch} yaw=${b.yaw}` : '보정 안 됨');
}

// 12. 변환 행렬 → pitch/yaw (스케일·이동 포함, 열 우선)
{
  const toRad = Math.PI / 180;
  const mat = (pitch: number, yaw: number, roll: number, s: number) => {
    const [a, b, c] = [pitch * toRad, yaw * toRad, roll * toRad];
    const Rx = [[1, 0, 0], [0, Math.cos(a), -Math.sin(a)], [0, Math.sin(a), Math.cos(a)]];
    const Ry = [[Math.cos(b), 0, Math.sin(b)], [0, 1, 0], [-Math.sin(b), 0, Math.cos(b)]];
    const Rz = [[Math.cos(c), -Math.sin(c), 0], [Math.sin(c), Math.cos(c), 0], [0, 0, 1]];
    const mul = (A: number[][], B: number[][]) => A.map((row) => B[0].map((_, j) => row.reduce((acc, v, k) => acc + v * B[k][j], 0)));
    const R = mul(mul(Rz, Ry), Rx);
    const data = new Array(16).fill(0);
    for (let r = 0; r < 3; r++) for (let cc = 0; cc < 3; cc++) data[cc * 4 + r] = R[r][cc] * s;
    data[12] = 1.5; data[13] = -2; data[14] = -40; data[15] = 1;
    return data;
  };
  const cases: [number, number, number][] = [[10, -20, 0], [-15, 25, 8], [0, 0, 0], [30, 5, -12]];
  const errs = cases.map(([p, y, r]) => {
    const pose = G.poseFromMatrix(mat(p, y, r, 1.3));
    return pose ? Math.max(Math.abs(pose.pitch - p * G.PITCH_SIGN), Math.abs(pose.yaw - y * G.YAW_SIGN)) : Infinity;
  });
  check('변환 행렬 분해 오차 < 0.01°', errs.every((e) => e < 0.01), `최대 오차 ${Math.max(...errs).toExponential(2)}°`);
  check('잘못된 행렬 → null', G.poseFromMatrix([1, 2, 3]) === null, 'len 3');
}

// 13. 시선: 디바운스, 깜빡임 무시, 얼굴 없음
{
  const tr = Z.createGazeTracker();
  const look = (dir: string) => {
    const b: Record<string, number> = {};
    if (dir === 'left') { b.eyeLookOutLeft = 0.6; b.eyeLookInRight = 0.6; }
    if (dir === 'right') { b.eyeLookInLeft = 0.6; b.eyeLookOutRight = 0.6; }
    if (dir === 'down') { b.eyeLookDownLeft = 0.55; b.eyeLookDownRight = 0.55; }
    if (dir === 'blink') { b.eyeBlinkLeft = 0.9; b.eyeBlinkRight = 0.9; b.eyeLookDownLeft = 0.8; b.eyeLookDownRight = 0.8; }
    return b;
  };
  const changes: string[] = [];
  let t = 0;
  const feed = (dir: string | null, ms: number) => {
    for (const end = t + ms; t < end; t += DT) {
      const r = tr.update(t, dir === null ? null : look(dir));
      if (r.changed) changes.push(`${r.region}@${Math.round(t)}`);
    }
  };
  feed('center', 700); // unknown → center
  feed('left', 200); // 짧은 곁눈질: 무시
  feed('center', 300);
  feed('blink', 600); // 깜빡임: 보류
  feed('right', 800); // 확정
  feed(null, 100); // 얼굴 없음 → unknown
  const regions = changes.map((c) => c.split('@')[0]);
  check('시선: 디바운스·깜빡임·얼굴 없음', JSON.stringify(regions) === JSON.stringify(['center', 'right', 'unknown']), changes.join(', '));
  check('시선 원시 영역: 아래', Z.rawGazeRegion(look('down')) === 'down', Z.rawGazeRegion(look('down')));
  check('GAZE_ENABLED 플래그 존재', typeof Z.GAZE_ENABLED === 'boolean', String(Z.GAZE_ENABLED));
}

console.log(`\n${passes} passed, ${failures} failed`);
if (failures) process.exit(1);
