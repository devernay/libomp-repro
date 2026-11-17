# libomp on macOS: three crashes, all fixed upstream

This repository has minimal reproducers, test scripts and bisection results for three
LLVM OpenMP runtime (libomp) bugs on macOS. Together they led several projects to stay
on libomp 11.1.0 for years:

- [llvm/llvm-project#49923](https://github.com/llvm/llvm-project/issues/49923):
  libomp 12.0.0 introduces an assertion failure when running OpenMP from a background thread
- [NatronGitHub/Natron#672](https://github.com/NatronGitHub/Natron/issues/672):
  OpenMP plugins crash on macOS
- [RawTherapee/RawTherapee#6220](https://github.com/RawTherapee/RawTherapee/issues/6220):
  immediate crash with libomp 12 on Apple Silicon. Sandboxed builds also failed with
  `OMP: Error #179: Function Can't open SHM2 failed` (bug 3).
- [microsoft/LightGBM#4229](https://github.com/microsoft/LightGBM/issues/4229),
  [microsoft/LightGBM#5764](https://github.com/microsoft/LightGBM/issues/5764)
- [conan-io/conan-center-index#19857](https://github.com/conan-io/conan-center-index/pull/19857):
  the llvm-openmp recipe rejects Debug builds on armv8 because "All versions except
  for v11 crash with a segfault for the simple test_package.cpp test"

**Summary.** These are three different bugs. All are fixed in current libomp (21.1.7,
22.1.8, 23.1.5, main). Bugs 1 and 3 happen on both arm64 and x86_64; bug 2 only
reproduces on arm64:

| | Bug 1: foreign threads | Bug 2: Debug-only crash at exit | Bug 3: no POSIX shared memory (sandbox) |
|---|---|---|---|
| Symptom | `OMP: Error #131: Thread identifier invalid`, `OMP: Error #13: Assertion failure at kmp_runtime.cpp(3689)`, or SIGSEGV | SIGSEGV in `__kmp_get_global_thread_id` during `exit()` | `OMP: Error #179` (`#178` in 12–13): `Function Can't open SHM2 failed: OMP: System error #1: Operation not permitted` at startup |
| Affects | Release and Debug builds, arm64 and x86_64 | Debug (`KMP_DEBUG`) builds only, on arm64 (x86_64 under Rosetta 2 passes) | processes where `shm_open` is denied, e.g. sandboxed apps |
| Tested broken | 12.0.1 (11.1.0 is fine) | 12.0.1 – 17.0.6 (11.1.0 is fine) | 12.0.1 – 15.0.7 (11.1.0 is fine) |
| Fixed by | [f1b9ce2736d8](https://github.com/llvm/llvm-project/commit/f1b9ce2736d826df2ff4cbd67116864f0856334f) "[OpenMP] Fix a few issues with hidden helper task" ([D105308](https://reviews.llvm.org/D105308)) | [35fdf8d70329](https://github.com/llvm/llvm-project/commit/35fdf8d70329b2b067cb9433a5891f2a57e2f4ed) "[OpenMP] Fix a segment fault in `__kmp_get_global_thread_id`" ([D159324](https://reviews.llvm.org/D159324)) | [dafebd5b5a08](https://github.com/llvm/llvm-project/commit/dafebd5b5a08dde25f5f52f65cac54bd6ec0ecde) "[OpenMP] Create a temp file in /tmp if /dev/shm is not accessible" plus follow-ups |
| First release with the fix | **13.0.0** | **18.1.0** | **16.0.0** |
| Reproducer | [`repro.c`](repro.c) | [`test_package.cpp`](test_package.cpp) with a Debug libomp | [`test_package.cpp`](test_package.cpp) under [`noshm.sb`](noshm.sb) |

## Bug 1: OpenMP used from short-lived non-OpenMP threads (libomp 12.x)

A common pattern in applications that host plug-ins (compositors, image editors,
Python extension modules): the application runs its own threads, such as
`std::thread`, `std::async`, a thread pool or `pthread`, and code running in those
threads uses `#pragma omp parallel`. Each such thread becomes an OpenMP *root* thread
and is registered with libomp on first use. When the thread exits, libomp unregisters it.

[`repro.c`](repro.c) does exactly that, in a loop: each round creates 32 pthreads that
each run 10 `#pragma omp parallel for` regions, then joins them. This is repeated for
30 rounds.

```
$ ./repro 30 32 10            # libomp 12.0.1
OMP: Error #131: Thread identifier invalid.
Abort trap: 6
```

or `OMP: Error #13: Assertion failure at kmp_runtime.cpp(3689)` (in
`__kmp_register_root`, the message from llvm#49923), or a plain segmentation fault.
It fails in every run on an 18-core Apple M5 Pro, natively on arm64 and as x86_64
under Rosetta 2.

**Cause.** libomp 12 introduced *hidden helper threads* and enabled them only on Linux.
On the other platforms the feature was disabled, but `__kmp_hidden_helper_threads_num`
still defaulted to 8, so gtids were still reserved for hidden helpers that never
existed. That left the gtid bookkeeping for root threads inconsistent. 13.0.0 sets
the number of hidden helper threads to 0 when the feature is disabled
([f1b9ce2736d8](https://github.com/llvm/llvm-project/commit/f1b9ce2736d826df2ff4cbd67116864f0856334f)).
This also explains why `LIBOMP_USE_HIDDEN_HELPER_TASK=0 LIBOMP_NUM_HIDDEN_HELPER_THREADS=0`
worked around the bug in llvm#49923.

[`stress.c`](stress.c) is a broader stress test. Spawner threads continuously create
detached and joinable threads that use a random mix of per-thread
`omp_set_num_threads`, `schedule(dynamic)`, `num_threads`, nested parallelism,
`critical`/`barrier`/`single` and `if` clauses. It fails like `repro.c` with 12.0.1
(one run hung until the 90 s timeout instead of crashing) and passes with 11.1.0 and
every version from 13.0.0 on. Clang 19 and later call `__kmpc_dispatch_deinit` after
`schedule(dynamic)` loops, and libomp only exports it from 19 on. So `runstress.sh` adds
a no-op stub of it to the test when the libomp lacks it, as Natron's libomp 11.1.0 port did.

## Bug 2: Debug libomp crashes at exit (libomp 12–17)

The conan llvm-openmp recipe's
[`test_package.cpp`](https://github.com/conan-io/conan-center-index/tree/master/recipes/llvm-openmp/all/test_package)
is single-threaded apart from one `#pragma omp parallel`. With a **Debug** libomp it
crashes at exit:

```
* thread #1, queue = 'com.apple.main-thread', stop reason = EXC_BAD_ACCESS (code=1, address=0x10)
  * frame #0: libomp.dylib`__kmp_get_global_thread_id() at kmp_runtime.cpp:201:8
    frame #1: libomp.dylib`__kmp_release_template<kmp_flag_64<false, true>>(flag=...) at kmp_wait_release.h:790:39
    frame #2: libomp.dylib`__kmp_release_64(flag=...) at kmp_wait_release.cpp:25:46
    frame #3: libomp.dylib`__kmp_reap_thread(thread=..., is_root=0) at kmp_runtime.cpp:6185:9
    frame #4: libomp.dylib`__kmp_internal_end() at kmp_runtime.cpp:6373:7
    frame #5: libomp.dylib`__kmp_internal_end_library(gtid_req=-1) at kmp_runtime.cpp:6537:3
    frame #6: libomp.dylib`__kmp_internal_end_atexit() at kmp_runtime.cpp:6154:3
    frame #7: libomp.dylib`__kmp_internal_end_dtor() at kmp_runtime.cpp:6122:3
    frame #8: libsystem_c.dylib`__cxa_finalize_ranges + 436
    frame #9: libsystem_c.dylib`exit + 44
```

(libomp 17.0.6, arm64). During shutdown the root thread's descriptor `__kmp_threads[0]` has
already been freed, but its gtid is still in TLS. A `KMP_DEBUG`-only call to
`__kmp_get_gtid()`, which exists only to print a `KF_TRACE` message, then dereferences
it. Release builds compile that code out and pass. 18.1.0 added a null check
([35fdf8d70329](https://github.com/llvm/llvm-project/commit/35fdf8d70329b2b067cb9433a5891f2a57e2f4ed)).

It reproduces only on arm64: the same Debug builds for x86_64, run under Rosetta 2,
pass. The fix's commit message says it "can happen on an Intel-based Mac"; native
Intel hardware was not tested.

This is **not** llvm#49923. It is what the conan recipe comment refers to (armv8 Debug
builds), and it was the source of the claim that "the bug persists until 17".

## Bug 3: libomp aborts when POSIX shared memory is denied (libomp 12–15)

Since 12.0.0, libomp registers itself at startup in a POSIX shared memory segment
(`shm_open("/__KMP_REGISTERED_LIB_<pid>")`). It uses that segment to detect two copies of
the OpenMP runtime in one process. If `shm_open` fails, libomp 12–15 abort before
`main()`. That can happen in a sandboxed app, for example one built with the App Sandbox
entitlement:

```
$ sandbox-exec -f noshm.sb ./test_package     # libomp 15.0.7
OMP: Error #179: Function Can't open SHM2 failed:
OMP: System error #1: Operation not permitted
Abort trap: 6
```

([`noshm.sb`](noshm.sb) allows everything except `ipc-posix-shm*`.) 16.0.0 falls back to
a regular file in `/tmp` when shared memory is not available
([dafebd5b5a08](https://github.com/llvm/llvm-project/commit/dafebd5b5a08dde25f5f52f65cac54bd6ec0ecde)).
That commit alone still crashes (SIGSEGV), but the 16.0.0 release works. 18.1.0 added an
environment-variable method as a third fallback
([102d86471915](https://github.com/llvm/llvm-project/commit/102d864719153bb5d18a17926c536b66d258df38)).

12.0.1 – 15.0.7 abort on both arm64 and x86_64, dafebd5b5a08 alone segfaults, and
16.0.0 and later run (see the results table below).

Run it with `./run-noshm.sh 13.0.0 arm64`.

## Results

Generated by `./run-all.sh` from a fresh clone, then `./summarize.py`. The raw output is
[`results/2026-11-17-macos27-m5pro.txt`](results/2026-11-17-macos27-m5pro.txt): macOS 27.2.1,
Apple M5 Pro (18 cores), libomp and tests built with Apple clang 21. x86_64 runs under
Rosetta 2. Each cell gives failed runs / total runs. `abort` is
`OMP: Error #178/#179: Function Can't open SHM2 failed`, and `rc=139` is SIGSEGV. `main` was
5a50b09613ce, and the commit of every release tag is listed in the results file.

| libomp | bug 1: repro arm64 | bug 1: repro x86_64 | bug 1: stress arm64 | bug 1: stress x86_64 | bug 2: test_package, Debug libomp arm64 | bug 2: test_package, Debug libomp x86_64 | bug 3: test_package in noshm.sb arm64 | bug 3: test_package in noshm.sb x86_64 | test_package, Release arm64 | test_package, Release x86_64 |
|---|---|---|---|---|---|---|---|---|---|---|
| 11.1.0 | 0/5 | 0/5 | 0/3 | 0/3 | 0/5 | 0/5 | ok | ok | 0/5 | 0/5 |
| 12.0.1 | **5/5** | **5/5** | **3/3** | **3/3** | **5/5** | 0/5 | **abort** | **abort** | 0/5 | 0/5 |
| f1b9ce2736d8^ (parent) | **5/5** | **5/5** | **3/3** | **3/3** | **5/5** | 0/5 | **abort** | **abort** | 0/5 | 0/5 |
| f1b9ce2736d8 | 0/5 | 0/5 | 0/3 | 0/3 | **5/5** | 0/5 | **abort** | **abort** | 0/5 | 0/5 |
| 13.0.0 | 0/5 | 0/5 | 0/3 | 0/3 | **5/5** | 0/5 | **abort** | **abort** | 0/5 | 0/5 |
| 13.0.1 | 0/5 | 0/5 | 0/3 | 0/3 | **5/5** | 0/5 | **abort** | **abort** | 0/5 | 0/5 |
| 14.0.6 | 0/5 | 0/5 | 0/3 | 0/3 | **5/5** | 0/5 | **abort** | **abort** | 0/5 | 0/5 |
| 15.0.7 | 0/5 | 0/5 | 0/3 | 0/3 | **5/5** | 0/5 | **abort** | **abort** | 0/5 | 0/5 |
| dafebd5b5a08^ (parent) | 0/5 | 0/5 | 0/3 | 0/3 | **5/5** | 0/5 | **abort** | **abort** | 0/5 | 0/5 |
| dafebd5b5a08 | 0/5 | 0/5 | 0/3 | 0/3 | **5/5** | 0/5 | **rc=139** | **rc=139** | 0/5 | 0/5 |
| 16.0.0 | 0/5 | 0/5 | 0/3 | 0/3 | **5/5** | 0/5 | ok | ok | 0/5 | 0/5 |
| 17.0.6 | 0/5 | 0/5 | 0/3 | 0/3 | **5/5** | 0/5 | ok | ok | 0/5 | 0/5 |
| 35fdf8d70329^ (parent) | 0/5 | 0/5 | 0/3 | 0/3 | **5/5** | 0/5 | ok | ok | 0/5 | 0/5 |
| 35fdf8d70329 | 0/5 | 0/5 | 0/3 | 0/3 | 0/5 | 0/5 | ok | ok | 0/5 | 0/5 |
| 18.1.8 | 0/5 | 0/5 | 0/3 | 0/3 | 0/5 | 0/5 | ok | ok | 0/5 | 0/5 |
| 19.1.7 | 0/5 | 0/5 | 0/3 | 0/3 | 0/5 | 0/5 | ok | ok | 0/5 | 0/5 |
| 20.1.8 | 0/5 | 0/5 | 0/3 | 0/3 | 0/5 | 0/5 | ok | ok | 0/5 | 0/5 |
| 21.1.7 | 0/5 | 0/5 | 0/3 | 0/3 | 0/5 | 0/5 | ok | ok | 0/5 | 0/5 |
| 22.1.8 | 0/5 | 0/5 | 0/3 | 0/3 | 0/5 | 0/5 | ok | ok | 0/5 | 0/5 |
| 23.1.5 | 0/5 | 0/5 | 0/3 | 0/3 | 0/5 | 0/5 | ok | ok | 0/5 | 0/5 |
| main | 0/5 | 0/5 | 0/3 | 0/3 | 0/5 | 0/5 | ok | ok | 0/5 | 0/5 |

Earlier runs (2026-11-15, same machine, tests built with MacPorts clang 22 or Apple clang)
gave the same results.

Bug 1's fix was found by inspecting the 12.0.1..13.0.0 openmp changes and testing the
candidate against its parent, then confirmed with `git bisect run bisect-step.sh repro`.
Bug 2's fix was found with `git bisect run bisect-step.sh debug-exit`. Bug 3's fix was
identified from the commit log and confirmed by testing it and its parent.

Some reports of hangs or crashes with libomp 14 or 15 (xgboost, LightGBM) don't
reproduce with these tests. They probably have other causes, for example two copies
of libomp loaded in the same process.

## Downstream status (2026-11-17)

- **Natron** removed its libomp 11.1.0 pin from its MacPorts overlay in
  [NatronGitHub/Natron#1146](https://github.com/NatronGitHub/Natron/pull/1146), which
  closed [#672](https://github.com/NatronGitHub/Natron/issues/672). The macOS build now
  uses MacPorts' libomp (21.1.7).
- These results were posted on
  [llvm#49923](https://github.com/llvm/llvm-project/issues/49923#issuecomment-6892693691),
  [conan-center-index#19857](https://github.com/conan-io/conan-center-index/pull/19857#issuecomment-6892694202)
  (the armv8 Debug restriction only needs to cover 12–17),
  [RawTherapee#6220](https://github.com/RawTherapee/RawTherapee/issues/6220#issuecomment-6893591937)
  and [LightGBM#5764](https://github.com/lightgbm-org/LightGBM/issues/5764#issuecomment-6892694554).

## Running the tests

Requirements: macOS, Xcode command line tools (Apple clang), CMake, Ninja, git, and
Rosetta 2 for x86_64 tests on Apple Silicon.

```sh
# Build a libomp (Release by default; BT=Debug for Debug) into prefix/<name>-<arch>.
# The first call clones llvm-project (blobless, sparse) into ./llvm-project,
# or set LLVM_PROJECT to an existing clone.
./build-libomp.sh llvmorg-12.0.1 arm64
./build-libomp.sh llvmorg-21.1.7 x86_64
BT=Debug ./build-libomp.sh llvmorg-17.0.6 arm64 17.0.6-debug

./runtest.sh 12.0.1 arm64 5               # bug 1: 5 runs of "repro 30 32 10"
./runstress.sh 21.1.7 x86_64 3            # broader stress, 3 runs of 20 s
./run-test-package.sh 17.0.6-debug arm64  # bug 2
./run-noshm.sh 13.0.0 arm64               # bug 3

./run-all.sh 6                            # the whole results table (6 parallel builds)
./summarize.py results/<date>-<host>.txt  # -> markdown table
```

`run-all.sh` builds 21 libomp versions × {Release, Debug} × {arm64, x86_64} (about
2.5 GB with the clone) and runs every test. On an M5 Pro it takes about 2 hours,
mostly for the tests. Afterwards, `rm -rf llvm-project src build prefix bin` frees the space.

When calling `build-libomp.sh` yourself, run parallel builds only after the first clone
has completed, and don't build two arches from the same new worktree at the same time.
`run-all.sh` takes care of both.
libomp 11.x needs [D88252](https://reviews.llvm.org/D88252) to build for arm64.
`build-libomp.sh` applies it from `patches/` automatically.

Bisecting. The terms are inverted because we look for the fix. Run this from a
worktree of the llvm-project clone, so that the clone's own checkout is left alone:

```sh
git -C "$LLVM_PROJECT" worktree add --detach $PWD/src/bisect llvmorg-13.0.0
cd src/bisect && git sparse-checkout set openmp cmake llvm/cmake llvm/utils runtimes third-party
git bisect start --term-old=broken --term-new=fixed llvmorg-13.0.0 llvmorg-12.0.1 -- openmp
git bisect run ../../bisect-step.sh repro        # -> f1b9ce2736d8
git bisect reset
git bisect start --term-old=broken --term-new=fixed llvmorg-18.1.8 \
    $(git merge-base llvmorg-17.0.6 llvmorg-18.1.8) -- openmp
git bisect run ../../bisect-step.sh debug-exit   # -> 35fdf8d70329
git bisect reset
```

The tests can also be built against an installed libomp, for example MacPorts
(`clang-mp-22 -fopenmp repro.c -o repro`) or Homebrew
(`clang -Xpreprocessor -fopenmp -I$(brew --prefix libomp)/include -L$(brew --prefix libomp)/lib -lomp repro.c -o repro`).

## Files

| file | purpose |
|---|---|
| `repro.c` | minimal reproducer for bug 1 |
| `stress.c` | broader stress test (many OpenMP constructs, thread churn) |
| `test_package.cpp` | reproducer for bug 2, from conan-center-index (MIT) |
| `build-libomp.sh` | build libomp at any git ref, for arm64 or x86_64 |
| `runtest.sh`, `runstress.sh`, `run-test-package.sh` | build a test against a libomp and run it N times |
| `noshm.sb`, `run-noshm.sh` | sandbox profile denying POSIX shared memory, and its runner (bug 3) |
| `bisect-step.sh` | `git bisect run` helper for bugs 1 and 2 |
| `run-all.sh` | build all versions and run all tests, writing `results/<date>-<host>.txt` |
| `summarize.py` | turn a results file into the README table |
| `results/` | raw results of `run-all.sh` runs |
| `common.sh` | shared settings (`LLVM_PROJECT`, compilers) |
| `patches/D88252-libomp11-arm64.diff` | arm64 build fix for libomp 11.x (from LLVM, Apache-2.0 WITH LLVM-exception) |
