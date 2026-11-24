// UDP sockets (NETPLAN S2) against a host echo server at 10.0.2.2: sendto,
// recvfrom, connect, send/recv/read/write, readv/writev, sendmsg/recvmsg,
// MSG_PEEK/MSG_TRUNC/MSG_DONTWAIT, blocking receives woken by the NIC's
// interrupt, poll and epoll readiness, and ECONNREFUSED from an ICMP port
// unreachable on a connected socket.
// net
// udp-echo
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <unistd.h>

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

static int fails_with(long ret, int err)
{
    return ret == -1 && errno == err;
}

// Wait up to two seconds for POLLIN (or an error) on fd.
static int readable(int fd)
{
    struct pollfd p = {fd, POLLIN, 0};
    return poll(&p, 1, 2000) == 1 ? p.revents : 0;
}

// Transmit packet count of interface name from /proc/net/dev.
static long tx_packets(const char *name)
{
    FILE *f = fopen("/proc/net/dev", "r");
    char line[256], key[16];
    long packets = -1;
    snprintf(key, sizeof key, "%s:", name);
    while (f && fgets(line, sizeof line, f)) {
        char *p = strstr(line, key);
        if (p && sscanf(p + strlen(key), "%*d %*d %*d %*d %*d %*d %*d %*d %*d %ld", &packets) == 1)
            break;
    }
    if (f)
        fclose(f);
    return packets;
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
    char buf[2048];
    static char big[65536], back[65536];
    for (int i = 0; i < (int)sizeof big; i++)
        big[i] = i * 7 ^ i >> 8;

    // Unconnected: sendto binds an ephemeral port; recvfrom names the sender.
    int u = socket(AF_INET, SOCK_DGRAM, 0);
    CHECK(fails_with(send(u, "x", 1, 0), EDESTADDRREQ));
    CHECK(fails_with(recv(u, buf, sizeof buf, MSG_DONTWAIT), EAGAIN));
    CHECK(sendto(u, "hello", 5, 0, (struct sockaddr *)&echo, sizeof echo) == 5);
    struct sockaddr_in local;
    socklen_t len = sizeof local;
    CHECK(getsockname(u, (struct sockaddr *)&local, &len) == 0 &&
          ntohs(local.sin_port) >= 32768 && local.sin_addr.s_addr == 0);
    CHECK(readable(u) == POLLIN);
    struct sockaddr_in from;
    memset(&from, 0, sizeof from);
    len = sizeof from;
    CHECK(recvfrom(u, buf, 3, MSG_PEEK, (struct sockaddr *)&from, &len) == 3 &&
          !memcmp(buf, "hel", 3));
    CHECK(len == sizeof from && from.sin_family == AF_INET &&
          from.sin_port == echo.sin_port && from.sin_addr.s_addr == echo.sin_addr.s_addr);
    CHECK(recv(u, buf, 2, MSG_PEEK | MSG_TRUNC) == 5);
    memset(buf, 0, sizeof buf);
    CHECK(recvfrom(u, buf, sizeof buf, 0, NULL, NULL) == 5 && !memcmp(buf, "hello", 5));
    CHECK(fails_with(recv(u, buf, sizeof buf, MSG_DONTWAIT), EAGAIN));

    // A blocking receive sleeps until the echo arrives.
    CHECK(sendto(u, "again", 5, 0, (struct sockaddr *)&echo, sizeof echo) == 5);
    CHECK(recv(u, buf, sizeof buf, 0) == 5 && !memcmp(buf, "again", 5));

    // Datagram boundaries and truncation.
    CHECK(sendto(u, "one", 3, 0, (struct sockaddr *)&echo, sizeof echo) == 3);
    CHECK(sendto(u, "twotwo", 6, 0, (struct sockaddr *)&echo, sizeof echo) == 6);
    CHECK(recv(u, buf, sizeof buf, 0) == 3 && !memcmp(buf, "one", 3));
    CHECK(recv(u, buf, 2, 0) == 2 && !memcmp(buf, "tw", 2));
    CHECK(fails_with(recv(u, buf, sizeof buf, MSG_DONTWAIT), EAGAIN));

    // Payloads up to 65507 bytes: more than 1472 go out as IP fragments,
    // which slirp reassembles; its echo comes back fragmented and is
    // reassembled here.
    static const int sizes[] = {1472, 1473, 1480, 1481, 2952, 2953, 8000, 30001, 65507};
    for (int i = 0; i < (int)(sizeof sizes / sizeof *sizes); i++) {
        int n = sizes[i];
        long tx = tx_packets("eth0");
        CHECK(sendto(u, big + i, n, 0, (struct sockaddr *)&echo, sizeof echo) == n);
        // 1480 bytes of IP payload per frame, the 8-byte UDP header included.
        long frames = tx_packets("eth0") - tx;
        if (frames != (n + 8 + 1479) / 1480)
            printf("FAIL %d bytes took %ld frames\n", n, frames), failed = 1;
        memset(back, 0, n);
        int r = recv(u, back, sizeof back, 0);
        if (r != n || memcmp(back, big + i, n))
            printf("FAIL %d bytes came back as %d\n", n, r), failed = 1;
    }
    CHECK(fails_with(sendto(u, big, 65508, 0, (struct sockaddr *)&echo, sizeof echo), EMSGSIZE));
    // A big datagram truncated by a small buffer still reports its length.
    CHECK(sendto(u, big, 40000, 0, (struct sockaddr *)&echo, sizeof echo) == 40000);
    CHECK(readable(u) == POLLIN);
    int avail = 0;
    CHECK(ioctl(u, FIONREAD, &avail) == 0 && avail == 40000);
    CHECK(recv(u, buf, 100, MSG_TRUNC) == 40000 && !memcmp(buf, big, 100));
    CHECK(fails_with(recv(u, buf, sizeof buf, MSG_DONTWAIT), EAGAIN));

    // sendmsg gathers one datagram; recvmsg scatters it and flags truncation.
    struct iovec iov[2] = {{"ab", 2}, {"cdef", 4}};
    struct msghdr m;
    memset(&m, 0, sizeof m);
    m.msg_name = &echo;
    m.msg_namelen = sizeof echo;
    m.msg_iov = iov;
    m.msg_iovlen = 2;
    CHECK(sendmsg(u, &m, 0) == 6);
    char p1[2], p2[3];
    struct iovec riov[2] = {{p1, 2}, {p2, 3}};
    memset(&m, 0, sizeof m);
    memset(&from, 0, sizeof from);
    m.msg_name = &from;
    m.msg_namelen = sizeof from;
    m.msg_iov = riov;
    m.msg_iovlen = 2;
    m.msg_controllen = 99;
    CHECK(recvmsg(u, &m, 0) == 5);
    CHECK(!memcmp(p1, "ab", 2) && !memcmp(p2, "cde", 3));
    CHECK(m.msg_flags == MSG_TRUNC && m.msg_controllen == 0 &&
          m.msg_namelen == sizeof from && from.sin_port == echo.sin_port);

    // Connected: send/recv, write/read, writev/readv.
    int c = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK, 0);
    CHECK(fails_with(recv(c, buf, sizeof buf, 0), EAGAIN));
    CHECK(connect(c, (struct sockaddr *)&echo, sizeof echo) == 0);
    struct sockaddr_in peer;
    len = sizeof peer;
    CHECK(getpeername(c, (struct sockaddr *)&peer, &len) == 0 &&
          peer.sin_port == echo.sin_port && peer.sin_addr.s_addr == echo.sin_addr.s_addr);
    len = sizeof local;
    CHECK(getsockname(c, (struct sockaddr *)&local, &len) == 0 &&
          ntohs(local.sin_port) >= 32768 && ntohl(local.sin_addr.s_addr) == 0x0A00020F);
    CHECK(send(c, "conn", 4, 0) == 4);
    CHECK(readable(c) == POLLIN);
    CHECK(recv(c, buf, sizeof buf, 0) == 4 && !memcmp(buf, "conn", 4));
    CHECK(write(c, "wr", 2) == 2);
    CHECK(readable(c) == POLLIN);
    CHECK(read(c, buf, sizeof buf) == 2 && !memcmp(buf, "wr", 2));
    CHECK(writev(c, iov, 2) == 6);
    CHECK(readable(c) == POLLIN);
    memset(p1, 0, 2);
    memset(p2, 0, 3);
    CHECK(readv(c, riov, 2) == 5 && !memcmp(p1, "ab", 2) && !memcmp(p2, "cde", 3));

    // epoll reports the arrival.
    int ep = epoll_create1(0);
    struct epoll_event ev = {.events = EPOLLIN, .data.u32 = 7}, out;
    CHECK(epoll_ctl(ep, EPOLL_CTL_ADD, c, &ev) == 0);
    CHECK(epoll_wait(ep, &out, 1, 0) == 0);
    CHECK(send(c, "ep", 2, 0) == 2);
    CHECK(epoll_wait(ep, &out, 1, 2000) == 1 && out.data.u32 == 7 && (out.events & EPOLLIN));
    CHECK(recv(c, buf, sizeof buf, 0) == 2);
    close(ep);

    // Disconnect with AF_UNSPEC.
    struct sockaddr unspec = {.sa_family = AF_UNSPEC};
    CHECK(connect(c, &unspec, sizeof unspec) == 0);
    len = sizeof peer;
    CHECK(fails_with(getpeername(c, (struct sockaddr *)&peer, &len), ENOTCONN));
    CHECK(fails_with(send(c, "x", 1, 0), EDESTADDRREQ));
    close(c);

    // A connected socket learns of the closed discard port as ECONNREFUSED,
    // once; an unconnected one does not.
    struct sockaddr_in discard = addr("10.0.2.2", 9);
    c = socket(AF_INET, SOCK_DGRAM, 0);
    CHECK(connect(c, (struct sockaddr *)&discard, sizeof discard) == 0);
    CHECK(send(c, "x", 1, 0) == 1);
    CHECK(readable(c) & POLLERR);
    CHECK(fails_with(recv(c, buf, sizeof buf, MSG_DONTWAIT), ECONNREFUSED));
    CHECK(fails_with(recv(c, buf, sizeof buf, MSG_DONTWAIT), EAGAIN));
    CHECK(send(c, "x", 1, 0) == 1);
    CHECK(readable(c) & POLLERR);
    CHECK(fails_with(send(c, "x", 1, 0), ECONNREFUSED));
    close(c);
    CHECK(sendto(u, "x", 1, 0, (struct sockaddr *)&discard, sizeof discard) == 1);
    struct pollfd pu = {u, POLLIN, 0};
    CHECK(poll(&pu, 1, 300) == 0);

    close(u);

    // Our own eth0 address is local: datagrams to it go over lo, from it,
    // and never reach the NIC (NETPLAN S6).
    int r = socket(AF_INET, SOCK_DGRAM, 0), l = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in self = addr("10.0.2.15", 0);
    CHECK(bind(r, (struct sockaddr *)&self, sizeof self) == 0);
    socklen_t slen = sizeof self;
    CHECK(getsockname(r, (struct sockaddr *)&self, &slen) == 0);
    long eth0 = tx_packets("eth0"), lo = tx_packets("lo");
    CHECK(sendto(l, "self", 4, 0, (struct sockaddr *)&self, sizeof self) == 4);
    struct sockaddr_in src;
    slen = sizeof src;
    CHECK(recvfrom(r, buf, sizeof buf, MSG_DONTWAIT, (struct sockaddr *)&src, &slen) == 4 &&
          ntohl(src.sin_addr.s_addr) == 0x0A00020F);
    CHECK(tx_packets("eth0") == eth0 && tx_packets("lo") == lo + 1);
    // lo addresses cannot leave the host.
    close(l);
    l = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in lo1 = addr("127.0.0.1", 0);
    CHECK(bind(l, (struct sockaddr *)&lo1, sizeof lo1) == 0);
    CHECK(fails_with(sendto(l, "x", 1, 0, (struct sockaddr *)&discard, sizeof discard), EINVAL));
    close(r);
    close(l);

    // send() on a connected AF_UNIX stream goes through sendto.
    int sv[2];
    CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
    CHECK(send(sv[0], "unix", 4, 0) == 4);
    CHECK(recv(sv[1], buf, sizeof buf, 0) == 4 && !memcmp(buf, "unix", 4));
    close(sv[0]);
    close(sv[1]);

    if (!failed)
        puts("PASS");
    return failed;
}
