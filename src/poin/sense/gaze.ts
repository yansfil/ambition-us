// 거친 시선 영역(left/right/up/down/center). 정확도가 낮을 수 있어 이 파일과 GAZE_ENABLED 하나로 격리한다.
// 끄려면 GAZE_ENABLED = false. 순수 로직(프레임워크·`@/` import 없음).

export const GAZE_ENABLED = true;

export type GazeRegion = 'left' | 'center' | 'right' | 'up' | 'down';

export interface GazeConfig {
  threshold: number; // 축 점수가 이 이상이면 그 방향
  debounceMs: number; // 새 영역이 이만큼 유지돼야 확정
  blinkMax: number; // 깜빡임 중이면 판정 보류(눈을 감으면 eyeLookDown이 튄다)
}

export const DEFAULT_GAZE_CONFIG: GazeConfig = { threshold: 0.3, debounceMs: 500, blinkMax: 0.5 };

type Bs = Record<string, number | undefined>;
const g = (b: Bs, k: string) => b[k] ?? 0;

/**
 * 한 프레임의 원시 영역. blendshape의 Left/Right는 피사체(사용자) 기준이다.
 * 사용자 왼쪽 = 화면 왼쪽(사용자가 화면을 마주 보므로). 입력 영상을 좌우 반전하지 않는다는 전제.
 */
export function rawGazeRegion(b: Bs, threshold = DEFAULT_GAZE_CONFIG.threshold): GazeRegion {
  const toLeft = (g(b, 'eyeLookOutLeft') + g(b, 'eyeLookInRight')) / 2;
  const toRight = (g(b, 'eyeLookInLeft') + g(b, 'eyeLookOutRight')) / 2;
  const up = (g(b, 'eyeLookUpLeft') + g(b, 'eyeLookUpRight')) / 2;
  const down = (g(b, 'eyeLookDownLeft') + g(b, 'eyeLookDownRight')) / 2;
  const h = toRight - toLeft;
  const v = up - down;
  if (Math.abs(h) < threshold && Math.abs(v) < threshold) return 'center';
  if (Math.abs(h) >= Math.abs(v)) return h > 0 ? 'right' : 'left';
  return v > 0 ? 'up' : 'down';
}

export interface GazeTracker {
  /** blendshapes가 null이면 얼굴 없음. changed는 확정 영역이 바뀐 프레임에만 true. */
  update: (t: number, b: Bs | null) => { region: GazeRegion | 'unknown'; changed: boolean };
  reset: () => void;
}

export function createGazeTracker(partial: Partial<GazeConfig> = {}): GazeTracker {
  const cfg = { ...DEFAULT_GAZE_CONFIG, ...partial };
  let committed: GazeRegion | 'unknown' = 'unknown';
  let candidate: GazeRegion | null = null;
  let candidateSince = 0;

  return {
    update(t, b) {
      if (!b) {
        candidate = null;
        const changed = committed !== 'unknown';
        committed = 'unknown';
        return { region: committed, changed };
      }
      const blink = (g(b, 'eyeBlinkLeft') + g(b, 'eyeBlinkRight')) / 2;
      if (blink > cfg.blinkMax) return { region: committed, changed: false };
      const r = rawGazeRegion(b, cfg.threshold);
      if (r === committed) { candidate = null; return { region: committed, changed: false }; }
      if (r !== candidate) { candidate = r; candidateSince = t; }
      if (t - candidateSince >= cfg.debounceMs) {
        committed = r;
        candidate = null;
        return { region: committed, changed: true };
      }
      return { region: committed, changed: false };
    },
    reset() { committed = 'unknown'; candidate = null; candidateSince = 0; },
  };
}
