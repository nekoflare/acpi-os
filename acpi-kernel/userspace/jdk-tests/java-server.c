// E2: the Server VM prints its version with the template interpreter only,
// with C1 only and with full tiered compilation, then runs Hello World from
// source (the source launcher compiles it in-process with javac).
// disk: openjdk musl-runtime alsa-lib
// disk-rw
// timeout: 600
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define JAVA "/usr/lib/jvm/java-21-openjdk/bin/java"

static char output[65536];

static long long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000LL + ts.tv_nsec / 1000000;
}

// Run java with the given arguments; collect stdout and stderr in output.
static int run_java(char *const argv[])
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
        char *envp[] = {"PATH=/usr/bin:/bin", "HOME=/tmp", NULL};
        execve(JAVA, argv, envp);
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

static int step(const char *name, char *const argv[], const char *expect1, const char *expect2)
{
    long long start = now_ms();
    int status = run_java(argv);
    printf("%s", output);
    printf("%s: status %#x in %lld ms\n", name, status, now_ms() - start);
    if (status != 0) { printf("FAIL %s exit status\n", name); return 1; }
    if (!strstr(output, expect1) || (expect2 && !strstr(output, expect2))) {
        printf("FAIL %s output\n", name);
        return 1;
    }
    return 0;
}

int main(void)
{
    char *const xint[] = {"java", "-Xint", "-version", NULL};
    char *const c1[] = {"java", "-XX:TieredStopAtLevel=1", "-version", NULL};
    char *const tiered[] = {"java", "-version", NULL};
    if (step("-Xint -version", xint, "Server VM", "interpreted mode")) { return 1; }
    if (step("C1 -version", c1, "Server VM", "21.0.13")) { return 1; }
    if (step("-version", tiered, "Server VM", "mixed mode")) { return 1; }

    const char *source =
        "public class Hello {\n"
        "    public static void main(String[] args) {\n"
        "        long sum = 0;\n"
        "        for (int i = 0; i < 20_000_000; i++) { sum += i % 7; }\n"
        "        System.out.println(\"Hello, World! sum=\" + sum + \" vm=\" + System.getProperty(\"java.vm.name\"));\n"
        "    }\n"
        "}\n";
    int fd = open("/tmp/Hello.java", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0 || write(fd, source, strlen(source)) != (ssize_t)strlen(source)) {
        printf("FAIL write Hello.java errno=%d\n", errno);
        return 1;
    }
    close(fd);
    char *const hello[] = {"java", "/tmp/Hello.java", NULL};
    if (step("Hello.java", hello, "Hello, World! sum=59999997", "Server VM")) { return 1; }
    printf("PASS\n");
    return 0;
}
