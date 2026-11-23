// E3: javac compiles a multithreaded, allocation-heavy program that checks
// its own results (java/Stress.java), then the Server VM runs it for minutes
// under each garbage collector with small heaps so that collections are
// frequent.
// disk: openjdk musl-runtime alsa-lib
// disk-rw
// disk-file: tmp/stress/Stress.java=java/Stress.java
// timeout: 1200
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define JDK "/usr/lib/jvm/java-21-openjdk/bin/"

static char output[1 << 20];

static long long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000LL + ts.tv_nsec / 1000000;
}

// Run a JDK tool, echoing its output as it arrives and keeping a copy.
static int run(const char *path, char *const argv[])
{
    int pipe_fds[2];
    if (pipe(pipe_fds)) { return -1; }
    fflush(stdout);
    pid_t pid = fork();
    if (pid < 0) { return -1; }
    if (pid == 0) {
        dup2(pipe_fds[1], 1);
        dup2(pipe_fds[1], 2);
        close(pipe_fds[0]);
        close(pipe_fds[1]);
        char *envp[] = {"PATH=/usr/bin:/bin", "HOME=/tmp", NULL};
        execve(path, argv, envp);
        printf("execve failed errno=%d\n", errno);
        _exit(127);
    }
    close(pipe_fds[1]);
    size_t total = 0;
    char chunk[4096];
    ssize_t got;
    while ((got = read(pipe_fds[0], chunk, sizeof chunk)) > 0) {
        if (write(1, chunk, got) != got) { break; }
        if (total + got < sizeof output) {
            memcpy(output + total, chunk, got);
            total += got;
        }
    }
    output[total] = 0;
    close(pipe_fds[0]);
    int status;
    if (waitpid(pid, &status, 0) != pid) { return -1; }
    return status;
}

static int step(const char *name, const char *path, char *const argv[], const char *expect)
{
    printf("== %s\n", name);
    long long start = now_ms();
    int status = run(path, argv);
    printf("%s: status %#x in %lld ms\n", name, status, now_ms() - start);
    if (status != 0) { printf("FAIL %s exit status\n", name); return 1; }
    if (expect && !strstr(output, expect)) {
        printf("FAIL %s output\n", name);
        return 1;
    }
    return 0;
}

int main(void)
{
    char *const javac[] = {"javac", "-d", "/tmp/stress", "/tmp/stress/Stress.java", NULL};
    if (step("javac", JDK "javac", javac, NULL)) { return 1; }

    struct {
        const char *name, *gc, *heap, *seconds;
    } runs[] = {
        {"ZGC", "-XX:+UseZGC", "-Xmx512m", "45"},
        {"Shenandoah", "-XX:+UseShenandoahGC", "-Xmx512m", "45"},
        {"G1", "-XX:+UseG1GC", "-Xmx512m", "120"},
        {"Parallel", "-XX:+UseParallelGC", "-Xmx256m", "45"},
        {"Serial", "-XX:+UseSerialGC", "-Xmx256m", "30"},
    };
    for (unsigned i = 0; i < sizeof runs / sizeof *runs; i++) {
        char *const java[] = {"java", (char *)runs[i].gc, (char *)runs[i].heap, "-cp", "/tmp/stress",
                              "Stress", (char *)runs[i].seconds, NULL};
        if (step(runs[i].name, JDK "java", java, "STRESS OK")) { return 1; }
    }
    printf("PASS\n");
    return 0;
}
