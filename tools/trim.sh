#!/usr/bin/env bash
# Trim an upstream LLVM release tarball down to what ESBMC's static link
# consumes: the per-component static archives, the CMake package config, the
# Clang resource headers, the public headers, and the two tblgen binaries the
# exports reference. Everything else (shared libs, the rest of bin/, compiler-rt
# runtimes, docs, scan-build Python) is dropped.
#
# Usage: tools/trim.sh <input.tar.xz> <output.tar.xz>
#
# Arch-agnostic: the input's single top-level directory is preserved verbatim
# in the output, so ESBMC_LLVM_NAME can match it without re-rooting.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <input.tar.xz> <output.tar.xz>" >&2
  exit 2
fi

IN=$1
OUT=$2

[[ -f "$IN" ]] || { echo "input not found: $IN" >&2; exit 1; }
command -v tar >/dev/null 2>&1 || { echo "tar is required" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT

# Upstream LLVM release tarballs have a single top-level directory
# (e.g. LLVM-22.1.6-Linux-ARM64). Derive it from the first member rather than
# assuming the root is listed first.
roots=$(tar -tJf "$IN" | cut -d/ -f1 | sort -u)
root_count=$(echo "$roots" | wc -l)
if (( root_count != 1 )); then
  echo "expected a single top-level directory; found $root_count:" >&2
  echo "$roots" >&2
  exit 1
fi
TOP=$roots

echo "[trim] $IN  (top: $TOP)"

# Selective extraction keeps the working tree small enough to fit a CI runner
# alongside the ESBMC build (the full tree is ~11 GB extracted). --no-wildcards
# -match-slash restricts '*' to a single path segment so lib/*.a stays flat and
# lib/clang/*/include picks only the resource-header subtree.
#
# lib/*.so* stays because LLVMExports/ClangTargets import libLTO, libRemarks,
# libclang and libclang-cpp by path, and find_package() aborts when an imported
# target's file is missing -- even though the static link never loads them.
tar -xJf "$IN" -C "$WORK" \
  --anchored --wildcards --no-wildcards-match-slash \
  "$TOP/include" \
  "$TOP/lib/*.a" \
  "$TOP/lib/*.so*" \
  "$TOP/lib/cmake" \
  "$TOP/lib/clang/*/include" \
  "$TOP/bin/llvm-tblgen" \
  "$TOP/bin/clang-tblgen"

verify() { [[ -e "$WORK/$1" ]] || { echo "missing required path: $1" >&2; exit 1; }; }
verify "$TOP/lib/cmake/llvm/LLVMConfig.cmake"
verify "$TOP/lib/cmake/clang/ClangConfig.cmake"
verify "$TOP/bin/llvm-tblgen"
verify "$TOP/bin/clang-tblgen"

# Every file an exported target points at must survive the trim, or the first
# find_package() in a consumer fails instead of this script.
while read -r ref; do
  verify "$TOP/$ref"
done < <(grep -rhoE 'IMPORTED_LOCATION[^ ]* "\$\{_IMPORT_PREFIX\}/[^"]*"' \
           "$WORK/$TOP/lib/cmake" | sed -E 's|.*_IMPORT_PREFIX\}/||; s|"$||' | sort -u)

shopt -s nullglob
archives=( "$WORK/$TOP/lib/"*.a )
shopt -u nullglob
if (( ${#archives[@]} == 0 )); then
  echo "no static archives under $TOP/lib" >&2
  exit 1
fi

echo "[trim] packing $OUT"
mkdir -p "$(dirname "$OUT")"
tar -cJf "$OUT" -C "$WORK" "$TOP"
size=$(stat -c%s "$OUT")
echo "[trim] done: $OUT ($(( size / 1024 / 1024 )) MiB, ${#archives[@]} archives)"
