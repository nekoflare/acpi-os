// AF_INET socket creation, descriptor behaviour and bind (NETPLAN S1).
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
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

static int bind_to(int fd, const char *ip, int port)
{
    struct sockaddr_in a = addr(ip, port);
    return bind(fd, (struct sockaddr *)&a, sizeof a);
}

// Local port of fd, or -1; the address goes to *ip.
static int local_port(int fd, unsigned *ip)
{
    struct sockaddr_in a;
    socklen_t len = sizeof a;
    memset(&a, 0xAA, sizeof a);
    if (getsockname(fd, (struct sockaddr *)&a, &len) || len != sizeof a ||
        a.sin_family != AF_INET)
        return -1;
    if (ip)
        *ip = ntohl(a.sin_addr.s_addr);
    return ntohs(a.sin_port);
}

static int fails_with(int ret, int err)
{
    return ret == -1 && errno == err;
}

int main(void)
{
    // Families, types and protocols.
    int u = socket(AF_INET, SOCK_DGRAM, 0);
    int t = socket(AF_INET, SOCK_STREAM, 0);
    CHECK(u >= 0 && t >= 0);
    int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    CHECK(fd >= 0);
    close(fd);
    fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    CHECK(fd >= 0);
    close(fd);
    CHECK(fails_with(socket(AF_INET, SOCK_STREAM, IPPROTO_UDP), EPROTONOSUPPORT));
    CHECK(fails_with(socket(AF_INET6, SOCK_DGRAM, 0), EAFNOSUPPORT));
    CHECK(socket(AF_INET, SOCK_RAW, IPPROTO_ICMP) == -1);

    // Descriptor flags.
    struct stat st;
    CHECK(fstat(u, &st) == 0 && S_ISSOCK(st.st_mode));
    CHECK(lseek(u, 0, SEEK_SET) == -1 && errno == ESPIPE);
    fd = socket(AF_INET, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    CHECK(fd >= 0);
    CHECK(fcntl(fd, F_GETFL) & O_NONBLOCK);
    CHECK(fcntl(fd, F_GETFD) & FD_CLOEXEC);
    CHECK(fcntl(fd, F_SETFL, 0) == 0 && !(fcntl(fd, F_GETFL) & O_NONBLOCK));
    CHECK(!(fcntl(u, F_GETFL) & O_NONBLOCK));
    close(fd);
    struct pollfd p = {u, POLLIN | POLLOUT, 0};
    CHECK(poll(&p, 1, 0) == 1 && p.revents == POLLOUT);

    // Names before bind.
    unsigned ip = 1;
    CHECK(local_port(u, &ip) == 0 && ip == 0);
    struct sockaddr_in peer;
    socklen_t len = sizeof peer;
    CHECK(fails_with(getpeername(u, (struct sockaddr *)&peer, &len), ENOTCONN));

    // Explicit ports conflict per protocol.
    CHECK(bind_to(u, "0.0.0.0", 5000) == 0);
    CHECK(local_port(u, &ip) == 5000 && ip == 0);
    CHECK(fails_with(bind_to(u, "0.0.0.0", 5001), EINVAL));
    int u2 = socket(AF_INET, SOCK_DGRAM, 0);
    CHECK(fails_with(bind_to(u2, "127.0.0.1", 5000), EADDRINUSE));
    CHECK(bind_to(t, "127.0.0.1", 5000) == 0);
    CHECK(local_port(t, &ip) == 5000 && ip == 0x7F000001);

    // Bad addresses.
    CHECK(fails_with(bind_to(u2, "1.2.3.4", 0), EADDRNOTAVAIL));
    struct sockaddr_in a = addr("0.0.0.0", 0);
    CHECK(fails_with(bind(u2, (struct sockaddr *)&a, sizeof a - 1), EINVAL));
    a.sin_family = AF_INET6;
    CHECK(fails_with(bind(u2, (struct sockaddr *)&a, sizeof a), EAFNOSUPPORT));

    // Ephemeral ports.
    CHECK(bind_to(u2, "127.0.0.1", 0) == 0);
    int e1 = local_port(u2, &ip);
    CHECK(e1 >= 32768 && e1 <= 60999 && ip == 0x7F000001);
    int u3 = socket(AF_INET, SOCK_DGRAM, 0);
    CHECK(bind_to(u3, "0.0.0.0", 0) == 0);
    int e2 = local_port(u3, NULL);
    CHECK(e2 >= 32768 && e2 <= 60999 && e2 != e1);
    close(u3);

    // A duplicate keeps the port until the last close.
    int d = dup(u);
    close(u);
    fd = socket(AF_INET, SOCK_DGRAM, 0);
    CHECK(fails_with(bind_to(fd, "0.0.0.0", 5000), EADDRINUSE));
    CHECK(local_port(d, NULL) == 5000);

    // A child inherits the socket; its exit does not release the port.
    pid_t pid = fork();
    if (pid == 0)
        _exit(local_port(d, NULL) == 5000 ? 0 : 1);
    int status = -1;
    CHECK(waitpid(pid, &status, 0) == pid && status == 0);
    CHECK(fails_with(bind_to(fd, "0.0.0.0", 5000), EADDRINUSE));
    close(d);
    CHECK(bind_to(fd, "0.0.0.0", 5000) == 0);

    // AF_UNIX sockets are not AF_INET ones.
    int sv[2];
    CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0);
    len = sizeof a;
    CHECK(fails_with(getsockname(0 + 1000, (struct sockaddr *)&a, &len), EBADF));
    close(sv[0]);
    close(sv[1]);

    close(fd);
    close(u2);
    close(t);
    if (!failed)
        puts("PASS");
    return failed;
}
