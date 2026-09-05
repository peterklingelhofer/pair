#!/usr/bin/env bash
# Builds a universal Pair.app, signs it with your Developer ID, and optionally
# notarizes it so your bandmate can open it without fighting Gatekeeper.
#
#   ./scripts/bundle.sh                 build and sign
#   ./scripts/bundle.sh --notarize      also notarize and staple
#
# Notarizing needs a stored credential profile, created once with:
#   xcrun notarytool store-credentials pair \
#     --apple-id you@example.com --team-id VZCHHV7VNW --password <app-specific-password>
set -euo pipefail

BUNDLE_ID="${PAIR_BUNDLE_ID:-com.peterklingelhofer.pair}"
PROFILE="${PAIR_NOTARY_PROFILE:-pair}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Pair.app"
NOTARIZE=0
[[ "${1:-}" == "--notarize" ]] && NOTARIZE=1

IDENTITY="$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" | head -1 \
  | sed -E 's/.*"(.*)"/\1/')"
if [[ -z "$IDENTITY" ]]; then
  echo "error: no 'Developer ID Application' certificate in the keychain." >&2
  echo "Create one at https://developer.apple.com/account/resources/certificates" >&2
  exit 1
fi
echo "signing identity: $IDENTITY"

# Built for both architectures and merged, so one download runs on Apple
# Silicon and on Intel. A missing target is a hard error, so a
# single-architecture build cannot slip through and fail on someone else's Mac.
TARGETS=(aarch64-apple-darwin x86_64-apple-darwin)
SLICES=()
for target in "${TARGETS[@]}"; do
  if ! rustup target list --installed | grep -qx "$target"; then
    echo "error: rust target $target is not installed." >&2
    echo "Add it with: rustup target add $target" >&2
    exit 1
  fi
  echo "building release binary for $target"
  cargo build --release --manifest-path "$ROOT/Cargo.toml" -p pair --target "$target"
  SLICES+=("$ROOT/target/$target/release/pair")
done

echo "assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
lipo -create -output "$APP/Contents/MacOS/pair" "${SLICES[@]}"
lipo -info "$APP/Contents/MacOS/pair"

VERSION="$(grep -m1 '^version' "$ROOT/Cargo.toml" | sed -E 's/.*"(.*)".*/\1/')"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>pair</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Pair</string>
  <key>CFBundleDisplayName</key><string>Pair</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# The hardened runtime is a prerequisite for notarization.
echo "signing"
codesign --force --timestamp --options runtime \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

ZIP="$ROOT/dist/Pair.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [[ $NOTARIZE -eq 1 ]]; then
  # Locally the credentials live in the keychain. CI has no keychain profile,
  # so it passes an App Store Connect key through the environment instead.
  if [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
    NOTARY_AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  elif [[ -n "${NOTARY_APPLE_ID:-}" ]]; then
    NOTARY_AUTH=(--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD")
  else
    NOTARY_AUTH=(--keychain-profile "$PROFILE")
  fi

  echo "notarizing (this usually takes a few minutes)"
  xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait
  xcrun stapler staple "$APP"
  # Re-zip so the archive carries the stapled ticket.
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "notarized and stapled"
  spctl --assess --type execute --verbose=2 "$APP" || true
else
  echo
  echo "signed but NOT notarized. Opening this on another Mac will be blocked."
  echo "Re-run with --notarize once you have stored credentials (see this script's header)."
fi

echo
echo "built: $APP"
echo "       $ZIP"
