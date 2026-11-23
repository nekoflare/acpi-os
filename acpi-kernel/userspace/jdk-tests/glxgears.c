// F2: mesa-demos' glxinfo and glxgears on Xvfb. glxinfo -B must report
// llvmpipe, and glxgears must print two "frames in 5.0 seconds" lines.
// disk: musl-runtime xvfb xorg-keymap mesa mesa-demos libx11-shared libxext-shared libxcb-shared libxau-shared libxdmcp-shared libxrender-shared
// disk-rw
// timeout: 300
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
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

// Waits until Xvfb accepts connections on display :0.
static int wait_for_server(void)
{
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    strcpy(address.sun_path, "/tmp/.X11-unix/X0");
    for (int attempt = 0; attempt < 600; attempt++) {
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0) { return -1; }
        int connected = connect(fd, (struct sockaddr *)&address, sizeof address) == 0;
        close(fd);
        if (connected) { return 0; }
        usleep(100000);
    }
    return -1;
}

// Runs a program with stdout and stderr on a pipe. Returns its pid.
static pid_t spawn(char *const arguments[], int *output)
{
    int pipe_fds[2];
    if (pipe(pipe_fds)) { return -1; }
    pid_t pid = fork();
    if (pid == 0) {
        dup2(pipe_fds[1], 1);
        dup2(pipe_fds[1], 2);
        close(pipe_fds[0]);
        close(pipe_fds[1]);
        char *const environment[] = {"DISPLAY=:0", "HOME=/tmp", NULL};
        execve(arguments[0], arguments, environment);
        printf("FAIL exec %s errno=%d\n", arguments[0], errno);
        _exit(127);
    }
    close(pipe_fds[1]);
    *output = pipe_fds[0];
    return pid;
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
    if (wait_for_server()) { printf("FAIL Xvfb did not start\n"); return 1; }

    // glxinfo -B: the renderer summary.
    char text[16384];
    size_t length = 0;
    int output;
    char *const info_arguments[] = {"/usr/bin/glxinfo", "-B", NULL};
    pid_t info = spawn(info_arguments, &output);
    if (info < 0) { printf("FAIL spawn glxinfo\n"); return 1; }
    ssize_t got;
    while (length < sizeof text - 1 && (got = read(output, text + length, sizeof text - 1 - length)) > 0) {
        length += got;
    }
    text[length] = 0;
    close(output);
    int status;
    waitpid(info, &status, 0);
    fputs(text, stdout);
    if (status != 0 || !strstr(text, "OpenGL renderer string: llvmpipe")) {
        printf("FAIL glxinfo status %#x\n", status);
        return 1;
    }

    // glxgears prints its frame rate every five seconds.
    char *const gears_arguments[] = {"/usr/bin/glxgears", "-info", NULL};
    pid_t gears = spawn(gears_arguments, &output);
    if (gears < 0) { printf("FAIL spawn glxgears\n"); return 1; }
    length = 0;
    int reports = 0;
    while (reports < 2 && length < sizeof text - 1 &&
           (got = read(output, text + length, sizeof text - 1 - length)) > 0) {
        length += got;
        text[length] = 0;
        reports = 0;
        for (char *line = strstr(text, "frames in"); line; line = strstr(line + 1, "frames in")) {
            reports++;
        }
    }
    text[length] = 0;
    kill(gears, SIGTERM);
    waitpid(gears, &status, 0);
    close(output);
    kill(server, SIGTERM);
    fputs(text, stdout);
    if (reports < 2) { printf("FAIL glxgears reports %d\n", reports); return 1; }
    printf("PASS\n");
    return 0;
}
