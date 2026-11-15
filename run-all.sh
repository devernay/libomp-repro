#!/bin/bash
# run-all.sh: build the versions from the README tables and run all tests.
cd "$(dirname "$0")"
REL="11.1.0 12.0.1 13.0.0 14.0.6 17.0.6 21.1.7 23.1.5"
for a in arm64 x86_64; do
  for v in $REL; do ./build-libomp.sh llvmorg-$v $a >/dev/null || echo "build failed $v $a"; done
  ./build-libomp.sh main $a main >/dev/null || echo "build failed main $a"
done
for v in 11.1.0 12.0.1 17.0.6 21.1.7 23.1.5 main; do BT=Debug ./build-libomp.sh $( [ $v = main ] && echo main || echo llvmorg-$v ) arm64 $v-debug >/dev/null || echo "build failed $v-debug"; done
for a in arm64 x86_64; do for v in $REL main; do ./runtest.sh $v $a 5; done; done
for a in arm64 x86_64; do for v in 11.1.0 21.1.7 23.1.5 main; do ./runstress.sh $v $a 3; done; done
for v in 11.1.0 12.0.1 17.0.6 21.1.7 23.1.5 main; do ./run-test-package.sh $v-debug arm64 5; done
for a in arm64 x86_64; do for v in $REL main; do ./run-test-package.sh $v $a 5; done; done
for v in 11.1.0 12.0.1 13.0.0 14.0.6 17.0.6 21.1.7 23.1.5 main; do ./run-noshm.sh $v arm64; done
