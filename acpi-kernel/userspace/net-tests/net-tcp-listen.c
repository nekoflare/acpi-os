// TCP passive open (NETPLAN T5): listen and accept/accept4 over lo, with
// SO_ACCEPTCONN, POLLIN and epoll on the listener, a blocking accept woken
// by another process, the backlog, port conflicts with listeners and
// SO_REUSEADDR after TIME_WAIT, a reset for connections nobody accepted, a
// 50 MB transfer between two processes, zero-window probes when the
// receiver's window updates are lost, and a server the host reaches through
// QEMU's hostfwd.
// net
// tcp-fwd: 7777
// timeout: 120
#include "tcp-common.h"
#include <sys/epoll.h>
#include <sys/wait.h>

static char big[1 << 20];

static int listener(uint32_t ip, int port, int backlog, int reuse)
{
    int l = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = addr_of(ip, port);
    if (reuse) set_int(l, SOL_SOCKET, SO_REUSEADDR, 1);
    if (bind(l, (struct sockaddr *)&a, sizeof a) || listen(l, backlog)) {
        close(l);
        return -1;
    }
    return l;
}

static int port_of(int s)
{
    struct sockaddr_in a;
    socklen_t len = sizeof a;
    getsockname(s, (struct sockaddr *)&a, &len);
    return ntohs(a.sin_port);
}

int main(void)
{
    char buf[256];
    setvbuf(stdout, NULL, _IONBF, 0);

    // A listener on an ephemeral lo port.
    int l = listener(LOOP, 0, 8, 0);
    CHECK(l >= 0);
    int port = port_of(l);
    CHECK(port >= 32768);
    CHECK(get_int(l, SOL_SOCKET, SO_ACCEPTCONN) == 1);
    CHECK(revents(l) == 0);
    CHECK(fcntl(l, F_SETFL, O_NONBLOCK) == 0);
    CHECK(fails_with(accept(l, NULL, NULL), EAGAIN));
    CHECK(fails_with(recv(l, buf, 1, 0), ENOTCONN));
    CHECK(fails_with(connect(l, (struct sockaddr *)&(struct sockaddr_in){0}, 16), EISCONN) || errno == EAFNOSUPPORT);

    // Connect and accept4.
    int c = connect_to(LOOP, port);
    CHECK(c >= 0);
    CHECK(revents(l) == (POLLIN));
    struct sockaddr_in peer;
    socklen_t len = sizeof peer;
    int a = accept4(l, (struct sockaddr *)&peer, &len, SOCK_NONBLOCK | SOCK_CLOEXEC);
    CHECK(a >= 0 && len == 16 && ntohs(peer.sin_port) == port_of(c) && peer.sin_addr.s_addr == htonl(LOOP));
    CHECK((fcntl(a, F_GETFL) & O_NONBLOCK) && (fcntl(a, F_GETFD) & FD_CLOEXEC));
    CHECK(get_int(a, SOL_SOCKET, SO_ACCEPTCONN) == 0);
    CHECK(get_int(a, IPPROTO_TCP, TCP_MAXSEG) == 65495);
    CHECK(port_of(a) == port);
    CHECK(send(c, "to server", 9, 0) == 9 && recv(a, buf, sizeof buf, 0) == 9 && !memcmp(buf, "to server", 9));
    CHECK(send(a, "to client", 9, 0) == 9 && recv(c, buf, sizeof buf, 0) == 9 && !memcmp(buf, "to client", 9));
    CHECK(fails_with(recv(a, buf, 1, 0), EAGAIN));
    close(c);
    CHECK(recv(a, buf, 1, 0) == 0);
    close(a);

    // epoll sees a pending connection.
    int ep = epoll_create1(0);
    struct epoll_event ev = {.events = EPOLLIN, .data.fd = l};
    CHECK(epoll_ctl(ep, EPOLL_CTL_ADD, l, &ev) == 0);
    CHECK(epoll_wait(ep, &ev, 1, 0) == 0);
    c = connect_to(LOOP, port);
    CHECK(epoll_wait(ep, &ev, 1, 1000) == 1 && ev.data.fd == l);
    a = accept(l, NULL, NULL);
    CHECK(a >= 0);
    close(a);
    close(c);
    close(ep);

    // A blocking accept is woken by a connection from another process.
    CHECK(fcntl(l, F_SETFL, 0) == 0);
    pid_t pid = fork();
    if (!pid) {
        usleep(200000);
        int k = connect_to(LOOP, port);
        if (k < 0 || send(k, "child\n", 6, 0) != 6) _exit(1);
        recv(k, buf, 1, 0);
        _exit(0);
    }
    a = accept(l, NULL, NULL);
    CHECK(a >= 0 && read_line(a, buf, sizeof buf) == 6 && !strcmp(buf, "child\n"));
    close(a);
    int status;
    CHECK(waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0);

    // Port conflicts: a listener's port stays taken even with SO_REUSEADDR.
    int r = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in same = addr_of(LOOP, port);
    CHECK(fails_with(bind(r, (struct sockaddr *)&same, sizeof same), EADDRINUSE));
    set_int(r, SOL_SOCKET, SO_REUSEADDR, 1);
    set_int(l, SOL_SOCKET, SO_REUSEADDR, 1);
    CHECK(fails_with(bind(r, (struct sockaddr *)&same, sizeof same), EADDRINUSE));
    close(r);

    // Backlog 1: two connections complete, a third waits for its SYN to be
    // retried once one is accepted.
    close(l);
    l = listener(LOOP, 0, 1, 1);
    port = port_of(l);
    int k[3];
    for (int i = 0; i < 3; i++) {
        k[i] = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
        struct sockaddr_in to = addr_of(LOOP, port);
        CHECK(fails_with(connect(k[i], (struct sockaddr *)&to, sizeof to), EINPROGRESS));
    }
    CHECK(revents(k[0]) & POLLOUT);
    CHECK(revents(k[1]) & POLLOUT);
    CHECK(!(revents(k[2]) & POLLOUT));
    for (int i = 0; i < 3; i++) {
        a = accept(l, NULL, NULL);
        CHECK(a >= 0);
        close(a);
    }
    CHECK(wait_for(k[2], POLLOUT, 3000) & POLLOUT);
    for (int i = 0; i < 3; i++) close(k[i]);

    // Connections nobody accepted are reset when the listener closes.
    c = connect_to(LOOP, port);
    CHECK(c >= 0);
    close(l);
    CHECK(fails_with(recv(c, buf, 1, 0), ECONNRESET));
    close(c);
    // Its port is free again for SO_REUSEADDR, connections in TIME_WAIT or not.
    l = listener(LOOP, port, 8, 1);
    CHECK(l >= 0);

    // 50 MB from a child process, checked by CRC-32.
    size_t total = 50u << 20;
    pid = fork();
    if (!pid) {
        int s = connect_to(LOOP, port);
        uint32_t crc = 0;
        for (size_t off = 0; off < total; off += sizeof big) {
            for (size_t i = 0; i < sizeof big; i++) big[i] = pat(off + i);
            crc = crc32_update(crc, big, sizeof big);
            if (send_all(s, big, sizeof big)) _exit(1);
        }
        if (send_all(s, &crc, 4)) _exit(2);
        close(s);
        _exit(0);
    }
    a = accept(l, NULL, NULL);
    CHECK(a >= 0);
    double t0 = now_s();
    uint32_t crc = 0, theirs = 0;
    size_t got = 0;
    for (;;) {
        ssize_t n = recv(a, big, sizeof big, 0);
        if (n <= 0) break;
        size_t data = n;
        if (got + n > total) data = got >= total ? 0 : total - got;
        crc = crc32_update(crc, big, data);
        for (size_t i = data; i < (size_t)n; i++) ((char *)&theirs)[got + i - total] = big[i];
        got += n;
    }
    double took = now_s() - t0;
    CHECK(got == total + 4 && crc == theirs);
    CHECK(waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0);
    printf("lo: %zu bytes in %.2f s: %.1f MB/s\n", total, took, total / took / 1e6);
    close(a);

    // Zero window: the receiver stops reading, then reads while its window
    // updates are lost; only the sender's probes find the window open.
    c = connect_to(LOOP, port);
    a = accept(l, NULL, NULL);
    CHECK(fcntl(c, F_SETFL, O_NONBLOCK) == 0);
    size_t queued = 0;
    for (size_t i = 0; i < sizeof big; i++) big[i] = pat(i);
    for (;;) {
        ssize_t n = send(c, big, sizeof big, 0);
        if (n > 0) queued += n;
        else if (!wait_for(c, POLLOUT, 300)) break; // stuck: both rings full
    }
    // Window scaling lets the receive ring fill beyond 64 KiB.
    CHECK(errno == EAGAIN && queued >= 262144 + 196608);
    printf("lo zero window after %zu bytes\n", queued);
    CHECK(set_int(a, IPPROTO_TCP, TCP_DBGDROP, 1) == 0);
    size_t drained = 0;
    ssize_t n;
    while ((n = recv(a, big, sizeof big, MSG_DONTWAIT)) > 0) drained += n;
    usleep(500000); // the delayed ACK and the first probes are lost too
    CHECK(set_int(a, IPPROTO_TCP, TCP_DBGDROP, 0) == 0);
    CHECK(wait_for(c, POLLOUT, 5000) & POLLOUT);
    CHECK(get_int(c, IPPROTO_TCP, 0x4E45) > 0);
    CHECK(fcntl(c, F_SETFL, 0) == 0);
    CHECK(shutdown(c, SHUT_WR) == 0);
    CHECK(fcntl(a, F_SETFL, 0) == 0);
    while ((n = recv(a, big, sizeof big, 0)) > 0) drained += n;
    CHECK(drained == queued);
    close(a);
    close(c);
    close(l);

    // The host connects through hostfwd to port 7777.
    l = listener(0, 7777, 4, 1);
    CHECK(l >= 0);
    a = accept(l, (struct sockaddr *)&peer, &len);
    CHECK(a >= 0 && peer.sin_addr.s_addr == htonl(HOST));
    CHECK(read_line(a, buf, sizeof buf) > 0 && !strcmp(buf, "hello from host\n"));
    CHECK(send_line(a, "HELLO FROM HOST\n") == 0);
    CHECK(read_line(a, buf, sizeof buf) > 0 && !strcmp(buf, "ok\n"));
    close(a);
    close(l);

    if (failed) return 1;
    printf("PASS\n");
    return 0;
}
