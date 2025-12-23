#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TAG="${1:-}"
if [[ -z "$TAG" ]]; then
	echo "Usage: tools/package-macapp.sh <tag>"
	echo "Example: tools/package-macapp.sh v0.5.0"
	exit 2
fi

# Avoid mixed logs by stopping an already running debug binary (if any).
pkill -f "$ROOT_DIR/.build/debug/YunqiMacApp" >/dev/null 2>&1 || true
pkill -f "YunqiMacApp" >/dev/null 2>&1 || true

echo "[pkg] Workspace: $ROOT_DIR"
echo "[pkg] Building YunqiMacApp…"
swift build --product YunqiMacApp

# Ensure the app icon exists (generated from the chosen SVG).
if [[ ! -f "$ROOT_DIR/AppResources/AppIcon.icns" || "$ROOT_DIR/AppResources/AppIcon-Timeline.svg" -nt "$ROOT_DIR/AppResources/AppIcon.icns" ]]; then
	echo "[pkg] Generating AppIcon.icns…"
	"$ROOT_DIR/tools/make-app-icon-icns.sh"
fi

BIN_DIR="$(swift build --show-bin-path)"
APP_DIR="$ROOT_DIR/.build/YunqiMacApp.app"
OUT_DIR="$ROOT_DIR/dist"
OUT_ZIP="$OUT_DIR/Yunqi-${TAG}-macos.zip"

echo "[pkg] Packaging .app bundle…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp "$BIN_DIR/YunqiMacApp" "$APP_DIR/Contents/MacOS/YunqiMacApp"

# Copy SwiftPM resource bundles (Bundle.module) so in-app localized strings still work.
find "$BIN_DIR" -maxdepth 1 -type d -name "*.bundle" -print0 | xargs -0 -I{} cp -R "{}" "$APP_DIR/Contents/Resources/"

# Localizations.
cp -R "$ROOT_DIR/AppResources/en.lproj" "$APP_DIR/Contents/Resources/"
cp -R "$ROOT_DIR/AppResources/zh-Hans.lproj" "$APP_DIR/Contents/Resources/"

# App icon.
cp "$ROOT_DIR/AppResources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>YunqiMacApp</string>
	<key>CFBundleIdentifier</key>
	<string>com.yunqi.YunqiMacApp</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Yunqi</string>
	<key>CFBundleDisplayName</key>
	<string>Yunqi</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.0.0</string>
	<key>CFBundleVersion</key>
	<string>0</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

mkdir -p "$OUT_DIR"
rm -f "$OUT_ZIP"

echo "[pkg] Creating zip: $OUT_ZIP"
(
	cd "$ROOT_DIR/.build"
	# Zip contains YunqiMacApp.app at root for convenient open.
	/usr/bin/zip -qry "$OUT_ZIP" "YunqiMacApp.app"
)

echo "[pkg] Done: $OUT_ZIP"
