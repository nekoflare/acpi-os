// A4: anonymous mappings are backed on first touch.
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

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

// Signal that killed a child doing a read (0) or write (1), or zero.
static int access_signal(volatile unsigned char *address, int write)
{
    pid_t child = fork();
    if (!child) {
        if (write) { *address = 1; }
        _exit(*address == 0 || write ? 0 : 1);
    }
    int status;
    if (child < 0 || waitpid(child, &status, 0) != child) { return -1; }
    if (WIFSIGNALED(status)) { return WTERMSIG(status); }
    return WEXITSTATUS(status) ? -2 : 0;
}

int main(void)
{
    long start = mem_free_kib();

    // A 4 GiB PROT_NONE reservation costs nothing.
    size_t reserve_size = 4096 * MIB;
    unsigned char *reserve = mmap(NULL, reserve_size, PROT_NONE,
                                  MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (reserve == MAP_FAILED) { return fail("reserve 4 GiB"); }
    long reserved = mem_free_kib();
    printf("4 GiB reserve used %ld kB\n", start - reserved);
    if (start - reserved > 1024) { return fail("reservation was backed"); }
    if (access_signal(reserve + 100 * MIB, 0) != SIGSEGV) { return fail("PROT_NONE readable"); }

    // Commit 8 MiB in the middle; only touched pages cost memory.
    unsigned char *heap = reserve + 2048 * MIB;
    if (mprotect(heap, 8 * MIB, PROT_READ | PROT_WRITE)) { return fail("commit"); }
    long committed = mem_free_kib();
    if (reserved - committed > 256) { return fail("commit was backed"); }
    memset(heap, 0x5A, 2 * MIB);
    long touched = mem_free_kib();
    printf("touching 2 MiB used %ld kB\n", committed - touched);
    if (committed - touched < 2048 || committed - touched > 2048 + 256) {
        return fail("touch accounting");
    }
    if (heap[2 * MIB + 5] != 0 || heap[0] != 0x5A) { return fail("contents"); }
    if (access_signal(heap - PAGE, 0) != SIGSEGV) { return fail("below commit readable"); }
    if (access_signal(heap + 8 * MIB, 1) != SIGSEGV) { return fail("above commit writable"); }
    printf("commit ok\n");

    // The kernel itself touches lazy pages through read() and write().
    int pipes[2];
    if (pipe(pipes)) { return fail("pipe"); }
    unsigned char *fresh = heap + 6 * MIB;
    if (write(pipes[1], fresh, 64) != 64) { return fail("write from lazy page"); }
    if (read(pipes[0], fresh + PAGE, 64) != 64) { return fail("read into lazy page"); }
    if (fresh[PAGE] != 0) { return fail("lazy page not zero"); }
    printf("syscalls on lazy pages ok\n");

    // Read-only lazy pages read as zero and refuse writes.
    if (mprotect(heap + 7 * MIB, MIB, PROT_READ)) { return fail("mprotect ro"); }
    if (access_signal(heap + 7 * MIB + 3 * PAGE, 0) != 0) { return fail("ro read"); }
    if (access_signal(heap + 7 * MIB + 3 * PAGE, 1) != SIGSEGV) { return fail("ro write"); }
    if (write(pipes[1], "x", 1) != 1) { return fail("queue byte"); }
    if (read(pipes[0], heap + 7 * MIB, 1) >= 0 || errno != EFAULT) {
        return fail("read into ro lazy page");
    }
    printf("read-only lazy ok\n");

    // fork copies touched pages and keeps the rest lazy.
    pid_t child = fork();
    if (!child) {
        int good = heap[MIB] == 0x5A && heap[3 * MIB] == 0;
        heap[3 * MIB] = 1;
        _exit(good ? 0 : 1);
    }
    int status;
    if (waitpid(child, &status, 0) != child || status != 0) { return fail("fork"); }
    if (heap[3 * MIB] != 0) { return fail("child write leaked"); }
    printf("fork ok\n");

    // Large anonymous RW mapping, touched sparsely.
    unsigned char *big = mmap(NULL, 1024 * MIB, PROT_READ | PROT_WRITE,
                              MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (big == MAP_FAILED) { return fail("1 GiB mmap"); }
    for (int i = 0; i < 16; i++) { big[i * 64 * MIB] = (unsigned char)i; }
    for (int i = 0; i < 16; i++) {
        if (big[i * 64 * MIB] != i) { return fail("sparse contents"); }
    }
    printf("sparse 1 GiB ok\n");

    // The first touch of a lazy RWX page can be an instruction fetch. A zero
    // page decodes as add %al,(%rax), so execution slides into a ret placed at
    // the start of the next page.
    unsigned char *code = mmap(NULL, 2 * PAGE, PROT_READ | PROT_WRITE | PROT_EXEC,
                               MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (code == MAP_FAILED) { return fail("code mmap"); }
    code[PAGE] = 0xc3;
    static unsigned char scratch;
    __asm__ volatile("call *%1" : : "a"(&scratch), "r"(code) : "memory", "cc");
    printf("lazy RWX ok\n");

    if (munmap(big, 1024 * MIB) || munmap(reserve, reserve_size)) { return fail("munmap"); }
    // The pipe's ring buffer is kernel memory too; it is freed on the last close.
    if (close(pipes[0]) || close(pipes[1])) { return fail("close pipe"); }
    long end = mem_free_kib();
    printf("MemFree start=%ld end=%ld kB\n", start, end);
    if (end < start - 128) { return fail("leak"); }
    printf("PASS\n");
    return 0;
}
