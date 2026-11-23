// The vDSO: AT_SYSINFO_EHDR points at an ELF image that musl's dynamic
// linker attaches, clock_gettime and friends agree with the system calls and
// no longer enter the kernel, /proc/self/maps names [vvar] and [vdso], and
// the shared pages survive fork, munmap in a child and exit.
// link: dynamic
#define _GNU_SOURCE
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/auxv.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int fail(const char *what)
{
    printf("FAIL %s\n", what);
    return 1;
}

static int64_t ns(const struct timespec *t) { return t->tv_sec * 1000000000LL + t->tv_nsec; }

static int64_t sys_clock(int clock)
{
    struct timespec t;
    if (syscall(SYS_clock_gettime, clock, &t)) { return -1; }
    return ns(&t);
}

static int64_t lib_clock(int clock)
{
    struct timespec t;
    if (clock_gettime(clock, &t)) { return -1; }
    return ns(&t);
}

// Find "[name]" in /proc/self/maps and return its start, or zero.
static uintptr_t map_start(const char *name)
{
    FILE *maps = fopen("/proc/self/maps", "r");
    if (!maps) { return 0; }
    char line[256];
    uintptr_t start = 0;
    while (fgets(line, sizeof line, maps)) {
        if (strstr(line, name)) {
            sscanf(line, "%lx", &start);
            break;
        }
    }
    fclose(maps);
    return start;
}

static int check_clocks(void)
{
    for (int clock = 0; clock <= 7; clock++) {
        if (clock == 2 || clock == 3) { continue; }
        int64_t a = lib_clock(clock), b = sys_clock(clock), c = lib_clock(clock);
        if (a < 0 || b < 0 || c < 0) { return fail("clock_gettime error"); }
        // The system call reads the same TSC; allow 1 ms of skew either way.
        if (b + 1000000 < a || c + 1000000 < b) {
            printf("clock %d: %lld %lld %lld\n", clock, (long long)a, (long long)b, (long long)c);
            return fail("vDSO and system call disagree");
        }
        if (c - a > 100000000) { return fail("clocks drift apart"); }
    }
    // CPU-time clocks are not on the data page and fall back.
    struct timespec t;
    if (clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &t) || clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)) {
        return fail("cputime clocks");
    }
    if (clock_gettime(99, &t) == 0) { return fail("bad clock accepted"); }
    struct timeval tv;
    if (gettimeofday(&tv, NULL)) { return fail("gettimeofday"); }
    int64_t real = sys_clock(CLOCK_REALTIME) / 1000;
    int64_t got = tv.tv_sec * 1000000LL + tv.tv_usec;
    if (got > real + 1000000 || got < real - 1000000) { return fail("gettimeofday disagrees"); }
    time_t now = time(NULL);
    if (now < real / 1000000 - 1 || now > real / 1000000 + 1) { return fail("time disagrees"); }
    return 0;
}

int main(void)
{
    uintptr_t ehdr = getauxval(AT_SYSINFO_EHDR);
    if (!ehdr) { return fail("no AT_SYSINFO_EHDR"); }
    if (memcmp((void *)ehdr, "\177ELF", 4)) { return fail("AT_SYSINFO_EHDR is not an ELF image"); }
    if (map_start("[vdso]") != ehdr) { return fail("[vdso] missing from maps"); }
    if (map_start("[vvar]") != ehdr - 4096) { return fail("[vvar] missing from maps"); }
    if (check_clocks()) { return 1; }

    int64_t last = lib_clock(CLOCK_MONOTONIC);
    for (int i = 0; i < 200000; i++) {
        int64_t now = lib_clock(CLOCK_MONOTONIC);
        if (now < last) { return fail("monotonic clock went back"); }
        last = now;
    }
    int64_t start = lib_clock(CLOCK_MONOTONIC);
    for (int i = 0; i < 1000000; i++) { lib_clock(CLOCK_MONOTONIC); }
    int64_t vdso_ns = (lib_clock(CLOCK_MONOTONIC) - start) / 1000000;
    start = lib_clock(CLOCK_MONOTONIC);
    for (int i = 0; i < 10000; i++) { sys_clock(CLOCK_MONOTONIC); }
    int64_t sys_ns = (lib_clock(CLOCK_MONOTONIC) - start) / 10000;
    printf("clock_gettime: %lld ns through the vDSO, %lld ns as a system call\n",
           (long long)vdso_ns, (long long)sys_ns);
    if (vdso_ns * 4 > sys_ns) { return fail("the vDSO is not faster than the system call"); }

    // A child drops both pages; the shared copies must stay intact.
    pid_t child = fork();
    if (child == 0) {
        if (check_clocks()) { _exit(1); }
        if (munmap((void *)(ehdr - 4096), 8192)) { _exit(2); }
        _exit(0);
    }
    int status;
    if (waitpid(child, &status, 0) != child || status) { return fail("fork child"); }
    if (check_clocks()) { return 1; }
    printf("PASS\n");
    return 0;
}
