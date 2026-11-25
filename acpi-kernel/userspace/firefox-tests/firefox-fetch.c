// P4 step toward the desktop browser: headless firefox-esr loads a page from
// the host test server over plain HTTP and takes a screenshot. The page's
// script dump()s "page loaded over http:", which only appears when the page
// arrived and ran. On the desktop every site failed (HTTPS-First fell back to
// http and that failed too).
// net
// http-server
// disk: musl-runtime busybox
// disk-rw
// prepare: [ -f ../target/alpine-firefox/manifest.txt ] || python3 -I scripts/fetch-alpine-firefox.py
// prepare: make -s $(realpath -m ../target/acpi-kernel-bash/bash.elf) $(realpath -m ../target/acpi-kernel-xorg/DejaVuSans.ttf)
// disk-dir: opt/alpine=../target/alpine-firefox/root
// disk-file: opt/alpine/usr/lib/firefox-esr/browser/defaults/preferences/acpi-os.js=../../config/firefox-prefs.js
// disk-file: bin/firefox-probe=../../config/firefox-probe
// disk-file: etc/fonts/firefox.conf=../../config/firefox-fonts.conf
// disk-file: bin/sh=../../../target/acpi-kernel-bash/bash.elf
// disk-file: fonts/DejaVuSans.ttf=../../../target/acpi-kernel-xorg/DejaVuSans.ttf
// timeout: 420
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static char output[65536];

// Run argv with stdout and stderr echoed to the serial log and collected in
// output; SIGALRM ends it after limit seconds. Return the wait status.
static int run(char *const argv[], char *const envp[], unsigned limit)
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
        alarm(limit);
        execve(argv[0], argv, envp);
        printf("execve %s failed errno=%d\n", argv[0], errno);
        _exit(127);
    }
    close(pipe_fds[1]);
    size_t total = 0;
    char chunk[1024];
    ssize_t got;
    while ((got = read(pipe_fds[0], chunk, sizeof chunk)) > 0) {
        fwrite(chunk, 1, got, stdout);
        fflush(stdout);
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

static int write_file(const char *path, const char *text)
{
    FILE *f = fopen(path, "w");
    if (!f) { return -1; }
    fputs(text, f);
    return fclose(f);
}

int main(void)
{
    FILE *ports = fopen("/etc/http-ports", "r");
    int http_port, https_port;
    if (!ports || fscanf(ports, "%d %d", &http_port, &https_port) != 2) {
        printf("FAIL /etc/http-ports\n");
        return 1;
    }
    // The test disk has no mkdir for the launcher's `mkdir -p`.
    static const char *const dirs[] = {"/tmp/firefox", "/tmp/firefox/config",
        "/tmp/firefox/cache", "/tmp/firefox/data", "/tmp/firefox/state",
        "/tmp/firefox/profile", "/tmp/firefox-runtime"};
    for (size_t i = 0; i < sizeof dirs / sizeof dirs[0]; i++) { mkdir(dirs[i], 0700); }
    // dump() prints to stdout; no first-run pages or background requests.
    if (write_file("/tmp/firefox/profile/user.js",
            "user_pref(\"browser.dom.window.dump.enabled\", true);\n"
            "user_pref(\"dom.security.https_first\", false);\n"
            "user_pref(\"browser.startup.homepage_override.mstone\", \"ignore\");\n"
            "user_pref(\"datareporting.policy.dataSubmissionEnabled\", false);\n"
            "user_pref(\"datareporting.healthreport.uploadEnabled\", false);\n"
            "user_pref(\"toolkit.telemetry.enabled\", false);\n"
            "user_pref(\"app.update.disabledForTesting\", true);\n"
            "user_pref(\"network.captive-portal-service.enabled\", false);\n"
            "user_pref(\"network.connectivity-service.enabled\", false);\n")) {
        printf("FAIL user.js errno=%d\n", errno);
        return 1;
    }
    char url[96];
    snprintf(url, sizeof url, "http://10.0.2.2:%d/page", http_port);
    char *const envp[] = {"PATH=/usr/bin:/bin", "HOME=/", "FIREFOX_DIR=/tmp/firefox", NULL};
    char *const argv[] = {"/bin/firefox-probe", "--headless", "--no-remote", "--profile",
        "/tmp/firefox/profile", "--screenshot", "/tmp/firefox/shot.png", url, NULL};
    int status = run(argv, envp, 360);
    struct stat st;
    int shot = stat("/tmp/firefox/shot.png", &st) == 0 ? (int)st.st_size : -1;
    printf("firefox status %#x, screenshot %d bytes\n", status, shot);
    if (!strstr(output, "page loaded over http:")) {
        printf("FAIL the page did not load\n");
        return 1;
    }
    printf("PASS\n");
    return 0;
}
