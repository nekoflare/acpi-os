// Socket options, shutdown and socket ioctls on AF_INET sockets (NETPLAN
// S3): getsockopt/setsockopt at SOL_SOCKET and IPPROTO_TCP, SO_REUSEADDR
// binds, shutdown on UDP, FIONREAD, SIOCOUTQ and FIONBIO. Uses the host
// echo server at 10.0.2.2.
// net
// udp-echo
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef SIOCOUTQ
#define SIOCOUTQ TIOCOUTQ
#endif
#ifndef POLLRDHUP
#define POLLRDHUP 0x2000
#endif

static int failed;

#define CHECK(cond)                                                          \
    do {                                                                     \
        if (!(cond)) {                                                       \
            printf("FAIL line %d: %s (errno %d)\n", __LINE__, #cond, errno); \
            failed = 1;                                                      \
        }                                                                    \
    } while (0)

static struct sockaddr_in addr(const char *ip, int port)
{
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    inet_pton(AF_INET, ip, &a.sin_addr);
    return a;
}

static int bind_to(int fd, const char *ip, int port)
{
    struct sockaddr_in a = addr(ip, port);
    return bind(fd, (struct sockaddr *)&a, sizeof a);
}

static int fails_with(long ret, int err)
{
    return ret == -1 && errno == err;
}

// The int option level/name of fd, or -1000 on failure.
static int get_int(int fd, int level, int name)
{
    int v = -1;
    socklen_t len = sizeof v;
    if (getsockopt(fd, level, name, &v, &len) || len != sizeof v)
        return -1000;
    return v;
}

static int set_int(int fd, int level, int name, int v)
{
    return setsockopt(fd, level, name, &v, sizeof v);
}

static int revents(int fd)
{
    struct pollfd p = {fd, POLLIN | POLLOUT | POLLRDHUP, 0};
    return poll(&p, 1, 0) == 1 ? p.revents : 0;
}

static int readable(int fd)
{
    struct pollfd p = {fd, POLLIN, 0};
    return poll(&p, 1, 2000) == 1 ? p.revents : 0;
}

int main(void)
{
    FILE *f = fopen("/etc/udp-echo-port", "r");
    int port = 0;
    if (!f || fscanf(f, "%d", &port) != 1) {
        puts("FAIL no /etc/udp-echo-port");
        return 1;
    }
    fclose(f);
    struct sockaddr_in echo = addr("10.0.2.2", port);
    char buf[64];

    int u = socket(AF_INET, SOCK_DGRAM, 0);
    int t = socket(AF_INET, SOCK_STREAM, 0);
    CHECK(u >= 0 && t >= 0);

    // Queries.
    CHECK(get_int(u, SOL_SOCKET, SO_TYPE) == SOCK_DGRAM);
    CHECK(get_int(t, SOL_SOCKET, SO_TYPE) == SOCK_STREAM);
    CHECK(get_int(u, SOL_SOCKET, SO_DOMAIN) == AF_INET);
    CHECK(get_int(u, SOL_SOCKET, SO_PROTOCOL) == IPPROTO_UDP);
    CHECK(get_int(t, SOL_SOCKET, SO_PROTOCOL) == IPPROTO_TCP);
    CHECK(get_int(u, SOL_SOCKET, SO_ERROR) == 0);
    CHECK(get_int(t, SOL_SOCKET, SO_ACCEPTCONN) == 0);
    CHECK(get_int(u, SOL_SOCKET, SO_RCVBUF) == 212992);
    CHECK(get_int(t, SOL_SOCKET, SO_SNDBUF) == 16384);
    CHECK(get_int(t, SOL_SOCKET, SO_RCVBUF) == 131072);

    // A short length truncates; a negative one is invalid.
    unsigned char c = 0xAA;
    socklen_t len = 1;
    CHECK(getsockopt(u, SOL_SOCKET, SO_TYPE, &c, &len) == 0 && len == 1 && c == SOCK_DGRAM);
    int v = 0;
    len = (socklen_t)-1;
    CHECK(fails_with(getsockopt(u, SOL_SOCKET, SO_TYPE, &v, &len), EINVAL));
    len = sizeof v;
    CHECK(fails_with(getsockopt(u, SOL_SOCKET, SO_TYPE, (void *)8, &len), EFAULT));
    CHECK(fails_with(getsockopt(u, SOL_SOCKET, 9999, &v, &len), ENOPROTOOPT));
    CHECK(fails_with(getsockopt(u, SOL_IP, IP_TTL, &v, &len), ENOPROTOOPT));
    CHECK(fails_with(getsockopt(u, IPPROTO_TCP, TCP_NODELAY, &v, &len), ENOPROTOOPT));

    // Booleans read back as 0 or 1.
    CHECK(get_int(t, SOL_SOCKET, SO_KEEPALIVE) == 0);
    CHECK(set_int(t, SOL_SOCKET, SO_KEEPALIVE, 5) == 0);
    CHECK(get_int(t, SOL_SOCKET, SO_KEEPALIVE) == 1);
    CHECK(set_int(t, SOL_SOCKET, SO_KEEPALIVE, 0) == 0);
    CHECK(get_int(t, SOL_SOCKET, SO_KEEPALIVE) == 0);
    CHECK(set_int(u, SOL_SOCKET, SO_BROADCAST, 1) == 0);
    CHECK(get_int(u, SOL_SOCKET, SO_BROADCAST) == 1);
    CHECK(get_int(u, SOL_SOCKET, SO_REUSEADDR) == 0);

    // Buffer sizes are doubled and clamped like Linux.
    CHECK(set_int(u, SOL_SOCKET, SO_RCVBUF, 65536) == 0);
    CHECK(get_int(u, SOL_SOCKET, SO_RCVBUF) == 131072);
    CHECK(set_int(u, SOL_SOCKET, SO_SNDBUF, 1) == 0);
    CHECK(get_int(u, SOL_SOCKET, SO_SNDBUF) == 4608);
    CHECK(set_int(u, SOL_SOCKET, SO_SNDBUF, 1 << 30) == 0);
    CHECK(get_int(u, SOL_SOCKET, SO_SNDBUF) == 425984);

    // Lengths and bad options.
    CHECK(fails_with(setsockopt(u, SOL_SOCKET, SO_KEEPALIVE, &v, 2), EINVAL));
    v = 1;
    CHECK(fails_with(setsockopt(u, SOL_SOCKET, SO_KEEPALIVE, (void *)8, sizeof v), EFAULT));
    CHECK(fails_with(set_int(u, SOL_SOCKET, 9999, 1), ENOPROTOOPT));
    CHECK(fails_with(set_int(u, IPPROTO_TCP, TCP_NODELAY, 1), ENOPROTOOPT));
    CHECK(fails_with(set_int(u, SOL_IP, IP_MULTICAST_ALL, 0), ENOPROTOOPT));

    // SO_LINGER.
    struct linger l = {1, 7};
    CHECK(fails_with(setsockopt(t, SOL_SOCKET, SO_LINGER, &l, 4), EINVAL));
    CHECK(setsockopt(t, SOL_SOCKET, SO_LINGER, &l, sizeof l) == 0);
    memset(&l, 0xAA, sizeof l);
    len = sizeof l;
    CHECK(getsockopt(t, SOL_SOCKET, SO_LINGER, &l, &len) == 0 && len == sizeof l &&
          l.l_onoff == 1 && l.l_linger == 7);
    l.l_onoff = 0;
    l.l_linger = 99;
    CHECK(setsockopt(t, SOL_SOCKET, SO_LINGER, &l, sizeof l) == 0);
    len = sizeof l;
    CHECK(getsockopt(t, SOL_SOCKET, SO_LINGER, &l, &len) == 0 && l.l_onoff == 0 &&
          l.l_linger == 7);

    // TCP options, as curl sets them.
    CHECK(get_int(t, IPPROTO_TCP, TCP_NODELAY) == 0);
    CHECK(set_int(t, IPPROTO_TCP, TCP_NODELAY, 1) == 0);
    CHECK(get_int(t, IPPROTO_TCP, TCP_NODELAY) == 1);
    CHECK(get_int(t, IPPROTO_TCP, TCP_KEEPIDLE) == 7200);
    CHECK(get_int(t, IPPROTO_TCP, TCP_KEEPINTVL) == 75);
    CHECK(get_int(t, IPPROTO_TCP, TCP_KEEPCNT) == 9);
    CHECK(set_int(t, IPPROTO_TCP, TCP_KEEPIDLE, 60) == 0);
    CHECK(set_int(t, IPPROTO_TCP, TCP_KEEPINTVL, 60) == 0);
    CHECK(set_int(t, IPPROTO_TCP, TCP_KEEPCNT, 3) == 0);
    CHECK(get_int(t, IPPROTO_TCP, TCP_KEEPIDLE) == 60);
    CHECK(get_int(t, IPPROTO_TCP, TCP_KEEPINTVL) == 60);
    CHECK(get_int(t, IPPROTO_TCP, TCP_KEEPCNT) == 3);
    CHECK(fails_with(set_int(t, IPPROTO_TCP, TCP_KEEPIDLE, 0), EINVAL));
    CHECK(fails_with(set_int(t, IPPROTO_TCP, TCP_KEEPINTVL, -1), EINVAL));
    CHECK(fails_with(set_int(t, IPPROTO_TCP, TCP_KEEPCNT, 128), EINVAL));
    CHECK(get_int(t, IPPROTO_TCP, TCP_MAXSEG) == 536);
    CHECK(fails_with(set_int(t, IPPROTO_TCP, TCP_MAXSEG, 10), EINVAL));
    CHECK(set_int(t, IPPROTO_TCP, TCP_MAXSEG, 1000) == 0);
    CHECK(get_int(t, IPPROTO_TCP, TCP_MAXSEG) == 1000);

    // Non-sockets and bad descriptors.
    CHECK(fails_with(getsockopt(0, SOL_SOCKET, SO_TYPE, &v, &len), ENOTSOCK));
    CHECK(fails_with(setsockopt(999, SOL_SOCKET, SO_TYPE, &v, sizeof v), EBADF));
    CHECK(fails_with(shutdown(0, SHUT_RD), ENOTSOCK));

    // SO_REUSEADDR on both sockets allows a shared port.
    int r1 = socket(AF_INET, SOCK_DGRAM, 0), r2 = socket(AF_INET, SOCK_DGRAM, 0);
    CHECK(bind_to(r1, "0.0.0.0", 6000) == 0);
    CHECK(set_int(r2, SOL_SOCKET, SO_REUSEADDR, 1) == 0);
    CHECK(fails_with(bind_to(r2, "0.0.0.0", 6000), EADDRINUSE));
    close(r1);
    r1 = socket(AF_INET, SOCK_DGRAM, 0);
    CHECK(set_int(r1, SOL_SOCKET, SO_REUSEADDR, 1) == 0);
    CHECK(bind_to(r1, "0.0.0.0", 6000) == 0);
    CHECK(bind_to(r2, "0.0.0.0", 6000) == 0);
    close(r1);
    close(r2);

    // FIONREAD reports the next datagram; SIOCOUTQ is empty.
    int n = -1;
    CHECK(ioctl(u, FIONREAD, &n) == 0 && n == 0);
    CHECK(sendto(u, "first", 5, 0, (struct sockaddr *)&echo, sizeof echo) == 5);
    CHECK(readable(u) == POLLIN);
    CHECK(sendto(u, "second!", 7, 0, (struct sockaddr *)&echo, sizeof echo) == 7);
    CHECK(ioctl(u, FIONREAD, &n) == 0 && n == 5);
    CHECK(ioctl(u, SIOCOUTQ, &n) == 0 && n == 0);
    CHECK(recv(u, buf, sizeof buf, 0) == 5);
    CHECK(readable(u) == POLLIN);
    CHECK(ioctl(u, FIONREAD, &n) == 0 && n == 7);
    CHECK(recv(u, buf, sizeof buf, 0) == 7);
    CHECK(fails_with(ioctl(u, FIONREAD, (void *)8), EFAULT));
    CHECK(ioctl(t, FIONREAD, &n) == 0 && n == 0);

    // Sockets are not terminals.
    CHECK(!isatty(u));

    // FIONBIO matches fcntl.
    int on = 1;
    CHECK(ioctl(u, FIONBIO, &on) == 0 && (fcntl(u, F_GETFL) & O_NONBLOCK));
    CHECK(fails_with(recv(u, buf, sizeof buf, 0), EAGAIN));
    on = 0;
    CHECK(ioctl(u, FIONBIO, &on) == 0 && !(fcntl(u, F_GETFL) & O_NONBLOCK));

    // SO_ERROR reports and clears a pending ICMP error.
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in discard = addr("10.0.2.2", 9);
    CHECK(connect(s, (struct sockaddr *)&discard, sizeof discard) == 0);
    CHECK(send(s, "x", 1, 0) == 1);
    CHECK(readable(s) & POLLERR);
    CHECK(get_int(s, SOL_SOCKET, SO_ERROR) == ECONNREFUSED);
    CHECK(get_int(s, SOL_SOCKET, SO_ERROR) == 0);
    CHECK(!(revents(s) & POLLERR));
    close(s);

    // shutdown: unconnected sockets record it but report ENOTCONN.
    CHECK(fails_with(shutdown(u, 3), EINVAL));
    CHECK(fails_with(shutdown(t, SHUT_RDWR), ENOTCONN));
    s = socket(AF_INET, SOCK_DGRAM, 0);
    CHECK(fails_with(shutdown(s, SHUT_WR), ENOTCONN));
    CHECK(fails_with(sendto(s, "x", 1, 0, (struct sockaddr *)&echo, sizeof echo), EPIPE));
    close(s);

    // A connected socket: SHUT_RD leaves queued data readable, then a
    // blocking receive returns 0 while a nonblocking one fails with EAGAIN.
    s = socket(AF_INET, SOCK_DGRAM, 0);
    CHECK(connect(s, (struct sockaddr *)&echo, sizeof echo) == 0);
    CHECK(revents(s) == POLLOUT);
    CHECK(send(s, "queued", 6, 0) == 6);
    CHECK(readable(s) == POLLIN);
    CHECK(shutdown(s, SHUT_RD) == 0);
    CHECK(revents(s) == (POLLIN | POLLOUT | POLLRDHUP));
    CHECK(recv(s, buf, sizeof buf, 0) == 6 && !memcmp(buf, "queued", 6));
    CHECK(recv(s, buf, sizeof buf, 0) == 0);
    CHECK(read(s, buf, sizeof buf) == 0);
    CHECK(fails_with(recv(s, buf, sizeof buf, MSG_DONTWAIT), EAGAIN));
    CHECK(send(s, "still", 5, 0) == 5); // Sending still works.
    CHECK(shutdown(s, SHUT_WR) == 0);
    CHECK(revents(s) == (POLLIN | POLLOUT | POLLRDHUP | POLLHUP));
    CHECK(fails_with(send(s, "x", 1, 0), EPIPE));
    close(s);

    // shutdown from another process wakes a blocked receive.
    s = socket(AF_INET, SOCK_DGRAM, 0);
    CHECK(connect(s, (struct sockaddr *)&echo, sizeof echo) == 0);
    pid_t pid = fork();
    if (pid == 0) {
        usleep(200000);
        _exit(shutdown(s, SHUT_RD) == 0 ? 0 : 1);
    }
    CHECK(recv(s, buf, sizeof buf, 0) == 0);
    int status = -1;
    CHECK(waitpid(pid, &status, 0) == pid && status == 0);
    close(s);

    close(u);
    close(t);
    if (!failed)
        puts("PASS");
    return failed;
}
