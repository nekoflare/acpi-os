// D4: AF_INET6 and other unsupported families fail cleanly (AF_INET works
// since NETPLAN S1), localhost resolves from /etc/hosts
// without DNS, and eventfd works the way the JDK's NIO Selector uses it.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static int fail(const char *what)
{
    printf("FAIL %s errno=%d\n", what, errno);
    return 1;
}

static long long now_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000000LL + ts.tv_nsec / 1000;
}

static int efd;
static volatile long long written_at;

static void *late_write(void *arg)
{
    struct timespec ts = {0, (long)(intptr_t)arg * 1000000L};
    nanosleep(&ts, NULL);
    uint64_t one = 1;
    written_at = now_us();
    if (write(efd, &one, 8) != 8) { return (void *)1; }
    return NULL;
}

int main(void)
{
    // Families without support.
    int families[] = {AF_INET6, AF_NETLINK, AF_PACKET};
    int types[] = {SOCK_STREAM, SOCK_DGRAM, SOCK_RAW};
    for (unsigned f = 0; f < sizeof families / sizeof *families; f++) {
        for (unsigned t = 0; t < sizeof types / sizeof *types; t++) {
            if (socket(families[f], types[t] | SOCK_CLOEXEC, 0) >= 0 || errno != EAFNOSUPPORT) {
                printf("family %d type %d\n", families[f], types[t]);
                return fail("EAFNOSUPPORT");
            }
        }
    }
    int sv[2];
    if (socketpair(AF_INET, SOCK_STREAM, 0, sv) == 0 || errno != EAFNOSUPPORT) { return fail("socketpair inet"); }
    int unix_socket = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (unix_socket < 0) { return fail("AF_UNIX still works"); }
    close(unix_socket);
    printf("socket errors ok\n");

    // localhost resolves from /etc/hosts; with no NIC other names fail after
    // musl's DNS timeout.
    struct addrinfo hints = {.ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM}, *result;
    int rc = getaddrinfo("localhost", "25565", &hints, &result);
    if (rc) { printf("getaddrinfo: %s\n", gai_strerror(rc)); return fail("localhost"); }
    int have4 = 0;
    for (struct addrinfo *ai = result; ai; ai = ai->ai_next) {
        if (ai->ai_family == AF_INET) {
            struct sockaddr_in *in = (struct sockaddr_in *)ai->ai_addr;
            have4 |= in->sin_addr.s_addr == htonl(INADDR_LOOPBACK) && in->sin_port == htons(25565);
        }
    }
    freeaddrinfo(result);
    if (!have4) { return fail("localhost 127.0.0.1"); }
    long long start = now_us();
    rc = getaddrinfo("example.invalid", NULL, &hints, &result);
    if (rc == 0) { return fail("dns name resolved"); }
    printf("localhost ok, dns fails in %lld ms (%s)\n", (now_us() - start) / 1000, gai_strerror(rc));
    char host[64];
    if (gethostname(host, sizeof host)) { return fail("gethostname"); }

    // eventfd counter semantics.
    if (eventfd(0, 0x40) >= 0 || errno != EINVAL) { return fail("eventfd flags"); }
    efd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    if (efd < 0) { return fail("eventfd"); }
    if (fcntl(efd, F_GETFD) != FD_CLOEXEC || !(fcntl(efd, F_GETFL) & O_NONBLOCK)) { return fail("eventfd flags set"); }
    uint64_t value;
    if (read(efd, &value, 8) >= 0 || errno != EAGAIN) { return fail("empty read"); }
    uint64_t add = 3;
    if (write(efd, &add, 8) != 8 || write(efd, &add, 8) != 8) { return fail("write"); }
    if (read(efd, &value, 8) != 8 || value != 6) { printf("value %llu\n", (unsigned long long)value); return fail("read sum"); }
    if (read(efd, &value, 4) >= 0 || errno != EINVAL) { return fail("short read"); }
    uint64_t bad = UINT64_MAX;
    if (write(efd, &bad, 8) >= 0 || errno != EINVAL) { return fail("write max"); }
    uint64_t big = UINT64_MAX - 1;
    if (write(efd, &big, 8) != 8) { return fail("write big"); }
    if (write(efd, &add, 8) >= 0 || errno != EAGAIN) { return fail("overflow EAGAIN"); }
    struct pollfd pfd = {.fd = efd, .events = POLLIN | POLLOUT};
    if (poll(&pfd, 1, 0) != 1 || pfd.revents != POLLIN) { printf("revents %#x\n", pfd.revents); return fail("poll full"); }
    if (read(efd, &value, 8) != 8 || value != big) { return fail("read big"); }
    if (poll(&pfd, 1, 0) != 1 || pfd.revents != POLLOUT) { printf("revents %#x\n", pfd.revents); return fail("poll empty"); }
    if (eventfd_write(efd, 5) || eventfd_read(efd, &value) || value != 5) { return fail("eventfd_read"); }

    int sem = eventfd(2, EFD_SEMAPHORE | EFD_NONBLOCK);
    if (sem < 0) { return fail("semaphore"); }
    if (read(sem, &value, 8) != 8 || value != 1 || read(sem, &value, 8) != 8 || value != 1) { return fail("semaphore read"); }
    if (read(sem, &value, 8) >= 0 || errno != EAGAIN) { return fail("semaphore empty"); }
    close(sem);
    if (lseek(efd, 0, SEEK_SET) >= 0 && pread(efd, &value, 8, 0) >= 0) { return fail("pread"); }
    printf("counter ok\n");

    // Blocking read after F_SETFL clears O_NONBLOCK.
    if (fcntl(efd, F_SETFL, 0) || (fcntl(efd, F_GETFL) & O_NONBLOCK)) { return fail("F_SETFL"); }
    pthread_t thread;
    if (pthread_create(&thread, NULL, late_write, (void *)(intptr_t)50)) { return fail("pthread_create"); }
    if (read(efd, &value, 8) != 8 || value != 1) { return fail("blocking read"); }
    long long latency = now_us() - written_at;
    pthread_join(thread, NULL);
    printf("blocking read ok (%lld us after the write)\n", latency);

    // Selector.wakeup(): an eventfd write ends epoll_wait promptly.
    int ep = epoll_create1(EPOLL_CLOEXEC);
    struct epoll_event ev = {.events = EPOLLIN, .data.u64 = 42};
    if (ep < 0 || epoll_ctl(ep, EPOLL_CTL_ADD, efd, &ev)) { return fail("epoll eventfd"); }
    if (pthread_create(&thread, NULL, late_write, (void *)(intptr_t)50)) { return fail("pthread_create 2"); }
    struct epoll_event out;
    int n = epoll_wait(ep, &out, 1, 5000);
    latency = now_us() - written_at;
    pthread_join(thread, NULL);
    if (n != 1 || out.data.u64 != 42 || out.events != EPOLLIN) { return fail("epoll wake"); }
    if (latency > 5000) { printf("latency %lld us\n", latency); return fail("epoll wake latency"); }
    printf("epoll wake ok (%lld us after the write)\n", latency);
    if (read(efd, &value, 8) != 8) { return fail("drain"); }
    close(ep);
    close(efd);
    printf("PASS\n");
    return 0;
}
