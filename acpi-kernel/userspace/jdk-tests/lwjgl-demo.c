// F3: LWJGL 3.3.1 with the natives from the lwjgl* recipes. Starts Xvfb and
// runs java/LwjglDemo.java from source with Mojang's LWJGL jars, which
// checks jemalloc, stb (with a native callback), OpenAL Soft on the null
// device, a GLFW window with an OpenGL 3.2 core context drawing 300 frames,
// and tinyfd. The jars come from scripts/fetch-lwjgl.sh.
// disk: openjdk musl-runtime alsa-lib xvfb xorg-keymap mesa libx11-shared libxext-shared libxcb-shared libxau-shared libxdmcp-shared libxrender-shared libxrandr lwjgl lwjgl-glfw lwjgl-openal lwjgl-jemalloc
// disk-rw
// prepare: scripts/fetch-lwjgl.sh
// disk-dir: opt/lwjgl=../target/lwjgl-3.3.1
// disk-file: tmp/lwjgl/LwjglDemo.java=java/LwjglDemo.java
// timeout: 600
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

    char *const java[] = {
        // uname reports "ASL kernel", which LWJGL rejects as an unknown platform.
        "/usr/lib/jvm/java-21-openjdk/bin/java", "-Dos.name=Linux",
        "-Dorg.lwjgl.librarypath=/usr/lib/lwjgl",
        "-Dorg.lwjgl.util.Debug=true", "-cp", "/opt/lwjgl/*", "/tmp/lwjgl/LwjglDemo.java", "300",
        NULL,
    };
    int output;
    pid_t demo = spawn(java, &output);
    if (demo < 0) { printf("FAIL spawn java\n"); return 1; }
    // Echo the output as it arrives and keep it for the final check.
    static char text[65536];
    size_t length = 0;
    char chunk[4096];
    ssize_t got;
    while ((got = read(output, chunk, sizeof chunk)) > 0) {
        fwrite(chunk, 1, got, stdout);
        fflush(stdout);
        if (length + got < sizeof text) {
            memcpy(text + length, chunk, got);
            length += got;
        }
    }
    text[length] = 0;
    close(output);
    int status;
    waitpid(demo, &status, 0);
    kill(server, SIGTERM);
    waitpid(server, NULL, 0);
    if (status != 0 || !strstr(text, "DEMO OK")) {
        printf("FAIL java status %#x\n", status);
        return 1;
    }
    printf("PASS\n");
    return 0;
}
