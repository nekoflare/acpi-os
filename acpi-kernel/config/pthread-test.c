// Smoke test for kernel thread support (clone CLONE_THREAD, futex, TLS,
// CLONE_CHILD_CLEARTID joins). Build in the guest:
//   clang pthread-test.c -o pthread-test && ./pthread-test
#define _GNU_SOURCE
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/syscall.h>

#define THREADS 8
#define ITERS 100000

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
static long counter;
static int ready;
static __thread long tls_value; // Each thread must see its own copy.
static long tids[THREADS];

static void *work(void *arg)
{
    long id = (long)arg;
    tids[id] = syscall(SYS_gettid);
    tls_value = id * 1000;

    // Wait on a condition variable until main releases everyone.
    pthread_mutex_lock(&lock);
    while (!ready)
        pthread_cond_wait(&cond, &lock);
    pthread_mutex_unlock(&lock);

    for (int i = 0; i < ITERS; i++) {
        pthread_mutex_lock(&lock);
        counter++;
        pthread_mutex_unlock(&lock);
    }
    return (void *)(long)(tls_value == id * 1000);
}

int main(void)
{
    pthread_t threads[THREADS];
    int failures = 0;

    printf("pid=%d main tid=%ld\n", getpid(), (long)syscall(SYS_gettid));
    for (long i = 0; i < THREADS; i++) {
        if (pthread_create(&threads[i], NULL, work, (void *)i)) {
            printf("pthread_create %ld failed\n", i);
            return 1;
        }
    }

    pthread_mutex_lock(&lock);
    ready = 1;
    pthread_cond_broadcast(&cond);
    pthread_mutex_unlock(&lock);

    for (int i = 0; i < THREADS; i++) {
        void *ok;
        pthread_join(threads[i], &ok);
        printf("thread %d tid=%ld tls %s\n", i, tids[i], ok ? "ok" : "BROKEN");
        if (!ok)
            failures++;
    }

    printf("counter=%ld (expect %d)\n", counter, THREADS * ITERS);
    if (counter != THREADS * ITERS)
        failures++;
    puts(failures ? "FAIL" : "PASS");
    return failures != 0;
}
