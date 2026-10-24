#!/usr/bin/env python3
"""Swift 전처리·CoreML 출력 ↔ Python 기준(crop_resize + PyTorch fp32) 비교.

입력 JSON(객체 하나 또는 목록):
  {"image": "/abs/path.png", "box": [x0, y0, x1, y1],      # 최종 크롭 직사각형(실수 픽셀, 좌상단 원점)
   "crop_png": "/abs/swift_crop.png",                      # Swift가 만든 448×448 크롭(선택)
   "coreml": [yaw, pitch, yaw_std, pitch_std]}             # Swift CoreML 출력(rad, 선택)

출력: 크롭 픽셀 차이(max/mean |Δ| uint8), Swift CoreML vs PyTorch 각도 차이(도),
--retinaface-boxes를 주면 같은 영상의 RetinaFace 상자 크롭(저장소 방식) PyTorch 각도와의 차이도.
"""

from __future__ import annotations

import argparse
import json
import sys
import warnings
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import ARCHS, GazeWrapper, crop_resize, load_repo_model, torch_gaze  # noqa: E402

warnings.filterwarnings("ignore")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--json", required=True, type=Path)
    parser.add_argument("--arch", default="resnet18", choices=ARCHS)
    parser.add_argument("--weights", required=True, type=Path)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--tta", type=int, default=1, choices=(0, 1))
    parser.add_argument("--retinaface-boxes", type=Path, default=None,
                        help="{파일 이름: [[x0,y0,x1,y1,score],...]} JSON (analyze.py samples가 만든다)")
    args = parser.parse_args()

    from PIL import Image  # noqa: PLC0415

    items = json.loads(args.json.read_text())
    if isinstance(items, dict):
        items = [items]
    wrapper = GazeWrapper(load_repo_model(args.arch, args.weights, args.repo), tta=bool(args.tta)).eval()
    retina = json.loads(args.retinaface_boxes.read_text()) if args.retinaface_boxes else {}

    print(f"{'image':28s} {'crop max':>8s} {'crop mean':>9s} {'Δyaw°':>7s} {'Δpitch°':>8s} {'torch yaw/pitch°':>18s} {'vsRetina°':>10s}")
    crop_max, angle_diffs, retina_diffs = [], [], []
    for item in items:
        rgb = np.asarray(Image.open(item["image"]).convert("RGB"))
        ref_crop = crop_resize(rgb, item["box"])
        ref = torch_gaze(wrapper, ref_crop)
        cmax = cmean = float("nan")
        if item.get("crop_png"):
            swift_crop = np.asarray(Image.open(item["crop_png"]).convert("RGB")).astype(np.int16)
            diff = np.abs(swift_crop - ref_crop.astype(np.int16))
            cmax, cmean = float(diff.max()), float(diff.mean())
            crop_max.append(cmax)
        dyaw = dpitch = float("nan")
        if item.get("coreml"):
            ml = np.asarray(item["coreml"], dtype=np.float64)
            dyaw, dpitch = np.degrees(np.abs(ml[:2] - ref[:2]))
            angle_diffs.append((dyaw, dpitch))
        vs_retina = float("nan")
        name = Path(item["image"]).name
        if retina.get(name):
            rb = max(retina[name], key=lambda b: (b[2] - b[0]) * (b[3] - b[1]))
            rg = torch_gaze(wrapper, crop_resize(rgb, rb[:4]))
            vs_retina = float(np.hypot(*np.degrees(rg[:2] - ref[:2])))
            retina_diffs.append(vs_retina)
        print(f"{name[:28]:28s} {cmax:8.0f} {cmean:9.3f} {dyaw:7.3f} {dpitch:8.3f} "
              f"{np.degrees(ref[0]):+8.2f}/{np.degrees(ref[1]):+8.2f} {vs_retina:10.2f}")
    if crop_max:
        print(f"crop: max |Δ| over all {max(crop_max):.0f} (uint8)")
    if angle_diffs:
        d = np.array(angle_diffs)
        print(f"CoreML(Swift) vs PyTorch: |Δyaw| max {d[:,0].max():.3f}° mean {d[:,0].mean():.3f}°, "
              f"|Δpitch| max {d[:,1].max():.3f}° mean {d[:,1].mean():.3f}°")
    if retina_diffs:
        print(f"Swift crop vs RetinaFace crop (PyTorch, combined): mean {np.mean(retina_diffs):.2f}° max {np.max(retina_diffs):.2f}°")


if __name__ == "__main__":
    main()
