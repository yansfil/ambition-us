// 감지 모드 순수 판정 로직: 머리 자세(pitch/yaw) → 끄덕임/젓기, blendshape → 찌푸림.
// 프레임워크와 `@/` import 없음. node scripts/test-gestures.ts 로 단독 검증한다.
// 입력은 추상 수치뿐이다. 영상·이미지는 이 파일에 들어오지 않는다.

export interface HeadPose {
  pitch: number; // 도
  yaw: number; // 도
}

export interface GestureConfig {
  calibrationMs: number; // 처음 이 시간 동안 중립 자세·찌푸림 기준점을 잡는다
  windowMs: number; // 제스처 판정 창
  minReversals: number; // 창 안의 방향 전환 최소 횟수
  minAmplitudeDeg: number; // 창 안의 주축 진폭(최대-최소) 최소값
  reversalStepDeg: number; // 이 이상 되돌아와야 방향 전환으로 센다(잡음 무시)
  quietRatio: number; // 보조축 진폭 ≤ 주축 진폭 × 이 값이어야 "조용"
  cooldownMs: number; // 제스처 간 최소 간격(끄덕임·젓기 공통)
  restMs: number; // 제스처 뒤 다음 제스처를 받으려면 머리가 이만큼 조용해야 한다(한 동작 = 신호 1번)
  restRangeDeg: number; // "조용"의 기준: restMs 동안 두 축 진폭 모두 이 값 미만
  browSpan: number; // 기준점 대비 이만큼 오르면 찌푸림 1.0
  browOn: number; // 이 값을 넘는 순간 찌푸림 신호(상승 엣지)
  browOff: number; // 이 값 밑으로 내려가야 다시 신호 가능(히스테리시스)
  browSmoothing: number; // 지수평활 계수(0..1, 클수록 즉각)
}

export const DEFAULT_GESTURE_CONFIG: GestureConfig = {
  calibrationMs: 1500,
  windowMs: 1200,
  minReversals: 2,
  minAmplitudeDeg: 8,
  reversalStepDeg: 2.5,
  quietRatio: 0.5,
  cooldownMs: 1000,
  restMs: 400,
  restRangeDeg: 4,
  browSpan: 0.5,
  browOn: 0.45,
  browOff: 0.35,
  browSmoothing: 0.35,
};

export interface FrameInput {
  t: number; // ms (단조 증가)
  pose: HeadPose; // 원시 자세
  browDown: number; // (browDownLeft + browDownRight) / 2
}

export interface GestureEvent {
  type: 'nod' | 'shake';
  confidence: number; // 0..1
}

export interface FrameOutput {
  calibrated: boolean;
  pitch: number; // 중립 대비 도
  yaw: number;
  brow: number; // 0..1
  gesture: GestureEvent | null;
  browEdge: { value: number } | null;
}

const clamp01 = (v: number) => (v < 0 ? 0 : v > 1 ? 1 : v);
const round2 = (v: number) => Math.round(v * 100) / 100;
const RAD = 180 / Math.PI;

/**
 * MediaPipe facialTransformationMatrixes[0].data(4×4, 열 우선)에서 pitch/yaw(도)를 뽑는다.
 * 행렬은 스케일을 포함할 수 있어 회전 3×3의 각 열을 정규화한 뒤 분해한다.
 * 분해 규약: R = Rz(roll) · Ry(yaw) · Rx(pitch).
 * 부호(위가 +, 오른쪽이 +)는 실제 웹캠에서 확인이 필요하다. 판정은 부호와 무관하다.
 */
export function poseFromMatrix(data: ArrayLike<number>): HeadPose | null {
  if (!data || data.length < 16) return null;
  // m(r, c) = data[c * 4 + r]
  const col = (c: number) => {
    const x = data[c * 4], y = data[c * 4 + 1], z = data[c * 4 + 2];
    const n = Math.hypot(x, y, z) || 1;
    return [x / n, y / n, z / n];
  };
  const c0 = col(0), c1 = col(1), c2 = col(2);
  const r20 = c0[2], r21 = c1[2], r22 = c2[2];
  if (![r20, r21, r22].every(Number.isFinite)) return null;
  const yaw = Math.asin(Math.max(-1, Math.min(1, -r20))) * RAD;
  const pitch = Math.atan2(r21, r22) * RAD;
  return { pitch: PITCH_SIGN * pitch, yaw: YAW_SIGN * yaw };
}

/** 실제 웹캠에서 방향이 반대로 보이면 여기만 뒤집는다(표시용). */
export const PITCH_SIGN = 1;
export const YAW_SIGN = 1;

/** 잡음에 강한 방향 전환 횟수: reversalStep 이상 되돌아올 때만 전환으로 센다. */
export function countReversals(values: readonly number[], step: number): number {
  if (values.length < 3) return 0;
  let dir = 0;
  let ext = values[0];
  let changes = 0;
  for (let i = 1; i < values.length; i++) {
    const v = values[i];
    if (dir === 0) {
      if (v - ext >= step) { dir = 1; ext = v; }
      else if (ext - v >= step) { dir = -1; ext = v; }
    } else if (dir === 1) {
      if (v > ext) ext = v;
      else if (ext - v >= step) { dir = -1; ext = v; changes++; }
    } else {
      if (v < ext) ext = v;
      else if (v - ext >= step) { dir = 1; ext = v; changes++; }
    }
  }
  return changes;
}

const range = (values: readonly number[]) => {
  let lo = Infinity, hi = -Infinity;
  for (const v of values) { if (v < lo) lo = v; if (v > hi) hi = v; }
  return values.length ? hi - lo : 0;
};

interface Sample { t: number; pitch: number; yaw: number }

export interface GestureTracker {
  update: (f: FrameInput) => FrameOutput;
  /** 얼굴을 놓친 프레임. 판정 창을 비워 공백을 건너 제스처가 이어지지 않게 한다. */
  lost: () => void;
  reset: () => void;
  readonly baseline: { pitch: number; yaw: number; brow: number } | null;
}

export function createGestureTracker(partial: Partial<GestureConfig> = {}): GestureTracker {
  const cfg: GestureConfig = { ...DEFAULT_GESTURE_CONFIG, ...partial };

  let calibStart = -1;
  let calibN = 0;
  let sumP = 0, sumY = 0, sumB = 0;
  let base: { pitch: number; yaw: number; brow: number } | null = null;
  let win: Sample[] = [];
  let lastGestureAt = -Infinity;
  let needRest = false;
  let rest: Sample[] = [];
  let browEma = 0;
  let browArmed = true;

  const reset = () => {
    calibStart = -1; calibN = 0; sumP = 0; sumY = 0; sumB = 0;
    base = null; win = []; lastGestureAt = -Infinity; needRest = false; rest = []; browEma = 0; browArmed = true;
  };

  const judge = (t: number): GestureEvent | null => {
    if (t - lastGestureAt < cfg.cooldownMs) return null;
    if (needRest) return null;
    if (win.length < 6 || t - win[0].t < cfg.windowMs * 0.5) return null;
    const ps = win.map((s) => s.pitch);
    const ys = win.map((s) => s.yaw);
    const pr = range(ps), yr = range(ys);
    const pick = (primary: number[], pAmp: number, oAmp: number, type: 'nod' | 'shake'): GestureEvent | null => {
      if (pAmp < cfg.minAmplitudeDeg) return null;
      if (oAmp > pAmp * cfg.quietRatio) return null;
      const rev = countReversals(primary, cfg.reversalStepDeg);
      if (rev < cfg.minReversals) return null;
      const ampScore = clamp01((pAmp - cfg.minAmplitudeDeg) / 12);
      const revScore = clamp01((rev - cfg.minReversals) / 2);
      const quietScore = clamp01(1 - oAmp / (pAmp * cfg.quietRatio));
      return { type, confidence: round2(Math.min(0.99, 0.5 + 0.25 * ampScore + 0.15 * revScore + 0.1 * quietScore)) };
    };
    return pick(ps, pr, yr, 'nod') ?? pick(ys, yr, pr, 'shake');
  };

  const update = (f: FrameInput): FrameOutput => {
    const out: FrameOutput = { calibrated: base !== null, pitch: 0, yaw: 0, brow: 0, gesture: null, browEdge: null };
    if (!base) {
      if (calibStart < 0) calibStart = f.t;
      calibN++; sumP += f.pose.pitch; sumY += f.pose.yaw; sumB += f.browDown;
      out.pitch = f.pose.pitch - sumP / calibN;
      out.yaw = f.pose.yaw - sumY / calibN;
      if (f.t - calibStart >= cfg.calibrationMs && calibN >= 5) {
        base = { pitch: sumP / calibN, yaw: sumY / calibN, brow: sumB / calibN };
        out.calibrated = true;
      }
      return out;
    }

    const pitch = f.pose.pitch - base.pitch;
    const yaw = f.pose.yaw - base.yaw;
    out.pitch = pitch;
    out.yaw = yaw;

    win.push({ t: f.t, pitch, yaw });
    while (win.length && f.t - win[0].t > cfg.windowMs) win.shift();
    if (needRest) {
      rest.push({ t: f.t, pitch, yaw });
      while (rest.length && f.t - rest[0].t > cfg.restMs) rest.shift();
      const quiet = rest.length >= 3 && f.t - rest[0].t >= cfg.restMs * 0.9
        && range(rest.map((s) => s.pitch)) < cfg.restRangeDeg && range(rest.map((s) => s.yaw)) < cfg.restRangeDeg;
      if (quiet) { needRest = false; rest = []; win = []; }
    }
    const g = judge(f.t);
    if (g) {
      out.gesture = g;
      lastGestureAt = f.t;
      win = [];
      needRest = true; // 같은 동작이 쿨다운 뒤 다시 잡히지 않게: 한 번 멈춰야 재무장
      rest = [];
    }

    const rawBrow = clamp01((f.browDown - base.brow) / cfg.browSpan);
    browEma += cfg.browSmoothing * (rawBrow - browEma);
    out.brow = round2(browEma);
    if (browArmed && browEma > cfg.browOn) {
      browArmed = false;
      out.browEdge = { value: out.brow };
    } else if (!browArmed && browEma < cfg.browOff) {
      browArmed = true;
    }
    return out;
  };

  return {
    update,
    lost: () => {
      win = []; rest = [];
      if (!base) { calibStart = -1; calibN = 0; sumP = 0; sumY = 0; sumB = 0; } // 보정 중 놓치면 보정을 처음부터
    },
    reset,
    get baseline() { return base; },
  };
}
