#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project Bean.xcodeproj -scheme Bean -configuration Debug -derivedDataPath build -quiet build
pkill -x Bean || true
open build/Build/Products/Debug/Bean.app
