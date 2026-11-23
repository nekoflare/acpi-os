// F1: Mesa's llvmpipe through xlib GLX on Xvfb. This program starts Xvfb and
// runs gl/glx-probe.c, a dynamically linked client that loads libGL,
// libX11 and libXrandr with dlopen as GLFW does, creates an OpenGL 3.2 core
// context, draws with GLSL and checks the pixels.
// disk: musl-runtime xvfb xorg-keymap xorgproto libx11 libxrender libxrandr mesa libx11-shared libxext-shared libxcb-shared libxau-shared libxdmcp-shared libxrender-shared
// disk-rw
// disk-dynamic: usr/bin/glx-probe=gl/glx-probe.c
// timeout: 300
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static int copy_file(const char *from, const char *to)
{
    int in = open(from, O_RDONLY);
    int out = open(to, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (in < 0 || out < 0) { return -1; }
    char buffer[65536];
    ssize_t got;
    while ((got = read(in, buffer, sizeof buffer)) > 0) {
        if (write(out, buffer, got) != got) { return -1; }
    }
    close(in);
    close(out);
    return got;
}

int main(void)
{
    // Xvfb reads its compiled keymap from /, as on the desktop.
    if (copy_file("/usr/share/acpi-os/xorg-default.xkm", "/xorg-default.xkm")) {
        printf("FAIL copy keymap errno=%d\n", errno);
        return 1;
    }
    fflush(stdout);
    pid_t server = fork();
    if (server == 0) {
        char *const arguments[] = {
            "Xvfb", ":0", "-screen", "0", "1024x768x24", "-nolock",
            "-ac", "-nolisten", "tcp", "-noreset", NULL,
        };
        char *const environment[] = {NULL};
        execve("/usr/bin/Xvfb", arguments, environment);
        printf("FAIL exec Xvfb errno=%d\n", errno);
        _exit(127);
    }
    if (server < 0) { printf("FAIL fork\n"); return 1; }

    pid_t client = fork();
    if (client == 0) {
        char *const arguments[] = {"glx-probe", NULL};
        char *const environment[] = {"DISPLAY=:0", "HOME=/tmp", NULL};
        execve("/usr/bin/glx-probe", arguments, environment);
        printf("FAIL exec glx-probe errno=%d\n", errno);
        _exit(127);
    }
    if (client < 0) { printf("FAIL fork\n"); return 1; }
    int status;
    if (waitpid(client, &status, 0) != client) { printf("FAIL waitpid\n"); return 1; }
    kill(server, SIGTERM);
    printf("glx-probe status %#x\n", status);
    if (status != 0) { printf("FAIL glx-probe\n"); return 1; }
    printf("PASS\n");
    return 0;
}
