// K7: AF_UNIX SOCK_SEQPACKET (and SOCK_DGRAM socket pairs) keep message
// boundaries. Firefox's crash helper needs this: it sends a header and a
// payload as two messages with SCM_RIGHTS, on non-blocking sockets, and
// expects each recvmsg to return exactly one of them.
#define _GNU_SOURCE
// musl's CMSG_NXTHDR compares signed with unsigned.
#pragma clang diagnostic ignored "-Wsign-compare"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

static int failures;

#define CHECK(cond, ...) do { \
    if (!(cond)) { printf("FAIL line %d: ", __LINE__); printf(__VA_ARGS__); \
        printf(" (errno=%d)\n", errno); failures++; } } while (0)

static ssize_t send_fd(int sock, const void *data, size_t len, int fd)
{
    struct iovec iov = {(void *)data, len};
    char control[CMSG_SPACE(sizeof(int))];
    struct msghdr msg = {.msg_iov = &iov, .msg_iovlen = 1,
        .msg_control = control, .msg_controllen = sizeof control};
    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(cmsg), &fd, sizeof fd);
    return sendmsg(sock, &msg, 0);
}

static ssize_t recv_fd(int sock, void *data, size_t len, int *fd, int *flags)
{
    struct iovec iov = {data, len};
    char control[CMSG_SPACE(sizeof(int))];
    struct msghdr msg = {.msg_iov = &iov, .msg_iovlen = 1,
        .msg_control = control, .msg_controllen = sizeof control};
    ssize_t n = recvmsg(sock, &msg, 0);
    *fd = -1;
    *flags = msg.msg_flags;
    // One control message at most: the buffer has room for one descriptor.
    struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
    if (n >= 0 && c && c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS) {
        memcpy(fd, CMSG_DATA(c), sizeof *fd);
    }
    return n;
}

static void boundaries(int type, const char *name)
{
    int sv[2];
    char buf[256];
    CHECK(socketpair(AF_UNIX, type, 0, sv) == 0, "%s socketpair", name);
    CHECK(write(sv[0], "hello", 5) == 5, "%s write 1", name);
    CHECK(write(sv[0], "world!!", 7) == 7, "%s write 2", name);
    CHECK(read(sv[1], buf, sizeof buf) == 5 && !memcmp(buf, "hello", 5), "%s read 1", name);
    CHECK(read(sv[1], buf, sizeof buf) == 7 && !memcmp(buf, "world!!", 7), "%s read 2", name);
    // A short buffer drops the rest of the message, not the next one.
    CHECK(send(sv[1], "0123456789", 10, 0) == 10, "%s send 10", name);
    CHECK(send(sv[1], "next", 4, 0) == 4, "%s send next", name);
    CHECK(recv(sv[0], buf, 4, 0) == 4 && !memcmp(buf, "0123", 4), "%s truncated recv", name);
    CHECK(recv(sv[0], buf, sizeof buf, 0) == 4 && !memcmp(buf, "next", 4), "%s after truncation", name);
    close(sv[0]);
    close(sv[1]);
}

int main(void)
{
    signal(SIGPIPE, SIG_IGN);
    boundaries(SOCK_SEQPACKET, "seqpacket");
    boundaries(SOCK_DGRAM, "dgram");
    boundaries(SOCK_SEQPACKET | SOCK_CLOEXEC | SOCK_NONBLOCK, "seqpacket flags");

    int sv[2];
    char buf[256];
    CHECK(socketpair(AF_UNIX, SOCK_SEQPACKET, 0, sv) == 0, "socketpair");

    // A gathered sendmsg is one message; a scattered recvmsg fills in order.
    struct iovec out[2] = {{"head", 4}, {"-body", 5}};
    struct msghdr msg = {.msg_iov = out, .msg_iovlen = 2};
    CHECK(sendmsg(sv[0], &msg, 0) == 9, "gathered sendmsg");
    char a[3], b[16];
    struct iovec in[2] = {{a, 3}, {b, sizeof b}};
    struct msghdr rmsg = {.msg_iov = in, .msg_iovlen = 2};
    CHECK(recvmsg(sv[1], &rmsg, 0) == 9 && !memcmp(a, "hea", 3) && !memcmp(b, "d-body", 6),
        "scattered recvmsg");

    // MSG_TRUNC in msg_flags, and MSG_TRUNC as a flag returns the real length.
    CHECK(send(sv[0], "truncate-me", 11, 0) == 11, "send truncate-me");
    struct iovec small = {buf, 3};
    struct msghdr tmsg = {.msg_iov = &small, .msg_iovlen = 1};
    CHECK(recvmsg(sv[1], &tmsg, 0) == 3 && (tmsg.msg_flags & MSG_TRUNC), "msg_flags MSG_TRUNC");
    CHECK(send(sv[0], "abcdef", 6, 0) == 6, "send abcdef");
    CHECK(recv(sv[1], buf, 2, MSG_TRUNC) == 6, "recv MSG_TRUNC returns full length");

    // MSG_PEEK leaves the message queued.
    CHECK(send(sv[0], "peek", 4, 0) == 4, "send peek");
    CHECK(recv(sv[1], buf, sizeof buf, MSG_PEEK) == 4, "peek");
    CHECK(recv(sv[1], buf, sizeof buf, 0) == 4 && !memcmp(buf, "peek", 4), "read after peek");

    // A zero-length message is delivered as one.
    CHECK(send(sv[0], "", 0, 0) == 0, "send empty");
    CHECK(send(sv[0], "z", 1, 0) == 1, "send z");
    CHECK(recv(sv[1], buf, sizeof buf, 0) == 0, "recv empty");
    CHECK(recv(sv[1], buf, sizeof buf, 0) == 1 && buf[0] == 'z', "recv after empty");

    // SCM_RIGHTS with a pipe and with a socket (the crash helper passes its
    // connectors), header and payload as separate messages.
    int p[2], other[2], fd, flags;
    CHECK(pipe(p) == 0, "pipe");
    CHECK(socketpair(AF_UNIX, SOCK_SEQPACKET, 0, other) == 0, "second socketpair");
    CHECK(send_fd(sv[0], "HDR", 3, p[1]) == 3, "send pipe fd");
    CHECK(send(sv[0], "payload", 7, 0) == 7, "send payload");
    CHECK(send_fd(sv[0], "SOCK", 4, other[1]) == 4, "send socket fd");
    CHECK(recv_fd(sv[1], buf, 3, &fd, &flags) == 3 && fd >= 0 && !(flags & MSG_CTRUNC),
        "recv pipe fd");
    CHECK(write(fd, "x", 1) == 1 && read(p[0], buf, 1) == 1 && buf[0] == 'x', "use passed pipe");
    close(fd);
    CHECK(recv_fd(sv[1], buf, 7, &fd, &flags) == 7 && fd < 0, "payload has no fd");
    CHECK(recv_fd(sv[1], buf, 4, &fd, &flags) == 4 && fd >= 0, "recv socket fd");
    CHECK(send(fd, "via", 3, 0) == 3 && recv(other[0], buf, sizeof buf, 0) == 3, "use passed socket");
    close(fd);
    close(other[0]);
    close(other[1]);
    close(p[0]);
    close(p[1]);

    // Non-blocking: EAGAIN when empty, poll, and whole messages only when full.
    CHECK(fcntl(sv[1], F_SETFL, fcntl(sv[1], F_GETFL) | O_NONBLOCK) == 0, "O_NONBLOCK");
    CHECK(recv(sv[1], buf, sizeof buf, 0) == -1 && errno == EAGAIN, "EAGAIN when empty");
    struct pollfd pfd = {sv[1], POLLIN, 0};
    CHECK(poll(&pfd, 1, 0) == 0, "poll empty");
    static char big[60000];
    memset(big, 'b', sizeof big);
    int sent = 0;
    while (send(sv[0], big, sizeof big, MSG_DONTWAIT) == (ssize_t)sizeof big) { sent++; }
    CHECK(errno == EAGAIN && sent == 2, "fill: %d messages then errno %d", sent, errno);
    CHECK(poll(&pfd, 1, 0) == 1 && (pfd.revents & POLLIN), "poll readable");
    for (int i = 0; i < sent; i++) {
        CHECK(recv(sv[1], big, sizeof big, 0) == (ssize_t)sizeof big, "drain %d", i);
    }
    CHECK(send(sv[0], big, 200000, 0) == -1 && errno == EMSGSIZE, "EMSGSIZE");

    // Blocking receive across processes.
    pid_t pid = fork();
    if (pid == 0) {
        usleep(100000);
        send(sv[0], "from child", 10, 0);
        _exit(0);
    }
    CHECK(fcntl(sv[1], F_SETFL, 0) == 0, "blocking again");
    CHECK(recv(sv[1], buf, sizeof buf, 0) == 10 && !memcmp(buf, "from child", 10), "blocking recv");
    int status;
    waitpid(pid, &status, 0);

    // EOF and EPIPE after the peer closes.
    close(sv[0]);
    CHECK(recv(sv[1], buf, sizeof buf, 0) == 0, "EOF");
    CHECK(send(sv[1], "x", 1, MSG_NOSIGNAL) == -1 && errno == EPIPE, "EPIPE");
    close(sv[1]);

    // socket/bind/listen/connect/accept with SOCK_SEQPACKET.
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    strcpy(addr.sun_path + 1, "seqpacket-test"); // abstract
    socklen_t alen = offsetof(struct sockaddr_un, sun_path) + 1 + strlen("seqpacket-test");
    int srv = socket(AF_UNIX, SOCK_SEQPACKET, 0);
    CHECK(srv >= 0, "socket seqpacket");
    CHECK(bind(srv, (struct sockaddr *)&addr, alen) == 0, "bind");
    CHECK(listen(srv, 4) == 0, "listen");
    int stream = socket(AF_UNIX, SOCK_STREAM, 0);
    CHECK(connect(stream, (struct sockaddr *)&addr, alen) == -1 && errno == EPROTOTYPE,
        "stream to seqpacket listener");
    close(stream);
    int cli = socket(AF_UNIX, SOCK_SEQPACKET, 0);
    CHECK(connect(cli, (struct sockaddr *)&addr, alen) == 0, "connect");
    int acc = accept(srv, NULL, NULL);
    CHECK(acc >= 0, "accept");
    CHECK(send(cli, "one", 3, 0) == 3 && send(cli, "two", 3, 0) == 3, "client sends");
    CHECK(recv(acc, buf, sizeof buf, 0) == 3 && recv(acc, buf, sizeof buf, 0) == 3,
        "accepted socket keeps boundaries");
    close(cli);
    close(acc);
    close(srv);

    // Socket options, and the Breakpad crash channel: SO_PASSCRED on the
    // server end makes every received message carry SCM_CREDENTIALS.
    int type = 0, on = 1, val = -1;
    socklen_t len = sizeof type;
    CHECK(socketpair(AF_UNIX, SOCK_SEQPACKET, 0, sv) == 0, "breakpad socketpair");
    CHECK(getsockopt(sv[0], SOL_SOCKET, SO_TYPE, &type, &len) == 0 && type == SOCK_SEQPACKET &&
        len == sizeof type, "SO_TYPE seqpacket %d", type);
    CHECK(setsockopt(sv[0], SOL_SOCKET, SO_PASSCRED, &on, sizeof on) == 0, "SO_PASSCRED");
    len = sizeof val;
    CHECK(getsockopt(sv[0], SOL_SOCKET, SO_PASSCRED, &val, &len) == 0 && val == 1, "get SO_PASSCRED");
    CHECK(fcntl(sv[0], F_SETFL, O_NONBLOCK) == 0, "server O_NONBLOCK");
    struct ucred peer = {0};
    len = sizeof peer;
    CHECK(getsockopt(sv[1], SOL_SOCKET, SO_PEERCRED, &peer, &len) == 0 && peer.pid == getpid() &&
        len == sizeof peer, "SO_PEERCRED pid %d", peer.pid);
    CHECK(setsockopt(sv[0], SOL_SOCKET, SO_KEEPALIVE, &on, sizeof on) == -1 && errno == ENOPROTOOPT,
        "unknown option");
    pid = fork();
    if (pid == 0) {
        int pp[2];
        pipe(pp);
        send_fd(sv[1], "crash", 5, pp[1]);
        _exit(0);
    }
    waitpid(pid, &status, 0);
    char control[CMSG_SPACE(sizeof(int)) + CMSG_SPACE(sizeof(struct ucred))];
    struct iovec civ = {buf, sizeof buf};
    struct msghdr cmsg_msg = {.msg_iov = &civ, .msg_iovlen = 1,
        .msg_control = control, .msg_controllen = sizeof control};
    CHECK(recvmsg(sv[0], &cmsg_msg, 0) == 5, "recv crash message");
    int got_fd = -1;
    pid_t got_pid = 0;
    for (struct cmsghdr *c = CMSG_FIRSTHDR(&cmsg_msg); c; c = CMSG_NXTHDR(&cmsg_msg, c)) {
        if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS) {
            memcpy(&got_fd, CMSG_DATA(c), sizeof got_fd);
        }
        if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_CREDENTIALS &&
            c->cmsg_len == CMSG_LEN(sizeof(struct ucred))) {
            struct ucred cred;
            memcpy(&cred, CMSG_DATA(c), sizeof cred);
            got_pid = cred.pid;
        }
    }
    CHECK(got_fd >= 0 && got_pid == pid && !(cmsg_msg.msg_flags & MSG_CTRUNC),
        "SCM_RIGHTS fd %d and SCM_CREDENTIALS pid %d (child %d)", got_fd, got_pid, pid);
    close(got_fd);
    // Without SO_PASSCRED there are no credentials.
    CHECK(send(sv[0], "plain", 5, 0) == 5, "send plain");
    cmsg_msg.msg_controllen = sizeof control;
    CHECK(recvmsg(sv[1], &cmsg_msg, 0) == 5 && cmsg_msg.msg_controllen == 0, "no credentials");
    close(sv[0]);
    close(sv[1]);
    CHECK(socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0, "stream pair");
    len = sizeof type;
    CHECK(getsockopt(sv[0], SOL_SOCKET, SO_TYPE, &type, &len) == 0 && type == SOCK_STREAM,
        "SO_TYPE stream %d", type);
    close(sv[0]);
    close(sv[1]);

    if (failures) {
        printf("%d failures\n", failures);
        return 1;
    }
    printf("PASS\n");
    return 0;
}
