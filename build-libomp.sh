#!/bin/bash
# build-libomp.sh <git-ref> <arch> [name]
#   Builds libomp at <git-ref> (e.g. llvmorg-12.0.1, main, a commit hash) for
#   <arch> (arm64 or x86_64) into prefix/<name>-<arch>/{lib,include}.
#   BT=Debug for a Debug build (default Release).
set -e
. "$(dirname "$0")/common.sh"
ref=$1; arch=$2; name=${3:-${ref#llvmorg-}}
[ -n "$ref" ] && [ -n "$arch" ] || { sed -n '2,6p' "$0"; exit 2; }
if [ ! -d "$LLVM_PROJECT/.git" ]; then
  echo "cloning llvm-project (blobless, sparse) into $LLVM_PROJECT"
  git clone -q --filter=blob:none --sparse --no-checkout https://github.com/llvm/llvm-project.git "$LLVM_PROJECT"
fi
src=$HERE/src/$name
if [ ! -d "$src" ]; then
  git -C "$LLVM_PROJECT" worktree add -q --no-checkout --detach -f "$src" "$ref"
  git -C "$src" sparse-checkout set openmp cmake llvm/cmake llvm/utils runtimes third-party libc/cmake libcxx/cmake
  git -C "$src" checkout -q --detach "$ref"
  # libomp 11.x needs https://reviews.llvm.org/D88252 to build for arm64 macOS
  if [ "$arch" = arm64 ] && (cd "$src/openmp" && patch --dry-run -s -f -p0 < "$HERE/patches/D88252-libomp11-arm64.diff" >/dev/null 2>&1); then
    (cd "$src/openmp" && patch -s -p0 < "$HERE/patches/D88252-libomp11-arm64.diff")
  fi
fi
srcdir=$src/openmp; extra="-DOPENMP_STANDALONE_BUILD=ON"
if grep -q "legacy standalone build mode has been removed" "$src/openmp/CMakeLists.txt"; then
  srcdir=$src/runtimes; extra="-DLLVM_ENABLE_RUNTIMES=openmp"
fi
bld=$HERE/build/$name-$arch; pre=$HERE/prefix/$name-$arch
rm -rf "$bld"; mkdir -p "$HERE/build"
cmake -S "$srcdir" -B "$bld" -G Ninja $extra -DCMAKE_BUILD_TYPE=${BT:-Release} \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_OSX_ARCHITECTURES=$arch \
  -DCMAKE_C_COMPILER="$BUILD_CC" -DCMAKE_CXX_COMPILER="$BUILD_CXX" \
  -DLIBOMP_OMPT_SUPPORT=OFF -DOPENMP_ENABLE_LIBOMPTARGET=OFF -DLIBOMP_INSTALL_ALIASES=OFF \
  -DOPENMP_ENABLE_OMPT_TOOLS=OFF -DLIBOMP_USE_HWLOC=OFF \
  -DLLVM_INCLUDE_TESTS=OFF -DOPENMP_ENABLE_TESTING=OFF > "$bld.log" 2>&1 \
  || { echo "cmake failed: $name $arch (see $bld.log)"; exit 1; }
ninja -C "$bld" omp >> "$bld.log" 2>&1 || { echo "build failed: $name $arch (see $bld.log)"; exit 1; }
mkdir -p "$pre/lib" "$pre/include"
cp "$(find "$bld" -name libomp.dylib -path '*runtime/src*' | head -1)" "$pre/lib/"
cp "$(find "$bld" -name omp.h -path '*runtime/src*' | head -1)" "$pre/include/"
install_name_tool -id "$pre/lib/libomp.dylib" "$pre/lib/libomp.dylib"
echo "built $pre"
