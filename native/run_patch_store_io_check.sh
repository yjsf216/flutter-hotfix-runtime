#!/bin/sh
set -eu

native_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/patch-store-io.XXXXXX")
test_dir=$(CDPATH= cd -- "$test_dir" && pwd -P)
trap 'rm -r -- "$test_dir"' EXIT HUP INT TERM
cc=${CC:-cc}
"$cc" -std=c11 -Wall -Wextra -Werror -pedantic -O1 -g \
  -fsanitize=address,undefined "$native_dir/patch_store_io.c" \
  "$native_dir/patch_store_io_check.c" -o "$test_dir/check"
"$test_dir/check" "$test_dir/store"

# Optional exact local toolchain paths; never fetch an SDK or operate a device.
if [ -n "${ANDROID_NDK_HOME:-}" ]; then
  "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android23-clang" \
    -std=c11 -Wall -Wextra -Werror -fPIC -c "$native_dir/patch_store_io.c" \
    -o "$test_dir/android-arm64.o"
  file "$test_dir/android-arm64.o"
  "$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/bin/aarch64-linux-android23-clang" \
    -shared "$test_dir/android-arm64.o" -o "$test_dir/libpatch_store_android.so"
  file "$test_dir/libpatch_store_android.so"
fi
if [ -n "${OHOS_NATIVE_HOME:-}" ]; then
  "$OHOS_NATIVE_HOME/llvm/bin/clang" --target=aarch64-linux-ohos \
    --sysroot="$OHOS_NATIVE_HOME/sysroot" \
    -std=c11 -Wall -Wextra -Werror -fPIC -c "$native_dir/patch_store_io.c" \
    -o "$test_dir/ohos-arm64.o"
  file "$test_dir/ohos-arm64.o"
  "$OHOS_NATIVE_HOME/llvm/bin/clang" --target=aarch64-linux-ohos \
    --sysroot="$OHOS_NATIVE_HOME/sysroot" -shared "$test_dir/ohos-arm64.o" \
    -o "$test_dir/libpatch_store_ohos.so"
  file "$test_dir/libpatch_store_ohos.so"
fi
if command -v xcrun >/dev/null 2>&1 && xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=13.0 \
    -std=c11 -Wall -Wextra -Werror -fPIC -c "$native_dir/patch_store_io.c" \
    -o "$test_dir/ios-arm64.o"
  file "$test_dir/ios-arm64.o"
  xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=13.0 \
    -dynamiclib "$test_dir/ios-arm64.o" -o "$test_dir/libpatch_store_ios.dylib"
  file "$test_dir/libpatch_store_ios.dylib"
fi
