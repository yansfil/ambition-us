#!/bin/bash
# Gaze.app 번들을 만든다: 릴리스 빌드 → .app 구조 → Info.plist → 코드 서명.
#
# 사용법
#   scripts/bundle.sh                 # build/Gaze.app (ad-hoc 서명)
#   OUTPUT_DIR=/tmp scripts/bundle.sh # 다른 위치에 만들기
#   CODESIGN_IDENTITY="Developer ID Application: ..." scripts/bundle.sh
#                                     # 실제 인증서로 서명(hardened runtime + 카메라·마이크 entitlement)
#   GAZE_MODEL=/path/GazeEstimator.mlpackage scripts/bundle.sh
#                                     # 시선 CNN을 지정 경로에서 넣기(기본: ~/Library/Application Support/Gaze/Models)
#
# 시선 CNN(scripts/fetch-gaze-model.sh로 설치)이 있으면 Resources/GazeEstimator.mlpackage로 넣는다.
# 앱은 처음 실행할 때 한 번 컴파일해 ~/Library/Application Support/Gaze/Models/Compiled에 캐시한다.
# 모델이 없으면 랜드마크 추정기(정확도 낮음)로 동작하고 메뉴에 표시된다.
#
# 실행: open build/Gaze.app              (카메라 시선)
#       open build/Gaze.app --args --mouse-gaze   (마우스를 시선으로)
#       open build/Gaze.app --args --demo         (오버레이 데모만)
#
# ad-hoc 서명은 빌드마다 서명이 달라져 손쉬운 사용·화면 기록 권한을 다시 허용해야 할 수 있다.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT/build}"
APP="$OUTPUT_DIR/Gaze.app"
BUNDLE_ID="${BUNDLE_ID:-com.ambition.gaze}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
# 서명 ID를 지정하지 않으면 키체인의 Developer ID → Apple Development 순으로 고른다.
# ad-hoc(-) 서명은 빌드마다 서명이 바뀌어 손쉬운 사용·화면 기록 허용이 매번 풀린다.
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    CODESIGN_IDENTITY="$(awk -F'"' '/Developer ID Application/ {print $2; exit}' <<<"$IDENTITIES")"
    [[ -n "$CODESIGN_IDENTITY" ]] || CODESIGN_IDENTITY="$(awk -F'"' '/Apple Development/ {print $2; exit}' <<<"$IDENTITIES")"
    [[ -n "$CODESIGN_IDENTITY" ]] || CODESIGN_IDENTITY="-"
fi

# 로컬 개발: Finder/open으로 띄워도 저장소 .env의 키를 읽도록 경로만 넘긴다(키 값은 번들에 넣지 않는다).
LS_ENVIRONMENT=""
ENV_FILE="${GAZE_ENV_FILE:-$ROOT/.env}"
if [[ -f "$ENV_FILE" && "${GAZE_EMBED_ENV_PATH:-1}" == "1" ]]; then
    LS_ENVIRONMENT="    <key>LSEnvironment</key>
    <dict>
        <key>GAZE_ENV_FILE</key>
        <string>${ENV_FILE}</string>
    </dict>
"
fi

cd "$ROOT"
echo "==> swift build -c release --product GazeApp"
swift build -c release --product GazeApp
BIN_DIR="$(swift build -c release --show-bin-path)"
BINARY="$BIN_DIR/GazeApp"
[[ -x "$BINARY" ]] || { echo "실행 파일이 없습니다: $BINARY" >&2; exit 1; }

echo "==> $APP 구성"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Gaze"
# SwiftPM 리소스 번들이 생기면 함께 넣는다(현재는 없음).
for bundle in "$BIN_DIR"/*.bundle; do
    [[ -e "$bundle" ]] && cp -R "$bundle" "$APP/Contents/Resources/"
done

GAZE_MODEL="${GAZE_MODEL:-$HOME/Library/Application Support/Gaze/Models/GazeEstimator.mlpackage}"
if [[ -d "$GAZE_MODEL" ]]; then
    echo "==> 시선 CNN 포함: $GAZE_MODEL"
    cp -R "$GAZE_MODEL" "$APP/Contents/Resources/GazeEstimator.mlpackage"
else
    echo "==> 시선 CNN 없음($GAZE_MODEL) — 랜드마크 추정기로 동작합니다. scripts/fetch-gaze-model.sh로 설치하세요."
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ko</string>
    <key>CFBundleDisplayName</key>
    <string>Gaze</string>
    <key>CFBundleExecutable</key>
    <string>Gaze</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Gaze</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
${LS_ENVIRONMENT}    <key>NSCameraUsageDescription</key>
    <string>Gaze는 웹캠으로 사용자가 화면의 어디를 보고 있는지 추적합니다. 영상은 기기 안에서만 처리하며 저장하거나 전송하지 않습니다.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Gaze는 "이거 저기로 옮겨줘" 같은 한국어 음성 명령과 받아쓰기를 듣기 위해 마이크를 사용합니다.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Gaze는 한국어 음성을 글자로 바꿔 명령과 받아쓰기를 이해하기 위해 음성 인식을 사용합니다.</string>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> 코드 서명 (${CODESIGN_IDENTITY})"
if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP"
else
    ENTITLEMENTS="$(mktemp -t gaze-entitlements).plist"
    cat > "$ENTITLEMENTS" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.camera</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
ENT
    codesign --force --sign "$CODESIGN_IDENTITY" --identifier "$BUNDLE_ID" --options runtime \
        --entitlements "$ENTITLEMENTS" --timestamp=none "$APP"
    rm -f "$ENTITLEMENTS"
fi

codesign --verify --strict --verbose=2 "$APP"
echo "==> 완료: $APP"
