#!/bin/sh
set -eu

native_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/patch-store-package.XXXXXX")
trap 'rm -r -- "$test_dir"' EXIT HUP INT TERM
cmake_bin=${CMAKE_BIN:-cmake}
symbols='open_root close lock unlock read replace free'

"$cmake_bin" -S "$native_dir" -B "$test_dir/host" \
  -DCMAKE_BUILD_TYPE=Release -DPSIO_BUILD_LINK_CHECK=ON
"$cmake_bin" --build "$test_dir/host"
case $(uname -s) in
  Darwin) "$test_dir/host/patch_store_link_check" ;;
  *) "$test_dir/host/patch_store_link_check" "$test_dir/host/libpatch_store_io.so" ;;
esac

if command -v xcrun >/dev/null 2>&1 && xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
  "$cmake_bin" -S "$native_dir" -B "$test_dir/ios" \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 -DCMAKE_BUILD_TYPE=Release \
    -DPSIO_BUILD_LINK_CHECK=ON
  "$cmake_bin" --build "$test_dir/ios"
  xcrun nm -gU "$test_dir/ios/patch_store_link_check.app/patch_store_link_check" \
    > "$test_dir/ios-symbols.txt"
  for symbol in $symbols; do
    awk -v name="_psio_$symbol" '$2 == "T" && $3 == name { found = 1 } END { exit !found }' \
      "$test_dir/ios-symbols.txt"
  done
  echo 'PASS: iOS arm64 final executable retains every FFI entry after dead stripping (not executed)'
fi

check_elf() {
  "$1" --file-header "$2" > "$test_dir/elf-header.txt"
  grep -q 'Machine:.*AArch64' "$test_dir/elf-header.txt"
  "$1" --dyn-syms "$2" > "$test_dir/elf-symbols.txt"
  for symbol in $symbols; do
    awk -v name="psio_$symbol" \
      '$4 == "FUNC" && $5 == "GLOBAL" && $6 == "DEFAULT" && $7 != "UND" && $8 == name { found = 1 } END { exit !found }' \
      "$test_dir/elf-symbols.txt"
  done
}

if [ -n "${OHOS_NATIVE_HOME:-}" ]; then
  ohos_cmake="$OHOS_NATIVE_HOME/build-tools/cmake/bin/cmake"
  "$ohos_cmake" -S "$native_dir" -B "$test_dir/ohos" \
    "-DCMAKE_TOOLCHAIN_FILE=$OHOS_NATIVE_HOME/build/cmake/ohos.toolchain.cmake" \
    -DOHOS_ARCH=arm64-v8a -DCMAKE_BUILD_TYPE=Release
  "$ohos_cmake" --build "$test_dir/ohos"
  check_elf "$OHOS_NATIVE_HOME/llvm/bin/llvm-readelf" \
    "$test_dir/ohos/libpatch_store_io.so"
  echo 'PASS: OHOS arm64 CMake library exports every FFI entry (HAR packaging not verified)'
fi

if [ -n "${ANDROID_APK:-}" ]; then
  : "${ANDROID_NDK_HOME:?ANDROID_APK requires ANDROID_NDK_HOME for ELF inspection}"
  case $(uname -s) in
    Darwin) ndk_host=darwin-x86_64 ;;
    Linux) ndk_host=linux-x86_64 ;;
    *) echo 'unsupported NDK host' >&2; exit 2 ;;
  esac
  readelf="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$ndk_host/bin/llvm-readelf"
  unzip -p "$ANDROID_APK" lib/arm64-v8a/libpatch_store_io.so > "$test_dir/android.so"
  check_elf "$readelf" "$test_dir/android.so"
  "$readelf" --program-headers "$test_dir/android.so" | \
    awk '$1 == "LOAD" { count++; if ($NF != "0x4000") bad = 1 } END { exit count == 0 || bad }'
  echo 'PASS: Android APK contains arm64 native store, all FFI exports, and 16 KiB LOAD alignment'
fi
