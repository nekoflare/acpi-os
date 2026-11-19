#include <stdio.h>
#include <string.h>

int check_x11(void);
int run_x11_desktop(void);
int run_guest_dwm(void);

int main(int argc, char **argv)
{
    if (argc == 2 && !strcmp(argv[1], "--dwm"))
        return run_guest_dwm() != 0;
    if (argc == 2 && !strcmp(argv[1], "--desktop")) {
        if (!run_x11_desktop())
            return 0;
        fputs("X11 desktop failed\n", stderr);
        return 1;
    }
    if (argc != 1) {
        fputs("Usage: x11-demo [--desktop | --dwm]\n", stderr);
        return 1;
    }
    if (check_x11()) {
        fputs("X11 framebuffer demo failed\n", stderr);
        return 1;
    }
    puts("X11 window mapped on /dev/fb0");
    return 0;
}
