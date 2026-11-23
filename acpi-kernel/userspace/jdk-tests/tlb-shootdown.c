// A6: munmap must flush other CPUs' TLBs before the page is reused.
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#define PAGE 4096

static volatile unsigned char *area;
static volatile int writing;

static void *writer(void *unused)
{
    (void)unused;
    volatile unsigned long *x = (volatile unsigned long *)area;
    writing = 1;
    for (;;) {
        for (int i = 0; i < PAGE / 8; i++) { x[i] = 0xBBBBBBBBBBBBBBBBUL; }
    }
    return NULL;
}

// Exits 1 if the freed page was written through a stale TLB entry. With a
// correct shootdown the writer faults and SIGSEGV ends the whole process.
static void experiment(void)
{
    area = mmap(NULL, 2 * PAGE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    memset((void *)area, 0, PAGE); // back X only; Y stays lazy
    pthread_t thread;
    pthread_create(&thread, NULL, writer, NULL);
    while (!writing) { }
    for (volatile int spin = 0; spin < 100000; spin++) { }
    munmap((void *)area, PAGE);
    volatile unsigned long *y = (volatile unsigned long *)(area + PAGE);
    y[1] = 0; // back Y, most likely with X's freed page
    for (long spin = 0; spin < 20000000; spin++) {
        if (y[spin & 511] == 0xBBBBBBBBBBBBBBBBUL) { _exit(1); }
    }
    _exit(2); // the writer neither faulted nor corrupted Y: not on another CPU?
}

int main(void)
{
    int faulted = 0, unclear = 0;
    for (int round = 0; round < 20; round++) {
        pid_t child = fork();
        if (!child) { experiment(); }
        int status;
        waitpid(child, &status, 0);
        if (WIFEXITED(status) && WEXITSTATUS(status) == 1) {
            printf("FAIL round %d: freed page written through a stale TLB entry\n", round);
            return 1;
        }
        if (WIFSIGNALED(status) && WTERMSIG(status) == SIGSEGV) { faulted++; }
        else { unclear++; }
    }
    printf("writer faulted %d times, unclear %d\n", faulted, unclear);
    if (faulted < 10) { printf("FAIL writer rarely ran concurrently\n"); return 1; }
    printf("PASS\n");
    return 0;
}
