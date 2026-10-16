#!/bin/zsh
set -euo pipefail
swift build -c release
app_path=".build/EchoPrompt.app"
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS"
cp .build/release/EchoPrompt "$app_path/Contents/MacOS/EchoPrompt"
cp Info.plist "$app_path/Contents/Info.plist"
# Give the locally packaged app a stable executable identity for macOS privacy
# services (Microphone and Speech Recognition). Release distribution should
# replace this ad-hoc signature with a Developer ID signature.
codesign --force --deep --sign - "$app_path"
echo "Built $app_path"
open "$app_path"
