// A2: MAP_FIXED, MAP_FIXED_NOREPLACE and address hints.
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

#define PAGE 4096
#ifndef MAP_FIXED_NOREPLACE
#define MAP_FIXED_NOREPLACE 0x100000
#endif

static int fail(const char *what)
{
    printf("FAIL %s errno=%d\n", what, errno);
    return 1;
}

int main(void)
{
    // A hint at a free address is used as given.
    unsigned char *want = (unsigned char *)0x200000000ULL;
    unsigned char *hint = mmap(want, 4 * PAGE, PROT_READ | PROT_WRITE,
                               MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (hint != want) { printf("got %p\n", (void *)hint); return fail("hint ignored"); }
    memset(hint, 1, 4 * PAGE);

    // A hint at a busy address falls back to another address.
    unsigned char *other = mmap(want, PAGE, PROT_READ | PROT_WRITE,
                                MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (other == MAP_FAILED || other == want) { return fail("busy hint"); }
    if (hint[0] != 1) { return fail("busy hint clobbered mapping"); }
    printf("hints ok\n");

    // MAP_FIXED_NOREPLACE refuses to overlap and works on free space.
    if (mmap(want + PAGE, PAGE, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE,
             -1, 0) != MAP_FAILED || errno != EEXIST) {
        return fail("NOREPLACE overlapped");
    }
    if (mmap(want + 4 * PAGE, PAGE, PROT_READ | PROT_WRITE,
             MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0) != want + 4 * PAGE) {
        return fail("NOREPLACE free");
    }
    printf("noreplace ok\n");

    // MAP_FIXED replaces pages 1 and 2 of the first mapping and spans into
    // the second; the replacement is zeroed and the rest is untouched.
    unsigned char *fixed = mmap(want + PAGE, 4 * PAGE, PROT_READ | PROT_WRITE | PROT_EXEC,
                                MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    if (fixed != want + PAGE) { return fail("MAP_FIXED"); }
    if (want[0] != 1 || want[PAGE - 1] != 1) { return fail("head lost"); }
    for (int i = PAGE; i < 5 * PAGE; i++) {
        if (want[i]) { return fail("replacement not zero"); }
    }
    printf("fixed replace ok\n");

    // Reserve-then-commit, the way HotSpot sets up its heap.
    size_t size = 64 * 1024 * 1024;
    unsigned char *reserve = mmap(NULL, size, PROT_NONE,
                                  MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (reserve == MAP_FAILED) { return fail("reserve"); }
    unsigned char *commit = mmap(reserve + size / 2, 16 * PAGE, PROT_READ | PROT_WRITE,
                                 MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED, -1, 0);
    if (commit != reserve + size / 2) { return fail("commit"); }
    memset(commit, 7, 16 * PAGE);
    if (mmap(commit, 16 * PAGE, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED | MAP_NORESERVE,
             -1, 0) != commit) {
        return fail("uncommit");
    }
    if (munmap(reserve, size)) { return fail("release"); }
    printf("reserve/commit ok\n");

    // Bad fixed addresses.
    if (mmap((void *)(uintptr_t)(want + 1), PAGE, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED,
             -1, 0) != MAP_FAILED || errno != EINVAL) {
        return fail("unaligned fixed");
    }
    printf("PASS\n");
    return 0;
}
