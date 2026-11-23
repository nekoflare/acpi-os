// The vDSO: clock_gettime, gettimeofday and time without entering the
// kernel, as on Linux. The kernel maps its data page (struct vvar) one page
// below this image and fills it in kernel.asl (VDUP). The time is computed
// exactly as MNOW does: TSC cycles since TMBS, at CTMH cycles per
// microsecond. Clocks the page cannot serve fall back to the system call.
#include <stdint.h>

struct timespec64 {
    long tv_sec;
    long tv_nsec;
};

struct timeval64 {
    long tv_sec;
    long tv_usec;
};

struct vvar {
    uint64_t flags; // 1: monotonic clocks, 2: also the realtime clock
    uint64_t tsc_base;
    uint64_t tsc_mhz;
    uint64_t realtime_offset; // Realtime minus monotonic, in ns
};

extern const char __ehdr_start[] __attribute__((visibility("hidden")));

static const volatile struct vvar *vvar(void)
{
    return (const volatile struct vvar *)(__ehdr_start - 4096);
}

static long syscall2(long number, long a, long b)
{
    long result;
    __asm__ volatile("syscall"
                     : "=a"(result)
                     : "a"(number), "D"(a), "S"(b)
                     : "rcx", "r11", "memory");
    return result;
}

static long syscall1(long number, long a)
{
    long result;
    __asm__ volatile("syscall" : "=a"(result) : "a"(number), "D"(a) : "rcx", "r11", "memory");
    return result;
}

// Nanoseconds on the monotonic clock, or on the realtime one. Returns 0, or
// -1 when the kernel has not published what that clock needs.
static int now_ns(int realtime, uint64_t *ns)
{
    const volatile struct vvar *page = vvar();
    uint64_t flags = page->flags;
    if (!(flags & 1) || (realtime && !(flags & 2))) { return -1; }
    uint64_t base = page->tsc_base, mhz = page->tsc_mhz;
    uint32_t low, high;
    __asm__ volatile("rdtsc" : "=a"(low), "=d"(high));
    uint64_t tsc = low | (uint64_t)high << 32;
    uint64_t delta = tsc > base ? tsc - base : 0;
    uint64_t time = delta / mhz * 1000 + delta % mhz * 1000 / mhz;
    if (realtime) { time += page->realtime_offset; }
    *ns = time;
    return 0;
}

int __vdso_clock_gettime(int clock, struct timespec64 *ts)
{
    int realtime;
    // REALTIME, REALTIME_COARSE; MONOTONIC, MONOTONIC_RAW, _COARSE, BOOTTIME.
    if (clock == 0 || clock == 5) { realtime = 1; }
    else if (clock == 1 || clock == 4 || clock == 6 || clock == 7) { realtime = 0; }
    else { return syscall2(228, clock, (long)ts); }
    uint64_t ns;
    if (now_ns(realtime, &ns)) { return syscall2(228, clock, (long)ts); }
    ts->tv_sec = ns / 1000000000;
    ts->tv_nsec = ns % 1000000000;
    return 0;
}

int __vdso_gettimeofday(struct timeval64 *tv, void *tz)
{
    uint64_t ns;
    if (now_ns(1, &ns)) { return syscall2(96, (long)tv, (long)tz); }
    if (tv) {
        tv->tv_sec = ns / 1000000000;
        tv->tv_usec = ns % 1000000000 / 1000;
    }
    if (tz) {
        ((int *)tz)[0] = 0;
        ((int *)tz)[1] = 0;
    }
    return 0;
}

long __vdso_time(long *t)
{
    uint64_t ns;
    if (now_ns(1, &ns)) { return syscall1(201, (long)t); }
    long seconds = ns / 1000000000;
    if (t) { *t = seconds; }
    return seconds;
}
