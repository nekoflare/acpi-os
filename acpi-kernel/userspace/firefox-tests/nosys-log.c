// The kernel's syscall gap logger (FIREFOX_PORT.md P1) prints one serial
// line per unsupported (process name, syscall, sub-code). This program
// makes each unsupported call twice; every line must appear exactly once.
// expect-once: nr=1000 err=38
// expect-once: nr=1001 err=38
// expect-once: nr=1002 err=38
// expect-once: nr=157 sub=0x7fff err=38
// expect-once: nr=16 sub=0x5a5a err=25
// expect-once: nr=72 sub=0x7777 err=22
// expect-once: nr=41 sub=0x1000000003 err=97
#include <errno.h>
#include <stdio.h>
#include <sys/syscall.h>
#include <unistd.h>

static int check(long ret, int err, const char *what)
{
    if (ret != -1 || errno != err) {
        printf("%s: ret=%ld errno=%d, want errno %d\n", what, ret, errno, err);
        return 1;
    }
    return 0;
}

int main(void)
{
    int pipefd[2];
    int bad = 0;

    if (pipe(pipefd)) {
        perror("pipe");
        return 1;
    }
    for (int i = 0; i < 2; i++) {
        bad |= check(syscall(1000), ENOSYS, "syscall 1000");
        bad |= check(syscall(1001, 1, 2, 3), ENOSYS, "syscall 1001");
        bad |= check(syscall(1002), ENOSYS, "syscall 1002");
        // Unknown prctl option, ioctl request and fcntl command.
        bad |= check(syscall(SYS_prctl, 0x7fff, 0, 0, 0, 0), ENOSYS, "prctl");
        bad |= check(syscall(SYS_ioctl, pipefd[0], 0x5a5a, 0), ENOTTY, "ioctl");
        bad |= check(syscall(SYS_fcntl, pipefd[0], 0x7777, 0), EINVAL, "fcntl");
        // AF_NETLINK, SOCK_RAW.
        bad |= check(syscall(SYS_socket, 16, 3, 0), EAFNOSUPPORT, "socket");
    }
    if (bad) return 1;
    puts("PASS");
    return 0;
}
