#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

int check_x11(void);

static _Thread_local volatile unsigned tls_cookie = 0x1234;

static int write_all(const char *text)
{
    size_t remaining = strlen(text);
    while (remaining) {
        ssize_t count = write(STDOUT_FILENO, text, remaining);
        if (count < 0 && errno == EINTR)
            continue;
        if (count <= 0)
            return -1;
        text += count;
        remaining -= (size_t)count;
    }
    return 0;
}

static int check_fork(unsigned char *page)
{
    int fd = open("/welcome.txt", O_RDONLY);
    if (fd < 0)
        return -1;

    pid_t parent = getpid();
    pid_t child = fork();
    if (child == 0) {
        char byte;
        if (getpid() == parent || getppid() != parent ||
            tls_cookie != 0x1234 || page[0] != 42 ||
            read(fd, &byte, 1) != 1 || byte != 'W' || close(fd))
            _exit(1);
        tls_cookie = 0x5678;
        page[0] = 99;
        _exit(37);
    }

    int status;
    char byte;
    if (child < 0 || waitpid(child, &status, 0) != child ||
        !WIFEXITED(status) || WEXITSTATUS(status) != 37 ||
        page[0] != 42 || tls_cookie != 0x1234 ||
        read(fd, &byte, 1) != 1 || byte != 'e' || close(fd))
        return -1;
    if (waitpid(child, &status, WNOHANG) != -1 || errno != ECHILD)
        return -1;

    enum { X86_64_SYS_FORK = 57 };
    child = (pid_t)syscall(X86_64_SYS_FORK);
    if (child == 0)
        _exit(19);
    if (child < 0 || waitpid(child, &status, 0) != child ||
        !WIFEXITED(status) || WEXITSTATUS(status) != 19)
        return -1;
    return 0;
}

static int check_poll(void)
{
    enum { X86_64_SYS_POLL = 7 };
    struct pollfd fds[] = {
        {.fd = -1, .events = POLLIN, .revents = POLLIN},
        {.fd = 99, .events = POLLIN},
        {.fd = STDOUT_FILENO, .events = POLLOUT},
    };
    if (syscall(X86_64_SYS_POLL, fds, 3UL, 0L) != 2 || fds[0].revents ||
        fds[1].revents != POLLNVAL || fds[2].revents != POLLOUT)
        return -1;

    struct pollfd input = {.fd = STDIN_FILENO, .events = POLLIN, .revents = POLLIN};
    if (poll(&input, 1, 20) != 0 || input.revents)
        return -1;
    return 0;
}

static int check_dev_null(void)
{
    struct stat info;
    unsigned char data[32] = {0};
    struct pollfd ready;
    int fd = open("/dev/null", O_RDWR);
    if (fd < 0) { write_all("/dev/null open failed\n"); return -1; }
    if (fstat(fd, &info)) { write_all("/dev/null fstat failed\n"); return -1; }
    if (!S_ISCHR(info.st_mode) || (info.st_mode & 0777) != 0666) { write_all("/dev/null stat mismatch\n"); return -1; }
    if (read(fd, data, sizeof(data)) != 0) { write_all("/dev/null read failed\n"); return -1; }
    if (write(fd, data, sizeof(data)) != (ssize_t)sizeof(data)) { write_all("/dev/null write failed\n"); return -1; }
    ready.fd = fd;
    ready.events = POLLIN | POLLOUT;
    ready.revents = 0;
    if (poll(&ready, 1, 0) != 1 ||
        ready.revents != (POLLIN | POLLOUT)) { write_all("/dev/null poll failed\n"); return -1; }
    if (close(fd)) { write_all("/dev/null close failed\n"); return -1; }

    fd = open("/dev/null", O_RDONLY);
    if (fd < 0)
        return -1;
    errno = 0;
    if (write(fd, data, 1) != -1 || errno != EBADF) { write_all("/dev/null readonly check failed\n"); return -1; }
    if (close(fd))
        return -1;
    fd = open("/dev/null", O_WRONLY);
    if (fd < 0)
        return -1;
    errno = 0;
    ssize_t count = read(fd, data, 1);
    if (count != -1) { write_all("/dev/null writeonly read returned non-error\n"); return -1; }
    if (errno != EBADF) { write_all("/dev/null writeonly read errno mismatch\n"); return -1; }
    if (close(fd))
        return -1;
    return 0;
}

static int stream_client(int listener, const struct sockaddr_un *address, socklen_t size)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    unsigned char data[4096];
    if (close(listener) || fd < 0 || connect(fd, (const struct sockaddr *)address, size))
        return 1;

    for (size_t i = 0; i < sizeof(data); ++i)
        data[i] = (unsigned char)(i % 251);
    size_t sent = 0;
    while (sent < sizeof(data)) {
        ssize_t count = write(fd, data + sent, sizeof(data) - sent);
        if (count <= 0)
            return 1;
        sent += (size_t)count;
    }

    unsigned char reply;
    if (read(fd, &reply, 1) != 1 || reply != 42 || close(fd))
        return 1;
    return 0;
}

static int check_unix_stream(void)
{
    const struct sockaddr_un address = {
        .sun_family = AF_UNIX,
        .sun_path = "/tmp/.X11-unix/X0",
    };
    const socklen_t size = offsetof(struct sockaddr_un, sun_path) + sizeof("/tmp/.X11-unix/X0");
    int listener = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (listener < 0 || fcntl(listener, F_GETFD) != FD_CLOEXEC ||
        bind(listener, (const struct sockaddr *)&address, size) || listen(listener, 2))
        return -1;
    if (fcntl(listener, F_SETFL, O_NONBLOCK) ||
        accept(listener, NULL, NULL) != -1 || errno != EAGAIN ||
        fcntl(listener, F_SETFL, 0))
        return -1;

    pid_t child = fork();
    if (child == 0)
        _exit(stream_client(listener, &address, size));
    if (child < 0)
        return -1;

    int fd = accept(listener, NULL, NULL);
    if (fd < 0 || close(listener))
        return -1;
    struct pollfd connection = {.fd = fd, .events = POLLIN};
    if (poll(&connection, 1, 1000) != 1 || connection.revents != POLLIN)
        return -1;

    unsigned char data[701];
    size_t received = 0;
    while (received < 4096) {
        ssize_t count = read(fd, data, sizeof(data));
        if (count <= 0)
            return -1;
        for (ssize_t i = 0; i < count; ++i, ++received) {
            if (data[i] != received % 251)
                return -1;
        }
    }
    data[0] = 42;
    if (received != 4096 || write(fd, data, 1) != 1 || read(fd, data, 1) != 0)
        return -1;
    if (poll(&connection, 1, 0) != 1 || !(connection.revents & POLLHUP) ||
        write(fd, data, 1) != -1 || errno != EPIPE || close(fd))
        return -1;
    int status;
    return waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status);
}

static int check_path_lookups(void)
{
    struct stat info;
    for (unsigned i = 0; i < 512; ++i) {
        if (stat("/./dev/../missing", &info) != -1 || errno != ENOENT)
            return -1;
    }
    if (stat("/.././dev/../welcome.txt", &info) || !S_ISREG(info.st_mode))
        return -1;
    return 0;
}

static int check_file_mapping(void)
{
    int fd = open("/welcome.txt", O_RDONLY);
    if (fd < 0)
        return -1;
    char *mapping = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_PRIVATE, fd, 0);
    if (mapping == MAP_FAILED) {
        close(fd);
        return -1;
    }
    int result = close(fd) || memcmp(mapping, "Welcome to the ASL kernel shell.\n", 32);
    mapping[0] = 'w';
    result |= munmap(mapping, 4096);
    return result;
}

int main(int argc, char **argv)
{
    if (argc < 1 || strcmp(argv[0], "hello.elf") || !isatty(STDOUT_FILENO))
        return 1;

    unsigned char *page = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                               MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (page == MAP_FAILED || page[0] != 0)
        return 1;
    page[0] = 42;
    if (check_fork(page)) { write_all("fork check failed\n"); return 1; }
    if (munmap(page, 4096)) { write_all("munmap check failed\n"); return 1; }
    if (check_poll()) { write_all("poll check failed\n"); return 1; }
    if (check_dev_null()) { write_all("/dev/null check failed\n"); return 1; }
    if (check_unix_stream()) { write_all("unix stream check failed\n"); return 1; }
    if (check_path_lookups()) { write_all("path lookup check failed\n"); return 1; }
    if (check_file_mapping()) { write_all("file mapping check failed\n"); return 1; }

    if (check_x11() || write_all("X11 setup, geometry, and framebuffer window verified in both byte orders\n"))
        return 1;

    enum { NAME_CAPACITY = 64 };
    char *name = malloc(NAME_CAPACITY);
    if (!name || tls_cookie != 0x1234 || write_all("What is your name?\n"))
        return 1;

    size_t length = 0;
    struct pollfd input = {.fd = STDIN_FILENO, .events = POLLIN};
    for (;;) {
        if (poll(&input, 1, -1) != 1 || input.revents != POLLIN)
            return 1;
        char key;
        ssize_t count = read(STDIN_FILENO, &key, 1);
        if (count < 0 && errno == EINTR)
            continue;
        if (count < 0)
            return 1;
        if (!count || key == '\n')
            break;

        if ((key == '\b' || key == 0x7f) && length) {
            --length;
            if (write_all("\b \b"))
                return 1;
        } else if (key >= ' ' && key <= '~' && length < NAME_CAPACITY - 1) {
            name[length++] = key;
            char echo[] = {key, '\0'};
            if (write_all(echo))
                return 1;
        }
    }
    if (tls_cookie != 0x1234)
        return 1;
    name[length] = '\0';

    char greeting[NAME_CAPACITY + 10];
    int count = snprintf(greeting, sizeof(greeting), "\nHello, %s!\n",
                         length ? name : "stranger");
    free(name);
    if (count < 0 || (size_t)count >= sizeof(greeting) || write_all(greeting))
        return 1;

    return write_all("mlibc C program verified fork, TLS, allocation, and console I/O\n") != 0;
}
