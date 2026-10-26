#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project Bean.xcodeproj -scheme Bean -configuration Debug -derivedDataPath build -quiet build
pkill -x Bean || true
while pgrep -x Bean >/dev/null; do sleep 0.2; done
sleep 0.5
open build/Build/Products/Debug/Bean.app
