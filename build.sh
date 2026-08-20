#!/bin/bash
# Builds MDView.app and ad-hoc signs it. No Apple developer account needed:
# a locally built, ad-hoc signed Mac app runs indefinitely.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MDView"
BUNDLE_ID="com.minh.mdview"
VERSION="1.0"
DEPLOY_TARGET="14.0"
ICON_VARIANT="ink"          # ink | paper | accent — see tools/make-icon.swift
OUT="build/${APP_NAME}.app"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
ARCH="$(uname -m)"

echo "==> cleaning"
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources"

# The page is an npm project (web/). Its build output is committed, so this works
# without node — it only rebuilds when the sources are newer.
if command -v node >/dev/null 2>&1 && [ -d web/node_modules ]; then
  needs_build=""
  for source in web/src/viewer.js web/src/mermaid.js web/build.mjs web/package.json; do
    [ "$source" -nt Resources/bundle.js ] && needs_build="yes"
  done
  if [ -n "$needs_build" ]; then
    echo "==> building web bundle"
    (cd web && npm run build)
  fi
elif [ ! -f Resources/bundle.js ]; then
  echo "no Resources/bundle.js and no way to build it — run: cd web && npm install" >&2
  exit 1
fi

echo "==> compiling swift ($ARCH, macOS $DEPLOY_TARGET target)"
swiftc \
  -parse-as-library \
  -O -whole-module-optimization \
  -target "${ARCH}-apple-macos${DEPLOY_TARGET}" \
  -sdk "$SDK" \
  -module-name "$APP_NAME" \
  -o "$OUT/Contents/MacOS/$APP_NAME" \
  Sources/*.swift

echo "==> copying resources"
cp -R Resources/. "$OUT/Contents/Resources/"

# build.sh is included: ICON_VARIANT lives here, so changing it must count.
if [ ! -f build/AppIcon.icns ] || [ tools/make-icon.swift -nt build/AppIcon.icns ] \
   || [ build.sh -nt build/AppIcon.icns ]; then
  echo "==> generating icon ($ICON_VARIANT)"
  rm -rf build/AppIcon.iconset
  mkdir -p build/AppIcon.iconset
  swift tools/make-icon.swift build/icon-1024.png "$ICON_VARIANT" 1024
  for s in 16 32 64 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon-1024.png --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  cp build/icon-1024.png build/AppIcon.iconset/icon_512x512@2x.png
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$OUT/Contents/Resources/AppIcon.icns"

echo "==> writing Info.plist"
cat > "$OUT/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>${DEPLOY_TARGET}</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsSuddenTermination</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Markdown Document</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>net.daringfireball.markdown</string>
        <string>public.plain-text</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

printf 'APPL????' > "$OUT/Contents/PkgInfo"

echo "==> ad-hoc signing"
codesign --force --sign - --timestamp=none "$OUT"
codesign --verify --verbose=1 "$OUT" 2>&1 | sed 's/^/    /'

echo "==> done: $OUT"
du -sh "$OUT" | sed 's/^/    /'
