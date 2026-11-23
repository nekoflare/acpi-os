// E1: the OpenJDK launcher starts the Zero VM and prints its version, both
// directly and through a symbolic link such as the desktop's /bin/java.
// disk: openjdk musl-runtime alsa-lib
// timeout: 300
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define JAVA "/usr/lib/jvm/java-21-openjdk/bin/java"
#define JAVA_LINK "/usr/bin/java"

static char output[16384];

static long long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000LL + ts.tv_nsec / 1000000;
}

// Run java with the given arguments; collect stdout and stderr in output.
static int run_java(const char *path, char *const argv[])
{
    int pipe_fds[2];
    if (pipe(pipe_fds)) { return -1; }
    pid_t pid = fork();
    if (pid < 0) { return -1; }
    if (pid == 0) {
        dup2(pipe_fds[1], 1);
        dup2(pipe_fds[1], 2);
        close(pipe_fds[0]);
        close(pipe_fds[1]);
        char *envp[] = {"PATH=/usr/bin:/bin", "HOME=/", NULL};
        execve(path, argv, envp);
        printf("execve failed errno=%d\n", errno);
        _exit(127);
    }
    close(pipe_fds[1]);
    size_t total = 0;
    ssize_t got;
    while ((got = read(pipe_fds[0], output + total, sizeof output - 1 - total)) > 0) { total += got; }
    output[total] = 0;
    close(pipe_fds[0]);
    int status;
    if (waitpid(pid, &status, 0) != pid) { return -1; }
    return status;
}

int main(void)
{
    if (access(JAVA, X_OK)) {
        printf("FAIL %s missing errno=%d\n", JAVA, errno);
        return 1;
    }
    const char *paths[] = {JAVA, JAVA_LINK};
    for (unsigned i = 0; i < sizeof paths / sizeof *paths; i++) {
        long long start = now_ms();
        char *const zero[] = {"java", "-zero", "-version", NULL};
        int status = run_java(paths[i], zero);
        printf("%s", output);
        printf("%s -zero -version: status %#x in %lld ms\n", paths[i], status, now_ms() - start);
        if (status != 0) { printf("FAIL exit status\n"); return 1; }
        if (!strstr(output, "Zero VM") || !strstr(output, "21.0.13")) {
            printf("FAIL version text\n");
            return 1;
        }
    }
    printf("PASS\n");
    return 0;
}
