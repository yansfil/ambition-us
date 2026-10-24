#!/bin/bash
# 시선 CNN(yakhyo/gaze-estimation, Gaze360 사전학습, MIT)을 받아 CoreML로 변환하고 설치한다.
#
# 사용법
#   scripts/fetch-gaze-model.sh                 # 기본: resnet18 + 좌우 반전 TTA
#   ARCH=resnet34 scripts/fetch-gaze-model.sh   # 다른 아키텍처(resnet18|resnet34|resnet50|mobileone_s0)
#   TTA=0 scripts/fetch-gaze-model.sh           # 반전 평균 끄기(지연 절반, 크롭 민감도 ↑)
#
# 결과: ~/Library/Application Support/Gaze/Models/GazeEstimator.mlpackage
#   - 입력 "image": 얼굴 크롭 RGB 448×448 (정규화는 모델 안에서)
#   - 출력 "gaze": [yaw, pitch, yaw_std, pitch_std] 라디안
# Gaze.app은 실행 시 이 모델을 찾아 한 번 컴파일해 캐시하고, 없으면 랜드마크 추정기로 돌아간다.
# scripts/bundle.sh는 모델이 있으면 앱 Resources에 함께 넣는다.
#
# 필요: uv(https://docs.astral.sh/uv/), 네트워크. 카메라는 쓰지 않는다.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="${ARCH:-resnet18}"
TTA="${TTA:-1}"
REPO_URL="https://github.com/yakhyo/gaze-estimation.git"
REPO_COMMIT="4125329cfb0dd0071bb91e4c6ca994013db5a26b"
WEIGHTS_URL="https://github.com/yakhyo/gaze-estimation/releases/download/weights/${ARCH}.pt"
CACHE="${GAZE_MODEL_CACHE:-$HOME/Library/Caches/Gaze}"
VENV="$CACHE/model-venv"
REPO_DIR="$CACHE/gaze-estimation"
WEIGHTS="$CACHE/weights/${ARCH}.pt"
DEST_DIR="$HOME/Library/Application Support/Gaze/Models"
DEST="$DEST_DIR/GazeEstimator.mlpackage"
BUILD="$CACHE/build"

case "$ARCH" in
    resnet18|resnet34|resnet50|mobileone_s0) ;;
    *) echo "지원하지 않는 ARCH: $ARCH (resnet18|resnet34|resnet50|mobileone_s0)" >&2; exit 2 ;;
esac
command -v uv >/dev/null || { echo "uv가 필요합니다: brew install uv" >&2; exit 1; }
mkdir -p "$CACHE/weights" "$BUILD" "$DEST_DIR"

echo "==> Python 환경 ($VENV)"
if [[ ! -x "$VENV/bin/python" ]]; then
    uv venv --python 3.12 "$VENV"
fi
# coremltools 9.0이 시험한 torch 2.7.0에 맞춘다.
uv pip install --python "$VENV/bin/python" --quiet \
    "torch==2.7.0" "torchvision==0.22.0" "coremltools==9.0" "numpy<2.6" pillow opencv-python-headless

echo "==> 모델 정의 저장소 ($REPO_COMMIT)"
if [[ ! -d "$REPO_DIR/.git" ]]; then
    git clone --quiet "$REPO_URL" "$REPO_DIR"
fi
git -C "$REPO_DIR" fetch --quiet origin "$REPO_COMMIT" 2>/dev/null || git -C "$REPO_DIR" fetch --quiet origin
git -C "$REPO_DIR" checkout --quiet "$REPO_COMMIT"

echo "==> 가중치 ($ARCH)"
if [[ ! -s "$WEIGHTS" ]]; then
    curl -fL --retry 3 -o "$WEIGHTS.part" "$WEIGHTS_URL"
    mv "$WEIGHTS.part" "$WEIGHTS"
fi

OUT="$BUILD/GazeEstimator-${ARCH}-tta${TTA}.mlpackage"
echo "==> CoreML 변환 (fp16 mlprogram, TTA=$TTA)"
"$VENV/bin/python" "$ROOT/scripts/gaze_model/convert.py" \
    --arch "$ARCH" --weights "$WEIGHTS" --repo "$REPO_DIR" --out "$OUT" --tta "$TTA" 2>&1 \
    | grep -v -E "Warning|warn|passes/s|Converting PyTorch|Running MIL|INFO" || true
[[ -d "$OUT" ]] || { echo "변환 실패" >&2; exit 1; }

echo "==> PyTorch ↔ CoreML 확인"
"$VENV/bin/python" "$ROOT/scripts/gaze_model/sanity.py" \
    --model "$OUT" --arch "$ARCH" --weights "$WEIGHTS" --repo "$REPO_DIR" --tta "$TTA" 2>&1 \
    | grep -v -E "Warning|warn|INFO"

echo "==> 설치: $DEST"
TMP_DEST="$DEST_DIR/.GazeEstimator.installing.mlpackage"
rm -rf "$TMP_DEST"
cp -R "$OUT" "$TMP_DEST"
rm -rf "$DEST"
mv "$TMP_DEST" "$DEST"
# 앱이 만든 컴파일 캐시는 모델이 바뀌면 다시 만든다(오래된 캐시 정리).
rm -rf "$DEST_DIR/Compiled"

echo "==> 완료: $ARCH (TTA=$TTA)"
echo "    다음: scripts/bundle.sh 로 앱을 다시 만들고, 메뉴 막대에서 '시선 보정 시작…'으로 다시 보정하세요."
