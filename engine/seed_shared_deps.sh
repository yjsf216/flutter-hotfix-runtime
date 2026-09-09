#!/bin/sh
set -eu

# Run before gclient sync. Never replace an existing checkout or discard edits.
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
engine_dir=${1:-"$repo_dir/work/upstream/flutter-engine-ddm"}
dart_dir=${2:-"$repo_dir/work/upstream/dart-sdk"}
test "$(git -C "$engine_dir" rev-parse HEAD)" = 00b0c91f06209d9e4a41f71b7a512d6eb3b9c694
test "$(git -C "$dart_dir" rev-parse HEAD)" = c70f78e7d682c158c15ca0c26c729b3ccb932284

seed() {
  source_repo="$dart_dir/third_party/$1"
  target_repo="$engine_dir/engine/src/flutter/third_party/$2"
  revision=$3
  upstream=$4
  git -C "$source_repo" cat-file -e "$revision^{commit}"
  if [ -e "$target_repo" ]; then
    actual=$(git -C "$target_repo" rev-parse --verify HEAD)
    test "$actual" = "$revision" || {
      echo "Refusing to replace existing checkout: $target_repo" >&2
      exit 1
    }
    git -C "$target_repo" diff-index --quiet HEAD -- || {
      echo "Refusing modified dependency source: $target_repo" >&2
      exit 1
    }
    test "$(git -C "$target_repo" remote get-url origin)" = "$upstream" || {
      echo "Existing origin differs; inspect it before sync: $target_repo" >&2
      exit 1
    }
  else
    git clone --shared --no-checkout "$source_repo" "$target_repo"
    git -C "$target_repo" checkout --detach "$revision"
    git -C "$target_repo" remote set-url origin "$upstream"
  fi
  echo "PASS: $2 at $revision (local Git objects)"
}

seed boringssl/src boringssl/src 9f138d05879fcf61965d1ea9d6c8b2cfc8bc12cb https://boringssl.googlesource.com/boringssl.git
seed protobuf protobuf 24487dd1045c7f3d64a21f38a3f0c06cc4cf2edb https://flutter.googlesource.com/third_party/protobuf
seed libcxx libcxx bd557f6f764d1e40b62528a13b124ce740624f8f https://llvm.googlesource.com/llvm-project/libcxx
seed libcxxabi libcxxabi a4dda1589d37a7e4b4f7a81ebad01b1083f2e726 https://llvm.googlesource.com/llvm-project/libcxxabi
seed libc llvm_libc 5af39a19a1ad51ce93972cdab206dcd3ff9b6afa https://llvm.googlesource.com/llvm-project/libc
