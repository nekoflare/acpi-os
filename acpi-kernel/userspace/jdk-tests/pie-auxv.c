// link: static-pie
// C1: ET_DYN executables load at a base address and get a full auxv. The
// program checks itself as the boot module, then again after execve.
#define _GNU_SOURCE
#include <elf.h>
#include <errno.h>
#include <link.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/auxv.h>
#include <sys/wait.h>
#include <unistd.h>

static int fail(const char *what)
{
    printf("FAIL %s errno=%d\n", what, errno);
    return 1;
}

extern char _start[];
// Pointers in data need R_X86_64_RELATIVE relocations applied by rcrt1.
static const char *const greeting[] = {"relocated", "data"};
static __thread int tls_value = 42;

static void *thread_main(void *arg)
{
    (void)arg;
    return tls_value == 42 ? (void *)&tls_value : NULL;
}

static int check(const char *who)
{
    // The load base is AT_PHDR minus the PT_PHDR link address.
    const ElfW(Phdr) *phdr = (const void *)getauxval(AT_PHDR);
    unsigned long phnum = getauxval(AT_PHNUM), base = 0;
    if (!phdr || getauxval(AT_PHENT) != sizeof *phdr || !phnum) { return fail("AT_PHDR"); }
    int has_phdr = 0;
    for (unsigned long i = 0; i < phnum; i++) {
        if (phdr[i].p_type == PT_PHDR) {
            base = (uintptr_t)phdr - phdr[i].p_vaddr;
            has_phdr = 1;
        }
    }
    if (!has_phdr || base != 0x5555400000UL) { printf("base=%#lx\n", base); return fail("load base"); }
    if (getauxval(AT_ENTRY) != (uintptr_t)_start) { return fail("AT_ENTRY"); }
    if (getauxval(AT_BASE) != 0 || getauxval(AT_PAGESZ) != 4096) { return fail("AT_BASE/AT_PAGESZ"); }
    if (getauxval(AT_CLKTCK) != 100 || getauxval(AT_SECURE) != 0) { return fail("AT_CLKTCK/AT_SECURE"); }
    // SSE2 is bit 26 of CPUID.1 EDX on every x86-64 CPU.
    if (!(getauxval(AT_HWCAP) & (1UL << 26))) { return fail("AT_HWCAP"); }
    errno = 0;
    if (getauxval(AT_UID) || errno) { return fail("AT_UID"); }
    const unsigned char *random = (const void *)getauxval(AT_RANDOM);
    if (!random) { return fail("AT_RANDOM"); }
    int nonzero = 0;
    for (int i = 0; i < 16; i++) { nonzero |= random[i]; }
    if (!nonzero) { return fail("AT_RANDOM bytes"); }
    if (strcmp(greeting[0], "relocated") || strcmp(greeting[1], "data")) { return fail("relocations"); }
    if ((uintptr_t)&check < base) { return fail("code below base"); }
    pthread_t thread;
    void *result;
    if (pthread_create(&thread, NULL, thread_main, NULL) || pthread_join(thread, &result) ||
        !result || result == &tls_value) {
        return fail("thread TLS");
    }
    printf("%s ok base=%#lx random=%02x%02x%02x%02x\n", who, base, random[0], random[1],
           random[2], random[3]);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc > 1 && !strcmp(argv[1], "child")) { return check("execve") ? 3 : 0; }
    if (check("boot")) { return 1; }
    pid_t child = fork();
    if (!child) {
        char *args[] = {"pie-auxv", "child", NULL};
        char *env[] = {"PATH=/bin", NULL};
        execve("/bin/pie-auxv.elf", args, env);
        _exit(2);
    }
    int status;
    if (waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status)) {
        printf("status=%#x\n", status);
        return fail("execve child");
    }
    printf("PASS\n");
    return 0;
}
