// 계기판 실시간 값. 초당 수십 번 바뀌므로 React 상태에 넣지 않는다.
// 쓰는 쪽: 신호 수집기, 감지 루프. 읽는 쪽: 로그 패널이 rAF/interval로 샘플링.

export interface LiveSense {
  fps: number;
  pitch: number; // 도, 위가 +
  yaw: number; // 도, 오른쪽이 +
  pitchHistory: number[]; // 최근 90프레임
  yawHistory: number[];
  brow: number; // 0..1 찌푸림
  gesture: 'none' | 'nod' | 'shake';
  gestureAt: number;
  gaze: 'left' | 'center' | 'right' | 'up' | 'down' | 'unknown';
  faceFound: boolean;
  landmarks: { x: number; y: number }[] | null; // 정규화 좌표 0..1, 썸네일 오버레이용
}

export interface Live {
  typingCpm: number;
  pauseMs: number; // 마지막 입력 후 경과 (입력창 포커스 중일 때만)
  deleteBursts: number; // 현재 초안에서의 삭제 버스트 수
  focusIdleMs: number; // 포커스 후 무입력 시간
  cursor: { x: number; y: number };
  cursorTarget: string | null; // data-poin-target 값
  cursorTargetLabel: string | null; // 사람이 읽는 이름, 예: "상품 카드 · 핸드드립 세트"
  dwellMs: number; // 현재 타깃 체류
  oscillations: number; // 최근 타깃 왕복 수
  scrollReversals: number;
  sense: LiveSense;
}

export const live: Live = {
  typingCpm: 0,
  pauseMs: 0,
  deleteBursts: 0,
  focusIdleMs: 0,
  cursor: { x: 0, y: 0 },
  cursorTarget: null,
  cursorTargetLabel: null,
  dwellMs: 0,
  oscillations: 0,
  scrollReversals: 0,
  sense: {
    fps: 0, pitch: 0, yaw: 0, pitchHistory: [], yawHistory: [], brow: 0,
    gesture: 'none', gestureAt: 0, gaze: 'unknown', faceFound: false, landmarks: null,
  },
};
