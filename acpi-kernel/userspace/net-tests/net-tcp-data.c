// TCP data transfer (NETPLAN T2) against the host server through slirp:
// a 10 MB download and upload checked byte for byte (pattern and CRC-32),
// one blocking send() of 4 MiB, MSG_WAITALL, MSG_PEEK, MSG_TRUNC,
// readv/writev and sendmsg/recvmsg, FIONREAD and SIOCOUTQ, a full send
// buffer (EAGAIN, then POLLOUT) while the peer does not read, and the
// throughput of both directions.
// net
// tcp-server
// timeout: 120
#include "tcp-common.h"
#include <sys/ioctl.h>
#include <sys/uio.h>

#define SIOCOUTQ 0x5411

static char big[1 << 20];

int main(void)
{
    read_ports();
    char buf[256];

    // Download 10 MB.
    int s = connect_to(HOST, server_port);
    CHECK(s >= 0);
    size_t total = 10 * 1000 * 1000, got = 0, bad = 0;
    snprintf(buf, sizeof buf, "send %zu\n", total);
    CHECK(send_line(s, buf) == 0);
    double t0 = now_s();
    for (;;) {
        ssize_t k = recv(s, big, sizeof big, 0);
        if (k <= 0) {
            CHECK(k == 0);
            break;
        }
        for (ssize_t i = 0; i < k; i++) bad += (unsigned char)big[i] != host_pat(got + i);
        got += k;
    }
    double down = now_s() - t0;
    CHECK(got == total && bad == 0);
    CHECK(recv(s, buf, 1, 0) == 0); // EOF stays
    close(s);
    printf("download %zu bytes in %.2f s: %.1f MB/s\n", got, down, got / down / 1e6);

    // Upload 10 MB in 64 KiB writes, then half-close and read the verdict.
    s = connect_to(HOST, server_port);
    CHECK(send_line(s, "sink\n") == 0);
    uint32_t crc = 0;
    t0 = now_s();
    for (size_t off = 0; off < total; off += 65536) {
        size_t n = total - off < 65536 ? total - off : 65536;
        for (size_t i = 0; i < n; i++) big[i] = pat(off + i);
        crc = crc32_update(crc, big, n);
        CHECK(send_all(s, big, n) == 0);
    }
    CHECK(shutdown(s, SHUT_WR) == 0);
    CHECK(read_line(s, buf, sizeof buf) > 0);
    double up = now_s() - t0;
    char want[64];
    snprintf(want, sizeof want, "%zu %08x\n", total, crc);
    CHECK(!strcmp(buf, want));
    if (strcmp(buf, want)) printf("host saw %s, want %s", buf, want);
    close(s);
    printf("upload %zu bytes in %.2f s: %.1f MB/s\n", total, up, total / up / 1e6);

    // One blocking send() of 4 MiB returns once all of it is queued.
    s = connect_to(HOST, server_port);
    CHECK(send_line(s, "sink\n") == 0);
    static char four[4 << 20];
    for (size_t i = 0; i < sizeof four; i++) four[i] = pat(i);
    CHECK(send(s, four, sizeof four, 0) == (ssize_t)sizeof four);
    CHECK(shutdown(s, SHUT_WR) == 0);
    CHECK(read_line(s, buf, sizeof buf) > 0);
    snprintf(want, sizeof want, "%zu %08x\n", sizeof four, crc32_update(0, four, sizeof four));
    CHECK(!strcmp(buf, want));
    close(s);

    // MSG_WAITALL gets all 1 MiB in one call; MSG_PEEK leaves data queued;
    // MSG_TRUNC discards it.
    s = connect_to(HOST, server_port);
    CHECK(send_line(s, "send 1048676\n") == 0);
    CHECK(recv(s, big, sizeof big, MSG_WAITALL) == (ssize_t)sizeof big);
    bad = 0;
    for (size_t i = 0; i < sizeof big; i++) bad += (unsigned char)big[i] != host_pat(i);
    CHECK(bad == 0);
    CHECK(wait_for(s, POLLIN, 5000) & POLLIN);
    usleep(100000);
    int avail = -1;
    CHECK(ioctl(s, FIONREAD, &avail) == 0 && avail == 100);
    CHECK(recv(s, buf, 10, MSG_PEEK) == 10 && (unsigned char)buf[0] == host_pat(1 << 20));
    CHECK(ioctl(s, FIONREAD, &avail) == 0 && avail == 100);
    CHECK(recv(s, NULL, 50, MSG_TRUNC) == 50);
    CHECK(recv(s, buf, sizeof buf, 0) == 50 && (unsigned char)buf[0] == host_pat((1 << 20) + 50));
    CHECK(recv(s, buf, sizeof buf, 0) == 0);
    close(s);

    // readv/writev and sendmsg/recvmsg on an echo connection.
    s = connect_to(HOST, server_port);
    CHECK(send_line(s, "echo\n") == 0);
    struct iovec iov[3] = {{"abc", 3}, {"", 0}, {"defgh", 5}};
    CHECK(writev(s, iov, 3) == 8);
    struct msghdr m = {.msg_iov = iov, .msg_iovlen = 1};
    iov[0] = (struct iovec){"0123456789", 10};
    CHECK(sendmsg(s, &m, 0) == 10);
    char all[19] = {0};
    size_t have = 0;
    while (have < 18) {
        struct iovec in[2] = {{all + have, have < 4 ? 4 - have : 1}, {all + have + (have < 4 ? 4 - have : 1), 18 - have - (have < 4 ? 4 - have : 1)}};
        ssize_t k = readv(s, in, 2);
        if (k <= 0) break;
        have += k;
    }
    CHECK(have == 18 && !strcmp(all, "abcdefgh0123456789"));
    close(s);

    struct sockaddr_in from;
    struct iovec in[2];
    s = connect_to(HOST, server_port);
    CHECK(send_line(s, "echo\n") == 0);
    CHECK(send(s, "0123456789abcdefgh", 18, 0) == 18);
    memset(all, 0, sizeof all);
    in[0] = (struct iovec){all, 4};
    in[1] = (struct iovec){all + 4, 14};
    m = (struct msghdr){.msg_name = &from, .msg_namelen = sizeof from, .msg_iov = in, .msg_iovlen = 2};
    CHECK(recvmsg(s, &m, MSG_WAITALL) == 18 && m.msg_namelen == 0 && !strcmp(all, "0123456789abcdefgh"));
    socklen_t flen = sizeof from;
    CHECK(send(s, "xy", 2, 0) == 2);
    CHECK(recvfrom(s, buf, 2, MSG_WAITALL, (struct sockaddr *)&from, &flen) == 2 && flen == 0);
    close(s);

    // A peer that does not read: a nonblocking writer fills the send ring,
    // gets EAGAIN, and POLLOUT once the peer catches up.
    s = connect_to(HOST, server_port);
    CHECK(send_line(s, "slow 6000000\n") == 0);
    CHECK(fcntl(s, F_SETFL, O_NONBLOCK) == 0);
    size_t queued = 0;
    for (;;) {
        ssize_t k = send(s, four, 65536, 0);
        if (k < 0) break;
        queued += k;
        if (queued > (8u << 20)) break;
    }
    CHECK(errno == EAGAIN && queued >= 131072 && queued < 6000000);
    int outq = -1;
    CHECK(ioctl(s, SIOCOUTQ, &outq) == 0 && outq > 0);
    CHECK(!(revents(s) & POLLOUT));
    CHECK(wait_for(s, POLLOUT, 10000) & POLLOUT);
    CHECK(fcntl(s, F_SETFL, 0) == 0);
    size_t rest = 6000000 - queued;
    while (rest) {
        size_t n = rest < sizeof four ? rest : sizeof four;
        CHECK(send(s, four, n, 0) == (ssize_t)n);
        rest -= n;
    }
    CHECK(read_line(s, buf, sizeof buf) > 0 && strtoul(buf, NULL, 10) == 6000000);
    close(s);

    printf("tcp: in %ld out %ld retrans %ld\n", snmp("InSegs"), snmp("OutSegs"), snmp("RetransSegs"));
    if (failed) return 1;
    printf("PASS\n");
    return 0;
}
