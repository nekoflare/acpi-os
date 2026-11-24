// Loopback (NETPLAN S6): UDP over 127.0.0.0/8 with no NIC at all. Datagrams
// to any 127.x address (and to 0.0.0.0) go through lo; port unreachables
// come back over lo too; everything else is unreachable.
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int failures;

#define CHECK(cond, ...)                                                       \
    do {                                                                       \
        if (!(cond)) {                                                         \
            printf("FAIL %s:%d: ", __FILE__, __LINE__);                        \
            printf(__VA_ARGS__);                                               \
            printf(" (errno %s)\n", strerror(errno));                          \
            failures++;                                                        \
        }                                                                      \
    } while (0)

static struct sockaddr_in addr(const char *ip, int port) {
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port)};
    inet_pton(AF_INET, ip, &a.sin_addr);
    return a;
}

static const char *show(const struct sockaddr_in *a) {
    static char text[32];
    char ip[INET_ADDRSTRLEN];
    inet_ntop(AF_INET, &a->sin_addr, ip, sizeof ip);
    snprintf(text, sizeof text, "%s:%d", ip, ntohs(a->sin_port));
    return text;
}

static int udp(const char *ip, int port) {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (ip) {
        struct sockaddr_in a = addr(ip, port);
        if (bind(s, (struct sockaddr *)&a, sizeof a)) {
            printf("bind %s:%d: %s\n", ip, port, strerror(errno));
            close(s);
            return -1;
        }
    }
    return s;
}

static struct sockaddr_in name_of(int s) {
    struct sockaddr_in a = {0};
    socklen_t len = sizeof a;
    getsockname(s, (struct sockaddr *)&a, &len);
    return a;
}

static int send_to(int s, const char *ip, int port, const void *data, size_t n) {
    struct sockaddr_in a = addr(ip, port);
    return sendto(s, data, n, 0, (struct sockaddr *)&a, sizeof a);
}

// Receive one datagram without blocking; fill from with its source.
static int take(int s, char *buf, size_t n, struct sockaddr_in *from) {
    struct sockaddr_in a;
    socklen_t len = sizeof a;
    int r = recvfrom(s, buf, n, MSG_DONTWAIT, (struct sockaddr *)&a, &len);
    if (from) *from = a;
    return r;
}

// lo's receive packet count from /proc/net/dev.
static long lo_packets(long *bytes) {
    FILE *f = fopen("/proc/net/dev", "r");
    char line[256];
    long rb = -1, rp = -1, tb = -1, tp = -1;
    while (f && fgets(line, sizeof line, f)) {
        char *p = strstr(line, "lo:");
        if (p && sscanf(p + 3, "%ld %ld %*d %*d %*d %*d %*d %*d %ld %ld", &rb, &rp, &tb, &tp) == 4) break;
    }
    if (f) fclose(f);
    CHECK(rb == tb && rp == tp, "lo rx %ld/%ld tx %ld/%ld", rb, rp, tb, tp);
    if (bytes) *bytes = rb;
    return rp;
}

int main(void) {
    char buf[2048];
    static char big[65536], back[65536];
    struct sockaddr_in from;
    long bytes0, packets0 = lo_packets(&bytes0);

    // An unbound socket talks to one bound to 127.0.0.1; replies go back to
    // the ephemeral port it was given.
    int server = udp("127.0.0.1", 0);
    int port = ntohs(name_of(server).sin_port);
    int client = udp(NULL, 0);
    CHECK(send_to(client, "127.0.0.1", port, "ping", 4) == 4, "sendto 127.0.0.1");
    struct sockaddr_in cname = name_of(client);
    CHECK(cname.sin_addr.s_addr == 0 && ntohs(cname.sin_port) >= 32768, "client bound to %s", show(&cname));
    CHECK(take(server, buf, sizeof buf, &from) == 4 && !memcmp(buf, "ping", 4), "server got ping");
    CHECK(!strcmp(show(&from), show(&(struct sockaddr_in){.sin_addr.s_addr = htonl(0x7F000001),
                                                          .sin_port = cname.sin_port})),
          "ping came from %s", show(&from));
    CHECK(sendto(server, "pong", 4, 0, (struct sockaddr *)&from, sizeof from) == 4, "reply");
    CHECK(take(client, buf, sizeof buf, &from) == 4 && !memcmp(buf, "pong", 4), "client got pong");
    CHECK(ntohs(from.sin_port) == port && from.sin_addr.s_addr == htonl(0x7F000001),
          "pong came from %s", show(&from));
    CHECK(take(client, buf, sizeof buf, NULL) == -1 && errno == EAGAIN, "only one reply");

    // Every 127.x address is ours; the source is 127.0.0.1 regardless.
    int wild = udp("0.0.0.0", 0);
    int wport = ntohs(name_of(wild).sin_port);
    CHECK(send_to(client, "127.45.6.7", wport, "x", 1) == 1, "sendto 127.45.6.7");
    CHECK(take(wild, buf, sizeof buf, &from) == 1 && from.sin_addr.s_addr == htonl(0x7F000001),
          "127.45.6.7 from %s", show(&from));
    int other = udp("127.0.0.2", port);
    CHECK(other >= 0, "bind 127.0.0.2 on the port 127.0.0.1 uses");
    CHECK(send_to(client, "127.0.0.2", port, "two", 3) == 3, "sendto 127.0.0.2");
    CHECK(take(other, buf, sizeof buf, NULL) == 3 && take(server, buf, sizeof buf, NULL) == -1,
          "127.0.0.2 went to its own socket only");
    // A socket bound to 127.0.0.2 sends from it.
    CHECK(send_to(other, "127.0.0.1", port, "from2", 5) == 5, "sendto from 127.0.0.2");
    CHECK(take(server, buf, sizeof buf, &from) == 5 && from.sin_addr.s_addr == htonl(0x7F000002),
          "from2 came from %s", show(&from));

    // 0.0.0.0 as a destination means 127.0.0.1, for sendto and connect.
    CHECK(send_to(client, "0.0.0.0", port, "any", 3) == 3, "sendto 0.0.0.0");
    CHECK(take(server, buf, sizeof buf, NULL) == 3 && !memcmp(buf, "any", 3), "0.0.0.0 reached 127.0.0.1");
    int conn = udp(NULL, 0);
    struct sockaddr_in a = addr("0.0.0.0", port);
    CHECK(connect(conn, (struct sockaddr *)&a, sizeof a) == 0, "connect 0.0.0.0");
    socklen_t len = sizeof a;
    CHECK(getpeername(conn, (struct sockaddr *)&a, &len) == 0 && a.sin_addr.s_addr == htonl(0x7F000001),
          "peer %s", show(&a));
    a = name_of(conn);
    CHECK(a.sin_addr.s_addr == htonl(0x7F000001), "connected local %s", show(&a));
    CHECK(send(conn, "c", 1, 0) == 1 && take(server, buf, sizeof buf, NULL) == 1, "send on connected");
    close(conn);

    // A send to a closed port on lo is refused through ICMP, as on Linux.
    int closed = udp("127.0.0.1", 0);
    int cport = ntohs(name_of(closed).sin_port);
    close(closed);
    conn = udp(NULL, 0);
    a = addr("127.0.0.1", cport);
    CHECK(connect(conn, (struct sockaddr *)&a, sizeof a) == 0, "connect closed port");
    CHECK(send(conn, "?", 1, 0) == 1, "send to closed port");
    struct pollfd pfd = {.fd = conn, .events = POLLIN};
    CHECK(poll(&pfd, 1, 0) == 1 && (pfd.revents & POLLERR), "POLLERR, revents %#x", pfd.revents);
    CHECK(recv(conn, buf, sizeof buf, MSG_DONTWAIT) == -1 && errno == ECONNREFUSED, "ECONNREFUSED");
    CHECK(recv(conn, buf, sizeof buf, MSG_DONTWAIT) == -1 && errno == EAGAIN, "error reported once");
    close(conn);
    // An unconnected sender hears nothing.
    CHECK(send_to(client, "127.0.0.1", cport, "?", 1) == 1, "unconnected send to closed port");
    CHECK(take(client, buf, sizeof buf, NULL) == -1 && errno == EAGAIN, "no error unconnected");

    // A socket sends to itself; a burst keeps its order and contents; the
    // largest datagram fits and one byte more does not.
    struct sockaddr_in self = name_of(server);
    for (int i = 0; i < 40; i++) {
        memset(buf, i, 1000);
        CHECK(sendto(server, buf, 1000 + i, 0, (struct sockaddr *)&self, sizeof self) == 1000 + i, "burst %d", i);
    }
    for (int i = 0; i < 40; i++) {
        int n = take(server, buf, sizeof buf, NULL);
        CHECK(n == 1000 + i && buf[0] == i && buf[999] == i, "burst %d came back as %d bytes", i, n);
    }
    // lo's MTU is 65536, so even the largest datagram is one packet.
    for (int i = 0; i < (int)sizeof big; i++) big[i] = i * 13 ^ i >> 9;
    static const int sizes[] = {1472, 1473, 4064, 4065, 30000, 65507};
    for (int i = 0; i < (int)(sizeof sizes / sizeof *sizes); i++) {
        int n = sizes[i];
        CHECK(sendto(server, big + i, n, 0, (struct sockaddr *)&self, sizeof self) == n, "send %d bytes", n);
        memset(back, 0, n);
        int r = take(server, back, sizeof back, NULL);
        CHECK(r == n && !memcmp(back, big + i, n), "%d bytes came back as %d", n, r);
    }
    CHECK(sendto(server, big, 65508, 0, (struct sockaddr *)&self, sizeof self) == -1 && errno == EMSGSIZE,
          "65508 bytes");
    // Big datagrams queue up to SO_RCVBUF (212992 by default): the queue
    // takes datagrams while it holds no more than that, so four of 65507
    // bytes fit and the fifth is dropped.
    for (int i = 0; i < 5; i++)
        CHECK(sendto(server, big, 65507, 0, (struct sockaddr *)&self, sizeof self) == 65507, "queue %d", i);
    for (int i = 0; i < 4; i++) CHECK(take(server, back, sizeof back, NULL) == 65507, "queued %d", i);
    CHECK(take(server, back, sizeof back, NULL) == -1 && errno == EAGAIN, "fifth dropped");

    // A blocked receiver in another process wakes up.
    pid_t pid = fork();
    if (!pid) {
        int n = recv(server, buf, sizeof buf, 0);
        _exit(n == 4 && !memcmp(buf, "wake", 4) ? 0 : 1);
    }
    usleep(100000);
    CHECK(send_to(client, "127.0.0.1", port, "wake", 4) == 4, "send wake");
    int status;
    CHECK(waitpid(pid, &status, 0) == pid && WIFEXITED(status) && !WEXITSTATUS(status),
          "child status %#x", status);

    // localhost from /etc/hosts works end to end.
    struct addrinfo hints = {.ai_family = AF_INET, .ai_socktype = SOCK_DGRAM}, *ai;
    char service[8];
    snprintf(service, sizeof service, "%d", port);
    int rc = getaddrinfo("localhost", service, &hints, &ai);
    CHECK(rc == 0, "getaddrinfo localhost: %s", gai_strerror(rc));
    if (!rc) {
        CHECK(sendto(client, "lh", 2, 0, ai->ai_addr, ai->ai_addrlen) == 2, "send to localhost");
        CHECK(take(server, buf, sizeof buf, NULL) == 2, "localhost datagram");
        freeaddrinfo(ai);
    }

    // Without a NIC nothing else is reachable or bindable.
    CHECK(send_to(client, "10.0.2.2", 9, "x", 1) == -1 && errno == ENETUNREACH, "sendto 10.0.2.2");
    a = addr("1.1.1.1", 53);
    CHECK(connect(conn = udp(NULL, 0), (struct sockaddr *)&a, sizeof a) == -1 && errno == ENETUNREACH,
          "connect 1.1.1.1");
    close(conn);
    CHECK(udp("10.0.2.15", 0) == -1 && errno == EADDRNOTAVAIL, "bind 10.0.2.15");
    CHECK(udp("10.0.2.255", 0) == -1 && errno == EADDRNOTAVAIL, "bind 10.0.2.255");

    long bytes1, packets1 = lo_packets(&bytes1);
    printf("lo carried %ld packets, %ld bytes\n", packets1 - packets0, bytes1 - bytes0);
    // 11 above the burst (two of them ICMP), 40 in it, 6 big ones, 5 queued,
    // wake and lh.
    CHECK(packets1 - packets0 == 64, "lo packets %ld", packets1 - packets0);

    if (failures) {
        printf("%d failures\n", failures);
        return 1;
    }
    printf("PASS\n");
    return 0;
}
