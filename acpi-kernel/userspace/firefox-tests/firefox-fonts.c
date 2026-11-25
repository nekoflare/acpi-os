// Firefox drew hex boxes on the desktop: Alpine's fontconfig only searches
// /usr/share/fonts, and the image keeps its fonts in /fonts. firefox-probe
// now points FONTCONFIG_FILE at /etc/fonts/firefox.conf
// (config/firefox-fonts.conf). Run Alpine's fc-match in the launcher's
// environment (FIREFOX_BIN) and check that every CSS generic family Firefox
// asks for resolves to a real font.
// disk: musl-runtime busybox
// disk-rw
// prepare: [ -f ../target/alpine-firefox/manifest.txt ] || python3 -I scripts/fetch-alpine-firefox.py
// prepare: make -s $(realpath -m ../target/acpi-kernel-bash/bash.elf) $(realpath -m ../target/acpi-kernel-xorg/DejaVuSans.ttf) $(realpath -m ../target/acpi-kernel-xorg/DejaVuSerif.ttf) $(realpath -m ../target/acpi-kernel-xorg/DejaVuSansMono.ttf)
// disk-dir: opt/alpine=../target/alpine-firefox/root
// disk-file: bin/firefox-probe=../../config/firefox-probe
// disk-file: etc/fonts/firefox.conf=../../config/firefox-fonts.conf
// disk-file: bin/sh=../../../target/acpi-kernel-bash/bash.elf
// disk-file: fonts/DejaVuSans.ttf=../../../target/acpi-kernel-xorg/DejaVuSans.ttf
// disk-file: fonts/DejaVuSerif.ttf=../../../target/acpi-kernel-xorg/DejaVuSerif.ttf
// disk-file: fonts/DejaVuSansMono.ttf=../../../target/acpi-kernel-xorg/DejaVuSansMono.ttf
// timeout: 300
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static char output[16384];

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
    static const struct { const char *family, *want; } cases[] = {
        {"sans-serif", "DejaVu Sans\""},
        {"serif", "DejaVu Serif\""},
        {"monospace", "DejaVu Sans Mono\""},
        {"system-ui", "DejaVu Sans\""},
        {"emoji", "Twemoji Mozilla"},
    };
    char *const envp[] = {"PATH=/usr/bin:/bin", "HOME=/", "FIREFOX_DIR=/tmp/firefox",
        "FIREFOX_BIN=/opt/alpine/usr/bin/fc-match", NULL};
    int failures = 0;
    // The test disk has no mkdir for the launcher's `mkdir -p`; the desktop
    // does. Create the cache directory it would have made.
    mkdir("/tmp/firefox", 0755);
    mkdir("/tmp/firefox/cache", 0755);
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        char *const argv[] = {"/bin/firefox-probe", (char *)cases[i].family, NULL};
        int status = run(argv, envp);
        printf("%s -> %s", cases[i].family, output);
        if (status != 0 || !strstr(output, cases[i].want) || strstr(output, "Fontconfig error")) {
            printf("FAIL %s: status %#x, want %s\n", cases[i].family, status, cases[i].want);
            failures++;
        }
    }
    // The first run wrote a cache, so later starts skip rescanning /fonts.
    int caches = 0;
    static const char *const cache_dirs[] = {"/var/cache/fontconfig", "/tmp/firefox/cache/fontconfig"};
    for (size_t i = 0; i < 2; i++) {
        DIR *dir = opendir(cache_dirs[i]);
        for (struct dirent *e; dir && (e = readdir(dir));) {
            if (e->d_name[0] != '.') { printf("%s/%s\n", cache_dirs[i], e->d_name); }
            caches += strstr(e->d_name, ".cache-") != NULL;
        }
        if (dir) { closedir(dir); }
    }
    printf("%d fontconfig cache files\n", caches);
    if (!caches) { printf("FAIL no fontconfig cache\n"); failures++; }
    if (failures) { return 1; }
    printf("PASS\n");
    return 0;
}
