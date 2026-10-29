#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project Bean.xcodeproj -scheme Bean -configuration Debug -derivedDataPath build -quiet build
APP="$PWD/build/Build/Products/Debug/Bean.app/Contents/MacOS/Bean"
pkill -xf "$APP" || true
while pgrep -xf "$APP" >/dev/null; do sleep 0.2; done
sleep 0.5
open build/Build/Products/Debug/Bean.app
