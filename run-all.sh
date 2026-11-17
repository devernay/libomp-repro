#!/bin/bash
# run-all.sh [jobs]
#   Builds every libomp version in the README tables (Release and Debug, arm64 and
#   x86_64), runs all tests, and writes results/<date>-<host>.txt.
#   jobs = parallel libomp builds (default 4). Tests run one at a time, so that
#   concurrent tests don't compete for CPUs.
#   Needs ~2.5 GB of disk for the llvm-project clone and the builds. Delete
#   src/ build/ prefix/ bin/ (and llvm-project/) afterwards.
cd "$(dirname "$0")" || exit 1
. ./common.sh
jobs=${1:-4}

# name:git-ref
REFS="11.1.0:llvmorg-11.1.0 12.0.1:llvmorg-12.0.1
f1b9ce2736d8-parent:f1b9ce2736d8^ f1b9ce2736d8:f1b9ce2736d8
13.0.0:llvmorg-13.0.0 13.0.1:llvmorg-13.0.1 14.0.6:llvmorg-14.0.6 15.0.7:llvmorg-15.0.7
dafebd5b5a08-parent:dafebd5b5a08^ dafebd5b5a08:dafebd5b5a08
16.0.0:llvmorg-16.0.0 17.0.6:llvmorg-17.0.6
35fdf8d70329-parent:35fdf8d70329^ 35fdf8d70329:35fdf8d70329
18.1.8:llvmorg-18.1.8 19.1.7:llvmorg-19.1.7 20.1.8:llvmorg-20.1.8 21.1.7:llvmorg-21.1.7
22.1.8:llvmorg-22.1.8 23.1.5:llvmorg-23.1.5 main:main"
ARCHS="arm64 x86_64"
D88252=$HERE/patches/D88252-libomp11-arm64.diff

mkdir -p results
out=results/$(date +%Y-%m-%d)-$(hostname -s).txt
{
  echo "# libomp-repro run-all.sh, $(date '+%Y-%m-%d %H:%M %Z')"
  echo "# $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion)), $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.ncpu) CPUs"
  echo "# build compiler: $("$BUILD_CC" --version | head -1)"
  echo "# test compiler:  $("$TEST_CC" --version | head -1)"
  echo "# x86_64 runs under Rosetta 2 on arm64 hosts"
} > "$out"

# 1. Sources: clone once, then create the worktrees one at a time
#    (concurrent "git worktree add" is not safe). Release and Debug builds use
#    separate worktrees, so that parallel builds never share a source tree's patching.
if [ ! -d "$LLVM_PROJECT/.git" ]; then
  echo "cloning llvm-project (blobless, sparse) into $LLVM_PROJECT"
  git clone -q --filter=blob:none --sparse --no-checkout https://github.com/llvm/llvm-project.git "$LLVM_PROJECT" || exit 1
fi
for r in $REFS; do
  n=${r%%:*}; ref=${r#*:}
  for d in "$n" "$n-debug"; do
    if [ ! -d "src/$d" ]; then
      git -C "$LLVM_PROJECT" worktree add -q --no-checkout --detach -f "$HERE/src/$d" "$ref" &&
      git -C "src/$d" sparse-checkout set openmp cmake llvm/cmake llvm/utils runtimes third-party libc/cmake libcxx/cmake &&
      git -C "src/$d" checkout -q --detach "$ref" || { echo "checkout failed: $ref"; continue; }
    fi
    (cd "src/$d/openmp" && patch --dry-run -s -f -p0 < "$D88252" >/dev/null 2>&1 && patch -s -p0 < "$D88252")
  done
  echo "# $n = $(git -C "src/$n" rev-parse --short=12 HEAD)" >> "$out"
done

# 2. Builds, in parallel. Each (name, arch) pair has its own build dir.
for r in $REFS; do n=${r%%:*}; ref=${r#*:}; for a in $ARCHS; do
  echo "Release $ref $a $n"; echo "Debug $ref $a $n-debug"
done; done | xargs -P "$jobs" -L 1 sh -c '
  BT=$1 ./build-libomp.sh "$2" "$3" "$4" >/dev/null || echo "build failed: $*"' _ | tee -a "$out"

# 3. Tests, one at a time.
for r in $REFS; do n=${r%%:*}; for a in $ARCHS; do
  [ -f "prefix/$n-$a/lib/libomp.dylib" ] || continue
  ./runtest.sh "$n" "$a" 5
  ./runstress.sh "$n" "$a" 3
  ./run-test-package.sh "$n" "$a" 5
  ./run-noshm.sh "$n" "$a"
  [ -f "prefix/$n-debug-$a/lib/libomp.dylib" ] && ./run-test-package.sh "$n-debug" "$a" 5
done; done 2>/dev/null | tee -a "$out"
echo "results: $out"
