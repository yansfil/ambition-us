"""Gaze360 시선 CNN(yakhyo/gaze-estimation) 공용 도우미.

- 저장소 정의로 모델을 다시 만들고 가중치를 읽는다.
- CoreML 변환용 래퍼: ImageNet 정규화 + (선택) 좌우 반전 TTA + 빈 기댓값 디코딩을 그래프 안에 넣는다.
- Swift(`GazeCropSampler`)가 그대로 따라 하는 기준 전처리 `crop_resize`.

출력 계약: "gaze" float32 [1, 4] = [yaw_rad, pitch_rad, yaw_std_rad, pitch_std_rad].
저장소 디코딩: softmax(90 bins) 기댓값 Σ pᵢ·i · 4 − 180 (도). 여기서는 fp16 정밀도를 위해
중심 지수 (i − 45)를 쓴다: 4·Σ pᵢ·(i − 45) = 4·Σ pᵢ·i − 180 (수학적으로 동일).
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn.functional as F
from torch import nn

REPO_COMMIT = "4125329cfb0dd0071bb91e4c6ca994013db5a26b"
REPO_SOURCE = f"yakhyo/gaze-estimation@{REPO_COMMIT} Gaze360"
WEIGHTS_BASE_URL = "https://github.com/yakhyo/gaze-estimation/releases/download/weights"

BINS = 90
BIN_WIDTH = 4.0
ANGLE_OFFSET = -180.0
INPUT_SIZE = 448
MEAN = (0.485, 0.456, 0.406)
STD = (0.229, 0.224, 0.225)

# Vision 얼굴 상자 → RetinaFace 비슷한 크롭 직사각형(Swift가 메타데이터로 읽는다).
# Vision 상자(정사각형) 대비 폭 ×0.85, 높이 ×1.19, 중심을 상자 높이의 0.10만큼 위로(16장 측정).
# 저장소 ONNX 추론처럼 이 직사각형을 448×448로 그대로 늘려 넣는다.
DEFAULT_CROP_WIDTH_SCALE = 0.85
DEFAULT_CROP_HEIGHT_SCALE = 1.19
DEFAULT_CROP_Y_OFFSET = -0.10

ARCHS = ("resnet18", "resnet34", "resnet50", "mobilenetv2", "mobileone_s0")


def load_repo_model(arch: str, weights: str | Path, repo: str | Path) -> nn.Module:
    """저장소의 모델 정의로 네트워크를 만들고 가중치를 읽는다(eval 모드)."""
    repo = str(Path(repo).resolve())
    if repo not in sys.path:
        sys.path.insert(0, repo)
    import models  # noqa: PLC0415  (저장소 패키지)

    if arch in ("resnet18", "resnet34", "resnet50"):
        net = getattr(models, arch)(pretrained=False, num_classes=BINS)
    elif arch == "mobilenetv2":
        net = models.mobilenet_v2(pretrained=False, num_classes=BINS)
    elif arch.startswith("mobileone_"):
        # 배포 가중치는 재매개변수화(fused)된 상태라 inference_mode=True로 만든다.
        net = getattr(models, arch)(pretrained=False, num_classes=BINS, inference_mode=True)
    else:
        raise ValueError(f"지원하지 않는 아키텍처: {arch}")
    state = torch.load(str(weights), map_location="cpu", weights_only=True)
    net.load_state_dict(state)
    return net.eval()


def decode_logits(logits: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
    """[N, 90] 로짓 → (각도 rad [N], 분포 표준편차 rad [N])."""
    probs = F.softmax(logits, dim=1)
    centered = torch.arange(BINS, dtype=logits.dtype, device=logits.device) - (BINS // 2)
    mean_bin = torch.sum(probs * centered, dim=1, keepdim=True)
    var_bin = torch.sum(probs * (centered - mean_bin) ** 2, dim=1)
    scale = BIN_WIDTH * np.pi / 180.0
    # BINS//2 * BIN_WIDTH + ANGLE_OFFSET == 0 이므로 중심 지수 기댓값이 곧 각도다.
    assert (BINS // 2) * BIN_WIDTH + ANGLE_OFFSET == 0
    return mean_bin.squeeze(1) * scale, torch.sqrt(torch.clamp(var_bin, min=0.0)) * scale


def decode_reference(yaw_logits: np.ndarray, pitch_logits: np.ndarray) -> np.ndarray:
    """저장소 onnx_inference.py와 같은 디코딩(float64). 반환: [yaw, pitch] rad."""
    def one(lg: np.ndarray) -> float:
        lg = lg.astype(np.float64).reshape(-1)
        e = np.exp(lg - lg.max())
        p = e / e.sum()
        return float(np.radians(np.sum(p * np.arange(BINS)) * BIN_WIDTH + ANGLE_OFFSET))
    return np.array([one(yaw_logits), one(pitch_logits)])


class GazeWrapper(nn.Module):
    """입력 RGB [0,1] [1,3,448,448] → "gaze" [1,4]."""

    def __init__(self, net: nn.Module, tta: bool) -> None:
        super().__init__()
        self.net = net
        self.tta = tta
        self.register_buffer("mean", torch.tensor(MEAN, dtype=torch.float32).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(STD, dtype=torch.float32).view(1, 3, 1, 1))
        # 좌우 반전 = 마지막 축에 역순 순열 행렬을 곱한다. ANE에서 flip(reverse)·배치 2는 CPU로 밀려나
        # 3~4배 느려서(측정), 같은 망을 두 번 순차 실행하고 반전은 matmul로 한다.
        flip = torch.zeros(INPUT_SIZE, INPUT_SIZE)
        flip[torch.arange(INPUT_SIZE), INPUT_SIZE - 1 - torch.arange(INPUT_SIZE)] = 1
        self.register_buffer("flip", flip)

    def forward(self, image: torch.Tensor) -> torch.Tensor:
        x = (image - self.mean) / self.std
        if self.tta:
            y0, p0 = self.net(x)
            y1, p1 = self.net(torch.matmul(x, self.flip))
            yaw_logits, pitch_logits = torch.cat([y0, y1], dim=0), torch.cat([p0, p1], dim=0)
        else:
            yaw_logits, pitch_logits = self.net(x)
        yaw, yaw_std = decode_logits(yaw_logits)
        pitch, pitch_std = decode_logits(pitch_logits)
        if self.tta:
            # 좌우 반전 영상의 yaw는 부호가 반대다.
            yaw = (yaw[0:1] - yaw[1:2]) * 0.5
            pitch = (pitch[0:1] + pitch[1:2]) * 0.5
            yaw_std = (yaw_std[0:1] + yaw_std[1:2]) * 0.5
            pitch_std = (pitch_std[0:1] + pitch_std[1:2]) * 0.5
        return torch.stack([yaw, pitch, yaw_std, pitch_std], dim=1)


def crop_resize(rgb: np.ndarray, box, size: int = INPUT_SIZE) -> np.ndarray:
    """기준 전처리. rgb uint8 [H,W,3], box = (x0, y0, x1, y1) 실수 픽셀(좌상단 원점, 반열림 아님: 연속 좌표).

    출력 (row i, col j): sx = x0 + (j + 0.5)·(x1 − x0)/size − 0.5, sy도 같다.
    좌표를 [0, W−1]·[0, H−1]로 자른 뒤 쌍선형 보간:
      top = p00 + (p01 − p00)·fx, bottom = p10 + (p11 − p10)·fx, v = top + (bottom − top)·fy
    반올림: floor(v + 0.5). Swift `GazeCropSampler`가 같은 식을 쓴다.
    """
    h, w = rgb.shape[:2]
    x0, y0, x1, y1 = (float(v) for v in box[:4])
    idx = np.arange(size, dtype=np.float64)
    sx = np.clip(x0 + (idx + 0.5) * (x1 - x0) / size - 0.5, 0, w - 1)
    sy = np.clip(y0 + (idx + 0.5) * (y1 - y0) / size - 0.5, 0, h - 1)
    xl = np.floor(sx).astype(np.int64)
    yl = np.floor(sy).astype(np.int64)
    xh = np.minimum(xl + 1, w - 1)
    yh = np.minimum(yl + 1, h - 1)
    fx = (sx - xl)[None, :, None]
    fy = (sy - yl)[:, None, None]
    img = rgb.astype(np.float64)
    p00 = img[yl][:, xl]
    p01 = img[yl][:, xh]
    p10 = img[yh][:, xl]
    p11 = img[yh][:, xh]
    top = p00 + (p01 - p00) * fx
    bottom = p10 + (p11 - p10) * fx
    v = top + (bottom - top) * fy
    return np.clip(np.floor(v + 0.5), 0, 255).astype(np.uint8)


def to_tensor01(crop_uint8: np.ndarray) -> torch.Tensor:
    """uint8 [448,448,3] → float32 [1,3,448,448] in [0,1]."""
    return torch.from_numpy(crop_uint8.astype(np.float32) / 255.0).permute(2, 0, 1).unsqueeze(0).contiguous()


def square_box(box, scale: float = 1.0, y_offset: float = 0.0):
    """상자 중심 기준 정사각형(변 = max(w,h)·scale), 중심을 y_offset·h만큼 아래로 옮긴다."""
    x0, y0, x1, y1 = (float(v) for v in box[:4])
    w, h = x1 - x0, y1 - y0
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2 + y_offset * h
    side = max(w, h) * scale
    return (cx - side / 2, cy - side / 2, cx + side / 2, cy + side / 2)


@torch.no_grad()
def torch_gaze(wrapper: GazeWrapper, crop_uint8: np.ndarray) -> np.ndarray:
    """fp32 PyTorch 결과 [yaw, pitch, yaw_std, pitch_std] rad."""
    return wrapper(to_tensor01(crop_uint8)).numpy().reshape(-1).astype(np.float64)
