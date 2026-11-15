/* Broader stress: many foreign (non-OpenMP) threads, created/destroyed
 * continuously, each using a mix of OpenMP constructs.
 * usage: stress [seconds] [threads] */
#include <omp.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <stdatomic.h>

static atomic_long work;
static volatile int stop;

static void *worker(void *arg) {
  unsigned s = (unsigned)(long)arg;
  int n = 1 + rand_r(&s) % 20;
  for (int r = 0; r < n; ++r) {
    long sum = 0;
    switch (rand_r(&s) % 6) {
    case 0:
      omp_set_num_threads(1 + rand_r(&s) % 16);
#pragma omp parallel for reduction(+ : sum)
      for (int i = 0; i < 20000; ++i) sum += i & 3;
      break;
    case 1:
#pragma omp parallel for schedule(dynamic, 64) reduction(+ : sum)
      for (int i = 0; i < 20000; ++i) sum += i & 3;
      break;
    case 2:
#pragma omp parallel num_threads(1 + rand_r(&s) % 8) reduction(+ : sum)
      { sum += omp_get_thread_num() < omp_get_num_threads(); }
      break;
    case 3:
      omp_set_max_active_levels(2);
#pragma omp parallel num_threads(4) reduction(+ : sum)
      {
#pragma omp parallel for num_threads(3) reduction(+ : sum)
        for (int i = 0; i < 1000; ++i) sum += 1;
      }
      break;
    case 4:
#pragma omp parallel
      {
#pragma omp critical
        sum += 1;
#pragma omp barrier
#pragma omp single
        sum += 1;
      }
      break;
    case 5:
#pragma omp parallel for if (rand_r(&s) & 1) reduction(+ : sum)
      for (int i = 0; i < 5000; ++i) sum += 1;
      break;
    }
    atomic_fetch_add(&work, sum);
  }
  return NULL;
}

static void *spawner(void *arg) {
  unsigned s = (unsigned)(long)arg;
  while (!stop) {
    pthread_t t;
    pthread_attr_t a; pthread_attr_init(&a);
    pthread_attr_setdetachstate(&a, (rand_r(&s) & 1) ? PTHREAD_CREATE_DETACHED : PTHREAD_CREATE_JOINABLE);
    int det; pthread_attr_getdetachstate(&a, &det);
    if (pthread_create(&t, &a, worker, (void *)(long)rand_r(&s)) == 0 && det == PTHREAD_CREATE_JOINABLE)
      pthread_join(t, NULL);
    pthread_attr_destroy(&a);
  }
  return NULL;
}

int main(int argc, char **argv) {
  int secs = argc > 1 ? atoi(argv[1]) : 20, n = argc > 2 ? atoi(argv[2]) : 24;
  pthread_t *t = malloc(sizeof *t * n);
  for (long i = 0; i < n; ++i) pthread_create(&t[i], NULL, spawner, (void *)(i + 1));
  sleep(secs); stop = 1;
  for (int i = 0; i < n; ++i) pthread_join(t[i], NULL);
  sleep(1); /* let detached workers finish */
  printf("OK work=%ld\n", (long)work);
  return 0;
}
