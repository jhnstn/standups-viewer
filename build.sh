#!/bin/zsh
# Builds Standups.app with the command-line Swift toolchain (no Xcode project needed).
#   ./build.sh            -> build/Standups.app
#   ./build.sh --install  -> also copies it to ~/Applications/Standups.app
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Standups.app
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macos14.0 -sdk "$(xcrun --show-sdk-path)" \
  -framework SwiftUI -framework WebKit -framework AppKit \
  Sources/*.swift -o "$APP/Contents/MacOS/Standups"
cp Info.plist "$APP/Contents/"
cp Resources/* "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null
echo "built $APP"
if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/Standups.app
  cp -R "$APP" ~/Applications/Standups.app
  echo "installed ~/Applications/Standups.app"
fi
