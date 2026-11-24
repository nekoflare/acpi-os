// TCP teardown (NETPLAN T4) through slirp: the peer closing first (EOF,
// CLOSE_WAIT, then our close through LAST_ACK), half-close with
// shutdown(SHUT_WR), a reset from the peer (ECONNRESET once, then EOF and
// EPIPE), EPIPE with SIGPIPE and MSG_NOSIGNAL, a reset when closing with
// unread data or SO_LINGER 0, an orphan that still delivers everything
// after close, and every socket reclaimed afterwards.
// net
// tcp-server
// timeout: 90
#include "tcp-common.h"
#include <signal.h>

static volatile int sigpipes;
static void on_sigpipe(int sig) { (void)sig; sigpipes++; }

static int tcp_sockets(void)
{
    FILE *f = fopen("/proc/net/tcp", "r");
    char line[256];
    int n = -1;
    if (!f) return -2;
    while (fgets(line, sizeof line, f)) n++;
    fclose(f);
    return n;
}

static int tcp_state(int port)
{
    FILE *f = fopen("/proc/net/tcp", "r");
    char line[256];
    int state = -1;
    if (!f) return -2;
    while (fgets(line, sizeof line, f)) {
        unsigned sl, la, lp, ra, rp, st;
        if (sscanf(line, " %u: %x:%x %x:%x %x", &sl, &la, &lp, &ra, &rp, &st) == 6 && (int)lp == port) state = st;
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

static char big[1 << 20];

int main(void)
{
    read_ports();
    signal(SIGPIPE, on_sigpipe);
    char buf[256];
    CHECK(tcp_sockets() == 0);

    // The peer closes first: data, then EOF (POLLIN | POLLRDHUP) in
    // CLOSE_WAIT; we may still send until its reset says it is gone.
    int s = connect_to(HOST, server_port);
    int port = local_port(s);
    CHECK(send_line(s, "send 10\n") == 0);
    CHECK(recv(s, buf, sizeof buf, MSG_WAITALL) == 10);
    CHECK(recv(s, buf, sizeof buf, 0) == 0);
    CHECK(recv(s, buf, sizeof buf, 0) == 0);
    CHECK(revents(s) == (POLLIN | POLLOUT | POLLRDHUP));
    CHECK(tcp_state(port) == 8); // CLOSE_WAIT
    // Writes to the closed host socket draw a reset (slirp sends it once
    // the host refuses a second write); the first failure is ECONNRESET.
    int sent = 0;
    while (sent < 100 && send(s, "late\n", 5, MSG_NOSIGNAL) == 5) {
        sent++;
        usleep(50000);
    }
    CHECK(sent >= 1 && sent < 100 && errno == ECONNRESET);
    CHECK((revents(s) & (POLLERR | POLLHUP)) == POLLHUP); // the error was reported
    CHECK(fails_with(send(s, "x", 1, 0), EPIPE) && sigpipes == 1);
    CHECK(fails_with(send(s, "x", 1, MSG_NOSIGNAL), EPIPE) && sigpipes == 1);
    CHECK(recv(s, buf, 1, 0) == 0);
    close(s);
    CHECK(tcp_state(port) == -1);

    // Closing in CLOSE_WAIT goes through LAST_ACK and frees the socket.
    s = connect_to(HOST, server_port);
    port = local_port(s);
    CHECK(send_line(s, "send 3\n") == 0);
    CHECK(recv(s, buf, sizeof buf, MSG_WAITALL) == 3 && recv(s, buf, 1, 0) == 0);
    close(s);
    usleep(200000);
    CHECK(tcp_state(port) == -1);

    // Half-close: our FIN, then the host's answer and its FIN.
    s = connect_to(HOST, server_port);
    port = local_port(s);
    CHECK(send_line(s, "wait\nsome data\n") == 0);
    CHECK(shutdown(s, SHUT_WR) == 0);
    CHECK(fails_with(send(s, "x", 1, 0), EPIPE) && sigpipes == 2);
    CHECK(read_line(s, buf, sizeof buf) == 4 && !strcmp(buf, "bye\n"));
    CHECK(recv(s, buf, 1, 0) == 0);
    usleep(100000);
    CHECK(tcp_state(port) == 6); // TIME_WAIT
    CHECK(revents(s) == (POLLIN | POLLOUT | POLLRDHUP | POLLHUP));
    close(s);

    // A reset from the host: ECONNRESET once, then end of file.
    s = connect_to(HOST, server_port);
    CHECK(send_line(s, "rst\n") == 0);
    CHECK((wait_for(s, POLLIN, 3000) & (POLLERR | POLLHUP | POLLIN)) == (POLLERR | POLLHUP | POLLIN));
    CHECK(fails_with(recv(s, buf, 1, 0), ECONNRESET));
    CHECK(recv(s, buf, 1, 0) == 0);
    CHECK(get_int(s, SOL_SOCKET, SO_ERROR) == 0);
    close(s);

    // Unread data at close: a reset instead of a FIN, as on Linux.
    long rsts = snmp("OutRsts");
    s = connect_to(HOST, server_port);
    CHECK(send_line(s, "echo\nunread\n") == 0);
    CHECK(wait_for(s, POLLIN, 3000) & POLLIN);
    close(s);
    CHECK(snmp("OutRsts") == rsts + 1);
    // SO_LINGER with a zero timeout resets too.
    s = connect_to(HOST, server_port);
    struct linger lg = {1, 0};
    CHECK(setsockopt(s, SOL_SOCKET, SO_LINGER, &lg, sizeof lg) == 0);
    close(s);
    CHECK(snmp("OutRsts") == rsts + 2);

    // An orphan finishes sending 3 MB after close() returns.
    s = connect_to(HOST, server_port);
    CHECK(send_line(s, "sinklog orphan\n") == 0);
    uint32_t crc = 0;
    for (size_t off = 0; off < 3u << 20; off += sizeof big) {
        for (size_t i = 0; i < sizeof big; i++) big[i] = pat(off + i);
        crc = crc32_update(crc, big, sizeof big);
        CHECK(send_all(s, big, sizeof big) == 0);
    }
    close(s);
    char want[64];
    snprintf(want, sizeof want, "%u %08x\n", 3u << 20, crc);
    for (int i = 0; i < 50; i++) {
        s = connect_to(HOST, server_port);
        CHECK(send_line(s, "query orphan\n") == 0 && read_line(s, buf, sizeof buf) > 0);
        close(s);
        if (strcmp(buf, "pending\n")) break;
        usleep(100000);
    }
    CHECK(!strcmp(buf, want));

    // Many short connections: all of them are reclaimed once TIME_WAIT ends.
    for (int i = 0; i < 100; i++) {
        s = connect_to(HOST, server_port);
        CHECK(s >= 0 && send_line(s, "send 1\n") == 0 && recv(s, buf, 2, MSG_WAITALL) == 1);
        close(s);
    }
    sleep(6);
    CHECK(tcp_sockets() == 0);
    if (tcp_sockets()) system("cat /proc/net/tcp");

    if (failed) return 1;
    printf("PASS\n");
    return 0;
}
