// B1: SA_SIGINFO handlers get a Linux siginfo_t and ucontext_t, and
// rt_sigreturn restores whatever the handler left in the ucontext.
#define _GNU_SOURCE
#include <errno.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/syscall.h>
#include <ucontext.h>
#include <unistd.h>

static int fail(const char *what)
{
    printf("FAIL %s errno=%d\n", what, errno);
    return 1;
}

static volatile int got_signo, got_code, got_pid, uc_has_usr2, usr1_blocked_inside;
static volatile int handler_calls;

static void info_handler(int signo, siginfo_t *info, void *context)
{
    ucontext_t *uc = context;
    sigset_t now;
    got_signo = info->si_signo == signo ? signo : -1;
    got_code = info->si_code;
    got_pid = info->si_pid;
    uc_has_usr2 = sigismember(&uc->uc_sigmask, SIGUSR2);
    sigprocmask(SIG_BLOCK, NULL, &now);
    usr1_blocked_inside = sigismember(&now, SIGUSR1);
    // Blocking inside the handler is undone by sigreturn.
    sigaddset(&now, SIGTERM);
    sigprocmask(SIG_SETMASK, &now, NULL);
    handler_calls++;
}

// Rewrites the interrupted registers: RAX is the syscall result, RBX gets a
// marker and RIP jumps to the address the caller left in R12.
static void redirect_handler(int signo, siginfo_t *info, void *context)
{
    (void)signo;
    (void)info;
    ucontext_t *uc = context;
    uc->uc_mcontext.gregs[REG_RAX] = 77;
    uc->uc_mcontext.gregs[REG_RBX] = 0x1234;
    uc->uc_mcontext.gregs[REG_RIP] = uc->uc_mcontext.gregs[REG_R12];
    handler_calls++;
}

// Clobbers the vector registers, then changes the saved XMM0 and adds
// SIGUSR2 to the mask that sigreturn restores.
static void fp_handler(int signo, siginfo_t *info, void *context)
{
    (void)signo;
    (void)info;
    ucontext_t *uc = context;
    __asm__ volatile("pxor %%xmm0, %%xmm0\n\tpxor %%xmm1, %%xmm1" ::: "xmm0", "xmm1");
    uint32_t *xmm0 = (uint32_t *)((char *)uc->uc_mcontext.fpregs + 160);
    if (xmm0[0] == 0x11111111) { xmm0[0] = 0x22222222; }
    sigaddset(&uc->uc_sigmask, SIGUSR2);
    handler_calls++;
}

static sigjmp_buf jump;
static void jump_handler(int signo)
{
    handler_calls++;
    siglongjmp(jump, signo);
}

static volatile int plain_calls;
static void plain_handler(int signo)
{
    if (signo == SIGUSR1) { plain_calls++; }
}

static int install(int signo, void (*handler)(int, siginfo_t *, void *), int flags)
{
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_sigaction = handler;
    action.sa_flags = SA_SIGINFO | flags;
    return sigaction(signo, &action, NULL);
}

int main(void)
{
    // siginfo contents, the mask seen inside and the mask restored after.
    sigset_t set;
    sigemptyset(&set);
    sigaddset(&set, SIGUSR2);
    sigprocmask(SIG_SETMASK, &set, NULL);
    if (install(SIGUSR1, info_handler, 0)) { return fail("sigaction"); }
    if (kill(getpid(), SIGUSR1)) { return fail("kill"); }
    if (handler_calls != 1) { return fail("handler not called"); }
    if (got_signo != SIGUSR1) { return fail("si_signo"); }
    if (got_code != SI_USER) { printf("si_code=%d\n", got_code); return fail("si_code"); }
    if (got_pid != getpid()) { printf("si_pid=%d\n", got_pid); return fail("si_pid"); }
    if (!uc_has_usr2) { return fail("uc_sigmask"); }
    if (!usr1_blocked_inside) { return fail("signal not blocked in its handler"); }
    sigprocmask(SIG_BLOCK, NULL, &set);
    if (sigismember(&set, SIGTERM) || sigismember(&set, SIGUSR1) || !sigismember(&set, SIGUSR2)) {
        return fail("mask after return");
    }
    syscall(SYS_tgkill, getpid(), gettid(), SIGUSR1);
    if (handler_calls != 2 || got_code != SI_TKILL) { return fail("tgkill si_code"); }
    printf("siginfo ok\n");

    // The handler changes RAX, RBX and RIP.
    if (install(SIGUSR1, redirect_handler, 0)) { return fail("sigaction redirect"); }
    long rax, rbx;
    __asm__ volatile(
        "lea 1f(%%rip), %%r12\n\t"
        "xor %%ebx, %%ebx\n\t"
        "syscall\n\t"
        "mov $0x99, %%ebx\n\t" // Skipped when RIP is redirected.
        "1:\n\t"
        "mov %%rbx, %1\n\t"
        : "=a"(rax), "=r"(rbx)
        : "a"((long)SYS_kill), "D"((long)getpid()), "S"((long)SIGUSR1)
        : "rbx", "r12", "rcx", "r11", "memory");
    if (rax != 77 || rbx != 0x1234) {
        printf("rax=%ld rbx=%#lx\n", rax, rbx);
        return fail("modified context");
    }
    printf("context edit ok\n");

    // Vector state survives a handler that clobbers it, and edits to
    // fpregs and uc_sigmask take effect.
    sigemptyset(&set);
    sigprocmask(SIG_SETMASK, &set, NULL);
    if (install(SIGUSR1, fp_handler, 0)) { return fail("sigaction fp"); }
    uint32_t xmm0_out, xmm1_out;
    __asm__ volatile(
        "movd %3, %%xmm0\n\t"
        "movd %4, %%xmm1\n\t"
        "syscall\n\t"
        "movd %%xmm0, %0\n\t"
        "movd %%xmm1, %1\n\t"
        : "=r"(xmm0_out), "=r"(xmm1_out), "+a"((long){SYS_kill})
        : "r"(0x11111111), "r"(0x33333333), "D"((long)getpid()), "S"((long)SIGUSR1)
        : "xmm0", "xmm1", "rcx", "r11", "memory");
    if (xmm0_out != 0x22222222 || xmm1_out != 0x33333333) {
        printf("xmm0=%#x xmm1=%#x\n", xmm0_out, xmm1_out);
        return fail("vector state");
    }
    sigprocmask(SIG_BLOCK, NULL, &set);
    if (!sigismember(&set, SIGUSR2)) { return fail("edited uc_sigmask"); }
    printf("fp state ok\n");

    // Leaving a handler with siglongjmp must not stop later deliveries.
    sigemptyset(&set);
    sigprocmask(SIG_SETMASK, &set, NULL);
    signal(SIGUSR1, jump_handler);
    handler_calls = 0;
    for (int i = 0; i < 3; i++) {
        if (!sigsetjmp(jump, 1)) {
            kill(getpid(), SIGUSR1);
            return fail("no jump");
        }
    }
    if (handler_calls != 3) { return fail("delivery after longjmp"); }
    printf("longjmp ok\n");

    // One-argument handlers and SA_RESETHAND.
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_handler = plain_handler;
    action.sa_flags = SA_RESETHAND;
    sigaction(SIGUSR1, &action, NULL);
    kill(getpid(), SIGUSR1);
    sigaction(SIGUSR1, NULL, &action);
    if (plain_calls != 1 || action.sa_handler != SIG_DFL) { return fail("SA_RESETHAND"); }
    printf("PASS\n");
    return 0;
}
