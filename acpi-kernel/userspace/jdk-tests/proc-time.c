// D3: sysinfo, getrandom, membarrier, clock_getres, clock_nanosleep,
// sched_yield, /proc/self/maps, /proc/self/stat and /proc/cpuinfo.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/random.h>
#include <sys/syscall.h>
#include <sys/sysinfo.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

static int fail(const char *what)
{
    printf("FAIL %s errno=%d\n", what, errno);
    return 1;
}

static long long ns(clockid_t clock)
{
    struct timespec ts;
    if (clock_gettime(clock, &ts)) { return -1; }
    return ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

static char text[256 * 1024];

static long slurp(const char *path)
{
    int fd = open(path, O_RDONLY);
    if (fd < 0) { return -1; }
    long total = 0, got;
    while ((got = read(fd, text + total, sizeof text - 1 - total)) > 0) { total += got; }
    close(fd);
    text[total] = 0;
    return got < 0 ? -1 : total;
}

// Find the maps line containing addr; copy its permissions.
static int find_map(unsigned long addr, char perms[5], int *is_stack)
{
    for (char *line = text; *line;) {
        char *end = strchr(line, '\n');
        if (!end) { return 0; }
        unsigned long lo, hi;
        char p[5];
        if (sscanf(line, "%lx-%lx %4s", &lo, &hi, p) == 3 && lo <= addr && addr < hi) {
            memcpy(perms, p, 5);
            *is_stack = strstr(line, "[stack]") && strstr(line, "[stack]") < end;
            return 1;
        }
        line = end + 1;
    }
    return 0;
}

static volatile int spin_stop;

static void *spinner(void *arg)
{
    (void)arg;
    while (!spin_stop) {}
    return NULL;
}

int main(int argc, char **argv)
{
    (void)argc;
    // sched_yield
    for (int i = 0; i < 100; i++) {
        if (sched_yield()) { return fail("sched_yield"); }
    }

    // clock_getres
    struct timespec res;
    if (clock_getres(CLOCK_MONOTONIC, &res) || res.tv_sec || res.tv_nsec != 1) { return fail("getres"); }
    if (clock_getres(CLOCK_REALTIME, NULL)) { return fail("getres NULL"); }
    if (clock_getres(99, &res) == 0 || errno != EINVAL) { return fail("getres EINVAL"); }

    // CLOCK_REALTIME has sub-second resolution and tracks CLOCK_MONOTONIC.
    long long r0 = ns(CLOCK_REALTIME), m0 = ns(CLOCK_MONOTONIC);
    if (r0 < 1577836800LL * 1000000000LL) { printf("realtime %lld\n", r0); return fail("realtime epoch"); }
    struct timespec nap = {0, 50 * 1000000L};
    if (clock_nanosleep(CLOCK_MONOTONIC, 0, &nap, NULL)) { return fail("clock_nanosleep rel"); }
    long long r1 = ns(CLOCK_REALTIME), m1 = ns(CLOCK_MONOTONIC);
    long long dr = r1 - r0, dm = m1 - m0;
    if (dm < 45000000 || dr - dm > 1000000 || dm - dr > 1000000) {
        printf("realtime moved %lld ns, monotonic %lld ns\n", dr, dm);
        return fail("realtime rate");
    }
    if (r0 % 1000000000 == 0 && r1 % 1000000000 == 0) { return fail("realtime nanoseconds"); }
    struct timeval tv;
    gettimeofday(&tv, NULL);
    if (tv.tv_sec * 1000000LL + tv.tv_usec < r1 / 1000) { return fail("gettimeofday"); }
    for (clockid_t c = 4; c <= 7; c++) {
        if (ns(c) < 0) { printf("clock %d\n", (int)c); return fail("clock id"); }
    }
    printf("clocks ok (slept %lld ms)\n", dm / 1000000);

    // CPU-time clocks advance while spinning.
    long long c0 = ns(CLOCK_PROCESS_CPUTIME_ID);
    volatile unsigned long sink = 0;
    long long until = ns(CLOCK_MONOTONIC) + 30000000;
    while (ns(CLOCK_MONOTONIC) < until) { sink++; }
    long long c1 = ns(CLOCK_PROCESS_CPUTIME_ID);
    if (c0 < 0 || c1 <= c0) { printf("cpu %lld -> %lld\n", c0, c1); return fail("cputime"); }
    if (ns(CLOCK_THREAD_CPUTIME_ID) < 0) { return fail("thread cputime"); }

    // clock_nanosleep with absolute deadlines.
    struct timespec deadline;
    clock_gettime(CLOCK_MONOTONIC, &deadline);
    deadline.tv_nsec += 40 * 1000000L;
    if (deadline.tv_nsec >= 1000000000L) { deadline.tv_sec++; deadline.tv_nsec -= 1000000000L; }
    if (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &deadline, NULL)) { return fail("abs monotonic"); }
    long long late = ns(CLOCK_MONOTONIC) - (deadline.tv_sec * 1000000000LL + deadline.tv_nsec);
    if (late < 0) { printf("woke %lld ns early\n", -late); return fail("abs monotonic early"); }
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_nsec += 40 * 1000000L;
    if (deadline.tv_nsec >= 1000000000L) { deadline.tv_sec++; deadline.tv_nsec -= 1000000000L; }
    if (clock_nanosleep(CLOCK_REALTIME, TIMER_ABSTIME, &deadline, NULL)) { return fail("abs realtime"); }
    if (ns(CLOCK_REALTIME) < deadline.tv_sec * 1000000000LL + deadline.tv_nsec) { return fail("abs realtime early"); }
    struct timespec past = {1, 0};
    if (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &past, NULL)) { return fail("abs past"); }
    if (clock_nanosleep(CLOCK_PROCESS_CPUTIME_ID, 0, &nap, NULL) != EINVAL) { return fail("cpu sleep"); }
    printf("clock_nanosleep ok\n");

    // membarrier
    long mask = syscall(SYS_membarrier, 0, 0);
    if (mask < 0 || (mask & 24) != 24) { printf("mask=%ld\n", mask); return fail("membarrier query"); }
    if (syscall(SYS_membarrier, 8, 0) == 0 || errno != EPERM) { return fail("membarrier unregistered"); }
    if (syscall(SYS_membarrier, 16, 0)) { return fail("membarrier register"); }
    pthread_t thread;
    if (pthread_create(&thread, NULL, spinner, NULL)) { return fail("pthread_create"); }
    for (int i = 0; i < 100; i++) {
        if (syscall(SYS_membarrier, 8, 0)) { return fail("membarrier private"); }
    }
    spin_stop = 1;
    pthread_join(thread, NULL);
    if (syscall(SYS_membarrier, 1234, 0) == 0 || errno != EINVAL) { return fail("membarrier bad cmd"); }
    printf("membarrier ok\n");

    // sysinfo, getrandom and processor counts
    struct sysinfo info;
    if (sysinfo(&info) || info.totalram == 0 || info.mem_unit != 1 || info.procs < 1) { return fail("sysinfo"); }
    unsigned char random_bytes[64] = {0};
    if (getrandom(random_bytes, sizeof random_bytes, GRND_NONBLOCK) != sizeof random_bytes) { return fail("getrandom"); }
    int nonzero = 0;
    for (unsigned i = 0; i < sizeof random_bytes; i++) { nonzero += random_bytes[i] != 0; }
    if (nonzero < 32) { return fail("getrandom bytes"); }
    long cpus = sysconf(_SC_NPROCESSORS_ONLN);
    if (cpus < 1) { return fail("nprocessors"); }
    printf("sysinfo ok (%ld cpus, %lu MiB)\n", cpus, (unsigned long)(info.totalram >> 20));

    // /proc/self/maps with more mappings than fit in one page.
    enum { MAPS = 200 };
    char *maps[MAPS];
    for (int i = 0; i < MAPS; i++) {
        maps[i] = mmap(NULL, 3 * 4096, i % 2 ? PROT_READ : PROT_READ | PROT_WRITE,
            MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (maps[i] == MAP_FAILED) { return fail("mmap"); }
    }
    char *code = mmap(NULL, 4096, PROT_READ | PROT_EXEC, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (code == MAP_FAILED) { return fail("mmap exec"); }
    long length = slurp("/proc/self/maps");
    if (length <= 4096) { printf("length %ld\n", length); return fail("maps length"); }
    char perms[5];
    int is_stack;
    for (int i = 0; i < MAPS; i++) {
        if (!find_map((unsigned long)maps[i] + 4096, perms, &is_stack)) { printf("map %d\n", i); return fail("maps entry"); }
        if (strcmp(perms, i % 2 ? "r--p" : "rw-p")) { printf("perms %s\n", perms); return fail("maps perms"); }
    }
    if (!find_map((unsigned long)code, perms, &is_stack) || strcmp(perms, "r-xp")) { return fail("maps exec"); }
    if (!find_map((unsigned long)&main, perms, &is_stack) || perms[0] != 'r' || perms[2] != 'x') {
        printf("main %p perms %s\n", (void *)&main, perms);
        return fail("maps text");
    }
    int local;
    if (!find_map((unsigned long)&local, perms, &is_stack) || !is_stack || strcmp(perms, "rw-p")) {
        return fail("maps stack");
    }
    // Lines are sorted and do not overlap.
    unsigned long previous = 0;
    int lines = 0;
    for (char *line = text; *line; line = strchr(line, '\n') + 1) {
        unsigned long lo, hi;
        if (sscanf(line, "%lx-%lx", &lo, &hi) != 2 || lo < previous || hi <= lo) {
            printf("line %d: %.60s\n", lines, line);
            return fail("maps order");
        }
        previous = hi;
        lines++;
    }
    printf("maps ok (%d lines, %ld bytes)\n", lines, length);
    for (int i = 0; i < MAPS; i++) { munmap(maps[i], 3 * 4096); }

    // /proc/self/stat field 28 is the initial stack pointer, which points
    // at argc, just below argv.
    if (slurp("/proc/self/stat") <= 0) { return fail("stat"); }
    char *field = strrchr(text, ')') + 2;
    unsigned long startstack = 0;
    int count = 2; // pid and comm
    for (char *token = strtok(field, " \n"); token; token = strtok(NULL, " \n")) {
        if (++count == 28) { startstack = strtoul(token, NULL, 10); }
    }
    if (count != 52) { printf("fields %d\n", count); return fail("stat fields"); }
    if (startstack + 8 != (unsigned long)argv) {
        printf("startstack %#lx argv %p\n", startstack, (void *)argv);
        return fail("startstack");
    }
    printf("stat ok\n");

    // pthread_getattr_np on the main thread finds the whole stack.
    pthread_attr_t attr;
    void *stack_low;
    size_t stack_size;
    if (pthread_getattr_np(pthread_self(), &attr) ||
        pthread_attr_getstack(&attr, &stack_low, &stack_size)) { return fail("getattr_np"); }
    if (stack_size < 1024 * 1024 || stack_size > 4 * 1024 * 1024 ||
        (char *)&local < (char *)stack_low || (char *)&local >= (char *)stack_low + stack_size) {
        printf("stack %p size %zu local %p\n", stack_low, stack_size, (void *)&local);
        return fail("main stack size");
    }
    printf("main stack %zu KiB\n", stack_size >> 10);

    if (slurp("/proc/cpuinfo") <= 0 || !strstr(text, "processor\t: 0\n") ||
        !strstr(text, "\nflags\t\t: ") || !strstr(text, "\nvendor_id\t: ")) {
        printf("%.300s\n", text);
        return fail("cpuinfo");
    }
    printf("PASS\n");
    return 0;
}
