// link: dynamic
// C2: a dynamically linked PIE names /lib/ld-musl-x86_64.so.1 in PT_INTERP.
// The kernel loads both and starts the dynamic linker, which relocates the
// program, write-protects its RELRO data and calls main. Checked as the boot
// module and again after execve.
#define _GNU_SOURCE
#include <elf.h>
#include <errno.h>
#include <link.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
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
static __thread int tls_value = 7;
static void *thread_main(void *arg)
{
    (void)arg;
    return tls_value == 7 ? (void *)&tls_value : NULL;
}

struct objects {
    int count, saw_ldso;
    uintptr_t app_base;
};
static int visit(struct dl_phdr_info *info, size_t size, void *data)
{
    (void)size;
    struct objects *seen = data;
    if (seen->count++ == 0) { seen->app_base = info->dlpi_addr; }
    if (info->dlpi_addr == 0x7FC0000000UL) { seen->saw_ldso = 1; }
    return 0;
}

static sigjmp_buf jump;
static void on_segv(int signo)
{
    siglongjmp(jump, signo);
}

static int check(const char *who)
{
    if (getauxval(AT_BASE) != 0x7FC0000000UL) {
        printf("AT_BASE=%#lx\n", getauxval(AT_BASE));
        return fail("AT_BASE");
    }
    if (getauxval(AT_ENTRY) != (uintptr_t)_start) { return fail("AT_ENTRY"); }
    struct objects seen = {0};
    dl_iterate_phdr(visit, &seen);
    if (seen.count < 2 || !seen.saw_ldso || seen.app_base != 0x5555400000UL) {
        printf("objects=%d ldso=%d app=%#lx\n", seen.count, seen.saw_ldso, seen.app_base);
        return fail("dl_iterate_phdr");
    }

    // The dynamic linker made PT_GNU_RELRO read-only: writing it faults.
    const ElfW(Phdr) *phdr = (const void *)getauxval(AT_PHDR);
    volatile char *relro = NULL;
    for (unsigned long i = 0; i < getauxval(AT_PHNUM); i++) {
        if (phdr[i].p_type == PT_GNU_RELRO) { relro = (char *)seen.app_base + phdr[i].p_vaddr; }
    }
    if (!relro) { return fail("no PT_GNU_RELRO"); }
    struct sigaction action = {.sa_handler = on_segv, .sa_flags = SA_NODEFER};
    sigaction(SIGSEGV, &action, NULL);
    if (!sigsetjmp(jump, 1)) {
        *relro = *relro;
        return fail("RELRO writable");
    }
    signal(SIGSEGV, SIG_DFL);

    pthread_t thread;
    void *result;
    if (pthread_create(&thread, NULL, thread_main, NULL) || pthread_join(thread, &result) ||
        !result || result == &tls_value) {
        return fail("thread TLS");
    }
    printf("%s ok objects=%d\n", who, seen.count);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc > 1 && !strcmp(argv[1], "child")) { return check("execve") ? 3 : 0; }
    if (check("boot")) { return 1; }
    pid_t child = fork();
    if (!child) {
        char *args[] = {"dynamic-interp", "child", NULL};
        char *env[] = {"PATH=/bin", NULL};
        execve("/bin/dynamic-interp.elf", args, env);
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
