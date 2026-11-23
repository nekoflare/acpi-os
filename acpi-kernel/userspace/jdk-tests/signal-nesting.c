// B4: nested handlers, sa_mask, SA_NODEFER, SA_RESETHAND and SA_RESTART.
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int fail(const char *what)
{
    printf("FAIL %s errno=%d\n", what, errno);
    return 1;
}

static volatile int depth, max_depth, calls, usr2_depth, order[8], order_len;

static void record(int value)
{
    if (order_len < 8) { order[order_len++] = value; }
}

static void usr2_handler(int signo)
{
    (void)signo;
    if (depth > usr2_depth) { usr2_depth = depth; }
    record(2);
}

static void usr1_handler(int signo)
{
    depth++;
    if (depth > max_depth) { max_depth = depth; }
    calls++;
    record(1);
    if (calls < 3) { raise(signo); } // Nested only with SA_NODEFER.
    raise(SIGUSR2);
    record(10);
    depth--;
}

static int install(int signo, void (*handler)(int), int flags, int masked)
{
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_handler = handler;
    action.sa_flags = flags;
    sigemptyset(&action.sa_mask);
    if (masked) { sigaddset(&action.sa_mask, masked); }
    return sigaction(signo, &action, NULL);
}

static void reset(void)
{
    depth = max_depth = calls = usr2_depth = order_len = 0;
}

static int pipe_fds[2];
static volatile long read_result;
static volatile int read_errno;

static void *reader(void *arg)
{
    (void)arg;
    char byte;
    read_result = read(pipe_fds[0], &byte, 1);
    read_errno = errno;
    return NULL;
}

static void nothing(int signo)
{
    (void)signo;
}

static void sleep_ms(int ms)
{
    struct timespec ts = {0, ms * 1000000L};
    while (nanosleep(&ts, &ts) && errno == EINTR) {}
}

// Interrupt a reader blocked on an empty pipe, then feed it a byte.
static int interrupted_read(int flags)
{
    install(SIGUSR1, nothing, flags, 0);
    read_result = -2;
    pthread_t thread;
    if (pthread_create(&thread, NULL, reader, NULL)) { return -3; }
    sleep_ms(50);
    pthread_kill(thread, SIGUSR1);
    sleep_ms(50);
    if (write(pipe_fds[1], "x", 1) != 1) { return -4; }
    pthread_join(thread, NULL);
    if (read_result < 0) {
        // Drain the byte the interrupted reader did not take.
        char byte;
        if (read(pipe_fds[0], &byte, 1) != 1) { return -5; }
        return read_errno == EINTR ? 0 : -6;
    }
    return (int)read_result;
}

int main(void)
{
    // Without SA_NODEFER the self-raise waits until the handler returns,
    // and sa_mask holds SIGUSR2 back too.
    install(SIGUSR2, usr2_handler, 0, 0);
    install(SIGUSR1, usr1_handler, 0, SIGUSR2);
    reset();
    raise(SIGUSR1);
    if (max_depth != 1 || calls != 3) {
        printf("max_depth=%d calls=%d\n", max_depth, calls);
        return fail("deferred");
    }
    if (order[0] != 1 || order[1] != 10 || usr2_depth != 0) {
        printf("order %d %d usr2_depth=%d\n", order[0], order[1], usr2_depth);
        return fail("sa_mask");
    }
    printf("sa_mask ok\n");

    // SA_NODEFER nests the handler in itself; an unmasked SIGUSR2 nests
    // inside the innermost one.
    install(SIGUSR1, usr1_handler, SA_NODEFER, 0);
    reset();
    raise(SIGUSR1);
    if (max_depth != 3 || calls != 3 || usr2_depth != 3) {
        printf("max_depth=%d calls=%d usr2_depth=%d\n", max_depth, calls, usr2_depth);
        return fail("SA_NODEFER");
    }
    sigset_t set;
    sigprocmask(SIG_BLOCK, NULL, &set);
    if (sigismember(&set, SIGUSR1) || sigismember(&set, SIGUSR2)) { return fail("mask leaked"); }
    printf("nesting ok\n");

    // SA_RESETHAND with SA_SIGINFO.
    install(SIGUSR2, usr2_handler, SA_RESETHAND | SA_SIGINFO, 0);
    reset();
    raise(SIGUSR2);
    struct sigaction now;
    sigaction(SIGUSR2, NULL, &now);
    if (order_len != 1 || now.sa_handler != SIG_DFL) { return fail("SA_RESETHAND"); }
    printf("resethand ok\n");

    // SA_RESTART resumes a blocked read; without it the read fails EINTR.
    if (pipe(pipe_fds)) { return fail("pipe"); }
    int restarted = interrupted_read(SA_RESTART);
    if (restarted != 1) { printf("result=%d\n", restarted); return fail("SA_RESTART read"); }
    int interrupted = interrupted_read(0);
    if (interrupted != 0) { printf("result=%d\n", interrupted); return fail("EINTR read"); }
    printf("restart ok\n");

    // nanosleep fails with EINTR even with SA_RESTART, as on Linux.
    install(SIGALRM, nothing, SA_RESTART, 0);
    alarm(1);
    struct timespec ts = {3, 0};
    if (nanosleep(&ts, &ts) == 0 || errno != EINTR) { return fail("nanosleep EINTR"); }
    printf("PASS\n");
    return 0;
}
