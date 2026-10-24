#!/usr/bin/env python3
"""변환된 .mlpackage를 PyTorch(fp32)와 비교하는 빠른 확인(fetch-gaze-model.sh가 부른다).

저장소 영상(assets/in_video.mp4) 304번째 프레임의 얼굴(RetinaFace 상자를 미리 잰 값)과 그 주변 크롭으로
CoreML 출력과 PyTorch 출력의 각도 차이를 잰다. 기준: 최대 |Δ| < 1°.
"""

from __future__ import annotations

import argparse
import sys
import warnings
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import ARCHS, GazeWrapper, crop_resize, load_repo_model, torch_gaze  # noqa: E402

warnings.filterwarnings("ignore")

FRAME_INDEX = 304
FACE_BOX = (711.0, 125.0, 838.0, 300.0)  # uniface RetinaFace, 고정 커밋 영상 기준


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--arch", required=True, choices=ARCHS)
    parser.add_argument("--weights", required=True, type=Path)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--tta", type=int, default=1, choices=(0, 1))
    parser.add_argument("--tolerance", type=float, default=1.0, help="도")
    args = parser.parse_args()

    import coremltools as ct  # noqa: PLC0415
    import cv2  # noqa: PLC0415
    from PIL import Image  # noqa: PLC0415

    cap = cv2.VideoCapture(str(args.repo / "assets/in_video.mp4"))
    cap.set(cv2.CAP_PROP_POS_FRAMES, FRAME_INDEX)
    ok, frame = cap.read()
    if not ok:
        sys.exit("샘플 프레임을 읽지 못했습니다")
    rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
    wrapper = GazeWrapper(load_repo_model(args.arch, args.weights, args.repo), tta=bool(args.tta)).eval()
    model = ct.models.MLModel(str(args.model), compute_units=ct.ComputeUnit.ALL)
    x0, y0, x1, y1 = FACE_BOX
    w, h = x1 - x0, y1 - y0
    worst = 0.0
    for dx, dy, k in ((0, 0, 1), (0.03, 0, 1), (0, 0.03, 1), (0, 0, 1.1)):
        cx, cy = (x0 + x1) / 2 + dx * w, (y0 + y1) / 2 + dy * h
        box = (cx - w * k / 2, cy - h * k / 2, cx + w * k / 2, cy + h * k / 2)
        crop = crop_resize(rgb, box)
        ref = torch_gaze(wrapper, crop)
        ml = np.asarray(model.predict({"image": Image.fromarray(crop)})["gaze"], dtype=np.float64).reshape(-1)
        diff = np.degrees(np.abs(ml[:2] - ref[:2]))
        worst = max(worst, float(diff.max()))
        print(f"  crop dx={dx:+.2f} dy={dy:+.2f} s={k:.2f}: torch yaw {np.degrees(ref[0]):+6.2f}° pitch "
              f"{np.degrees(ref[1]):+6.2f}° | coreml Δ {diff[0]:.3f}°/{diff[1]:.3f}°")
    print(f"  최대 |Δ| = {worst:.3f}° (허용 {args.tolerance}°)")
    sys.exit(0 if worst < args.tolerance else 1)


if __name__ == "__main__":
    main()
