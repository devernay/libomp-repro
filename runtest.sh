#!/bin/bash
# runtest.sh <name> <arch> [runs [rounds threads regions]]
#   Builds repro.c against prefix/<name>-<arch> and runs it <runs> times (default 5).
. "$(dirname "$0")/common.sh"
v=$1; arch=$2; runs=${3:-5}; shift 3 2>/dev/null
p=$HERE/prefix/$v-$arch; exe=$HERE/bin/repro-$v-$arch; mkdir -p "$HERE/bin"
"$TEST_CC" -arch $arch $OMP_FLAGS -I"$p/include" "$HERE/repro.c" -L"$p/lib" -lomp -o "$exe" || { echo "$v $arch: compile failed"; exit 1; }
otool -L "$exe" | grep -q "$p/lib/libomp.dylib" || { echo "$v $arch: not linked to $p"; exit 1; }
fail=0; msgs=""
for i in $(seq $runs); do
  out=$(timeout 120 "$exe" ${@:-30 32 10} 2>&1); rc=$?
  [ $rc -ne 0 ] && { fail=$((fail+1)); msgs="$msgs [rc=$rc $(echo "$out" | grep -m1 -o 'OMP: Error.*')]"; }
done
echo "repro $v $arch: $fail/$runs failed$msgs"
