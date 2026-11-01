#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -version >/dev/null 2>&1 || { echo "Bean needs Xcode, not only the command line tools. Install it, then run: sudo xcode-select -s /Applications/Xcode.app" >&2; exit 1; }
command -v xcodegen >/dev/null || { echo "Bean needs XcodeGen. Run: brew install xcodegen" >&2; exit 1; }
signing=()
if ! security find-identity -p codesigning | grep -q "Bean Local Signing"; then
  signing=(CODE_SIGN_IDENTITY=-)
  echo "No \"Bean Local Signing\" certificate: signing for this Mac only. macOS asks for its permission again after each rebuild."
fi
xcodegen generate --quiet
xcodebuild -project Bean.xcodeproj -scheme Bean -configuration Debug -derivedDataPath build -quiet "${signing[@]}" build
APP="$PWD/build/Build/Products/Debug/Bean.app/Contents/MacOS/Bean"
pkill -xf "$APP" || true
while pgrep -xf "$APP" >/dev/null; do sleep 0.2; done
sleep 0.5
open build/Build/Products/Debug/Bean.app
