#!/bin/bash
# Build AnySnap.app (menu bar app + bundled anysnap CLI) into ./build
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
echo "▶ swift build -c $CONFIG"
swift build -c "$CONFIG" --product AnySnapBar
swift build -c "$CONFIG" --product anysnap
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

APP="build/AnySnap.app"
rm -rf "$APP" build/AppSnap.app   # build/AppSnap.app: leftover from the old name
# Note: the CLI must NOT sit next to the main executable: "AnySnap" and "anysnap"
# collide on the case-insensitive macOS filesystem. It lives in Contents/Helpers.
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/AnySnapBar" "$APP/Contents/MacOS/AnySnap"
cp "$BIN/anysnap" "$APP/Contents/Helpers/anysnap"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"   # regenerate: python3 scripts/make-icon.py

# Signing: a stable identity keeps macOS permissions across rebuilds.
# Order: $ANYSNAP_SIGN_IDENTITY → "AnySnap Dev" (scripts/make-dev-cert.sh) → Apple Development → ad-hoc
IDENTITY="${ANYSNAP_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDS="$(security find-identity -p codesigning 2>/dev/null || true)"
  if echo "$IDS" | grep -q '"AnySnap Dev"'; then
    IDENTITY="AnySnap Dev"
  else
    IDENTITY="$(echo "$IDS" | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)"
  fi
fi
if [ -z "$IDENTITY" ]; then
  IDENTITY="-"
  echo "⚠️  Ad-hoc signing: after every rebuild macOS may ask for permissions again."
  echo "   Run scripts/make-dev-cert.sh once to avoid that."
fi
echo "▶ codesign with: $IDENTITY"
codesign --force --sign "$IDENTITY" --identifier com.anysnap.cli "$APP/Contents/Helpers/anysnap"
codesign --force --sign "$IDENTITY" --identifier com.anysnap.AnySnap "$APP"

echo "✅ Built $APP"
