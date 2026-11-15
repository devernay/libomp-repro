#!/bin/bash
# run-noshm.sh <name> <arch>
#   Bug 3: runs test_package.cpp against prefix/<name>-<arch> in a sandbox that
#   denies POSIX shared memory (as an App Sandbox may). Exit 0 if it runs.
. "$(dirname "$0")/common.sh"
v=$1; arch=$2
p=$HERE/prefix/$v-$arch; exe=$HERE/bin/tp-$v-$arch; mkdir -p "$HERE/bin"
"$TEST_CXX" -arch $arch $OMP_FLAGS -I"$p/include" "$HERE/test_package.cpp" -L"$p/lib" -lomp -o "$exe" || { echo "$v $arch: compile failed"; exit 125; }
out=$(sandbox-exec -f "$HERE/noshm.sb" "$exe" 2>&1); rc=$?
echo "noshm $v $arch: rc=$rc $(echo "$out" | grep -m1 -o 'OMP: Error.*')"; [ $rc = 0 ]
