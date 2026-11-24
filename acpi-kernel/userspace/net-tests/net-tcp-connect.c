// TCP connection setup (NETPLAN T1): blocking and nonblocking connect to a
// host server through slirp and over lo, the three-way handshake (MSS
// option), ECONNREFUSED from a reset, EHOSTUNREACH when ARP fails, the
// 4-tuple lookup with several connections from one process, and the queries
// that work once connected.
// net
// tcp-server
#include "tcp-common.h"

int main(void)
{
    read_ports();
    struct sockaddr_in host = addr_of(HOST, server_port), got;
    socklen_t len;

    // Before connecting.
    int s = socket(AF_INET, SOCK_STREAM, 0);
    len = sizeof got;
    CHECK(fails_with(getpeername(s, (struct sockaddr *)&got, &len), ENOTCONN));
    CHECK(revents(s) == (POLLOUT | POLLHUP));
    char c;
    CHECK(fails_with(recv(s, &c, 1, 0), ENOTCONN));
    CHECK(fails_with(send(s, "x", 1, MSG_NOSIGNAL), EPIPE));

    // Blocking connect.
    CHECK(connect(s, (struct sockaddr *)&host, sizeof host) == 0);
    len = sizeof got;
    CHECK(getpeername(s, (struct sockaddr *)&got, &len) == 0 && len == 16 &&
          got.sin_addr.s_addr == host.sin_addr.s_addr && got.sin_port == host.sin_port);
    len = sizeof got;
    CHECK(getsockname(s, (struct sockaddr *)&got, &len) == 0 &&
          got.sin_addr.s_addr == htonl(0x0A00020F) && ntohs(got.sin_port) >= 32768);
    CHECK(get_int(s, IPPROTO_TCP, TCP_MAXSEG) == 1460);
    CHECK(revents(s) == POLLOUT);
    CHECK(fails_with(connect(s, (struct sockaddr *)&host, sizeof host), EISCONN));
    CHECK(get_int(s, SOL_SOCKET, SO_ERROR) == 0);
    // A short exchange proves the handshake's sequence numbers.
    char buf[64];
    CHECK(send_line(s, "echo\nping\n") == 0);
    CHECK(read_line(s, buf, sizeof buf) == 5 && !strcmp(buf, "ping\n"));

    // Nonblocking connect: EINPROGRESS, then POLLOUT and SO_ERROR 0; a second
    // connect reports success once, then EISCONN.
    int n = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
    CHECK(fails_with(connect(n, (struct sockaddr *)&host, sizeof host), EINPROGRESS));
    CHECK(fails_with(connect(n, (struct sockaddr *)&host, sizeof host), EALREADY) ||
          errno == EISCONN || errno == 0);
    CHECK(fails_with(recv(n, &c, 1, 0), EAGAIN));
    CHECK(wait_for(n, POLLOUT, 5000) == POLLOUT);
    CHECK(get_int(n, SOL_SOCKET, SO_ERROR) == 0);
    int rc = connect(n, (struct sockaddr *)&host, sizeof host);
    CHECK(rc == 0 || errno == EISCONN);
    CHECK(fails_with(connect(n, (struct sockaddr *)&host, sizeof host), EISCONN));
    CHECK(send_line(n, "echo\nnonblocking\n") == 0);
    CHECK(wait_for(n, POLLIN, 5000) & POLLIN);
    CHECK(read_line(n, buf, sizeof buf) == 12 && !strcmp(buf, "nonblocking\n"));

    // Both connections stay apart (4-tuple lookup).
    CHECK(fcntl(n, F_SETFL, 0) == 0);
    CHECK(send_line(s, "one\n") == 0 && send_line(n, "two\n") == 0);
    CHECK(read_line(n, buf, sizeof buf) == 4 && !strcmp(buf, "two\n"));
    CHECK(read_line(s, buf, sizeof buf) == 4 && !strcmp(buf, "one\n"));
    close(s);
    close(n);

    // A closed host port: slirp answers the SYN with a reset.
    struct sockaddr_in closed = addr_of(HOST, closed_port);
    s = socket(AF_INET, SOCK_STREAM, 0);
    CHECK(fails_with(connect(s, (struct sockaddr *)&closed, sizeof closed), ECONNREFUSED));
    CHECK(get_int(s, SOL_SOCKET, SO_ERROR) == 0);
    close(s);
    n = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
    CHECK(fails_with(connect(n, (struct sockaddr *)&closed, sizeof closed), EINPROGRESS));
    short ev = wait_for(n, POLLOUT, 5000);
    CHECK((ev & (POLLOUT | POLLERR | POLLHUP)) == (POLLOUT | POLLERR | POLLHUP));
    CHECK(get_int(n, SOL_SOCKET, SO_ERROR) == ECONNREFUSED);
    CHECK(get_int(n, SOL_SOCKET, SO_ERROR) == 0);
    close(n);

    // Over lo, our own stack answers with the reset.
    struct sockaddr_in lo = addr_of(LOOP, 9);
    s = socket(AF_INET, SOCK_STREAM, 0);
    CHECK(fails_with(connect(s, (struct sockaddr *)&lo, sizeof lo), ECONNREFUSED));
    close(s);
    s = socket(AF_INET, SOCK_STREAM, 0);
    lo = addr_of(0, 9); // 0.0.0.0 means 127.0.0.1
    CHECK(fails_with(connect(s, (struct sockaddr *)&lo, sizeof lo), ECONNREFUSED));
    close(s);

    // No ARP answer: EHOSTUNREACH after about 3 s, as on Linux.
    struct sockaddr_in none = addr_of(0x0A00024D, 80); // 10.0.2.77
    s = socket(AF_INET, SOCK_STREAM, 0);
    double t0 = now_s();
    CHECK(fails_with(connect(s, (struct sockaddr *)&none, sizeof none), EHOSTUNREACH));
    double took = now_s() - t0;
    CHECK(took > 2 && took < 5);
    close(s);

    // Many connections in a row reuse nothing they should not.
    for (int i = 0; i < 20; i++) {
        s = connect_to(HOST, server_port);
        CHECK(s >= 0);
        snprintf(buf, sizeof buf, "echo\n%d\n", i);
        CHECK(send_line(s, buf) == 0);
        char want[16];
        snprintf(want, sizeof want, "%d\n", i);
        CHECK(read_line(s, buf, sizeof buf) > 0 && !strcmp(buf, want));
        close(s);
    }
    CHECK(snmp("ActiveOpens") >= 26);
    CHECK(snmp("AttemptFails") >= 4);

    if (failed) return 1;
    printf("PASS\n");
    return 0;
}
