#!/usr/bin/env python3
"""yakhyo/gaze-estimation(Gaze360) PyTorch 가중치 → fp16 CoreML mlprogram(.mlpackage).

입력 "image": RGB 448×448 이미지(scale 1/255, bias 0) — ImageNet 정규화는 그래프 안에서 한다.
출력 "gaze": float32 [1,4] = [yaw_rad, pitch_rad, yaw_std_rad, pitch_std_rad].

예)
  python convert.py --arch resnet18 --weights weights/resnet18.pt --repo gaze-estimation --out GazeEstimator.mlpackage
"""

from __future__ import annotations

import argparse
import shutil
import sys
import warnings
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from common import (  # noqa: E402
    ANGLE_OFFSET,
    ARCHS,
    BIN_WIDTH,
    BINS,
    DEFAULT_CROP_HEIGHT_SCALE,
    DEFAULT_CROP_WIDTH_SCALE,
    DEFAULT_CROP_Y_OFFSET,
    INPUT_SIZE,
    REPO_SOURCE,
    GazeWrapper,
    load_repo_model,
)

warnings.filterwarnings("ignore")


def convert(arch: str, weights: Path, repo: Path, out: Path, tta: bool,
            crop_width_scale: float = DEFAULT_CROP_WIDTH_SCALE, crop_height_scale: float = DEFAULT_CROP_HEIGHT_SCALE,
            crop_y_offset: float = DEFAULT_CROP_Y_OFFSET):
    import coremltools as ct  # noqa: PLC0415

    net = load_repo_model(arch, weights, repo)
    wrapper = GazeWrapper(net, tta=tta).eval()
    example = torch.rand(1, 3, INPUT_SIZE, INPUT_SIZE)
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example)
    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[ct.ImageType(name="image", shape=(1, 3, INPUT_SIZE, INPUT_SIZE), scale=1 / 255.0,
                             bias=[0.0, 0.0, 0.0], color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="gaze", dtype=np.float32)],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS15,
    )
    mlmodel.short_description = (
        f"Gaze360 appearance-based gaze ({arch}{', flip TTA' if tta else ''}). "
        "Input: face crop RGB 448x448. Output gaze=[yaw, pitch, yaw_std, pitch_std] radians."
    )
    mlmodel.author = "Yakhyokhuja Valikhujaev (yakhyo/gaze-estimation, built on L2CS-Net); converted for Gaze"
    mlmodel.license = "MIT"
    mlmodel.version = "1"
    meta = mlmodel.user_defined_metadata
    meta["gaze.arch"] = arch
    meta["gaze.source"] = REPO_SOURCE
    meta["gaze.bins"] = str(BINS)
    meta["gaze.binwidth"] = f"{BIN_WIDTH:g}"
    meta["gaze.angleOffset"] = f"{ANGLE_OFFSET:g}"
    meta["gaze.tta"] = "1" if tta else "0"
    meta["gaze.offsets"] = "none"
    meta["gaze.cropWidthScale"] = f"{crop_width_scale:g}"
    meta["gaze.cropHeightScale"] = f"{crop_height_scale:g}"
    meta["gaze.cropYOffset"] = f"{crop_y_offset:g}"
    meta["gaze.inputSize"] = str(INPUT_SIZE)
    meta["gaze.output"] = "gaze=[yaw_rad,pitch_rad,yaw_std_rad,pitch_std_rad]"
    meta["gaze.version"] = "1"
    mlmodel.input_description["image"] = "Face crop (RetinaFace-like rect) resized to RGB 448x448"
    mlmodel.output_description["gaze"] = "[yaw, pitch, yaw_std, pitch_std] in radians (Gaze360 convention)"

    out = out.resolve()
    tmp = out.with_name(out.stem + ".tmp.mlpackage")
    if tmp.exists():
        shutil.rmtree(tmp)
    mlmodel.save(str(tmp))
    if out.exists():
        shutil.rmtree(out)
    tmp.rename(out)
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--arch", required=True, choices=ARCHS)
    parser.add_argument("--weights", required=True, type=Path)
    parser.add_argument("--repo", required=True, type=Path, help="yakhyo/gaze-estimation 체크아웃 경로")
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--tta", type=int, default=0, choices=(0, 1), help="좌우 반전 평균(배치 2)")
    parser.add_argument("--crop-width-scale", type=float, default=DEFAULT_CROP_WIDTH_SCALE)
    parser.add_argument("--crop-height-scale", type=float, default=DEFAULT_CROP_HEIGHT_SCALE)
    parser.add_argument("--crop-y-offset", type=float, default=DEFAULT_CROP_Y_OFFSET)
    args = parser.parse_args()
    out = convert(args.arch, args.weights, args.repo, args.out, bool(args.tta), args.crop_width_scale,
                  args.crop_height_scale, args.crop_y_offset)
    print(f"저장: {out}")


if __name__ == "__main__":
    main()
