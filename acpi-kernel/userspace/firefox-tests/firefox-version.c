// P3: Alpine's firefox-esr in /opt/alpine, started through /bin/firefox-probe,
// prints its version. This loads libxul and its ~110 libraries and runs their
// static constructors, but starts no child processes. The expected version is
// read from the tree's application.ini.
// disk: musl-runtime busybox
// prepare: [ -f ../target/alpine-firefox/manifest.txt ] || python3 -I scripts/fetch-alpine-firefox.py
// prepare: make -s $(realpath -m ../target/acpi-kernel-bash/bash.elf)
// disk-dir: opt/alpine=../target/alpine-firefox/root
// disk-file: bin/firefox-probe=../../config/firefox-probe
// disk-file: bin/sh=../../../target/acpi-kernel-bash/bash.elf
// timeout: 300
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define APP_INI "/opt/alpine/usr/lib/firefox-esr/application.ini"

static char output[16384];

static long long now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000LL + ts.tv_nsec / 1000000;
}

// Run argv with stdout and stderr collected in output; return the wait status.
static int run(char *const argv[], char *const envp[])
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
        execve(argv[0], argv, envp);
        printf("execve %s failed errno=%d\n", argv[0], errno);
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
    char version[64] = "";
    FILE *ini = fopen(APP_INI, "r");
    if (!ini) {
        printf("FAIL %s missing errno=%d\n", APP_INI, errno);
        return 1;
    }
    char line[256];
    while (fgets(line, sizeof line, ini)) {
        if (!strncmp(line, "Version=", 8)) {
            snprintf(version, sizeof version, "%s", line + 8);
            version[strcspn(version, "\r\n")] = 0;
            break;
        }
    }
    fclose(ini);
    if (!version[0]) {
        printf("FAIL no Version= in %s\n", APP_INI);
        return 1;
    }
    char want[96];
    snprintf(want, sizeof want, "Mozilla Firefox %sesr", version);

    // Run the wrapper through its #!/bin/sh line with the desktop's /bin/sh,
    // our bash (busybox sh hid a bash crash on ${icu%/}). The volume is
    // read-only; the profile goes to /tmp.
    char *const argv[] = {"/bin/firefox-probe", "--version", NULL};
    char *const envp[] = {"PATH=/usr/bin:/bin", "HOME=/", "FIREFOX_DIR=/tmp/firefox", NULL};
    long long start = now_ms();
    int status = run(argv, envp);
    printf("%s", output);
    printf("firefox-probe --version: status %#x in %lld ms\n", status, now_ms() - start);
    if (status != 0) { printf("FAIL exit status\n"); return 1; }
    if (!strstr(output, want)) {
        printf("FAIL want \"%s\"\n", want);
        return 1;
    }
    printf("PASS\n");
    return 0;
}
