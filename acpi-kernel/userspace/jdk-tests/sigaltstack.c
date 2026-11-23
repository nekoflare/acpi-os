// B3: sigaltstack and SA_ONSTACK, including recovering from a thread stack
// overflow on the alternate stack.
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ucontext.h>
#include <unistd.h>

#ifndef SS_AUTODISARM
#define SS_AUTODISARM (1U << 31)
#endif

static int fail(const char *what)
{
    printf("FAIL %s errno=%d\n", what, errno);
    return 1;
}

static char *alt_base;
static size_t alt_size = 64 * 1024;
static volatile int on_alt, query_flags, change_errno, uc_flags;

static int in_alt(void *p)
{
    return (char *)p >= alt_base && (char *)p < alt_base + alt_size;
}

static void handler(int signo, siginfo_t *info, void *context)
{
    (void)signo;
    (void)info;
    ucontext_t *uc = context;
    volatile char local;
    stack_t now, other = {.ss_sp = alt_base, .ss_size = alt_size};
    on_alt = in_alt((void *)&local);
    sigaltstack(NULL, &now);
    query_flags = now.ss_flags;
    change_errno = sigaltstack(&other, NULL) ? errno : 0;
    uc_flags = uc->uc_stack.ss_flags;
}

static int install(int flags)
{
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_sigaction = handler;
    action.sa_flags = SA_SIGINFO | flags;
    return sigaction(SIGUSR1, &action, NULL);
}

static __thread sigjmp_buf overflow_jump;
static __thread char *thread_alt;
static __thread volatile int overflow_on_alt;

static void overflow_handler(int signo)
{
    volatile char local;
    overflow_on_alt = (char *)&local >= thread_alt && (char *)&local < thread_alt + SIGSTKSZ * 4;
    siglongjmp(overflow_jump, signo);
}

static volatile int keep_going = 1;
static int recurse(int depth)
{
    volatile char pad[512];
    pad[0] = (char)depth;
    return keep_going ? recurse(depth + 1) + pad[0] : 0;
}

static void *overflow_thread(void *arg)
{
    (void)arg;
    thread_alt = malloc(SIGSTKSZ * 4);
    stack_t ss = {.ss_sp = thread_alt, .ss_size = SIGSTKSZ * 4};
    if (sigaltstack(&ss, NULL)) { return (void *)1; }
    if (sigsetjmp(overflow_jump, 1)) { return overflow_on_alt ? NULL : (void *)2; }
    recurse(0);
    return (void *)3;
}

int main(void)
{
    stack_t ss, old;
    if (sigaltstack(NULL, &old) || !(old.ss_flags & SS_DISABLE)) { return fail("initial state"); }

    alt_base = malloc(alt_size);
    ss.ss_sp = alt_base;
    ss.ss_size = 1024;
    ss.ss_flags = 0;
    if (sigaltstack(&ss, NULL) == 0 || errno != ENOMEM) { return fail("small stack"); }
    ss.ss_size = alt_size;
    ss.ss_flags = 0x40;
    if (sigaltstack(&ss, NULL) == 0 || errno != EINVAL) { return fail("bad flags"); }
    ss.ss_flags = 0;
    if (sigaltstack(&ss, &old)) { return fail("sigaltstack"); }
    if (sigaltstack(NULL, &old) || old.ss_sp != alt_base || old.ss_size != alt_size || old.ss_flags) {
        return fail("query");
    }

    // SA_ONSTACK runs on the alternate stack, which cannot change meanwhile.
    install(SA_ONSTACK);
    raise(SIGUSR1);
    if (!on_alt || query_flags != SS_ONSTACK || change_errno != EPERM || uc_flags != 0) {
        printf("on_alt=%d flags=%d errno=%d uc=%d\n", on_alt, query_flags, change_errno, uc_flags);
        return fail("SA_ONSTACK");
    }
    // Without SA_ONSTACK the handler stays on the normal stack.
    install(0);
    raise(SIGUSR1);
    if (on_alt || query_flags != 0 || change_errno != 0) { return fail("no SA_ONSTACK"); }
    printf("onstack ok\n");

    // SS_AUTODISARM clears the setting inside the handler and sigreturn
    // restores it.
    ss.ss_flags = SS_AUTODISARM;
    if (sigaltstack(&ss, NULL)) { return fail("autodisarm"); }
    install(SA_ONSTACK);
    raise(SIGUSR1);
    if (!on_alt || !(query_flags & SS_DISABLE) || change_errno != 0) {
        printf("on_alt=%d flags=%d errno=%d\n", on_alt, query_flags, change_errno);
        return fail("autodisarm in handler");
    }
    // The handler installed a stack without SS_AUTODISARM; sigreturn puts
    // back the one saved in uc_stack.
    if (sigaltstack(NULL, &old) || old.ss_flags != (int)SS_AUTODISARM || old.ss_sp != alt_base) {
        printf("flags=%#x\n", old.ss_flags);
        return fail("autodisarm restore");
    }
    printf("autodisarm ok\n");

    // SS_DISABLE turns it off.
    ss.ss_flags = SS_DISABLE;
    if (sigaltstack(&ss, NULL)) { return fail("disable"); }
    raise(SIGUSR1);
    if (on_alt) { return fail("disabled stack used"); }

    // A thread overflows its stack and recovers on its alternate stack.
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_handler = overflow_handler;
    action.sa_flags = SA_ONSTACK | SA_NODEFER;
    sigaction(SIGSEGV, &action, NULL);
    for (int i = 0; i < 3; i++) {
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setstacksize(&attr, 128 * 1024);
        pthread_t thread;
        void *result;
        if (pthread_create(&thread, &attr, overflow_thread, NULL)) { return fail("pthread_create"); }
        pthread_join(thread, &result);
        if (result) { printf("result=%ld\n", (long)result); return fail("overflow recovery"); }
    }
    printf("stack overflow ok\n");
    printf("PASS\n");
    return 0;
}
