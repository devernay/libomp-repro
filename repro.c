/* Concurrent OpenMP use from short-lived non-OpenMP threads (as in an
 * OpenFX host such as Natron, whose render threads call into plug-ins
 * that use "#pragma omp parallel").
 * usage: repro [rounds] [threads] [regions-per-thread]
 */
#include <omp.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

static int regions = 10;

static void *worker(void *arg) {
  long seed = (long)arg;
  volatile long sum = 0;
  for (int r = 0; r < regions; ++r) {
#pragma omp parallel for reduction(+ : sum)
    for (int i = 0; i < 10000; ++i)
      sum += (i ^ seed) & 7;
  }
  return NULL;
}

int main(int argc, char **argv) {
  int rounds = argc > 1 ? atoi(argv[1]) : 200;
  int nthreads = argc > 2 ? atoi(argv[2]) : 16;
  regions = argc > 3 ? atoi(argv[3]) : 10;
  pthread_t *t = malloc(sizeof(pthread_t) * nthreads);
  for (int round = 0; round < rounds; ++round) {
    for (long i = 0; i < nthreads; ++i)
      if (pthread_create(&t[i], NULL, worker, (void *)i)) {
        perror("pthread_create");
        return 2;
      }
    for (int i = 0; i < nthreads; ++i)
      pthread_join(t[i], NULL);
  }
  printf("OK %d rounds x %d threads x %d regions\n", rounds, nthreads, regions);
  return 0;
}
