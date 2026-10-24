#!/bin/zsh
set -euo pipefail
swift build -c release
app_path=".build/EchoPrompter.app"
icon_source="Assets/EchoPrompterAppIcon.png"
iconset_path=".build/EchoPrompter.iconset"
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp .build/release/EchoPrompter "$app_path/Contents/MacOS/EchoPrompter"
cp Info.plist "$app_path/Contents/Info.plist"

# Build a standard macOS .icns bundle from the shared EchoPrompter source icon.
# Keeping the source PNG in the repository also lets the web app use the exact
# same visual identity for its browser tab icon.
if [[ ! -f "$icon_source" ]]; then
  echo "Missing app icon: $icon_source" >&2
  exit 1
fi

rm -rf "$iconset_path"
mkdir -p "$iconset_path"
sips -z 16 16 "$icon_source" --out "$iconset_path/icon_16x16.png" >/dev/null
sips -z 32 32 "$icon_source" --out "$iconset_path/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$icon_source" --out "$iconset_path/icon_32x32.png" >/dev/null
sips -z 64 64 "$icon_source" --out "$iconset_path/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$icon_source" --out "$iconset_path/icon_128x128.png" >/dev/null
sips -z 256 256 "$icon_source" --out "$iconset_path/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$icon_source" --out "$iconset_path/icon_256x256.png" >/dev/null
sips -z 512 512 "$icon_source" --out "$iconset_path/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$icon_source" --out "$iconset_path/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$icon_source" --out "$iconset_path/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$iconset_path" -o "$app_path/Contents/Resources/EchoPrompter.icns"
rm -rf "$iconset_path"

# Give the locally packaged app a stable executable identity for macOS privacy
# services (Microphone and Speech Recognition). Release distribution should
# replace this ad-hoc signature with a Developer ID signature.
codesign --force --deep --sign - "$app_path"
echo "Built $app_path"

if [[ "${ECHO_PROMPTER_OPEN_AFTER_BUILD:-1}" == "1" ]]; then
  open "$app_path"
fi
