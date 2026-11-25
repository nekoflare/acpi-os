// Kernel gaps Alpine's firefox-esr hit on its way to a running browser
// (FIREFOX_PORT.md, P3 follow-up): prctl, every getrlimit resource, memfd
// with MFD_NOEXEC_SEAL and Firefox's seals, reopening a memfd through
// /proc/self/fd, a user GS base for wasm2c's segue, and removing the last
// epoll entry (which read one entry before the interest table), link
// (EPERM), fadvise, waitid (Firefox's process watcher peeks at exited
// children with WNOWAIT before reaping them), and /dev/urandom, /dev/random
// and /dev/zero (NSS, Firefox's TLS, fails to start without /dev/urandom).
#define _GNU_SOURCE
#include <sched.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/epoll.h>
#include <poll.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/prctl.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

#define ARCH_SET_GS 0x1001
#define ARCH_GET_FS 0x1003
#define ARCH_GET_GS 0x1004
#ifndef MFD_NOEXEC_SEAL
#define MFD_NOEXEC_SEAL 8U
#endif
#ifndef MFD_EXEC
#define MFD_EXEC 0x10U
#endif
#ifndef F_SEAL_FUTURE_WRITE
#define F_SEAL_FUTURE_WRITE 0x10
#endif
#ifndef F_SEAL_EXEC
#define F_SEAL_EXEC 0x20
#endif
#ifndef PR_SET_PTRACER
#define PR_SET_PTRACER 0x59616d61
#endif
#ifndef PR_SET_VMA
#define PR_SET_VMA 0x53564d41
#endif

static int failures;

#define CHECK(cond, ...) do { \
    if (!(cond)) { printf("FAIL line %d: ", __LINE__); printf(__VA_ARGS__); \
        printf(" (errno=%d)\n", errno); failures++; } } while (0)

static unsigned long read_gs_qword(void)
{
    unsigned long value;
    __asm__ volatile("movq %%gs:0, %0" : "=r"(value));
    return value;
}

int main(void)
{
    // prctl
    char name[16] = "";
    CHECK(prctl(PR_SET_NAME, "worker") == 0, "PR_SET_NAME");
    CHECK(prctl(PR_GET_NAME, name) == 0 && name[0], "PR_GET_NAME '%s'", name);
    CHECK(prctl(PR_SET_DUMPABLE, 1) == 0 && prctl(PR_GET_DUMPABLE) == 1, "dumpable");
    int sig = -1;
    CHECK(prctl(PR_SET_PDEATHSIG, 9) == 0 && prctl(PR_GET_PDEATHSIG, &sig) == 0 && sig == 0,
        "pdeathsig %d", sig);
    CHECK(prctl(PR_SET_PTRACER, getppid()) == 0, "PR_SET_PTRACER");
    CHECK(prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == 0, "PR_SET_NO_NEW_PRIVS");
    CHECK(prctl(PR_GET_SECCOMP) == 0, "PR_GET_SECCOMP");
    CHECK(prctl(PR_SET_SECCOMP, 1) == -1 && errno == EINVAL, "PR_SET_SECCOMP");
    CHECK(prctl(PR_SET_VMA, 0, 0, 0, 0) == -1 && errno == EINVAL, "PR_SET_VMA");

    // getrlimit: every resource answers.
    struct rlimit rl;
    CHECK(getrlimit(RLIMIT_AS, &rl) == 0 && rl.rlim_cur == RLIM_INFINITY, "RLIMIT_AS");
    CHECK(getrlimit(RLIMIT_CORE, &rl) == 0 && rl.rlim_cur == 0, "RLIMIT_CORE");
    CHECK(getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur > 0, "RLIMIT_NOFILE");
    for (int r = 0; r < RLIM_NLIMITS; r++) {
        CHECK(getrlimit(r, &rl) == 0, "getrlimit %d", r);
    }

    // memfd as Firefox's IPC shared memory uses it.
    int fd = memfd_create("mozilla-ipc-test", MFD_CLOEXEC | MFD_ALLOW_SEALING | MFD_NOEXEC_SEAL);
    CHECK(fd >= 0, "memfd_create NOEXEC_SEAL");
    CHECK(fcntl(fd, F_GET_SEALS) == F_SEAL_EXEC, "NOEXEC_SEAL seals %#x", fcntl(fd, F_GET_SEALS));
    CHECK(memfd_create("x", MFD_EXEC | MFD_NOEXEC_SEAL) == -1 && errno == EINVAL, "EXEC|NOEXEC_SEAL");
    CHECK(ftruncate(fd, 4096) == 0, "ftruncate");
    CHECK(fcntl(fd, F_ADD_SEALS, F_SEAL_SHRINK | F_SEAL_GROW) == 0, "size seals");
    char path[64];
    snprintf(path, sizeof path, "/proc/self/fd/%d", fd);
    int ro = open(path, O_RDONLY | O_CLOEXEC);
    CHECK(ro >= 0 && ro != fd, "reopen %s", path);
    snprintf(path, sizeof path, "/proc/%d/fd/%d", getpid(), fd);
    int ro2 = open(path, O_RDONLY | O_CLOEXEC);
    CHECK(ro2 >= 0, "reopen %s", path);
    close(ro2);
    CHECK(open("/proc/self/fd/999", O_RDONLY) == -1 && errno == ENOENT, "missing fd");
    char *rw = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    char *rd = mmap(NULL, 4096, PROT_READ, MAP_SHARED, ro, 0);
    CHECK(rw != MAP_FAILED && rd != MAP_FAILED, "map both");
    if (rw != MAP_FAILED && rd != MAP_FAILED) {
        strcpy(rw, "shared");
        CHECK(!strcmp(rd, "shared"), "read-only view sees writes");
    }
    // Freeze: FUTURE_WRITE is not supported yet, so Firefox retries without it.
    int seals = F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL;
    CHECK(fcntl(fd, F_ADD_SEALS, seals | F_SEAL_FUTURE_WRITE) == -1 && errno == EINVAL,
        "FUTURE_WRITE refused");
    CHECK(fcntl(fd, F_ADD_SEALS, seals) == 0, "freeze seals");
    CHECK(fcntl(fd, F_ADD_SEALS, F_SEAL_GROW) == -1 && errno == EPERM, "sealed seals");
    close(fd);
    close(ro);

    // User GS base, inherited by fork.
    static unsigned long gs_block[2] = {0x5e6e5e6e1234ULL, 0};
    unsigned long base = 0;
    CHECK(syscall(SYS_arch_prctl, ARCH_SET_GS, gs_block) == 0, "ARCH_SET_GS");
    CHECK(syscall(SYS_arch_prctl, ARCH_GET_GS, &base) == 0 && base == (unsigned long)gs_block,
        "ARCH_GET_GS %#lx", base);
    CHECK(read_gs_qword() == gs_block[0], "%%gs:0 reads the block");
    sched_yield();
    usleep(20000); // Other tasks run; the GS base must come back.
    CHECK(read_gs_qword() == gs_block[0], "%%gs:0 after a reschedule");
    pid_t pid = fork();
    if (pid == 0) {
        _exit(read_gs_qword() == gs_block[0] ? 0 : 1);
    }
    int status;
    CHECK(waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0,
        "child inherits GS base");
    CHECK(syscall(SYS_arch_prctl, ARCH_SET_GS, 0) == 0, "clear GS base");
    unsigned long fsbase = 0;
    CHECK(syscall(SYS_arch_prctl, ARCH_GET_FS, &fsbase) == 0 && fsbase != 0, "ARCH_GET_FS");

    // No hard links: EPERM (not ENOSYS) so fontconfig's cache lock falls
    // back to mkdir. fadvise is accepted and ignored.
    CHECK(link("/proc/self/exe", "/tmp/hardlink") == -1 && errno == EPERM, "link EPERM");
    CHECK(linkat(AT_FDCWD, "/a", AT_FDCWD, "/b", 0) == -1 && errno == EPERM, "linkat EPERM");
    CHECK(posix_fadvise(0, 0, 0, POSIX_FADV_SEQUENTIAL) == 0, "fadvise");

    // waitid: peek with WNOWAIT, then reap.
    siginfo_t si;
    pid = fork();
    if (pid == 0) {
        _exit(7);
    }
    memset(&si, 0xff, sizeof si);
    CHECK(waitid(P_PID, pid, &si, WEXITED | WNOWAIT) == 0 && si.si_pid == pid &&
        si.si_signo == SIGCHLD && si.si_code == CLD_EXITED && si.si_status == 7,
        "waitid WNOWAIT pid=%d code=%d status=%d", si.si_pid, si.si_code, si.si_status);
    CHECK(waitid(P_ALL, 0, &si, WEXITED | WNOHANG | WNOWAIT) == 0 && si.si_pid == pid,
        "child still waitable");
    CHECK(waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 7,
        "waitpid reaps after WNOWAIT");
    pid = fork();
    if (pid == 0) {
        usleep(200000);
        _exit(0);
    }
    memset(&si, 0xff, sizeof si);
    CHECK(waitid(P_PID, pid, &si, WEXITED | WNOHANG) == 0 && si.si_pid == 0, "WNOHANG running");
    CHECK(kill(pid, SIGKILL) == 0, "kill");
    CHECK(waitid(P_ALL, 0, &si, WEXITED) == 0 && si.si_pid == pid && si.si_code == CLD_KILLED &&
        si.si_status == SIGKILL, "waitid killed code=%d status=%d", si.si_code, si.si_status);
    CHECK(waitid(P_ALL, 0, &si, WEXITED) == -1 && errno == ECHILD, "ECHILD");
    CHECK(waitid(P_PID, pid, &si, 0) == -1 && errno == EINVAL, "no wait flags");
    CHECK(waitid(3, 0, &si, WEXITED) == -1 && errno == EINVAL, "P_PIDFD");

    // /dev/urandom, /dev/random, /dev/zero.
    static const char *const devs[] = {"/dev/urandom", "/dev/random", "/dev/zero"};
    for (int d = 0; d < 3; d++) {
        unsigned char bytes[300];
        memset(bytes, 0xa5, sizeof bytes);
        int dev = open(devs[d], O_RDWR | O_CLOEXEC);
        CHECK(dev >= 0, "open %s", devs[d]);
        CHECK(read(dev, bytes, sizeof bytes) == (ssize_t)sizeof bytes, "read %s", devs[d]);
        int zeros = 0;
        for (size_t i = 0; i < sizeof bytes; i++) { zeros += bytes[i] == 0; }
        if (d == 2) {
            CHECK(zeros == (int)sizeof bytes, "/dev/zero reads zeros (%d)", zeros);
        } else {
            CHECK(zeros < 20, "%s looks random (%d zero bytes)", devs[d], zeros);
        }
        CHECK(write(dev, bytes, 10) == 10, "write %s", devs[d]);
        struct pollfd pfd = {.fd = dev, .events = POLLIN | POLLOUT};
        CHECK(poll(&pfd, 1, 0) == 1 && (pfd.revents & (POLLIN | POLLOUT)) == (POLLIN | POLLOUT),
            "poll %s", devs[d]);
        struct stat st;
        CHECK(fstat(dev, &st) == 0 && S_ISCHR(st.st_mode), "%s is a character device", devs[d]);
        close(dev);
    }
    int wo = open("/dev/urandom", O_WRONLY);
    char byte;
    CHECK(wo >= 0 && read(wo, &byte, 1) == -1 && errno == EBADF, "write-only urandom read EBADF");
    close(wo);

    // epoll: add two, delete both (the second delete scans down to index 0).
    int ep = epoll_create1(EPOLL_CLOEXEC);
    int p[2];
    CHECK(ep >= 0 && pipe(p) == 0, "epoll and pipe");
    struct epoll_event ev = {.events = EPOLLIN};
    CHECK(epoll_ctl(ep, EPOLL_CTL_ADD, p[0], &ev) == 0, "add read end");
    ev.events = EPOLLOUT;
    CHECK(epoll_ctl(ep, EPOLL_CTL_ADD, p[1], &ev) == 0, "add write end");
    CHECK(epoll_ctl(ep, EPOLL_CTL_DEL, p[1], NULL) == 0, "delete last");
    CHECK(epoll_ctl(ep, EPOLL_CTL_DEL, p[0], NULL) == 0, "delete first");
    CHECK(epoll_ctl(ep, EPOLL_CTL_ADD, p[0], &ev) == 0, "add again");
    close(ep);
    close(p[0]);
    close(p[1]);

    if (failures) {
        printf("%d failures\n", failures);
        return 1;
    }
    printf("PASS\n");
    return 0;
}
