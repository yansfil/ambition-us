'use client';
// 감지 모드 실행기(화면 없음). senseEnabled가 true면 웹캠 + MediaPipe FaceLandmarker를 돌려
// live.sense를 매 프레임 갱신하고, 끄덕임/젓기/찌푸림/시선 변화만 신호로 push한다.
// 원칙: 영상·이미지는 이 브라우저 밖으로 나가지 않는다. 로그와 신호에는 추상 수치만 쓴다.
// 어떤 실패도 밖으로 새지 않는다(권한 거부, 모델 로드 실패, 추론 예외 → 상태만 바꾸고 앱은 계속).
import { useEffect } from 'react';
import type { FaceLandmarker, FaceLandmarkerResult } from '@mediapipe/tasks-vision';
import { log } from '@/lib/log';
import { live } from '@/poin/live';
import { poin, usePoin } from '@/poin/store';
import { createGestureTracker, poseFromMatrix } from './gestures';
import { GAZE_ENABLED, createGazeTracker } from './gaze';
import { getSenseVideo, setSenseVideo } from './video';

const WASM_BASE = '/mediapipe/wasm';
const MODEL_URL =
  'https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task';
const TARGET_FPS = 30;
const HISTORY = 90;
const LANDMARK_STRIDE = 4; // 478 → 120
const GESTURE_DISPLAY_MS = 1500;
const LOW_FPS = 10;
const LOW_FPS_WARN_MS = 3000;
const NO_FACE_INFO_MS = 5000;
const PERF_LOG_MS = 10_000;
const MAX_CONSECUTIVE_ERRORS = 30;

function resetLiveSense() {
  const s = live.sense;
  s.fps = 0; s.pitch = 0; s.yaw = 0;
  s.pitchHistory.length = 0; s.yawHistory.length = 0;
  s.brow = 0; s.gesture = 'none'; s.gestureAt = 0; s.gaze = 'unknown';
  s.faceFound = false; s.landmarks = null;
}

const pushHistory = (arr: number[], v: number) => {
  arr.push(Math.round(v * 10) / 10);
  if (arr.length > HISTORY) arr.splice(0, arr.length - HISTORY);
};

class StaleRun extends Error {}

/** Run 세대. 늦게 끝난 이전 Run이 새 Run의 live.sense를 지우지 않게 한다. */
let generation = 0;

/** 한 번의 켜기 = 한 Run. 자원(스트림, video, landmarker, 루프)을 소유하고 dispose로 모두 정리한다. */
class Run {
  disposed = false;
  failed = false;
  private readonly gen = ++generation;
  private stream: MediaStream | null = null;
  private video: HTMLVideoElement | null = null;
  private landmarker: FaceLandmarker | null = null;
  private rafId = 0;
  private vfcId = 0;
  private startedAt = performance.now();
  private frames = 0;

  // 루프 상태
  private lastProcAt = 0;
  private lastTs = 0;
  private frameTimes: number[] = [];
  private lowFpsSince = 0;
  private lowFpsWarned = false;
  private noFaceSince = 0;
  private noFaceLogged = false;
  private procSum = 0;
  private procN = 0;
  private lastPerfLog = 0;
  private consecutiveErrors = 0;
  private calibratedLogged = false;
  private tracker = createGestureTracker();
  private gaze = createGazeTracker();

  private check() {
    if (this.disposed) throw new StaleRun();
  }

  async start() {
    const st = poin();
    st.setSense({ status: 'starting' });
    log.info('sense', '감지 모드 시작', { gaze: GAZE_ENABLED });
    try {
      if (!navigator.mediaDevices?.getUserMedia) throw Object.assign(new Error('getUserMedia를 쓸 수 없는 환경'), { name: 'NotSupportedError' });

      const endCam = log.time('sense', '카메라 권한·스트림 획득');
      const stream = await navigator.mediaDevices.getUserMedia({
        video: { width: { ideal: 640 }, height: { ideal: 480 }, facingMode: 'user' },
        audio: false,
      });
      this.stream = stream;
      const track = stream.getVideoTracks()[0];
      const s = track?.getSettings();
      endCam({ width: s?.width, height: s?.height, frameRate: s?.frameRate });
      this.check();
      track?.addEventListener('ended', () => {
        if (this.disposed) return;
        log.warn('sense', '카메라 트랙이 끊김(장치 분리 또는 권한 회수)');
        this.fail('error');
      });

      const video = document.createElement('video');
      video.muted = true;
      video.playsInline = true;
      video.autoplay = true;
      video.setAttribute('aria-hidden', 'true');
      video.setAttribute('data-poin-layer', '');
      Object.assign(video.style, {
        position: 'fixed', left: '0', top: '0', width: '1px', height: '1px',
        opacity: '0', pointerEvents: 'none', zIndex: '-1',
      });
      video.srcObject = stream;
      document.body.appendChild(video);
      this.video = video;
      await video.play();
      this.check();
      setSenseVideo(video);

      const endWasm = log.time('sense', 'MediaPipe wasm 로드');
      const { FaceLandmarker, FilesetResolver } = await import('@mediapipe/tasks-vision');
      const fileset = await FilesetResolver.forVisionTasks(WASM_BASE);
      endWasm({ base: WASM_BASE });
      this.check();

      const endModel = log.time('sense', '얼굴 모델 다운로드');
      const res = await fetch(MODEL_URL);
      if (!res.ok) throw new Error(`모델 다운로드 실패 HTTP ${res.status}`);
      const model = new Uint8Array(await res.arrayBuffer());
      endModel({ bytes: model.byteLength });
      this.check();

      const create = (delegate: 'GPU' | 'CPU') =>
        FaceLandmarker.createFromOptions(fileset, {
          baseOptions: { modelAssetBuffer: model.slice(), delegate },
          runningMode: 'VIDEO',
          numFaces: 1,
          outputFaceBlendshapes: true,
          outputFacialTransformationMatrixes: true,
        });
      let delegate: 'GPU' | 'CPU' = 'GPU';
      const endInit = log.time('sense', 'FaceLandmarker 초기화');
      try {
        this.landmarker = await create('GPU');
      } catch (e) {
        log.warn('sense', 'GPU delegate 실패, CPU로 재시도', e);
        this.check();
        delegate = 'CPU';
        this.landmarker = await create('CPU');
      }
      endInit({ delegate });
      this.check();

      poin().setSense({ status: 'on' });
      log.info('sense', '감지 모드 켜짐', { delegate, video: { w: video.videoWidth, h: video.videoHeight } });
      this.schedule();
    } catch (e) {
      if (e instanceof StaleRun || this.disposed) {
        this.release();
        return;
      }
      const name = (e as { name?: string })?.name ?? '';
      const denied = name === 'NotAllowedError' || name === 'SecurityError' || name === 'PermissionDeniedError';
      if (denied) log.warn('sense', '카메라 권한 거부', { name, message: (e as Error)?.message });
      else log.error('sense', '감지 모드 시작 실패', e);
      this.fail(denied ? 'denied' : 'error');
    }
  }

  /** 실패: 자원 정리 + 상태 표시 + 토글을 끈다. 이후 effect cleanup이 상태를 off로 덮지 않도록 failed 표시. */
  private fail(status: 'denied' | 'error') {
    this.failed = true;
    this.release();
    poin().setSense({ enabled: false, status });
  }

  private schedule() {
    if (this.disposed || !this.video) return;
    const v = this.video;
    if (typeof v.requestVideoFrameCallback === 'function') {
      this.vfcId = v.requestVideoFrameCallback((now) => this.tick(now));
    } else {
      this.rafId = requestAnimationFrame((now) => this.tick(now));
    }
  }

  private tick(now: number) {
    if (this.disposed) return;
    this.schedule();
    if (now - this.lastProcAt < 1000 / TARGET_FPS - 3) return; // 약 30fps 제한
    const v = this.video, lm = this.landmarker;
    if (!v || !lm || v.readyState < 2 || v.videoWidth === 0) return;
    this.lastProcAt = now;

    const ts = Math.max(this.lastTs + 1, Math.round(now)); // MediaPipe는 단조 증가 타임스탬프 필요
    this.lastTs = ts;
    const t0 = performance.now();
    let result: FaceLandmarkerResult;
    try {
      result = lm.detectForVideo(v, ts);
      this.consecutiveErrors = 0;
    } catch (e) {
      this.consecutiveErrors++;
      if (this.consecutiveErrors === 1) log.error('sense', '프레임 추론 예외', e);
      if (this.consecutiveErrors >= MAX_CONSECUTIVE_ERRORS) {
        log.error('sense', `추론 예외 ${MAX_CONSECUTIVE_ERRORS}회 연속, 감지 모드를 끔`);
        this.fail('error');
      }
      return;
    }
    try {
      this.process(result, now);
    } catch (e) {
      log.error('sense', '프레임 처리 예외', e);
    }
    this.procSum += performance.now() - t0;
    this.procN++;
    this.frames++;
    this.perf(now);
  }

  private process(r: FaceLandmarkerResult, now: number) {
    const s = live.sense;
    const st = poin();
    const face = r.faceLandmarks?.[0];
    const matrix = r.facialTransformationMatrixes?.[0];
    const pose = matrix ? poseFromMatrix(matrix.data) : null;

    if (!face || !pose) {
      s.faceFound = false;
      s.landmarks = null;
      this.tracker.lost();
      if (GAZE_ENABLED) s.gaze = this.gaze.update(now, null).region;
      if (!this.noFaceSince) this.noFaceSince = now;
      if (!this.noFaceLogged && now - this.noFaceSince >= NO_FACE_INFO_MS) {
        this.noFaceLogged = true;
        log.info('sense', '얼굴이 5초째 보이지 않음');
      }
      this.decayGesture();
      return;
    }
    if (this.noFaceLogged) log.info('sense', '얼굴 다시 찾음', { missingMs: Math.round(now - this.noFaceSince) });
    this.noFaceSince = 0;
    this.noFaceLogged = false;
    s.faceFound = true;

    const bs: Record<string, number> = {};
    for (const c of r.faceBlendshapes?.[0]?.categories ?? []) bs[c.categoryName] = c.score;
    const browDown = ((bs.browDownLeft ?? 0) + (bs.browDownRight ?? 0)) / 2;

    const out = this.tracker.update({ t: now, pose, browDown });
    if (out.calibrated && !this.calibratedLogged) {
      this.calibratedLogged = true;
      const b = this.tracker.baseline;
      log.info('sense', '중립 자세 보정 완료', b && { pitch: +b.pitch.toFixed(1), yaw: +b.yaw.toFixed(1), brow: +b.brow.toFixed(3) });
    }
    s.pitch = out.pitch;
    s.yaw = out.yaw;
    pushHistory(s.pitchHistory, out.pitch);
    pushHistory(s.yawHistory, out.yaw);
    s.brow = out.brow;

    const pts: { x: number; y: number }[] = [];
    for (let i = 0; i < face.length; i += LANDMARK_STRIDE) pts.push({ x: face[i].x, y: face[i].y });
    s.landmarks = pts;

    if (out.gesture) {
      s.gesture = out.gesture.type;
      s.gestureAt = Date.now();
      st.pushSignal({ kind: 'sense', type: out.gesture.type, data: { confidence: out.gesture.confidence } });
      log.info('sense', out.gesture.type === 'nod' ? '끄덕임 감지' : '젓기 감지', { confidence: out.gesture.confidence });
    } else {
      this.decayGesture();
    }
    if (out.browEdge) {
      st.pushSignal({ kind: 'sense', type: 'brow', data: { value: out.browEdge.value } });
      log.info('sense', '찌푸림 감지', out.browEdge);
    }

    if (GAZE_ENABLED) {
      const g = this.gaze.update(now, bs);
      s.gaze = g.region;
      if (g.changed && g.region !== 'unknown') st.pushSignal({ kind: 'sense', type: 'gaze', data: { region: g.region } });
    }
  }

  private decayGesture() {
    const s = live.sense;
    if (s.gesture !== 'none' && Date.now() - s.gestureAt > GESTURE_DISPLAY_MS) s.gesture = 'none';
  }

  private perf(now: number) {
    const ft = this.frameTimes;
    ft.push(now);
    while (ft.length && now - ft[0] > 1000) ft.shift();
    const running = now - this.startedAt > 1500;
    live.sense.fps = ft.length;

    if (running && ft.length < LOW_FPS) {
      if (!this.lowFpsSince) this.lowFpsSince = now;
      if (!this.lowFpsWarned && now - this.lowFpsSince >= LOW_FPS_WARN_MS) {
        this.lowFpsWarned = true;
        log.warn('perf', `감지 fps ${ft.length} < ${LOW_FPS} (3초 지속)`, { fps: ft.length, avgProcMs: this.avgProc() });
      }
    } else if (ft.length >= LOW_FPS) {
      if (this.lowFpsWarned) log.info('perf', '감지 fps 회복', { fps: ft.length });
      this.lowFpsSince = 0;
      this.lowFpsWarned = false;
    }

    if (!this.lastPerfLog) this.lastPerfLog = now;
    if (now - this.lastPerfLog >= PERF_LOG_MS) {
      log.debug('perf', '감지 프레임 처리', { avgProcMs: this.avgProc(), frames: this.procN, fps: ft.length });
      this.lastPerfLog = now;
      this.procSum = 0;
      this.procN = 0;
    }
  }

  private avgProc() {
    return this.procN ? Math.round((this.procSum / this.procN) * 10) / 10 : 0;
  }

  /** 자원 해제(멱등). 상태는 바꾸지 않는다. */
  private release() {
    this.disposed = true;
    if (this.vfcId && this.video && typeof this.video.cancelVideoFrameCallback === 'function') {
      this.video.cancelVideoFrameCallback(this.vfcId);
    }
    if (this.rafId) cancelAnimationFrame(this.rafId);
    this.vfcId = 0;
    this.rafId = 0;
    try { this.landmarker?.close(); } catch (e) { log.warn('sense', 'landmarker close 실패', e); }
    this.landmarker = null;
    this.stream?.getTracks().forEach((t) => t.stop());
    this.stream = null;
    if (this.video) {
      if (getSenseVideo() === this.video) setSenseVideo(null);
      this.video.srcObject = null;
      this.video.remove();
      this.video = null;
    }
    if (this.gen === generation) resetLiveSense();
  }

  /** 사용자가 끄거나 언마운트될 때 */
  dispose() {
    if (this.disposed) return;
    const wasRunning = this.frames > 0;
    this.release();
    if (wasRunning) log.info('sense', '감지 모드 꺼짐', { seconds: Math.round((performance.now() - this.startedAt) / 1000), frames: this.frames });
    else log.info('sense', '감지 모드 시작 취소');
  }
}

export default function SenseRunner() {
  const enabled = usePoin((s) => s.senseEnabled);

  useEffect(() => {
    if (!enabled) return;
    const run = new Run();
    void run.start();
    return () => {
      const failed = run.failed;
      run.dispose();
      if (!failed) poin().setSense({ status: 'off' });
    };
  }, [enabled]);

  return null;
}
