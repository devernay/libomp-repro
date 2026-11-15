# Sourced by the scripts. Override with environment variables.
# "git bisect run" exports GIT_DIR; it must not leak into our git -C commands
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
: "${LLVM_PROJECT:=$HERE/llvm-project}"          # llvm-project clone (created if missing)
: "${BUILD_CC:=$(xcrun -f clang)}"               # compiler used to build libomp
: "${BUILD_CXX:=$(xcrun -f clang++)}"
: "${TEST_CC:=$(xcrun -f clang)}"                # compiler used to build the tests
: "${TEST_CXX:=$(xcrun -f clang++)}"
# -Xpreprocessor -fopenmp works with both Apple clang and LLVM clang
export SDKROOT=${SDKROOT:-$(xcrun --show-sdk-path)}
OMP_FLAGS="-Xpreprocessor -fopenmp"
command -v timeout >/dev/null || timeout() { perl -e 'alarm shift; exec @ARGV' "$@"; }
