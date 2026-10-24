#!/usr/bin/env python3
"""시선 CNN 후보 비교(오프라인). 카메라를 쓰지 않는다.

하위 명령
  samples    샘플 얼굴 영상 준비(저장소 영상 프레임 + 받아 둔 초상 사진) + RetinaFace 상자 JSON
  parity     아키텍처별 PyTorch(fp32) vs CoreML(fp16) 각도 차이
  latency    coremltools predict 지연(ALL / CPU_AND_NE, TTA 유무)
  stability  크롭 이동·크기 변화 민감도, 연속 프레임 떨림, TTA 효과(작은 얼굴 포함 전체)
  webcam     웹캠 상황(정면 큰 얼굴) 민감도 + 센서 잡음에 대한 출력 표준편차
  signs      부호 규약 확인(좌우 반전 시 yaw 반전) + 화살표 주석 영상

공통 인자: --work /tmp/gaze-work (weights/, models/, samples/, gaze-estimation/)
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
import warnings
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import (  # noqa: E402
    ARCHS,
    GazeWrapper,
    crop_resize,
    decode_reference,
    load_repo_model,
    square_box,
    to_tensor01,
    torch_gaze,
)

warnings.filterwarnings("ignore")
CANDIDATES = ("resnet18", "resnet34", "resnet50", "mobileone_s0")


def deg(x):
    return np.degrees(x)


# ---------------------------------------------------------------- samples

def cmd_samples(work: Path) -> None:
    import cv2
    from PIL import Image
    from uniface import RetinaFace

    out = work / "samples"
    out.mkdir(exist_ok=True)
    cap = cv2.VideoCapture(str(work / "gaze-estimation/assets/in_video.mp4"))
    frames = []
    index = 0
    # 넓게 퍼진 20프레임 + 떨림 분석용 연속 프레임 묶음(3구간 × 12프레임)
    spread = set(range(0, 329, 16))
    runs = {start + k for start in (40, 150, 260) for k in range(12)}
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        if index in spread:
            name = f"video_{index:03d}.png"
            cv2.imwrite(str(out / name), frame)
            frames.append(name)
        if index in runs:
            cv2.imwrite(str(out / f"run_{index:03d}.png"), frame)
        index += 1
    # 초상 사진(EXIF 없이 PNG로 정규화) + 웹캠처럼 1920×1080 캔버스에 얼굴 ~420px로 합성
    for jpg in sorted(out.glob("portrait_*.jpg")):
        img = Image.open(jpg).convert("RGB")
        img.save(out / (jpg.stem + ".png"))
    detector = RetinaFace(confidence_threshold=0.6)
    boxes: dict[str, list] = {}
    for png in sorted(out.glob("*.png")):
        if png.name.startswith("webcam_"):
            continue
        bgr = cv2.imread(str(png))
        faces = detector.detect(bgr)
        boxes[png.name] = [[float(v) for v in f.bbox[:4]] + [float(f.confidence)] for f in faces]
        if png.name.startswith("portrait_") and faces:
            f = max(faces, key=lambda f: (f.bbox[2] - f.bbox[0]) * (f.bbox[3] - f.bbox[1]))
            fw = f.bbox[2] - f.bbox[0]
            scale = 420.0 / fw
            small = cv2.resize(bgr, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
            canvas = np.full((1080, 1920, 3), 96, np.uint8)
            cx = (f.bbox[0] + f.bbox[2]) / 2 * scale
            cy = (f.bbox[1] + f.bbox[3]) / 2 * scale
            ox, oy = int(round(960 - cx)), int(round(500 - cy))
            h, w = small.shape[:2]
            x0, y0 = max(0, ox), max(0, oy)
            x1, y1 = min(1920, ox + w), min(1080, oy + h)
            canvas[y0:y1, x0:x1] = small[y0 - oy:y1 - oy, x0 - ox:x1 - ox]
            name = "webcam_" + png.name
            cv2.imwrite(str(out / name), canvas)
            wf = detector.detect(canvas)
            boxes[name] = [[float(v) for v in g.bbox[:4]] + [float(g.confidence)] for g in wf]
    (out / "retinaface_boxes.json").write_text(json.dumps(boxes, indent=1))
    # RetinaFace 상자 모양과 눈 위치(상자 높이 대비)
    aspects, eye_fracs, eye_x = [], [], []
    for png in sorted(out.glob("*.png")):
        bgr = cv2.imread(str(png))
        for f in detector.detect(bgr):
            x0, y0, x1, y1 = f.bbox[:4]
            if (x1 - x0) < 60:
                continue
            aspects.append((y1 - y0) / (x1 - x0))
            lm = np.asarray(f.landmarks)  # 5점: 왼눈, 오른눈, 코, 입 양끝
            eye_y = (lm[0][1] + lm[1][1]) / 2
            eye_fracs.append((eye_y - y0) / (y1 - y0))
            eye_x.append(((lm[0][0] + lm[1][0]) / 2 - x0) / (x1 - x0))
    print(f"samples: {len(list(out.glob('*.png')))} png, faces measured {len(aspects)}")
    print(f"RetinaFace h/w: median {np.median(aspects):.3f} (p10 {np.percentile(aspects,10):.3f}, p90 {np.percentile(aspects,90):.3f})")
    print(f"eye-line y / box h: median {np.median(eye_fracs):.3f} (p10 {np.percentile(eye_fracs,10):.3f}, p90 {np.percentile(eye_fracs,90):.3f})")
    print(f"eye-mid x / box w: median {np.median(eye_x):.3f}")


def load_faces(work: Path, prefix: tuple[str, ...] = ("video_", "portrait_", "webcam_"), min_width: float = 60):
    """(파일 이름, RGB, RetinaFace 상자) 목록. 영상당 가장 큰 얼굴."""
    from PIL import Image

    boxes = json.loads((work / "samples/retinaface_boxes.json").read_text())
    items = []
    for name in sorted(boxes):
        if not name.startswith(prefix) or not boxes[name]:
            continue
        box = max(boxes[name], key=lambda b: (b[2] - b[0]) * (b[3] - b[1]))
        if box[2] - box[0] < min_width:
            continue
        rgb = np.asarray(Image.open(work / "samples" / name).convert("RGB"))
        items.append((name, rgb, box[:4]))
    return items


def wrappers(work: Path, tta: bool):
    for arch in CANDIDATES:
        net = load_repo_model(arch, work / f"weights/{arch}.pt", work / "gaze-estimation")
        yield arch, GazeWrapper(net, tta=tta).eval()


# ---------------------------------------------------------------- parity

def cmd_parity(work: Path, tta: bool) -> None:
    import coremltools as ct
    import torch
    from PIL import Image

    faces = load_faces(work)
    print(f"parity on {len(faces)} faces (square RetinaFace box), tta={int(tta)}")
    for arch, wrapper in wrappers(work, tta):
        path = work / f"models/{arch}_tta{int(tta)}.mlpackage"
        if not path.exists():
            print(f"{arch}: missing {path}")
            continue
        model = ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.ALL)
        diffs, ref_diffs, angles = [], [], []
        for _, rgb, box in faces:
            crop = crop_resize(rgb, square_box(box))
            ref = torch_gaze(wrapper, crop)
            ml = np.asarray(model.predict({"image": Image.fromarray(crop)})["gaze"], dtype=np.float64).reshape(-1)
            diffs.append(np.abs(deg(ml[:2] - ref[:2])))
            angles.append(deg(ref[:2]))
            if not tta:
                # 저장소 디코딩(float64, 0..89 지수)과 래퍼 디코딩이 같은지
                with torch.no_grad():
                    x = (to_tensor01(crop) - wrapper.mean) / wrapper.std
                    yl, pl = wrapper.net(x)
                rd = decode_reference(yl.numpy(), pl.numpy())
                ref_diffs.append(np.abs(deg(rd - ref[:2])))
        d = np.array(diffs)
        msg = f"{arch:13s} coreml-vs-torch |Δyaw| max {d[:,0].max():.3f}° mean {d[:,0].mean():.3f}°, |Δpitch| max {d[:,1].max():.3f}° mean {d[:,1].mean():.3f}°"
        if ref_diffs:
            msg += f"; wrapper-vs-repo-decode max {np.array(ref_diffs).max():.2e}°"
        a = np.array(angles)
        msg += f"; yaw range {a[:,0].min():.1f}..{a[:,0].max():.1f}°, pitch {a[:,1].min():.1f}..{a[:,1].max():.1f}°"
        print(msg)


# ---------------------------------------------------------------- latency

def cmd_latency(work: Path) -> None:
    import coremltools as ct
    from PIL import Image

    img = Image.fromarray((np.random.default_rng(0).random((448, 448, 3)) * 255).astype(np.uint8))
    print(f"{'model':22s} {'ALL ms':>8s} {'CPU_AND_NE ms':>14s} {'CPU_ONLY ms':>12s}")
    for arch in CANDIDATES:
        for tta in (0, 1):
            path = work / f"models/{arch}_tta{tta}.mlpackage"
            if not path.exists():
                continue
            row = []
            for unit in (ct.ComputeUnit.ALL, ct.ComputeUnit.CPU_AND_NE, ct.ComputeUnit.CPU_ONLY):
                model = ct.models.MLModel(str(path), compute_units=unit)
                for _ in range(10):
                    model.predict({"image": img})
                times = []
                for _ in range(50):
                    t0 = time.perf_counter()
                    model.predict({"image": img})
                    times.append((time.perf_counter() - t0) * 1000)
                row.append(statistics.median(times))
            print(f"{arch + '_tta' + str(tta):22s} {row[0]:8.2f} {row[1]:14.2f} {row[2]:12.2f}")


# ---------------------------------------------------------------- stability

def cmd_stability(work: Path) -> None:
    faces = load_faces(work, prefix=("video_", "portrait_", "webcam_"), min_width=80)
    runs = sorted((work / "samples").glob("run_*.png"))
    boxes = json.loads((work / "samples/retinaface_boxes.json").read_text())
    from PIL import Image

    def perturbations(box):
        x0, y0, x1, y1 = square_box(box)
        s = x1 - x0
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        out = {}
        for name, dx, dy, k in (("shift2", 0.02, 0, 1), ("shift2y", 0, 0.02, 1), ("shift4", 0.04, 0, 1),
                                ("shift4y", 0, 0.04, 1), ("scale+4", 0, 0, 1.04), ("scale-4", 0, 0, 0.96),
                                ("scale1.2", 0, 0, 1.2)):
            side = s * k
            ncx, ncy = cx + dx * s, cy + dy * s
            out[name] = (ncx - side / 2, ncy - side / 2, ncx + side / 2, ncy + side / 2)
        return out

    print("sensitivity: mean |Δgaze| (deg, combined sqrt(Δyaw²+Δpitch²)) vs square RetinaFace crop")
    header = None
    for tta in (False, True):
        for arch, wrapper in wrappers(work, tta):
            results: dict[str, list[float]] = {}
            for _, rgb, box in faces:
                base = torch_gaze(wrapper, crop_resize(rgb, square_box(box)))
                for name, pbox in perturbations(box).items():
                    g = torch_gaze(wrapper, crop_resize(rgb, pbox))
                    results.setdefault(name, []).append(float(np.hypot(*deg(g[:2] - base[:2]))))
            # 연속 프레임 떨림: 구간별로 각 얼굴을 프레임 사이 IoU로 이어 붙여 2차 차분 RMS(움직임 제거)
            jitters = []
            for start in (40, 150, 260):
                seq = []
                prev = None
                for k in range(12):
                    name = f"run_{start + k:03d}.png"
                    if name not in boxes or not boxes[name]:
                        break
                    cand = [b for b in boxes[name] if b[2] - b[0] >= 60]
                    if not cand:
                        break
                    if prev is None:
                        b = max(cand, key=lambda b: b[2] - b[0])
                    else:
                        b = min(cand, key=lambda b: abs(b[0] - prev[0]) + abs(b[1] - prev[1]))
                    prev = b
                    rgb = np.asarray(Image.open(work / "samples" / name).convert("RGB"))
                    seq.append(deg(torch_gaze(wrapper, crop_resize(rgb, square_box(b)))[:2]))
                if len(seq) >= 5:
                    s = np.array(seq)
                    second = s[2:] - 2 * s[1:-1] + s[:-2]
                    jitters.append(float(np.sqrt(np.mean(np.sum(second**2, axis=1)) / 6)))
            if header is None:
                header = list(results)
                print(f"{'model':18s} " + " ".join(f"{h:>9s}" for h in header) + f" {'jitter':>8s}")
            print(f"{arch + ('+tta' if tta else ''):18s} " + " ".join(f"{np.mean(results[h]):9.2f}" for h in header)
                  + f" {np.mean(jitters) if jitters else float('nan'):8.2f}")


def cmd_webcam(work: Path) -> None:
    """웹캠 상황(정면, 얼굴 ≥ 300px) 민감도: 작은 크롭 이동·크기 변화, 센서 잡음(σ 2·4) 출력 표준편차."""
    faces = load_faces(work, prefix=("portrait_", "webcam_"), min_width=300)
    rng = np.random.default_rng(1)

    def moved(box, dx, dy, k):
        x0, y0, x1, y1 = square_box(box)
        s = x1 - x0
        cx, cy = (x0 + x1) / 2 + dx * s, (y0 + y1) / 2 + dy * s
        side = s * k
        return (cx - side / 2, cy - side / 2, cx + side / 2, cy + side / 2)

    cases = (("dx0.5%", 0.005, 0, 1), ("dx1%", 0.01, 0, 1), ("dy1%", 0, 0.01, 1), ("dx2%", 0.02, 0, 1),
             ("dy2%", 0, 0.02, 1), ("s+2%", 0, 0, 1.02), ("s-2%", 0, 0, 0.98))
    print(f"webcam-like faces: {len(faces)} (frontal, width >= 300px). mean |Δgaze| deg; noise = per-axis std over 8 draws")
    print(f"{'model':18s} " + " ".join(f"{c[0]:>7s}" for c in cases) + f" {'σ2 yaw':>7s} {'σ2 pit':>7s} {'σ4 yaw':>7s} {'σ4 pit':>7s}")
    for tta in (False, True):
        for arch, wrapper in wrappers(work, tta):
            res = {c[0]: [] for c in cases}
            noise = {2: [], 4: []}
            for _, rgb, box in faces:
                base_box = square_box(box)
                base = torch_gaze(wrapper, crop_resize(rgb, base_box))
                for name, dx, dy, k in cases:
                    g = torch_gaze(wrapper, crop_resize(rgb, moved(box, dx, dy, k)))
                    res[name].append(float(np.hypot(*deg(g[:2] - base[:2]))))
                for sigma in (2, 4):
                    outs = []
                    for _ in range(8):
                        noisy = np.clip(rgb.astype(np.float32) + rng.normal(0, sigma, rgb.shape), 0, 255).astype(np.uint8)
                        outs.append(deg(torch_gaze(wrapper, crop_resize(noisy, base_box))[:2]))
                    noise[sigma].append(np.std(np.array(outs), axis=0))
            n2, n4 = np.mean(noise[2], axis=0), np.mean(noise[4], axis=0)
            print(f"{arch + ('+tta' if tta else ''):18s} " + " ".join(f"{np.mean(res[c[0]]):7.2f}" for c in cases)
                  + f" {n2[0]:7.2f} {n2[1]:7.2f} {n4[0]:7.2f} {n4[1]:7.2f}", flush=True)


# ---------------------------------------------------------------- signs

def cmd_signs(work: Path, arch: str) -> None:
    import cv2

    net = load_repo_model(arch, work / f"weights/{arch}.pt", work / "gaze-estimation")
    wrapper = GazeWrapper(net, tta=False).eval()
    faces = load_faces(work, prefix=("video_",), min_width=80)
    flips = []
    for name, rgb, box in faces:
        g = torch_gaze(wrapper, crop_resize(rgb, square_box(box)))
        flipped = np.ascontiguousarray(rgb[:, ::-1])
        w = rgb.shape[1]
        fbox = (w - box[2], box[1], w - box[0], box[3])
        gf = torch_gaze(wrapper, crop_resize(flipped, square_box(fbox)))
        flips.append((deg(g[0]), deg(gf[0]), deg(g[1]), deg(gf[1])))
    f = np.array(flips)
    corr = np.corrcoef(f[:, 0], -f[:, 1])[0, 1]
    print(f"flip: yaw vs -yaw(flipped) corr {corr:.3f}, mean |yaw+yaw_f| {np.mean(np.abs(f[:,0]+f[:,1])):.2f}° "
          f"(mean |yaw| {np.mean(np.abs(f[:,0])):.1f}°); pitch mean |p-p_f| {np.mean(np.abs(f[:,2]-f[:,3])):.2f}°")
    # 주석 영상: 저장소 draw_gaze와 같은 화살표(dx = -L·sin(yaw)·cos(pitch), dy = -L·sin(pitch))
    picks = sorted(faces, key=lambda t: -abs(torch_gaze(wrapper, crop_resize(t[1], square_box(t[2])))[0]))[:3]
    for k, (name, rgb, box) in enumerate(picks):
        g = torch_gaze(wrapper, crop_resize(rgb, square_box(box)))
        img = cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR).copy()
        x0, y0, x1, y1 = map(int, box)
        L = x1 - x0
        c = ((x0 + x1) // 2, (y0 + y1) // 2)
        d = (int(-L * np.sin(g[0]) * np.cos(g[1])), int(-L * np.sin(g[1])))
        cv2.rectangle(img, (x0, y0), (x1, y1), (0, 255, 0), 2)
        cv2.arrowedLine(img, c, (c[0] + d[0], c[1] + d[1]), (0, 0, 255), 3, tipLength=0.25)
        cv2.putText(img, f"yaw {deg(g[0]):+.1f} pitch {deg(g[1]):+.1f}", (x0, max(20, y0 - 10)),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 0, 255), 2)
        pad = int(L * 1.2)
        crop = img[max(0, y0 - pad):y1 + pad, max(0, x0 - pad):x1 + pad]
        cv2.imwrite(str(work / f"annot_{k}.png"), crop)
        print(f"annot_{k}.png <- {name}: yaw {deg(g[0]):+.1f}° pitch {deg(g[1]):+.1f}°")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("samples", "parity", "latency", "stability", "webcam", "signs"))
    parser.add_argument("--work", type=Path, default=Path("/tmp/gaze-work"))
    parser.add_argument("--tta", type=int, default=0)
    parser.add_argument("--arch", default="resnet50", choices=ARCHS)
    args = parser.parse_args()
    if args.command == "samples":
        cmd_samples(args.work)
    elif args.command == "parity":
        cmd_parity(args.work, bool(args.tta))
    elif args.command == "latency":
        cmd_latency(args.work)
    elif args.command == "stability":
        cmd_stability(args.work)
    elif args.command == "webcam":
        cmd_webcam(args.work)
    elif args.command == "signs":
        cmd_signs(args.work, args.arch)


if __name__ == "__main__":
    main()
