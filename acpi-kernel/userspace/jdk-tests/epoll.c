// D2: epoll_create1, epoll_ctl, epoll_wait and epoll_pwait on pipes and
// socket pairs, as used by the JDK's EPollSelectorImpl.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static int fail(const char *what)
{
    printf("FAIL %s errno=%d\n", what, errno);
    return 1;
}

static long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int add(int ep, int fd, unsigned events, unsigned long data)
{
    struct epoll_event ev = {.events = events, .data.u64 = data};
    return epoll_ctl(ep, EPOLL_CTL_ADD, fd, &ev);
}

static int writer_fd;

static void *late_writer(void *arg)
{
    (void)arg;
    struct timespec ts = {0, 100 * 1000000L};
    nanosleep(&ts, NULL);
    if (write(writer_fd, "w", 1) != 1) { return (void *)1; }
    return NULL;
}

static void nothing(int signo)
{
    (void)signo;
}

static pthread_t main_thread;

static void *interrupter(void *arg)
{
    (void)arg;
    struct timespec ts = {0, 100 * 1000000L};
    nanosleep(&ts, NULL);
    pthread_kill(main_thread, SIGUSR1);
    return NULL;
}

int main(void)
{
    struct epoll_event out[4];

    if (epoll_create(0) >= 0 || errno != EINVAL) { return fail("epoll_create(0)"); }
    if (epoll_create1(1) >= 0 || errno != EINVAL) { return fail("epoll_create1 flags"); }
    int ep = epoll_create1(EPOLL_CLOEXEC);
    if (ep < 0) { return fail("epoll_create1"); }
    if (fcntl(ep, F_GETFD) != FD_CLOEXEC) { return fail("EPOLL_CLOEXEC"); }
    int ep2 = epoll_create(16);
    if (ep2 < 0 || fcntl(ep2, F_GETFD) != 0) { return fail("epoll_create"); }

    int p[2];
    if (pipe(p)) { return fail("pipe"); }

    // Error cases.
    int file = open("/", O_RDONLY);
    if (file < 0) { return fail("open"); }
    if (add(ep, file, EPOLLIN, 0) == 0 || errno != EPERM) { return fail("regular file EPERM"); }
    if (add(ep, ep, EPOLLIN, 0) == 0 || errno != EINVAL) { return fail("self EINVAL"); }
    if (add(ep, 999, EPOLLIN, 0) == 0 || errno != EBADF) { return fail("bad fd EBADF"); }
    if (add(p[0], p[1], EPOLLIN, 0) == 0 || errno != EINVAL) { return fail("not epoll EINVAL"); }
    if (epoll_ctl(ep, EPOLL_CTL_DEL, p[0], NULL) == 0 || errno != ENOENT) { return fail("DEL ENOENT"); }
    char byte;
    if (read(ep, &byte, 1) >= 0 || errno != EINVAL) { return fail("read epoll"); }
    if (epoll_wait(ep, out, 0, 0) >= 0 || errno != EINVAL) { return fail("maxevents 0"); }

    // Level-triggered readiness.
    if (add(ep, p[0], EPOLLIN, 0x1234)) { return fail("ADD"); }
    if (add(ep, p[0], EPOLLIN, 0) == 0 || errno != EEXIST) { return fail("EEXIST"); }
    if (epoll_wait(ep, out, 4, 0) != 0) { return fail("empty wait"); }
    if (write(p[1], "ab", 2) != 2) { return fail("write"); }
    for (int round = 0; round < 2; round++) {
        int n = epoll_wait(ep, out, 4, 0);
        if (n != 1 || out[0].events != EPOLLIN || out[0].data.u64 != 0x1234) {
            printf("n=%d events=%#x data=%#llx\n", n, n > 0 ? out[0].events : 0,
                n > 0 ? (unsigned long long)out[0].data.u64 : 0ULL);
            return fail("level ready");
        }
    }
    if (read(p[0], &byte, 1) != 1 || read(p[0], &byte, 1) != 1) { return fail("drain"); }
    if (epoll_wait(ep, out, 4, 0) != 0) { return fail("drained wait"); }
    printf("level ok\n");

    // MOD to a mask that is not ready, then DEL.
    if (write(p[1], "c", 1) != 1) { return fail("write c"); }
    struct epoll_event mod = {.events = EPOLLOUT, .data.u64 = 7};
    if (epoll_ctl(ep, EPOLL_CTL_MOD, p[0], &mod)) { return fail("MOD"); }
    if (epoll_wait(ep, out, 4, 0) != 0) { return fail("MOD mask"); }
    if (epoll_ctl(ep, EPOLL_CTL_DEL, p[0], NULL)) { return fail("DEL"); }
    if (epoll_ctl(ep, EPOLL_CTL_MOD, p[0], &mod) == 0 || errno != ENOENT) { return fail("MOD ENOENT"); }
    if (read(p[0], &byte, 1) != 1) { return fail("drain c"); }

    // Write ends and socket pairs; maxevents limits the result.
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv)) { return fail("socketpair"); }
    if (add(ep, p[1], EPOLLOUT, 1) || add(ep, sv[0], EPOLLIN | EPOLLOUT, 2)) { return fail("ADD two"); }
    if (epoll_wait(ep, out, 1, 0) != 1) { return fail("maxevents 1"); }
    int n = epoll_wait(ep, out, 4, 0);
    if (n != 2) { printf("n=%d\n", n); return fail("two ready"); }
    for (int i = 0; i < n; i++) {
        // The socket has nothing to read yet; both are writable.
        if (out[i].events != EPOLLOUT) {
            printf("data=%llu events=%#x\n", (unsigned long long)out[i].data.u64, out[i].events);
            return fail("write readiness");
        }
    }
    if (write(sv[1], "s", 1) != 1) { return fail("socket write"); }
    n = epoll_wait(ep, out, 4, 0);
    int socket_in = 0;
    for (int i = 0; i < n; i++) {
        if (out[i].data.u64 == 2 && out[i].events == (EPOLLIN | EPOLLOUT)) { socket_in = 1; }
    }
    if (!socket_in) { return fail("socket EPOLLIN"); }
    epoll_ctl(ep, EPOLL_CTL_DEL, p[1], NULL);
    epoll_ctl(ep, EPOLL_CTL_DEL, sv[0], NULL);
    printf("sockets ok\n");

    // EPOLLONESHOT reports once until MOD re-arms it.
    if (add(ep, sv[0], EPOLLIN | EPOLLONESHOT, 3)) { return fail("ADD oneshot"); }
    if (epoll_wait(ep, out, 4, 0) != 1) { return fail("oneshot first"); }
    if (epoll_wait(ep, out, 4, 0) != 0) { return fail("oneshot disarmed"); }
    struct epoll_event rearm = {.events = EPOLLIN | EPOLLONESHOT, .data.u64 = 3};
    if (epoll_ctl(ep, EPOLL_CTL_MOD, sv[0], &rearm)) { return fail("re-arm"); }
    if (epoll_wait(ep, out, 4, 0) != 1 || out[0].data.u64 != 3) { return fail("oneshot rearmed"); }
    epoll_ctl(ep, EPOLL_CTL_DEL, sv[0], NULL);
    if (read(sv[0], &byte, 1) != 1) { return fail("drain s"); }
    printf("oneshot ok\n");

    // poll() on the epoll descriptor itself.
    if (add(ep, p[0], EPOLLIN, 4)) { return fail("ADD p0"); }
    struct pollfd pfd = {.fd = ep, .events = POLLIN};
    if (poll(&pfd, 1, 0) != 0) { return fail("poll idle epoll"); }
    if (write(p[1], "d", 1) != 1) { return fail("write d"); }
    if (poll(&pfd, 1, 0) != 1 || !(pfd.revents & POLLIN)) { return fail("poll ready epoll"); }
    if (read(p[0], &byte, 1) != 1) { return fail("drain d"); }

    // Timeouts and blocking waits.
    long start = now_ms();
    if (epoll_wait(ep, out, 4, 100) != 0) { return fail("timeout"); }
    long waited = now_ms() - start;
    if (waited < 90) { printf("waited %ld ms\n", waited); return fail("timeout short"); }
    writer_fd = p[1];
    pthread_t thread;
    if (pthread_create(&thread, NULL, late_writer, NULL)) { return fail("pthread_create"); }
    start = now_ms();
    n = epoll_pwait(ep, out, 4, -1, NULL);
    waited = now_ms() - start;
    pthread_join(thread, NULL);
    if (n != 1 || out[0].data.u64 != 4 || waited < 50) {
        printf("n=%d waited %ld ms\n", n, waited);
        return fail("blocking wake");
    }
    if (read(p[0], &byte, 1) != 1) { return fail("drain w"); }
    printf("blocking ok (%ld ms)\n", waited);

    // A signal interrupts the wait with EINTR, even with SA_RESTART.
    struct sigaction action;
    memset(&action, 0, sizeof action);
    action.sa_handler = nothing;
    action.sa_flags = SA_RESTART;
    sigaction(SIGUSR1, &action, NULL);
    main_thread = pthread_self();
    if (pthread_create(&thread, NULL, interrupter, NULL)) { return fail("pthread_create 2"); }
    n = epoll_wait(ep, out, 4, 5000);
    int saved = errno;
    pthread_join(thread, NULL);
    if (n != -1 || saved != EINTR) { printf("n=%d\n", n); errno = saved; return fail("EINTR"); }

    // Closing the write end reports EPOLLHUP on the read end.
    close(p[1]);
    n = epoll_wait(ep, out, 4, 0);
    if (n != 1 || !(out[0].events & EPOLLHUP)) {
        printf("n=%d events=%#x\n", n, n > 0 ? out[0].events : 0);
        return fail("EPOLLHUP");
    }
    // A closed descriptor drops out of the results.
    close(p[0]);
    if (epoll_wait(ep, out, 4, 0) != 0) { return fail("closed fd"); }
    close(ep);
    close(ep2);
    printf("PASS\n");
    return 0;
}
