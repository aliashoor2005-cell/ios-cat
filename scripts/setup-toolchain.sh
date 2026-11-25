#!/usr/bin/env bash
# Builds an iOS cross toolchain on Ubuntu (24.04) that can link armv7/armv7s
# (32-bit, iOS 8) and arm64 binaries:
#   clang (system)  +  ld64 from cctools-port (with libtapi for .tbd stubs)
#   ldid (fake code signing)  +  iPhoneOS 9.3 SDK (patched)
#
# Usage: scripts/setup-toolchain.sh [TOOLCHAIN_DIR]   (default: ~/ios-toolchain)
# Safe to re-run: finished steps are skipped, so the dir can be cached in CI.
set -euo pipefail

T="${1:-$HOME/ios-toolchain}"
mkdir -p "$T/src"
T="$(cd "$T" && pwd)"
JOBS="$(nproc)"

# Pinned sources (known-good combination)
LIBTAPI_REF=2a5705470a92691520fa2ff589482ea6c4039740
CCTOOLS_REF=ef969083aecf77dee1814d6961a06b88af23edef
DISPATCH_REF=20b4c8b2e168a20a661edf8ce9c2bcc6dc79793b
LDID_REF=18255c55405ab1702d8677bf42018eadc76e0b87
SDKS_REF=0222fd5413cf4b9af096f37b4621afa2688572f7

SUDO=""; [ "$(id -u)" != 0 ] && SUDO="sudo"

echo "==> Installing build dependencies"
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq clang llvm cmake ninja-build make autoconf automake libtool \
  pkg-config python3 git zip libblocksruntime-dev uuid-dev libssl-dev libplist-dev >/dev/null

fetch() { # fetch <url> <ref> <dir>
  if [ ! -d "$3/.git" ]; then
    git init -q "$3"
    git -C "$3" remote add origin "$1"
  fi
  git -C "$3" fetch -q --depth 1 origin "$2"
  git -C "$3" checkout -q FETCH_HEAD
}

if [ ! -f "$T/lib/libtapi.so" ]; then
  echo "==> Building libtapi (takes a while)"
  fetch https://github.com/tpoechtrager/apple-libtapi.git "$LIBTAPI_REF" "$T/src/apple-libtapi"
  (cd "$T/src/apple-libtapi" && INSTALLPREFIX="$T" JOBS="$JOBS" ./build.sh && ./install.sh)
fi

if [ ! -f "$T/lib/libdispatch.so" ]; then
  echo "==> Building libdispatch"
  fetch https://github.com/apple/swift-corelibs-libdispatch.git "$DISPATCH_REF" "$T/src/libdispatch"
  cmake -S "$T/src/libdispatch" -B "$T/src/libdispatch-build" -G Ninja \
    -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
    -DCMAKE_INSTALL_PREFIX="$T" -DBUILD_TESTING=OFF
  ninja -C "$T/src/libdispatch-build" install
fi

if [ ! -x "$T/bin/arm-apple-darwin11-ld" ]; then
  echo "==> Building cctools-port (ld64, lipo, ...)"
  fetch https://github.com/tpoechtrager/cctools-port.git "$CCTOOLS_REF" "$T/src/cctools-port"
  (cd "$T/src/cctools-port/cctools" && \
    ./configure --prefix="$T" --target=arm-apple-darwin11 \
      --with-libtapi="$T" --with-libdispatch="$T" --with-libblocksruntime="$T" \
      CC=clang CXX=clang++ && \
    make -j"$JOBS" && make install)
fi

if [ ! -x "$T/bin/ldid" ]; then
  echo "==> Building ldid"
  fetch https://github.com/ProcursusTeam/ldid.git "$LDID_REF" "$T/src/ldid"
  make -C "$T/src/ldid" -j"$JOBS"
  cp "$T/src/ldid/ldid" "$T/bin/ldid"
fi

if [ ! -d "$T/sdks/iPhoneOS9.3.sdk" ]; then
  echo "==> Fetching iPhoneOS 9.3 SDK"
  rm -rf "$T/src/sdks"
  git clone -q --filter=blob:none --no-checkout https://github.com/theos/sdks.git "$T/src/sdks"
  git -C "$T/src/sdks" sparse-checkout set iPhoneOS9.3.sdk iPhoneOS10.3.sdk/usr/lib/system
  git -C "$T/src/sdks" checkout -q "$SDKS_REF"
  mkdir -p "$T/sdks"
  # The 9.3 stubs still carry armv7/armv7s symbols (10.3+ dropped them), but
  # miss a couple of libraries libSystem re-exports: borrow them from 10.3.
  for f in "$T/src/sdks/iPhoneOS10.3.sdk/usr/lib/system/"*.tbd; do
    n="$(basename "$f")"
    [ -e "$T/src/sdks/iPhoneOS9.3.sdk/usr/lib/system/$n" ] || cp "$f" "$T/src/sdks/iPhoneOS9.3.sdk/usr/lib/system/"
  done
  mv "$T/src/sdks/iPhoneOS9.3.sdk" "$T/sdks/"
fi

# Short tool names for clang's -fuse-ld / convenience
for tool in ld lipo otool nm strip; do
  ln -sf "$T/bin/arm-apple-darwin11-$tool" "$T/bin/$tool-ios"
done

# Sources and build trees are no longer needed (keeps the CI cache small).
rm -rf "$T/src"

echo "==> Toolchain ready in $T"
