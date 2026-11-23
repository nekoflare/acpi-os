// D1: at least 1024 descriptors per process, EMFILE past the limit, and
// close-on-exec bits above descriptor 64 across fork and execve.
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

static int fail(const char *what)
{
    printf("FAIL %s errno=%d\n", what, errno);
    return 1;
}

static int is_open(int fd)
{
    return fcntl(fd, F_GETFD) >= 0;
}

int main(int argc, char **argv)
{
    if (argc > 1 && !strcmp(argv[1], "child")) {
        // 700 was close-on-exec, 800 was not.
        if (is_open(700) || errno != EBADF) { return 2; }
        if (!is_open(800)) { return 3; }
        char byte;
        if (read(800, &byte, 1) != 1 || byte != 'z') { return 4; }
        return 0;
    }

    struct rlimit limit;
    if (getrlimit(RLIMIT_NOFILE, &limit)) { return fail("getrlimit"); }
    if (limit.rlim_cur < 1024) {
        printf("RLIMIT_NOFILE=%lu\n", (unsigned long)limit.rlim_cur);
        return fail("limit");
    }
    printf("limit %lu\n", (unsigned long)limit.rlim_cur);

    // Fill the table with pipes until EMFILE.
    int fds[2], count = 0, last = -1;
    for (;;) {
        if (pipe(fds)) { break; }
        count += 2;
        last = fds[1];
    }
    if (errno != EMFILE) { return fail("expected EMFILE"); }
    if (last < 1000) { printf("last=%d\n", last); return fail("too few"); }
    // A pipe needs two slots, so one may still be free for open.
    int single;
    while ((single = open("/", O_RDONLY)) >= 0) { count++; }
    if (errno != EMFILE) { return fail("open EMFILE"); }
    if (count < 1021) { printf("count=%d\n", count); return fail("not full"); }
    printf("opened %d descriptors, highest %d\n", count, last);

    // Writing through the highest pair proves the slots really hold pipes.
    char byte = 'q';
    if (write(last, &byte, 1) != 1 || read(last - 1, &byte, 1) != 1 || byte != 'q') {
        return fail("high pipe");
    }
    for (int fd = 3; fd < (int)limit.rlim_cur; fd++) { close(fd); }
    if (!is_open(1)) { return fail("stdout closed"); }

    // dup2, F_DUPFD and close-on-exec above 64.
    if (pipe(fds)) { return fail("pipe"); }
    if (dup2(fds[0], 1000) != 1000) { return fail("dup2 1000"); }
    if (dup2(fds[0], (int)limit.rlim_cur) >= 0 || errno != EBADF) { return fail("dup2 limit"); }
    int high = fcntl(fds[0], F_DUPFD_CLOEXEC, 900);
    if (high != 900 || fcntl(900, F_GETFD) != FD_CLOEXEC) { return fail("F_DUPFD_CLOEXEC"); }
    if (fcntl(1000, F_GETFD) != 0) { return fail("dup2 cloexec"); }
    if (fcntl(1000, F_SETFD, FD_CLOEXEC) || fcntl(1000, F_GETFD) != FD_CLOEXEC) {
        return fail("F_SETFD");
    }
    if (fcntl(1000, F_SETFD, 0) || fcntl(1000, F_GETFD) != 0) { return fail("F_SETFD clear"); }
    close(900);
    close(1000);

    // fork copies the table; the child's closes do not affect the parent.
    if (dup2(fds[1], 999) != 999) { return fail("dup2 999"); }
    pid_t pid = fork();
    if (pid == 0) {
        if (write(999, "k", 1) != 1) { _exit(5); }
        close(999);
        _exit(is_open(999) ? 6 : 0);
    }
    int status;
    if (waitpid(pid, &status, 0) != pid || status != 0) {
        printf("status=%#x\n", status);
        return fail("fork child");
    }
    if (!is_open(999) || read(fds[0], &byte, 1) != 1 || byte != 'k') { return fail("fork table"); }
    printf("fork ok\n");

    // execve closes close-on-exec descriptors anywhere in the table.
    if (dup3(fds[0], 700, O_CLOEXEC) != 700) { return fail("dup3"); }
    if (dup2(fds[0], 800) != 800) { return fail("dup2 800"); }
    if (write(fds[1], "z", 1) != 1) { return fail("write z"); }
    pid = fork();
    if (pid == 0) {
        char *args[] = {argv[0], "child", NULL};
        char *env[] = {NULL};
        execve("/bin/fd-limit.elf", args, env);
        _exit(7);
    }
    if (waitpid(pid, &status, 0) != pid || status != 0) {
        printf("status=%#x\n", status);
        return fail("exec child");
    }
    printf("exec ok\n");
    printf("PASS\n");
    return 0;
}
