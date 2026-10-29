#!/bin/zsh
# Builds a release binary, wraps it in BigMac.app and signs it with Developer ID (hardened runtime).
#   SIGN_IDENTITY="-" ./make-app.sh          # ad-hoc instead
#   NOTARY_PROFILE=bigmac ./make-app.sh      # also notarize + staple (see README)
set -euo pipefail
cd "$(dirname "$0")"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"

# Icon: Resources/AppIcon.png (rendered by scripts/logo.py) → AppIcon.icns
if [[ ! -f Resources/AppIcon.icns || Resources/AppIcon.png -nt Resources/AppIcon.icns ]]; then
  ICONSET=$(mktemp -d)/AppIcon.iconset
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

swift build -c release
APP=build/BigMac.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/BigMac "$APP/Contents/MacOS/BigMac"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>BigMac</string>
  <key>CFBundleDisplayName</key><string>BigMac</string>
  <key>CFBundleIdentifier</key><string>com.bigmac.app</string>
  <key>CFBundleExecutable</key><string>BigMac</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  ZIP=build/BigMac.zip
  ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
fi
echo "Built $APP — run: open $APP"
