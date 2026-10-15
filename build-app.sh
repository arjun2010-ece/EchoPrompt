#!/bin/zsh
set -euo pipefail
swift build -c release
app_path=".build/EchoPrompt.app"
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS"
cp .build/release/EchoPrompt "$app_path/Contents/MacOS/EchoPrompt"
cp Info.plist "$app_path/Contents/Info.plist"
echo "Built $app_path"
