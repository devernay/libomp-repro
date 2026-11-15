#!/bin/bash
# run-test-package.sh <name> <arch> [runs]
#   Builds test_package.cpp against prefix/<name>-<arch>; exit 0 if all runs pass.
. "$(dirname "$0")/common.sh"
v=$1; arch=$2; runs=${3:-5}
p=$HERE/prefix/$v-$arch; exe=$HERE/bin/tp-$v-$arch; mkdir -p "$HERE/bin"
"$TEST_CXX" -arch $arch $OMP_FLAGS -I"$p/include" "$HERE/test_package.cpp" -L"$p/lib" -lomp -o "$exe" || { echo "$v $arch: compile failed"; exit 125; }
otool -L "$exe" | grep -q "$p/lib/libomp.dylib" || { echo "$v $arch: not linked to $p"; exit 125; }
fail=0; for i in $(seq $runs); do timeout 30 "$exe" >/dev/null 2>&1 || fail=$((fail+1)); done
echo "test_package $v $arch: $fail/$runs failed"; [ $fail = 0 ]
