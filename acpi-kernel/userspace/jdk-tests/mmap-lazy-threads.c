// A4: threads on several CPUs fault in the same lazy mapping concurrently.
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

#define PAGE 4096
#define THREADS 4
#define PAGES 4096

static unsigned char *area;

static void *worker(void *argument)
{
    long id = (long)argument;
    // Every thread touches every page, so many faults race on the same page.
    for (int round = 0; round < 4; round++) {
        for (long page = 0; page < PAGES; page++) {
            __atomic_fetch_add((int *)(area + page * PAGE + id * 4), 1, __ATOMIC_RELAXED);
        }
    }
    return NULL;
}

int main(void)
{
    area = mmap(NULL, PAGES * PAGE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (area == MAP_FAILED) { printf("FAIL mmap\n"); return 1; }
    pthread_t threads[THREADS];
    for (long i = 0; i < THREADS; i++) {
        if (pthread_create(&threads[i], NULL, worker, (void *)i)) { printf("FAIL create\n"); return 1; }
    }
    for (int i = 0; i < THREADS; i++) { pthread_join(threads[i], NULL); }
    for (long page = 0; page < PAGES; page++) {
        for (int id = 0; id < THREADS; id++) {
            int value = *(int *)(area + page * PAGE + id * 4);
            if (value != 4) { printf("FAIL page %ld thread %d value %d\n", page, id, value); return 1; }
        }
    }
    printf("%d threads faulted %d pages consistently\nPASS\n", THREADS, PAGES);
    return 0;
}
