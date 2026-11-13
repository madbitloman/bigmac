#!/bin/zsh
# Builds a release binary, wraps it in BigMac.app and signs it with Developer ID (hardened runtime).
#   SIGN_IDENTITY="-" ./make-app.sh          # ad-hoc instead
#   NOTARY_PROFILE=bigmac ./make-app.sh      # also notarize + staple (see README)
set -euo pipefail
cd "$(dirname "$0")"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
VERSION=0.1.0
BUILD=1
ARCH=$(uname -m)

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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/PlugIns"
cp .build/release/BigMac "$APP/Contents/MacOS/BigMac"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/hosts-blocklist.txt "$APP/Contents/Resources/"

# Safari extensions (Extensions/): each is a sandboxed .appex in Contents/PlugIns, built straight with swiftc
# because SwiftPM can't produce app extensions. The content blocker shares Sources/BigMac/AdBlock/Shared with the app.
appex() { # name dir sources...
  local name=$1 dir=$2; shift 2
  local out="$APP/Contents/PlugIns/$name.appex/Contents"
  mkdir -p "$out/MacOS" "$out/Resources"
  swiftc -O -swift-version 6 -application-extension -module-name "$name" -target "$ARCH-apple-macos14.0" \
    -Xlinker -e -Xlinker _NSExtensionMain "$@" -o "$out/MacOS/$name"
  sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" "$dir/Info.plist" > "$out/Info.plist"
}
appex BigMacContentBlocker Extensions/ContentBlocker Extensions/ContentBlocker/*.swift Sources/BigMac/AdBlock/Shared/*.swift
cp Extensions/Filters/*.json "$APP/Contents/PlugIns/BigMacContentBlocker.appex/Contents/Resources/"
appex BigMacYouTube Extensions/YouTube Extensions/YouTube/*.swift -framework SafariServices
cp Extensions/YouTube/Resources/* "$APP/Contents/PlugIns/BigMacYouTube.appex/Contents/Resources/"

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
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>BigMacAppGroup</key><string>G4XQRZC8R6.com.bigmac.app</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

# Inside out: each extension with its own (sandboxed) entitlements, then the app. Never --deep.
sign() { # path entitlements
  if [[ "$SIGN_IDENTITY" == "-" ]]; then
    codesign --force --sign - --entitlements "$2" "$1"
  else
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --entitlements "$2" "$1"
  fi
}
sign "$APP/Contents/PlugIns/BigMacContentBlocker.appex" Extensions/ContentBlocker/Extension.entitlements
sign "$APP/Contents/PlugIns/BigMacYouTube.appex" Extensions/YouTube/Extension.entitlements
sign "$APP" Resources/BigMac.entitlements
codesign --verify --strict --deep --verbose=2 "$APP"

# Notarize with a stored keychain profile (NOTARY_PROFILE) or an Apple ID + app-specific password
# (APPLE_ID, APPLE_APP_PASSWORD, APPLE_TEAM_ID), then staple so it opens offline without a Gatekeeper prompt.
NOTARY_AUTH=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
  NOTARY_AUTH=(--apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$APPLE_TEAM_ID")
fi
if [[ ${#NOTARY_AUTH[@]} -gt 0 && "$SIGN_IDENTITY" != "-" ]]; then
  ZIP=build/BigMac-notarize.zip
  ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
  echo "==> Notarizing (usually 1-5 min)"
  xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  rm -f "$ZIP"
fi
echo "Built $APP — run: open $APP"
