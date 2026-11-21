#include <errno.h>
#include <stdio.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

static int connect_to_display(void)
{
    const struct sockaddr_un address = {
        .sun_family = AF_UNIX,
        .sun_path = "/tmp/.X11-unix/X0",
    };
    const struct timespec delay = {.tv_nsec = 50000000};
    for (unsigned attempt = 0; attempt < 200; ++attempt) {
        int fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd < 0)
            return -1;
        if (!connect(fd, (const struct sockaddr *)&address, sizeof(address)))
            return fd;
        int error = errno;
        close(fd);
        if (error != ECONNREFUSED && error != ENOENT && error != EAGAIN) {
            errno = error;
            return -1;
        }
        nanosleep(&delay, NULL);
    }
    errno = ETIMEDOUT;
    return -1;
}

static int read_reply(int fd, unsigned char *data, size_t size)
{
    while (size) {
        ssize_t count = read(fd, data, size);
        if (count <= 0)
            return -1;
        data += count;
        size -= (size_t)count;
    }
    return 0;
}

static int start_client(const char *path, char *const arguments[])
{
    pid_t process = fork();
    if (process < 0) {
        perror(path);
        return -1;
    }
    if (!process) {
        char *const environment[] = {
            "DISPLAY=:0", "FONTCONFIG_FILE=/dwm-fonts.conf", "HOME=/",
            "PATH=/bin", "SHELL=/bin/bash.elf", "XDG_CURRENT_DESKTOP=dwm", NULL,
        };
        execve(path, arguments, environment);
        perror(path);
        _exit(1);
    }
    return 0;
}

int main(void)
{
    pid_t server = fork();
    if (server < 0) {
        perror("fork Xvfb");
        return 1;
    }
    if (server == 0) {
        char *const arguments[] = {
            "Xvfb", ":0", "-screen", "0", "1024x768x24", "-nolock",
            "-ac", "-nolisten", "tcp", "-noreset", NULL,
        };
        char *const environment[] = {NULL};
        execve("/bin/Xvfb", arguments, environment);
        perror("exec Xvfb");
        return 1;
    }

    int fd = connect_to_display();
    if (fd < 0) {
        perror("connect to Xvfb");
        return 1;
    }

    unsigned char setup[12] = {'l', 0, 11};
    unsigned char reply[8];
    int error = write(fd, setup, sizeof(setup)) != sizeof(setup) ||
                read_reply(fd, reply, sizeof(reply)) ||
                reply[0] != 1 || reply[2] != 11;
    if (!error) {
        size_t remaining = ((unsigned)reply[6] | (unsigned)reply[7] << 8) * 4;
        while (remaining && !error) {
            unsigned char data[256];
            size_t size = remaining < sizeof(data) ? remaining : sizeof(data);
            error = read_reply(fd, data, size);
            remaining -= size;
        }
    }
    close(fd);
    if (error) {
        fputs("X.Org rejected the X11 setup request\n", stderr);
        return 1;
    }
    puts("Upstream X.Org accepted an X11 client");
    if (!access("/bin/dwm", X_OK)) {
        if (!access("/bin/picom", X_OK)) {
            char *const picom[] = {
                "picom", "--backend", "xrender", "--config", "/usr/share/picom/picom.conf", "--daemon", NULL,
            };
            start_client("/bin/picom", picom);
        }
        char wallpaper[] = "/usr/share/wallpapers/serval_wp.jpg";
        if (!access("/bin/xwallpaper", X_OK) && !access(wallpaper, R_OK)) {
            char *const arguments[] = {
                "xwallpaper", "--zoom", wallpaper, NULL,
            };
            struct timespec now;
            if (!clock_gettime(CLOCK_MONOTONIC, &now))
                fprintf(stderr, "AMLDRAG wallpaper=%s launch_t_us=%lld\n", wallpaper,
                        (long long)now.tv_sec * 1000000 + now.tv_nsec / 1000);
            start_client("/bin/xwallpaper", arguments);
        }
        char *const dwm[] = {"dwm", NULL};
        if (start_client("/bin/dwm", dwm))
            return 1;
        if (!access("/bin/conky", X_OK)) {
            char *const conky[] = {
                "conky", "-c", "/usr/share/conky/conky.conf", NULL,
            };
            start_client("/bin/conky", conky);
        }
        if (!access("/time.sh", R_OK)) {
            char *const arguments[] = {"bash.elf", "/time.sh", NULL};
            start_client("/bin/bash.elf", arguments);
        }
    }
    return 0;
}
