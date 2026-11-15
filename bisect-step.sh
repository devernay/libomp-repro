#!/bin/bash
# For "git bisect run" inside $LLVM_PROJECT (terms: old=broken, new=fixed).
# bisect-step.sh repro|debug-exit
#   repro:      Release arm64 build, runs repro.c (bug 1)
#   debug-exit: Debug arm64 build, runs test_package.cpp (bug 2)
. "$(dirname "$0")/common.sh"
ref=$(git rev-parse HEAD); name=bisect-${ref:0:12}
rm -rf "$HERE/src/$name"; git -C "$LLVM_PROJECT" worktree prune
case $1 in
  repro) "$HERE/build-libomp.sh" $ref arm64 $name >/dev/null || exit 125
         "$HERE/runtest.sh" $name arm64 5 | tee /dev/stderr | grep -q ' 0/5 failed' && exit 1 || exit 0 ;;
  debug-exit) BT=Debug "$HERE/build-libomp.sh" $ref arm64 $name >/dev/null || exit 125
         "$HERE/run-test-package.sh" $name arm64 3; r=$?; [ $r = 125 ] && exit 125; [ $r = 0 ] && exit 1 || exit 0 ;;
  *) echo "usage: $0 repro|debug-exit"; exit 2 ;;
esac
