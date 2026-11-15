#!/bin/bash
# runstress.sh <name> <arch> [runs [seconds threads]]
. "$(dirname "$0")/common.sh"
v=$1; arch=$2; runs=${3:-3}; shift 3 2>/dev/null
p=$HERE/prefix/$v-$arch; exe=$HERE/bin/stress-$v-$arch; mkdir -p "$HERE/bin"
"$TEST_CC" -O1 -arch $arch $OMP_FLAGS -I"$p/include" "$HERE/stress.c" -L"$p/lib" -lomp -o "$exe" || { echo "$v $arch: compile failed"; exit 1; }
otool -L "$exe" | grep -q "$p/lib/libomp.dylib" || { echo "$v $arch: not linked to $p"; exit 1; }
fail=0; msgs=""
for i in $(seq $runs); do
  out=$(timeout 90 "$exe" ${@:-20 24} 2>&1); rc=$?
  [ $rc -ne 0 ] && { fail=$((fail+1)); msgs="$msgs [rc=$rc $(echo "$out" | grep -m1 -o 'OMP: Error.*')]"; }
done
echo "stress $v $arch: $fail/$runs failed$msgs"
