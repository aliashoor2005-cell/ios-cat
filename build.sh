#!/usr/bin/env bash
# Builds CatInvoice.ipa for iOS 8+ (armv7 + armv7s + arm64, iPhone & iPad).
# armv7s covers 32-bit A6/A6X devices such as the iPad 4 and iPhone 5/5c.
#
# Usage: ./build.sh [TOOLCHAIN_DIR]   (default: ~/ios-toolchain)
# Run scripts/setup-toolchain.sh first.
set -euo pipefail

T="${1:-$HOME/ios-toolchain}"
T="$(cd "$T" && pwd)"
ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="$T/sdks/iPhoneOS9.3.sdk"
APP=CatInvoice
MIN_IOS=8.0
ARCHS="armv7 armv7s arm64"
OUT="$ROOT/build"
DIST="$ROOT/dist"

[ -d "$SDK" ] || { echo "SDK not found: run scripts/setup-toolchain.sh"; exit 1; }

rm -rf "$OUT" "$DIST"
mkdir -p "$OUT" "$DIST"

slices=()
for arch in $ARCHS; do
  echo "==> Compiling $arch"
  clang -target "$arch-apple-ios$MIN_IOS" -isysroot "$SDK" \
    -fobjc-arc -Os -Wall -Wno-deprecated-declarations \
    -c "$ROOT/main.m" -o "$OUT/main_$arch.o"
  # Link without -fobjc-arc so clang does not ask for libarclite (not needed on iOS 8).
  # -flat_namespace: the 9.3 SDK records some classes (e.g. NSUserDefaults) as
  # living in CoreFoundation, but on iOS 8 they are in Foundation. A flat
  # namespace lets dyld find each symbol wherever it lives on the running iOS.
  clang -target "$arch-apple-ios$MIN_IOS" -isysroot "$SDK" \
    -fuse-ld="$T/bin/ld-ios" -Wl,-flat_namespace \
    -framework UIKit -framework Foundation -framework CoreBluetooth -lobjc \
    "$OUT/main_$arch.o" -o "$OUT/${APP}_$arch" 2>&1 | { grep -v 'built for iOS Simulator' || true; }
  [ -f "$OUT/${APP}_$arch" ] || { echo "link failed for $arch"; exit 1; }
  slices+=("$OUT/${APP}_$arch")
done

echo "==> Creating universal binary"
"$T/bin/lipo-ios" -create "${slices[@]}" -output "$OUT/$APP"
"$T/bin/lipo-ios" -info "$OUT/$APP"

echo "==> Assembling $APP.app"
BUNDLE="$OUT/Payload/$APP.app"
mkdir -p "$BUNDLE"
cp "$OUT/$APP" "$BUNDLE/"
cp "$ROOT/Resources/"* "$BUNDLE/"
printf 'APPL????' > "$BUNDLE/PkgInfo"

echo "==> Signing (ad-hoc)"
"$T/bin/ldid" -S "$BUNDLE/$APP"

echo "==> Packaging IPA"
(cd "$OUT" && zip -qry "$DIST/${APP}_iOS8.ipa" Payload)
ls -la "$DIST"
