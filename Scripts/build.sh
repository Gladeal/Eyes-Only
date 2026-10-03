#!/bin/bash
# Build Eyes Only.app — a universal (arm64 + x86_64) app bundle, signed with a stable local identity so the
# Screen Recording permission survives rebuilds (see make-signing-identity.sh).
#
#   Scripts/build.sh           # development build → build/Eyes Only.app (named "Eyes Only Dev",
#                              # full diagnostics log in results/)
#   SHIP=1 Scripts/build.sh    # the shared version → build-ship/ (warnings-only log) — see make-release.sh
#   SIGN_ID="Developer ID Application: …" Scripts/build.sh   # sign with a real identity instead
#
set -euo pipefail
cd "$(dirname "$0")/.."

SHIP="${SHIP:-}"
OUT="build"; SCRATCH=".build/dev"; FLAGS=(); APP_NAME="Eyes Only Dev"
if [ -n "$SHIP" ]; then OUT="build-ship"; SCRATCH=".build/ship"; FLAGS=(-Xswiftc -DSHIP); APP_NAME="Eyes Only"; fi
APP="$OUT/Eyes Only.app"

# The stable local signing identity (create it once with make-signing-identity.sh). Falls back to
# ad-hoc (-) so the build always succeeds; the permission surviving rebuilds needs the stable identity.
SIGN_ID="${SIGN_ID:-Eyes Only Local Signing}"
# Note: no -v — a self-signed local cert is valid for signing but "untrusted", which is fine here
# (permission persistence needs a STABLE signature, not Gatekeeper trust).
if ! security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  echo "note: signing identity '$SIGN_ID' not found; falling back to ad-hoc (-)."
  echo "      run Scripts/make-signing-identity.sh once for permission that persists."
  SIGN_ID="-"
fi

echo "Building Eyes Only (universal)…"
thin=()
for arch in arm64 x86_64; do
  swift build --quiet -c release --arch "$arch" --scratch-path "$SCRATCH/$arch" ${FLAGS[@]+"${FLAGS[@]}"}
  thin+=("$SCRATCH/$arch/release/EyesOnly")
done

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${thin[@]}" -output "$APP/Contents/MacOS/EyesOnly"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>EyesOnly</string>
  <key>CFBundleIdentifier</key><string>com.eyesonly.app</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Eyes Only</string>
  <key>LSUIElement</key><true/>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>$(date +%Y%m%d%H%M)</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# The Chromium extension ships inside the app; it's copied out to Application Support at launch.
cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R BrowserExtension "$APP/Contents/Resources/BrowserExtension"

echo "Signing (identity: $SIGN_ID)…"
# Hardened runtime: macOS blocks code injection into the app (it holds the Screen Recording permission).
codesign --force --sign "$SIGN_ID" --timestamp=none --options runtime "$APP"

echo "Done: $APP"
codesign -dvv "$APP" 2>&1 | grep -E 'Identifier|Authority' || true
