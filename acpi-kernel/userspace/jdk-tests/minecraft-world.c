// F4: Minecraft 1.20.1 in offline mode on Xvfb, with the arguments of
// config/minecraft. Passes when the game finishes loading its resources
// (the last texture atlas) and is still running a minute later. It then
// grabs the screen with a raw X11 GetImage into /tmp/minecraft.ppm on the
// test disk, for a human to look at. The files come from
// scripts/fetch-minecraft.sh and scripts/fetch-lwjgl.sh.
// disk: openjdk musl-runtime alsa-lib xvfb xorg-keymap mesa libx11-shared libxext-shared libxcb-shared libxau-shared libxdmcp-shared libxrender-shared libxrandr lwjgl lwjgl-glfw lwjgl-openal lwjgl-jemalloc
// disk-rw
// prepare: scripts/fetch-lwjgl.sh
// prepare: scripts/fetch-minecraft.sh
// disk-dir: opt/lwjgl=../target/lwjgl-3.3.1
// disk-dir: opt/minecraft=../target/minecraft-1.20.1
// disk-dir: tmp/minecraft/saves/perf=/tmp/claude-1000/-home-neko-Desktop-AMLAOT/3c995418-c731-4682-8a20-e686b807f343/scratchpad/mcserver/perf
// timeout: 1200
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define WIDTH 1024
#define HEIGHT 768

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

static int connect_display(void)
{
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    strcpy(address.sun_path, "/tmp/.X11-unix/X0");
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) { return -1; }
    if (connect(fd, (struct sockaddr *)&address, sizeof address)) {
        close(fd);
        return -1;
    }
    return fd;
}

// Waits until Xvfb accepts connections on display :0.
static int wait_for_server(void)
{
    for (int attempt = 0; attempt < 600; attempt++) {
        int fd = connect_display();
        if (fd >= 0) {
            close(fd);
            return 0;
        }
        usleep(100000);
    }
    return -1;
}

static int read_all(int fd, void *buffer, size_t length)
{
    for (size_t done = 0; done < length;) {
        ssize_t got = read(fd, (char *)buffer + done, length - done);
        if (got <= 0) { return -1; }
        done += got;
    }
    return 0;
}

// Saves the root window as a binary PPM, speaking the X11 protocol directly:
// connection setup for the root window id, then GetImage in ZPixmap format.
static int screenshot(const char *path)
{
    int fd = connect_display();
    if (fd < 0) { return -1; }
    uint8_t setup[12] = {'l', 0, 11, 0, 0, 0, 0, 0, 0, 0, 0, 0};
    uint8_t header[8];
    if (write(fd, setup, sizeof setup) != sizeof setup || read_all(fd, header, 8) || header[0] != 1) {
        return -1;
    }
    size_t length = (size_t)(header[6] | header[7] << 8) * 4;
    uint8_t *data = malloc(length);
    if (!data || read_all(fd, data, length)) { return -1; }
    // Offsets below count from the start of the reply, 8 bytes before data.
    size_t vendor = data[24 - 8] | data[25 - 8] << 8;
    size_t formats = data[29 - 8];
    uint8_t *screen = data + 40 - 8 + ((vendor + 3) & ~3u) + formats * 8;
    uint32_t root;
    memcpy(&root, screen, 4);
    free(data);
    uint8_t request[20] = {73, 2, 5, 0};
    memcpy(request + 4, &root, 4);
    uint16_t geometry[4] = {0, 0, WIDTH, HEIGHT};
    memcpy(request + 8, geometry, 8);
    memset(request + 16, 0xff, 4);
    uint8_t reply[32];
    if (write(fd, request, sizeof request) != sizeof request || read_all(fd, reply, 32) || reply[0] != 1) {
        return -1;
    }
    uint32_t words;
    memcpy(&words, reply + 4, 4);
    uint8_t *pixels = malloc((size_t)words * 4);
    if (!pixels || (size_t)words * 4 < WIDTH * HEIGHT * 4 || read_all(fd, pixels, (size_t)words * 4)) {
        return -1;
    }
    close(fd);
    FILE *file = fopen(path, "wb");
    if (!file) { return -1; }
    fprintf(file, "P6\n%d %d\n255\n", WIDTH, HEIGHT);
    unsigned long sum = 0;
    for (int i = 0; i < WIDTH * HEIGHT; i++) {
        uint8_t rgb[3] = {pixels[i * 4 + 2], pixels[i * 4 + 1], pixels[i * 4]};
        sum += rgb[0] + rgb[1] + rgb[2];
        fwrite(rgb, 1, 3, file);
    }
    fclose(file);
    free(pixels);
    printf("screenshot: %s, mean level %lu\n", path, sum / (WIDTH * HEIGHT * 3));
    return 0;
}

static double now(void)
{
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return time.tv_sec + time.tv_nsec / 1e9;
}

int main(void)
{
    // Xvfb reads its compiled keymap from /, as on the desktop.
    if (copy_file("/usr/share/acpi-os/xorg-default.xkm", "/xorg-default.xkm")) {
        printf("FAIL copy keymap errno=%d\n", errno);
        return 1;
    }
    // Skip the first-launch accessibility screen so the title screen shows.
    mkdir("/tmp/minecraft", 0755);
    FILE *options = fopen("/tmp/minecraft/options.txt", "w");
    if (!options) { printf("FAIL options.txt errno=%d\n", errno); return 1; }
    fputs("onboardAccessibility:false\n", options);
    fclose(options);
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

    // The arguments of config/minecraft, with the game directory in /tmp.
    char *const java[] = {
        "/usr/lib/jvm/java-21-openjdk/bin/java", "-Xmx2G", "-Dos.name=Linux",
        "-Dorg.lwjgl.librarypath=/usr/lib/lwjgl",
        "-cp", "/opt/minecraft/client.jar:/opt/minecraft/libraries/*:/opt/lwjgl/*",
        "net.minecraft.client.main.Main", "--username", "Player",
        "--uuid", "a01e3843-e521-3998-958a-f459800e4d11", "--accessToken", "0",
        "--userType", "legacy", "--version", "1.20.1", "--versionType", "release",
        "--gameDir", "/tmp/minecraft", "--assetsDir", "/opt/minecraft/assets",
        "--assetIndex", "5", "--quickPlaySingleplayer", "perf", NULL,
    };
    int pipe_fds[2];
    if (pipe(pipe_fds)) { printf("FAIL pipe\n"); return 1; }
    pid_t game = fork();
    if (game == 0) {
        dup2(pipe_fds[1], 1);
        dup2(pipe_fds[1], 2);
        close(pipe_fds[0]);
        close(pipe_fds[1]);
        char *const environment[] = {"DISPLAY=:0", "HOME=/tmp", "GALLIUM_HUD=stdout,fps", NULL};
        execve(java[0], java, environment);
        printf("FAIL exec java errno=%d\n", errno);
        _exit(127);
    }
    if (game < 0) { printf("FAIL fork\n"); return 1; }
    close(pipe_fds[1]);
    int output = pipe_fds[0];

    // Echo the output; look for the end of the resource reload, line by line.
    double start = now(), loaded = 0;
    char line[8192];
    size_t used = 0;
    int open_pipe = 1;
    while (open_pipe) {
        if (loaded && now() - loaded > 90) { break; }
        struct pollfd poll_fd = {.fd = output, .events = POLLIN};
        if (poll(&poll_fd, 1, 1000) <= 0) { continue; }
        ssize_t got = read(output, line + used, sizeof line - 1 - used);
        if (got <= 0) { open_pipe = 0; got = 0; }
        used += got;
        line[used] = 0;
        char *end;
        while ((end = strchr(line, '\n')) || (used == sizeof line - 1 && (end = line + used - 1))) {
            *end = 0;
            printf("[%7.2f] %s\n", now() - start, line);
            if (!loaded && strstr(line, "Created:") && strstr(line, "minecraft:textures/atlas/mob_effects.png-atlas")) {
                loaded = now();
                printf("[%7.2f] resources loaded, watching for 60 s\n", now() - start);
            }
            used -= end + 1 - line;
            memmove(line, end + 1, used);
            line[used] = 0;
        }
        fflush(stdout);
    }
    int status = 0;
    pid_t exited = waitpid(game, &status, WNOHANG);
    if (exited == 0 && loaded) {
        char maps[64];
        snprintf(maps, sizeof maps, "/proc/%d/maps", game);
        printf("maps copy %d\n", copy_file(maps, "/tmp/maps.txt"));
        if (screenshot("/tmp/minecraft.ppm")) { printf("screenshot failed\n"); }
        kill(game, SIGKILL);
        waitpid(game, &status, 0);
        kill(server, SIGTERM);
        waitpid(server, NULL, 0);
        sync();
        printf("PASS\n");
        return 0;
    }
    if (exited == 0) {
        kill(game, SIGKILL);
        waitpid(game, &status, 0);
    }
    kill(server, SIGTERM);
    waitpid(server, NULL, 0);
    printf("FAIL java status %#x, loaded %d\n", status, loaded != 0);
    return 1;
}
