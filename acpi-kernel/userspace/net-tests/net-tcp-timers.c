// TCP timers (NETPLAN T3), with this kernel's TCP_DBGDROP switch standing in
// for a lossy network: SYN retransmission and ETIMEDOUT under TCP_SYNCNT,
// retransmission with RTO backoff, fast retransmit and go-back-N when
// outgoing segments are lost, recovery from lost incoming data and ACKs,
// zero-window probes against a peer that stops reading, TCP_USER_TIMEOUT,
// keepalive (answered and unanswered), and TIME_WAIT in /proc/net/tcp.
// net
// tcp-server
// timeout: 180
#include "tcp-common.h"

static char big[1 << 20];

// State (Linux's numbering) of the TCP socket bound to local port Arg in
// /proc/net/tcp, or -1 if none.
static int tcp_state(int port)
{
    FILE *f = fopen("/proc/net/tcp", "r");
    char line[256];
    int state = -1;
    if (!f) return -2;
    while (fgets(line, sizeof line, f)) {
        unsigned sl, la, lp, ra, rp, st;
        if (sscanf(line, " %u: %x:%x %x:%x %x", &sl, &la, &lp, &ra, &rp, &st) == 6 && (int)lp == port) {
            state = st;
        }
    }
    fclose(f);
    return state;
}

static int local_port(int s)
{
    struct sockaddr_in a;
    socklen_t len = sizeof a;
    getsockname(s, (struct sockaddr *)&a, &len);
    return ntohs(a.sin_port);
}

// Upload n pattern bytes to the sink and check its verdict.
static int upload(int s, size_t n)
{
    char buf[64], want[64];
    uint32_t crc = 0;
    if (send_line(s, "sink\n")) return 0;
    for (size_t off = 0; off < n; off += sizeof big) {
        size_t k = n - off < sizeof big ? n - off : sizeof big;
        for (size_t i = 0; i < k; i++) big[i] = pat(off + i);
        crc = crc32_update(crc, big, k);
        if (send_all(s, big, k)) return 0;
    }
    if (shutdown(s, SHUT_WR) || read_line(s, buf, sizeof buf) <= 0) return 0;
    snprintf(want, sizeof want, "%zu %08x\n", n, crc);
    if (strcmp(buf, want)) printf("host saw %s", buf);
    return !strcmp(buf, want);
}

static int download(int s, size_t n)
{
    char buf[64];
    size_t got = 0, bad = 0;
    snprintf(buf, sizeof buf, "send %zu\n", n);
    if (send_line(s, buf)) return 0;
    for (;;) {
        ssize_t k = recv(s, big, sizeof big, 0);
        if (k <= 0) break;
        for (ssize_t i = 0; i < k; i++) bad += (unsigned char)big[i] != host_pat(got + i);
        got += k;
    }
    if (got != n || bad) printf("download: %zu of %zu bytes, %zu bad\n", got, n, bad);
    return got == n && !bad;
}

int main(void)
{
    read_ports();
    struct sockaddr_in host = addr_of(HOST, server_port);
    char buf[64];

    // Every SYN lost: with TCP_SYNCNT 1, ETIMEDOUT after 1 + 2 s.
    int s = socket(AF_INET, SOCK_STREAM, 0);
    CHECK(set_int(s, IPPROTO_TCP, TCP_SYNCNT, 1) == 0 && get_int(s, IPPROTO_TCP, TCP_SYNCNT) == 1);
    CHECK(set_int(s, IPPROTO_TCP, TCP_DBGDROP, 1) == 0);
    double t0 = now_s();
    CHECK(fails_with(connect(s, (struct sockaddr *)&host, sizeof host), ETIMEDOUT));
    double took = now_s() - t0;
    CHECK(took > 2.5 && took < 4);
    CHECK(get_int(s, IPPROTO_TCP, TCP_DBGDROP) == 2);
    close(s);
    // The first SYN lost: the retransmitted one connects after 1 s.
    s = socket(AF_INET, SOCK_STREAM, 0);
    CHECK(set_int(s, IPPROTO_TCP, TCP_DBGDROP, 1) == 0);
    int n = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
    CHECK(set_int(n, IPPROTO_TCP, TCP_DBGDROP, 1) == 0);
    CHECK(fails_with(connect(n, (struct sockaddr *)&host, sizeof host), EINPROGRESS));
    CHECK(set_int(n, IPPROTO_TCP, TCP_DBGDROP, 0) == 0);
    t0 = now_s();
    CHECK(wait_for(n, POLLOUT, 5000) == POLLOUT);
    took = now_s() - t0;
    CHECK(took > 0.8 && took < 1.5);
    CHECK(get_int(n, SOL_SOCKET, SO_ERROR) == 0);
    close(n);
    close(s);

    // Lost outgoing data: every 7th segment, then every 3rd.
    long retrans = snmp("RetransSegs");
    s = connect_to(HOST, server_port);
    CHECK(set_int(s, IPPROTO_TCP, TCP_DBGDROP, 7) == 0);
    t0 = now_s();
    CHECK(upload(s, 3000000));
    printf("upload with every 7th segment lost: %.2f s, %d dropped\n", now_s() - t0,
           get_int(s, IPPROTO_TCP, TCP_DBGDROP));
    close(s);
    s = connect_to(HOST, server_port);
    CHECK(set_int(s, IPPROTO_TCP, TCP_DBGDROP, 3) == 0);
    CHECK(upload(s, 1000000));
    close(s);
    CHECK(snmp("RetransSegs") > retrans);

    // Lost incoming data (every 25th segment): what arrives behind a hole
    // waits in the receive ring. slirp's sender (BSD, without limited
    // transmit) often recovers only by its 1 s timeout, so keep this short.
    s = connect_to(HOST, server_port);
    CHECK(set_int(s, IPPROTO_TCP, TCP_DBGDROP, 25 << 16) == 0);
    t0 = now_s();
    CHECK(download(s, 300000));
    printf("download with every 25th segment lost: %.2f s, %d dropped\n", now_s() - t0,
           get_int(s, IPPROTO_TCP, TCP_DBGDROP));
    close(s);
    s = connect_to(HOST, server_port);
    CHECK(set_int(s, IPPROTO_TCP, TCP_DBGDROP, 5 | 4 << 16) == 0);
    CHECK(upload(s, 2000000));
    close(s);

    // A peer that stops reading closes its window; when its window updates
    // are lost, our zero-window probes recover.
    s = connect_to(HOST, server_port);
    CHECK(send_line(s, "slow 3000000\n") == 0);
    CHECK(set_int(s, IPPROTO_TCP, TCP_DBGDROP, 2 << 16) == 0);
    for (size_t i = 0; i < sizeof big; i++) big[i] = pat(i);
    uint32_t crc = 0;
    for (size_t off = 0; off < 3000000; off += 600000) {
        crc = crc32_update(crc, big, 600000);
        CHECK(send_all(s, big, 600000) == 0);
    }
    CHECK(read_line(s, buf, sizeof buf) > 0);
    char want[64];
    snprintf(want, sizeof want, "3000000 %08x\n", crc);
    CHECK(!strcmp(buf, want));
    int probes = get_int(s, IPPROTO_TCP, 0x4E45);
    // slirp usually reopens its window itself; net-tcp-listen forces the
    // probes over lo, where both ends are ours.
    printf("zero window: %d probes\n", probes);
    close(s);

    // TCP_USER_TIMEOUT: unacknowledged data fails the connection.
    s = connect_to(HOST, server_port);
    CHECK(send_line(s, "echo\nx\n") == 0 && read_line(s, buf, sizeof buf) == 2);
    CHECK(set_int(s, IPPROTO_TCP, TCP_USER_TIMEOUT, 1500) == 0);
    CHECK(get_int(s, IPPROTO_TCP, TCP_USER_TIMEOUT) == 1500);
    CHECK(set_int(s, IPPROTO_TCP, TCP_DBGDROP, 1) == 0);
    t0 = now_s();
    CHECK(send(s, "lost\n", 5, 0) == 5);
    CHECK(wait_for(s, POLLIN, 10000) & POLLERR);
    took = now_s() - t0;
    CHECK(took > 1.4 && took < 4);
    CHECK(fails_with(recv(s, buf, 1, 0), ETIMEDOUT));
    CHECK(recv(s, buf, 1, 0) == 0);
    CHECK(fails_with(send(s, "x", 1, MSG_NOSIGNAL), EPIPE));
    close(s);

    // Keepalive probes that slirp answers keep an idle connection up.
    s = connect_to(HOST, server_port);
    CHECK(send_line(s, "echo\n") == 0);
    CHECK(set_int(s, IPPROTO_TCP, TCP_KEEPIDLE, 1) == 0 && set_int(s, IPPROTO_TCP, TCP_KEEPINTVL, 1) == 0);
    CHECK(set_int(s, IPPROTO_TCP, TCP_KEEPCNT, 2) == 0);
    CHECK(set_int(s, SOL_SOCKET, SO_KEEPALIVE, 1) == 0);
    sleep(4);
    CHECK(revents(s) == POLLOUT);
    CHECK(send_line(s, "alive\n") == 0 && read_line(s, buf, sizeof buf) == 6);
    // Unanswered probes end it: idle 1 s, then 2 probes 1 s apart.
    CHECK(set_int(s, IPPROTO_TCP, TCP_DBGDROP, 1) == 0);
    t0 = now_s();
    CHECK(wait_for(s, POLLIN, 10000) & POLLERR);
    took = now_s() - t0;
    CHECK(took > 2.5 && took < 4.5);
    CHECK(get_int(s, SOL_SOCKET, SO_ERROR) == ETIMEDOUT);
    close(s);

    // TIME_WAIT: closing first leaves the socket in TIME_WAIT (6), shown in
    // /proc/net/tcp until it expires after 5 s.
    s = connect_to(HOST, server_port);
    int port = local_port(s);
    CHECK(tcp_state(port) == 1);
    CHECK(send_line(s, "echo\n") == 0);
    CHECK(shutdown(s, SHUT_WR) == 0);
    CHECK(recv(s, buf, 1, 0) == 0);
    usleep(100000);
    CHECK(tcp_state(port) == 6);
    sleep(6);
    CHECK(tcp_state(port) == 7); // closed, still bound while the descriptor lives
    close(s);
    CHECK(tcp_state(port) == -1);
    // An orphan in TIME_WAIT goes away by itself.
    s = connect_to(HOST, server_port);
    port = local_port(s);
    CHECK(send_line(s, "echo\n") == 0 && shutdown(s, SHUT_WR) == 0 && recv(s, buf, 1, 0) == 0);
    close(s);
    usleep(100000);
    CHECK(tcp_state(port) == 6);
    sleep(6);
    CHECK(tcp_state(port) == -1);

    printf("tcp: in %ld out %ld retrans %ld\n", snmp("InSegs"), snmp("OutSegs"), snmp("RetransSegs"));
    if (failed) return 1;
    printf("PASS\n");
    return 0;
}
