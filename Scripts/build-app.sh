#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build --configuration release
BIN_PATH="$(swift build --configuration release --show-bin-path)"
APP_PATH="$ROOT/.build/HackMail.app"

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH/HackMail" "$APP_PATH/Contents/MacOS/HackMail"
cp "$ROOT/Icons/PirateMail.icns" "$APP_PATH/Contents/Resources/PirateMail.icns"
rm -f "$APP_PATH/Contents/Resources/Assets.car" "$APP_PATH/Contents/Resources/AppIcon.icns"
chmod +x "$APP_PATH/Contents/MacOS/HackMail"

cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>HackMail</string>
    <key>CFBundleIdentifier</key>
    <string>com.hackmail.desktop</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>HackMail</string>
    <key>CFBundleDisplayName</key>
    <string>HackMail</string>
    <key>CFBundleIconFile</key>
    <string>PirateMail.icns</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSContactsUsageDescription</key>
    <string>HackMail uses the selected macOS Contacts list to suggest recipient email addresses as you type.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"
xattr -cr "$APP_PATH"
codesign --force --deep --sign - "$APP_PATH"
printf 'Created %s\n' "$APP_PATH"
