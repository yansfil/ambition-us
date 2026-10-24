#!/bin/bash
# 변환한 시선 CNN 후보들의 프레임당 처리 시간을 Swift 경로(Vision + 크롭 + CoreML)로 잰다. 카메라는 열지 않는다.
#
# 사용법
#   scripts/bench-gaze-models.sh FACE_IMAGE MODEL.mlpackage [MODEL2.mlpackage ...]
#   FRAMES=200 UNITS=ane SIZE=1080 scripts/bench-gaze-models.sh face.png /tmp/gaze-work/models/*.mlpackage
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FACE="${1:?얼굴 이미지 경로가 필요합니다}"
shift
FRAMES="${FRAMES:-150}"
UNITS="${UNITS:-all}"
SIZE="${SIZE:-1080}"

cd "$ROOT"
swift build -c release --product GazeBench >/dev/null
BENCH="$(swift build -c release --show-bin-path)/GazeBench"

for model in "$@"; do
    echo "== $(basename "$model") (units=$UNITS, ${SIZE}p, $FRAMES frames)"
    GAZE_MODEL_PATH="$model" "$BENCH" bench --image "$FACE" --frames "$FRAMES" --units "$UNITS" --size "$SIZE"
done
