// A3: munmap and mprotect on parts of mappings and across several mappings.
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#define PAGE 4096

static int fail(const char *what)
{
    printf("FAIL %s errno=%d\n", what, errno);
    return 1;
}

static long mem_free_kib(void)
{
    FILE *file = fopen("/proc/meminfo", "r");
    char line[128];
    long value = -1;
    while (file && fgets(line, sizeof line, file)) {
        if (sscanf(line, "MemFree: %ld kB", &value) == 1) { break; }
    }
    if (file) { fclose(file); }
    return value;
}

// Returns the signal that killed a child touching the address, or zero.
static int touch_signal(volatile unsigned char *address)
{
    pid_t child = fork();
    if (!child) { _exit(*address == 0xAA ? 0 : 1); }
    int status;
    if (child < 0 || waitpid(child, &status, 0) != child) { return -1; }
    return WIFSIGNALED(status) ? WTERMSIG(status) : 0;
}

static int check_page(unsigned char *page, int value)
{
    for (int i = 0; i < PAGE; i++) {
        if (page[i] != (unsigned char)value) { return 0; }
    }
    return 1;
}

int main(void)
{
    unsigned char *map = mmap(NULL, 16 * PAGE, PROT_READ | PROT_WRITE,
                              MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (map == MAP_FAILED) { return fail("mmap"); }
    for (int i = 0; i < 16; i++) { memset(map + i * PAGE, i, PAGE); }

    // Split in the middle, then trim both ends.
    if (munmap(map + 4 * PAGE, 4 * PAGE)) { return fail("munmap middle"); }
    if (munmap(map, 2 * PAGE)) { return fail("munmap head"); }
    if (munmap(map + 14 * PAGE, 2 * PAGE)) { return fail("munmap tail"); }
    for (int i = 2; i < 14; i++) {
        if (i >= 4 && i < 8) { continue; }
        if (!check_page(map + i * PAGE, i)) { printf("page %d\n", i); return fail("contents"); }
    }
    printf("split contents ok\n");

    memset(map + 3 * PAGE, 0xAA, PAGE);
    if (touch_signal(map + 3 * PAGE) != 0) { return fail("mapped page faulted"); }
    if (touch_signal(map + 5 * PAGE) != SIGSEGV) { return fail("hole still mapped"); }
    if (touch_signal(map) != SIGSEGV) { return fail("head still mapped"); }
    if (touch_signal(map + 15 * PAGE) != SIGSEGV) { return fail("tail still mapped"); }
    printf("holes fault ok\n");

    // mprotect a span that covers parts of both pieces and the hole is
    // ENOMEM; covering only mapped pages works.
    if (mprotect(map + 3 * PAGE, 6 * PAGE, PROT_READ) == 0 || errno != ENOMEM) {
        return fail("mprotect over hole");
    }
    if (mprotect(map + 9 * PAGE, 2 * PAGE, PROT_READ)) { return fail("mprotect part"); }
    if (!check_page(map + 9 * PAGE, 9)) { return fail("read after mprotect"); }

    // Fork copies the pieces with their contents.
    pid_t child = fork();
    if (!child) {
        _exit(check_page(map + 2 * PAGE, 2) && check_page(map + 13 * PAGE, 13) ? 0 : 1);
    }
    int status;
    if (waitpid(child, &status, 0) != child || status != 0) { return fail("fork copy"); }
    printf("fork after split ok\n");

    // One munmap across both remaining pieces and the hole between them, and
    // munmap of a range that is not mapped at all.
    if (munmap(map, 16 * PAGE)) { return fail("munmap across"); }
    if (touch_signal(map + 10 * PAGE) != SIGSEGV) { return fail("still mapped after munmap across"); }
    if (munmap(map, 16 * PAGE)) { return fail("munmap unmapped"); }
    if (munmap(map + 1, PAGE) == 0 || errno != EINVAL) { return fail("unaligned munmap"); }
    printf("munmap across ok\n");

    // Splitting must not leak pages or records.
    long before = mem_free_kib();
    for (int i = 0; i < 2000; i++) {
        unsigned char *p = mmap(NULL, 8 * PAGE, PROT_READ | PROT_WRITE,
                                MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p == MAP_FAILED) { return fail("mmap loop"); }
        if (munmap(p + 3 * PAGE, 2 * PAGE) || munmap(p, 8 * PAGE)) { return fail("munmap loop"); }
    }
    long after = mem_free_kib();
    printf("MemFree before=%ld after=%ld kB\n", before, after);
    if (before < 0 || after < before - 64) { return fail("leak"); }
    printf("PASS\n");
    return 0;
}
