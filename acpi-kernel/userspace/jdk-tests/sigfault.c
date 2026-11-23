// B2: CPU exceptions become signals that a handler can inspect and resume
// from, the way HotSpot handles implicit null checks and safepoint polls.
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <ucontext.h>
#include <unistd.h>

static int fail(const char *what)
{
    printf("FAIL %s errno=%d\n", what, errno);
    return 1;
}

static __thread int last_signo, last_code;
static __thread void *last_addr;
static __thread long last_trapno, last_err, last_cr2;
static __thread greg_t last_rip;

// Record the fault and resume at the address the faulting code left in R12.
static void handler(int signo, siginfo_t *info, void *context)
{
    ucontext_t *uc = context;
    last_signo = signo;
    last_code = info->si_code;
    last_addr = info->si_addr;
    last_trapno = uc->uc_mcontext.gregs[REG_TRAPNO];
    last_err = uc->uc_mcontext.gregs[REG_ERR];
    last_cr2 = uc->uc_mcontext.gregs[REG_CR2];
    last_rip = uc->uc_mcontext.gregs[REG_RIP];
    uc->uc_mcontext.gregs[REG_RIP] = uc->uc_mcontext.gregs[REG_R12];
}

// Each probe runs one faulting instruction at label 2 and continues at 1.
// It returns the RIP of the faulting instruction.
#define PROBE(insn, ...)                                                  \
    ({                                                                    \
        uintptr_t fault_rip;                                              \
        __asm__ volatile("lea 1f(%%rip), %%r12\n\t"                       \
                         "lea 2f(%%rip), %0\n\t"                          \
                         "2: " insn "\n\t"                                \
                         "1:\n\t"                                         \
                         : "=&r"(fault_rip)                               \
                         : __VA_ARGS__                                    \
                         : "r12", "rax", "rdx", "memory");                \
        fault_rip;                                                        \
    })

static int check(const char *name, int signo, int code, void *addr, long trapno, uintptr_t rip)
{
    if (last_signo != signo || last_code != code || last_addr != addr || last_trapno != trapno ||
        (uintptr_t)last_rip != rip) {
        printf("%s: signo=%d code=%d addr=%p trapno=%ld rip=%#lx\n", name, last_signo, last_code,
               last_addr, last_trapno, (unsigned long)last_rip);
        return 0;
    }
    last_signo = 0;
    return 1;
}

static int install(int signo)
{
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_sigaction = handler;
    action.sa_flags = SA_SIGINFO;
    return sigaction(signo, &action, NULL);
}

static unsigned char *readonly;

static void *fault_loop(void *arg)
{
    (void)arg;
    for (int i = 0; i < 2000; i++) {
        uintptr_t rip = PROBE("movb $1, (%1)", "r"(readonly + (i % 4096)));
        if (!check("thread", SIGSEGV, SEGV_ACCERR, readonly + (i % 4096), 14, rip)) {
            return (void *)1;
        }
    }
    return NULL;
}

// Runs body in a child and returns the signal that ended it.
static int child_signal(void (*body)(void))
{
    pid_t child = fork();
    if (!child) {
        body();
        _exit(0);
    }
    int status;
    if (waitpid(child, &status, 0) != child) { return -1; }
    return WIFSIGNALED(status) ? WTERMSIG(status) : 0;
}

static void blocked_segv(void)
{
    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set, SIGSEGV);
    sigprocmask(SIG_BLOCK, &set, NULL);
    *(volatile int *)16 = 1;
}

static void ignored_segv(void)
{
    signal(SIGSEGV, SIG_IGN);
    *(volatile int *)16 = 1;
}

static void default_sigill(void)
{
    signal(SIGILL, SIG_DFL);
    __asm__ volatile("ud2");
}

int main(void)
{
    if (install(SIGSEGV) || install(SIGILL) || install(SIGFPE) || install(SIGTRAP) ||
        install(SIGBUS)) {
        return fail("sigaction");
    }

    // Unmapped page: SEGV_MAPERR, write error code, CR2 in the context.
    uintptr_t rip = PROBE("movl $1, (%1)", "r"((void *)0x10));
    if (!check("null write", SIGSEGV, SEGV_MAPERR, (void *)0x10, 14, rip)) { return fail("null"); }
    if ((last_err & 6) != 6 || last_cr2 != 0x10) { return fail("err/cr2"); }

    // Read-only page: SEGV_ACCERR. PROT_NONE inside a mapping is ACCERR too.
    readonly = mmap(NULL, 4096, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    unsigned char *none = mmap(NULL, 4096, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (readonly == MAP_FAILED || none == MAP_FAILED) { return fail("mmap"); }
    rip = PROBE("movb $1, (%1)", "r"(readonly + 5));
    if (!check("readonly", SIGSEGV, SEGV_ACCERR, readonly + 5, 14, rip)) { return fail("accerr"); }
    rip = PROBE("movb (%1), %%al", "r"(none + 7));
    if (!check("prot_none", SIGSEGV, SEGV_ACCERR, none + 7, 14, rip)) { return fail("prot none"); }
    printf("SIGSEGV ok\n");

    rip = PROBE("ud2", "r"(0));
    if (!check("ud2", SIGILL, ILL_ILLOPN, (void *)rip, 6, rip)) { return fail("SIGILL"); }
    rip = PROBE("xor %%edx, %%edx\n\tmov $1, %%eax\n\t2: divl %1", "r"(0));
    // The probe's label 2 is the xor; the fault is on the divl two labels on.
    if (last_signo != SIGFPE || last_code != FPE_INTDIV || last_trapno != 0 ||
        last_addr != (void *)last_rip) {
        return fail("SIGFPE");
    }
    (void)rip;
    last_signo = 0;
    // A non-canonical address raises #GP: SIGSEGV with SI_KERNEL and no address.
    rip = PROBE("movb (%1), %%al", "r"((void *)0x8000000000000000ULL));
    if (!check("noncanonical", SIGSEGV, SI_KERNEL, NULL, 13, rip)) { return fail("#GP"); }
    printf("SIGILL SIGFPE #GP ok\n");

    // int3 reports SIGTRAP after the instruction; the handler resumes via R12.
    rip = PROBE("int3", "r"(0));
    if (last_signo != SIGTRAP || last_trapno != 3 || (uintptr_t)last_rip != rip + 1) {
        printf("trap signo=%d trapno=%ld\n", last_signo, last_trapno);
        return fail("SIGTRAP");
    }
    last_signo = 0;

    // SIMD divide by zero with the exception unmasked: FPE_FLTDIV.
    unsigned int mxcsr = 0x1F80 & ~0x200;
    float one = 1.0f, zero = 0.0f;
    __asm__ volatile("ldmxcsr %0" ::"m"(mxcsr));
    rip = PROBE("movss %1, %%xmm0\n\tdivss %2, %%xmm0", "m"(one), "m"(zero));
    mxcsr = 0x1F80;
    __asm__ volatile("ldmxcsr %0" ::"m"(mxcsr));
    if (last_signo != SIGFPE || last_code != FPE_FLTDIV || last_trapno != 19) {
        printf("simd signo=%d code=%d trapno=%ld\n", last_signo, last_code, last_trapno);
        return fail("SIMD SIGFPE");
    }
    last_signo = 0;
    printf("SIGTRAP SIMD ok\n");

    // Many faults from several threads at once.
    pthread_t threads[4];
    for (int i = 0; i < 4; i++) {
        if (pthread_create(&threads[i], NULL, fault_loop, NULL)) { return fail("pthread_create"); }
    }
    for (int i = 0; i < 4; i++) {
        void *result;
        pthread_join(threads[i], &result);
        if (result) { return fail("thread faults"); }
    }
    printf("threaded faults ok\n");

    // A blocked or ignored fault signal still kills, as does the default.
    if (child_signal(blocked_segv) != SIGSEGV) { return fail("blocked SIGSEGV"); }
    if (child_signal(ignored_segv) != SIGSEGV) { return fail("ignored SIGSEGV"); }
    if (child_signal(default_sigill) != SIGILL) { return fail("default SIGILL"); }
    printf("forced signals ok\n");
    printf("PASS\n");
    return 0;
}
