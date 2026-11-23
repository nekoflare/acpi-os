// A5: madvise(MADV_DONTNEED) and mremap.
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#define PAGE 4096
#define MIB (1024L * 1024)

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

static int filled(unsigned char *p, size_t size, int value)
{
    for (size_t i = 0; i < size; i++) {
        if (p[i] != (unsigned char)value) { return 0; }
    }
    return 1;
}

int main(void)
{
    // MADV_DONTNEED frees touched pages; they read back as zero.
    unsigned char *a = mmap(NULL, 4 * MIB, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (a == MAP_FAILED) { return fail("mmap"); }
    memset(a, 0x11, 4 * MIB);
    long before = mem_free_kib();
    if (madvise(a + MIB, 2 * MIB, MADV_DONTNEED)) { return fail("madvise"); }
    long after = mem_free_kib();
    printf("DONTNEED freed %ld kB\n", after - before);
    if (after - before < 2000) { return fail("pages not freed"); }
    if (!filled(a, MIB, 0x11) || !filled(a + MIB, 2 * MIB, 0) || !filled(a + 3 * MIB, MIB, 0x11)) {
        return fail("contents after DONTNEED");
    }
    if (madvise(a, MIB, MADV_WILLNEED) || madvise(a, MIB, MADV_HUGEPAGE)) { return fail("hints"); }
    if (madvise(a + 1, PAGE, MADV_DONTNEED) == 0 || errno != EINVAL) { return fail("unaligned"); }
    printf("madvise ok\n");

    // Shrink in place.
    unsigned char *r = mremap(a, 4 * MIB, 2 * MIB, 0);
    if (r != a || !filled(a, MIB, 0x11)) { return fail("shrink"); }

    // Grow in place when the space after is free.
    unsigned char *g = mmap(NULL, 8 * MIB, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (g == MAP_FAILED || munmap(g + 2 * MIB, 6 * MIB)) { return fail("grow setup"); }
    if (mprotect(g, 2 * MIB, PROT_READ | PROT_WRITE)) { return fail("grow prot"); }
    memset(g, 0x22, 2 * MIB);
    r = mremap(g, 2 * MIB, 6 * MIB, 0);
    if (r != g) { return fail("grow in place"); }
    if (!filled(g, 2 * MIB, 0x22) || !filled(g + 2 * MIB, 4 * MIB, 0)) { return fail("grown contents"); }
    printf("shrink and grow ok\n");

    // Grow without room: without MAYMOVE it fails, with it the pages move.
    unsigned char *blocker = mmap(g + 6 * MIB, PAGE, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    if (blocker != g + 6 * MIB) { return fail("blocker"); }
    if (mremap(g, 6 * MIB, 8 * MIB, 0) != MAP_FAILED || errno != ENOMEM) { return fail("grow blocked"); }
    before = mem_free_kib();
    unsigned char *m = mremap(g, 6 * MIB, 8 * MIB, MREMAP_MAYMOVE);
    after = mem_free_kib();
    if (m == MAP_FAILED || m == g) { return fail("move"); }
    printf("move used %ld kB\n", before - after);
    if (before - after > 256) { return fail("move copied pages"); }
    if (!filled(m, 2 * MIB, 0x22) || !filled(m + 2 * MIB, 6 * MIB, 0)) { return fail("moved contents"); }
    m[8 * MIB - 1] = 1;
    if (mincore(g, PAGE, (unsigned char[1]){0}) == 0) {
        // mincore may be unsupported; only a successful call means mapped.
        return fail("old range still mapped");
    }

    // MREMAP_FIXED to a chosen address.
    unsigned char *target = (unsigned char *)0x300000000ULL;
    unsigned char *f = mremap(m, 8 * MIB, 8 * MIB, MREMAP_MAYMOVE | MREMAP_FIXED, target);
    if (f != target || !filled(f, 2 * MIB, 0x22) || f[8 * MIB - 1] != 1) { return fail("fixed move"); }
    printf("move ok\n");

    // musl realloc on large blocks goes through mremap.
    char *buffer = malloc(1 * MIB);
    memset(buffer, 0x33, MIB);
    for (size_t size = 2 * MIB; size <= 64 * MIB; size *= 2) {
        buffer = realloc(buffer, size);
        if (!buffer || !filled((unsigned char *)buffer, MIB, 0x33)) { return fail("realloc"); }
    }
    free(buffer);
    printf("realloc ok\n");
    printf("PASS\n");
    return 0;
}
