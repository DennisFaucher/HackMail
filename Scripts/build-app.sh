#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build --configuration release
BIN_PATH="$(swift build --configuration release --show-bin-path)"
APP_PATH="$ROOT/.build/HackMail.app"
ICON_BUILD_DIR="$(mktemp -d "$ROOT/.build/HackMailIcon.XXXXXX")"
trap 'rm -rf "$ICON_BUILD_DIR"' EXIT
ICONSET_PATH="$ICON_BUILD_DIR/PirateMail.iconset"
APP_ICONSET_PATH="$ICON_BUILD_DIR/HackMailAssets.xcassets/AppIcon.appiconset"

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_PATH/HackMail" "$APP_PATH/Contents/MacOS/HackMail"
cp "$ROOT/Icons/PirateMail.icns" "$APP_PATH/Contents/Resources/PirateMail.icns"
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

# Compile the supplied ICNS into an asset catalog so LaunchServices recognizes it as the app icon.
iconutil --convert iconset --output "$ICONSET_PATH" "$ROOT/Icons/PirateMail.icns"
mkdir -p "$APP_ICONSET_PATH"
sips -s format png -z 16 16 "$ROOT/Icons/PirateMail.icns" --out "$APP_ICONSET_PATH/icon_16x16.png" >/dev/null
sips -s format png -z 32 32 "$ROOT/Icons/PirateMail.icns" --out "$APP_ICONSET_PATH/icon_32x32.png" >/dev/null
cp "$ICONSET_PATH/icon_16x16@2x.png" "$APP_ICONSET_PATH/icon_16x16@2x.png"
cp "$ICONSET_PATH/icon_32x32@2x.png" "$APP_ICONSET_PATH/icon_32x32@2x.png"
cp "$ICONSET_PATH/icon_128x128.png" "$APP_ICONSET_PATH/icon_128x128.png"
cp "$ICONSET_PATH/icon_128x128@2x.png" "$APP_ICONSET_PATH/icon_128x128@2x.png"
cp "$ICONSET_PATH/icon_256x256.png" "$APP_ICONSET_PATH/icon_256x256.png"
cp "$ICONSET_PATH/icon_256x256@2x.png" "$APP_ICONSET_PATH/icon_256x256@2x.png"
cp "$ICONSET_PATH/icon_512x512.png" "$APP_ICONSET_PATH/icon_512x512.png"
cp "$ICONSET_PATH/icon_512x512@2x.png" "$APP_ICONSET_PATH/icon_512x512@2x.png"
cat > "$APP_ICONSET_PATH/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
xcrun actool --compile "$APP_PATH/Contents/Resources" --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist "$ICON_BUILD_DIR/assetcatalog-generated-info.plist" "$ICON_BUILD_DIR/HackMailAssets.xcassets"
python3 - "$APP_PATH/Contents/Info.plist" "$ICON_BUILD_DIR/assetcatalog-generated-info.plist" <<'PY'
import plistlib
import sys

info_path, partial_path = sys.argv[1:]
with open(info_path, "rb") as file:
    info = plistlib.load(file)
with open(partial_path, "rb") as file:
    info.update(plistlib.load(file))
with open(info_path, "wb") as file:
    plistlib.dump(info, file, fmt=plistlib.FMT_XML, sort_keys=False)
PY
printf 'APPL????' > "$APP_PATH/Contents/PkgInfo"
xattr -cr "$APP_PATH"
codesign --force --deep --sign - "$APP_PATH"
printf 'Created %s\n' "$APP_PATH"
