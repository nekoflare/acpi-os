// Helpers shared by the TCP guest tests.
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define TCP_DBGDROP 0x4E44 // this kernel: drop every Nth outgoing segment

static __attribute__((unused)) int failed;

#define CHECK(cond)                                                          \
    do {                                                                     \
        if (!(cond)) {                                                       \
            printf("FAIL line %d: %s (errno %d)\n", __LINE__, #cond, errno); \
            failed = 1;                                                      \
        }                                                                    \
    } while (0)

static __attribute__((unused)) int fails_with(long rc, int err) { return rc == -1 && errno == err; }

static __attribute__((unused)) int server_port, closed_port;

static __attribute__((unused)) void read_ports(void)
{
    FILE *f = fopen("/etc/tcp-port", "r");
    if (!f || fscanf(f, "%d %d", &server_port, &closed_port) != 2) {
        printf("FAIL: /etc/tcp-port\n");
        exit(1);
    }
    fclose(f);
}

static __attribute__((unused)) struct sockaddr_in addr_of(uint32_t ip, int port)
{
    struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(port)};
    a.sin_addr.s_addr = htonl(ip);
    return a;
}

#define HOST 0x0A000202u
#define LOOP 0x7F000001u

static __attribute__((unused)) double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static __attribute__((unused)) int connect_to(uint32_t ip, int port)
{
    int s = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = addr_of(ip, port);
    if (s < 0 || connect(s, (struct sockaddr *)&a, sizeof a)) {
        if (s >= 0) close(s);
        return -1;
    }
    return s;
}

static __attribute__((unused)) int send_all(int s, const void *buf, size_t n)
{
    const char *p = buf;
    while (n) {
        ssize_t k = send(s, p, n, MSG_NOSIGNAL);
        if (k <= 0) return -1;
        p += k;
        n -= k;
    }
    return 0;
}

static __attribute__((unused)) int send_line(int s, const char *line) { return send_all(s, line, strlen(line)); }

static __attribute__((unused)) ssize_t read_line(int s, char *buf, size_t size)
{
    size_t n = 0;
    while (n + 1 < size) {
        ssize_t k = recv(s, buf + n, 1, 0);
        if (k <= 0) break;
        if (buf[n++] == '\n') break;
    }
    buf[n] = 0;
    return n;
}

static __attribute__((unused)) unsigned char pat(size_t i) { return (unsigned char)(i * 7 + (i >> 8)); }

// The host pattern restarts every MiB.
static __attribute__((unused)) unsigned char host_pat(size_t i) { return pat(i & ((1u << 20) - 1)); }

static __attribute__((unused)) uint32_t crc_table[256];

static __attribute__((unused)) uint32_t crc32_update(uint32_t crc, const void *data, size_t n)
{
    if (!crc_table[1]) {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
            crc_table[i] = c;
        }
    }
    const unsigned char *p = data;
    crc = ~crc;
    while (n--) crc = crc_table[(crc ^ *p++) & 255] ^ (crc >> 8);
    return ~crc;
}

static __attribute__((unused)) short revents(int s)
{
    struct pollfd p = {.fd = s, .events = POLLIN | POLLOUT | POLLRDHUP};
    if (poll(&p, 1, 0) < 0) return -1;
    return p.revents;
}

static __attribute__((unused)) short wait_for(int s, short events, int ms)
{
    struct pollfd p = {.fd = s, .events = events};
    if (poll(&p, 1, ms) <= 0) return 0;
    return p.revents;
}

static __attribute__((unused)) int get_int(int s, int level, int name)
{
    int v = -1;
    socklen_t len = sizeof v;
    if (getsockopt(s, level, name, &v, &len)) return -1000 - errno;
    return v;
}

static __attribute__((unused)) int set_int(int s, int level, int name, int v) { return setsockopt(s, level, name, &v, sizeof v); }

// A field of the Tcp line of /proc/net/snmp.
static __attribute__((unused)) long snmp(const char *field)
{
    FILE *f = fopen("/proc/net/snmp", "r");
    if (!f) return -1;
    char names[1024], values[1024];
    long result = -1;
    while (fgets(names, sizeof names, f)) {
        if (strncmp(names, "Tcp:", 4) || !fgets(values, sizeof values, f)) continue;
        char *ns = names + 4, *vs = values + 4, *n, *v;
        while ((n = strsep(&ns, " \n")) && (v = strsep(&vs, " \n"))) {
            if (*n && !strcmp(n, field)) result = atol(v);
        }
        break;
    }
    fclose(f);
    return result;
}
