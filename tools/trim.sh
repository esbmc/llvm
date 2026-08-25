#!/usr/bin/env bash
# Trim an upstream LLVM release tarball down to what ESBMC's static link
# consumes: the per-component static archives, the CMake package config, the
# public and Clang resource headers, the shared libraries the CMake exports
# import, and the two tblgen binaries. Everything else (the rest of bin/,
# compiler-rt runtimes, docs, scan-build Python) is dropped.
#
# Usage: tools/trim.sh <input.tar.xz> <output.tar.xz>
#
# Arch-agnostic: the input's single top-level directory is preserved verbatim
# in the output, so ESBMC_LLVM_NAME can match it without re-rooting.
set -euo pipefail

# What the trim keeps, one selector per line, matched against every member of
# the archive. Each is anchored at both ends, and the leading [^/]+ stands for
# the top-level directory: matching it beats interpolating it, because a name
# like clang+llvm-22.1.6-x86_64-linux-gnu-ubuntu-22.04 is not regex-safe. Use
# [^/]* rather than .* where the match must not cross a directory boundary:
# lib/.*\.a would drag in the compiler-rt archives under lib/clang/22/lib.
KEEP=(
  '[^/]+/include/.*'                  # public headers
  '[^/]+/lib/cmake/.*'                # LLVMConfig, ClangConfig and the exports
  '[^/]+/lib/clang/[^/]+/include/.*'  # Clang resource headers
  '[^/]+/lib/[^/]+\.a'                # the static archives the link consumes
  '[^/]+/lib/[^/]+\.so[0-9.]*'        # the shared libs the exports import
  '[^/]+/bin/llvm-tblgen'
  '[^/]+/bin/clang-tblgen'
)

# Missing from the extracted tree, each of these means the selectors above kept
# the wrong things.
REQUIRED=(
  lib/cmake/llvm/LLVMConfig.cmake
  lib/cmake/clang/ClangConfig.cmake
  bin/llvm-tblgen
  bin/clang-tblgen
)

# The generated line find_package() reads to assert that an imported target's
# file is present. CMake renamed the variable in 3.24 and LLVM publishes
# archives from either side of that, so match both spellings.
export CHECK_RE='^list\(APPEND _(cmake_import_check_files_for_|IMPORT_CHECK_FILES_FOR_)'

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <input.tar.xz> <output.tar.xz>" >&2
  exit 2
fi

IN=$1
OUT=$2

[[ -f "$IN" ]] || { echo "input not found: $IN" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT

# One listing pass gives both the top-level directory and the file selection.
# Directory members are dropped here: naming one would pull its whole subtree
# back in, defeating the selectors.
tar -tJf "$IN" | grep -Ev '/$' > "$WORK/members"
TOP=$(cut -d/ -f1 "$WORK/members" | sort -u)
if [[ $(wc -l <<< "$TOP") -ne 1 ]]; then
  echo "expected a single top-level directory; found:" >&2
  echo "$TOP" >&2
  exit 1
fi

echo "[trim] $IN  (top: $TOP)"

: > "$WORK/keep"
for selector in "${KEEP[@]}"; do
  matched=$(grep -Ec "^$selector\$" "$WORK/members") || true
  (( matched > 0 )) || { echo "selector matched nothing: $selector" >&2; exit 1; }
  grep -E "^$selector\$" "$WORK/members" >> "$WORK/keep"
  echo "[trim]   $matched  $selector"
done

# Collecting the paths first and extracting them in one pass matters: a tar
# call per selector would decompress the whole 1.7 GB archive seven times.
tar -xJf "$IN" -C "$WORK" --files-from="$WORK/keep"

for path in "${REQUIRED[@]}"; do
  [[ -e "$WORK/$TOP/$path" ]] || { echo "missing required path: $path" >&2; exit 1; }
done

# The Linux-ARM64 package installs the whole monorepo, so LLVMExports and
# ClangTargets import ~100 tool binaries (llc, opt, clang-tidy, ...) that a
# consumer of the libraries never touches and that would put the archive into
# the gigabytes. find_package() aborts on the first one missing, so drop the
# check for every file the trim did not keep; the imported target stays behind,
# with a location nothing here resolves.
while read -r cfg; do
  awk -v top="$TOP" '
    NR == FNR { kept[$0]; next }
    $0 ~ ENVIRON["CHECK_RE"] {
      n = split($0, field, "\"")
      for (i = 2; i < n; i += 2) {
        path = field[i]
        sub(/^\$\{_IMPORT_PREFIX\}\//, "", path)
        key = top "/" path
        if (!(key in kept)) next
      }
    }
    { print }
  ' "$WORK/keep" "$cfg" > "$cfg.pruned"
  mv "$cfg.pruned" "$cfg"
done < <(find "$WORK/$TOP/lib/cmake" -name '*.cmake')

# Whatever find_package() still checks has to be there, or the first consumer
# to configure fails instead of this script. Finding no checks at all means the
# spelling moved again and the prune above quietly did nothing.
checked=$(grep -rhE "$CHECK_RE" "$WORK/$TOP/lib/cmake" |
  grep -o '\${_IMPORT_PREFIX}/[^"]*' | sed 's|\${_IMPORT_PREFIX}/||' | sort -u) || true
[[ -n $checked ]] || { echo "no import checks found under lib/cmake" >&2; exit 1; }

absent=$(while read -r path; do
  [[ -e "$WORK/$TOP/$path" ]] || echo "$path"
done <<< "$checked")
[[ -z $absent ]] || { echo "checked but absent:" >&2; echo "$absent" >&2; exit 1; }

echo "[trim] packing $OUT"
mkdir -p "$(dirname "$OUT")"
tar -cJf "$OUT" -C "$WORK" "$TOP"
echo "[trim] done: $OUT ($(( $(stat -c%s "$OUT") / 1024 / 1024 )) MiB)"
