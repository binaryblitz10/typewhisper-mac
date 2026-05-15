#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
SCHEME="TypeWhisper"
PROJECT="TypeWhisper.xcodeproj"
APP_NAME="TypeWhisper"
BUILD_DIR="$PROJECT_DIR/build-release"

# Self-signed certificate for stable local identity.
# Run scripts/setup-code-signing.sh once to create it.
LOCAL_CERT_NAME="TypeWhisper Development"

# Developer ID signing (requires Apple Developer account). Use --sign to opt in.
SIGN_DEVELOPER=false
for arg in "$@"; do
  case "$arg" in
    --sign) SIGN_DEVELOPER=true ;;
    *) echo "Unknown option: $arg"; echo "Usage: $0 [--sign]"; exit 1 ;;
  esac
done

echo "=== TypeWhisper Local Release Build ==="
echo ""

# Resolve signing identity
if [ "$SIGN_DEVELOPER" = true ]; then
  echo "--- Developer ID signing requested ---"
  IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/')
  if [ -z "$IDENTITY" ]; then
    echo "ERROR: No Developer ID Application certificate found in keychain"
    exit 1
  fi
  echo "Using identity: $IDENTITY"
else
  if security find-certificate -c "$LOCAL_CERT_NAME" "$HOME/Library/Keychains/login.keychain-db" &>/dev/null; then
    IDENTITY="$LOCAL_CERT_NAME"
    echo "Using self-signed identity: $IDENTITY"
  else
    echo "No signing identity found. Run scripts/setup-code-signing.sh first."
    echo "Falling back to ad-hoc signing (TCC permissions will NOT persist across builds)."
    IDENTITY="-"
  fi
fi

# Clean previous build
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Resolve packages
echo "--- Resolving Swift packages ---"
xcodebuild -resolvePackageDependencies \
  -project "$PROJECT_DIR/$PROJECT" \
  -scheme "$SCHEME"

# Build (ad-hoc signed — we replace with stable cert afterwards)
echo "--- Building Release ---"
set -o pipefail
xcodebuild -project "$PROJECT_DIR/$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO | tee "$BUILD_DIR/build.log"

bash "$PROJECT_DIR/scripts/check_first_party_warnings.sh" "$BUILD_DIR/build.log" || true

APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"

if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: App not found at $APP_PATH"
  exit 1
fi

echo "--- App built at $APP_PATH ---"

# Re-sign with stable identity if we have one (preserves TCC permissions across builds)
if [ "$IDENTITY" != "-" ]; then
  echo "--- Re-signing with stable identity: $IDENTITY ---"

  # Resolve $(APP_GROUP_ID) from the built Info.plist (xcodebuild resolved it there)
  RESOLVED_ENTITLEMENTS="$BUILD_DIR/resolved-entitlements.plist"
  APP_GROUP_ID=$(/usr/libexec/PlistBuddy -c "Print AppGroupIdentifier" "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo "")
  if [ -n "$APP_GROUP_ID" ]; then
    sed "s|\$(APP_GROUP_ID)|${APP_GROUP_ID}|g" \
      "$PROJECT_DIR/TypeWhisper/Resources/TypeWhisper.entitlements" > "$RESOLVED_ENTITLEMENTS"
  else
    cp "$PROJECT_DIR/TypeWhisper/Resources/TypeWhisper.entitlements" "$RESOLVED_ENTITLEMENTS"
  fi

  find "$APP_PATH" -name '._*' -delete
  xattr -cr "$APP_PATH"
  codesign --force --deep --options runtime --sign "$IDENTITY" \
    --entitlements "$RESOLVED_ENTITLEMENTS" \
    "$APP_PATH"
  rm -f "$RESOLVED_ENTITLEMENTS"

  codesign --verify --deep --strict --verbose=2 "$APP_PATH" 2>&1
  echo "--- Re-signing complete ---"
else
  echo "--- WARNING: Ad-hoc signed (TCC permissions will reset next build) ---"
fi

echo "--- Signature info ---"
codesign -dvv "$APP_PATH" 2>&1 | head -8
echo ""

# Create DMG
echo "--- Creating DMG ---"

if ! command -v dmgbuild &> /dev/null; then
  echo "dmgbuild not found. Installing..."
  pip3 install --break-system-packages dmgbuild 2>/dev/null || \
    pipx install dmgbuild 2>/dev/null || \
    brew install dmgbuild 2>/dev/null || {
    echo "ERROR: Could not install dmgbuild. Install it manually:"
    echo "  pip3 install --break-system-packages dmgbuild"
    exit 1
  }
fi

VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "dev")
DMG_NAME="TypeWhisper-v${VERSION}.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"

dmgbuild -s "$PROJECT_DIR/.github/dmgbuild-settings.py" \
  -D app="$APP_NAME" \
  -D app_path="$APP_PATH" \
  -D background="$PROJECT_DIR/.github/dmg-background.png" \
  "$APP_NAME" \
  "$DMG_PATH"

echo ""
echo "=== Done ==="
echo "App:  $APP_PATH"
echo "DMG:  $DMG_PATH"

if [ "$SIGN_DEVELOPER" = true ]; then
  echo ""
  echo "To notarize, run:"
  echo "  xcrun notarytool submit \"$DMG_PATH\" --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID --password YOUR_APP_PASSWORD --wait"
  echo "  xcrun stapler staple \"$DMG_PATH\""
fi
