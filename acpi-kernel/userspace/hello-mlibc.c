#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

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

int main(int argc, char **argv)
{
    if (argc < 1 || strcmp(argv[0], "hello.elf") || !isatty(STDOUT_FILENO))
        return 1;

    unsigned char *page = mmap(NULL, 4096, PROT_READ | PROT_WRITE,
                               MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (page == MAP_FAILED || page[0] != 0)
        return 1;
    page[0] = 42;
    if (check_fork(page) || munmap(page, 4096))
        return 1;

    enum { NAME_CAPACITY = 64 };
    char *name = malloc(NAME_CAPACITY);
    if (!name || tls_cookie != 0x1234 || write_all("What is your name?\n"))
        return 1;

    size_t length = 0;
    for (;;) {
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
