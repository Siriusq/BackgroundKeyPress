#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/后台按键助手.app"
CONTENTS="$APP/Contents"
EXECUTABLE="BackgroundKeyPress"

mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Resources"
rm -f "$CONTENTS/MacOS/BackgroundPressT"
cp "$ROOT/icon/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/backgroundpresst-module-cache" \
  swiftc -parse-as-library "$ROOT/main.swift" -o "$CONTENTS/MacOS/$EXECUTABLE"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>BackgroundKeyPress</string>
    <key>CFBundleIdentifier</key><string>com.backgroundpresst.app</string>
    <key>CFBundleName</key><string>后台按键助手</string>
    <key>CFBundleDisplayName</key><string>后台按键助手</string>
    <key>CFBundleIconFile</key><string>AppIcon.icns</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>CFBundleSupportedPlatforms</key>
    <array><string>MacOSX</string></array>
    <key>LSArchitecturePriority</key>
    <array><string>arm64</string></array>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS/PkgInfo"
codesign --force --deep --sign - "$APP"
/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$CONTENTS/Info.plist" >/dev/null
codesign --verify --deep --strict "$APP"
echo "Built: $APP"
