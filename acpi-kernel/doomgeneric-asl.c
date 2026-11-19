#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#include "doomgeneric.h"
#include "doomkeys.h"

static int display_fd, keyboard_fd;
static uint8_t *frame;
static struct fb_var_screeninfo mode;
static struct fb_fix_screeninfo layout;
static const unsigned char set1_keys[128] = {
    [0x01] = KEY_ESCAPE,
    [0x02] = '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=',
    [0x0e] = KEY_BACKSPACE, KEY_TAB,
    [0x10] = 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']',
    [0x1c] = KEY_ENTER, KEY_FIRE,
    [0x1e] = 'a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', '`',
    [0x2a] = KEY_RSHIFT, '\\',
    [0x2c] = 'z', 'x', 'c', 'v', 'b', 'n', 'm', ',', '.', '/',
    [0x36] = KEY_RSHIFT, '*', KEY_RALT, KEY_USE, KEY_CAPSLOCK,
    [0x3b] = KEY_F1, KEY_F2, KEY_F3, KEY_F4, KEY_F5,
    KEY_F6, KEY_F7, KEY_F8, KEY_F9, KEY_F10,
    [0x47] = KEY_HOME, KEY_UPARROW, KEY_PGUP, '-', KEY_LEFTARROW, '5',
    KEY_RIGHTARROW, '+', KEY_END, KEY_DOWNARROW, KEY_PGDN, KEY_INS, KEY_DEL,
    [0x57] = KEY_F11, KEY_F12,
};
static const unsigned char extended_keys[128] = {
    [0x1c] = KEY_ENTER, [0x1d] = KEY_FIRE, [0x35] = '/', [0x38] = KEY_RALT,
    [0x47] = KEY_HOME, KEY_UPARROW, KEY_PGUP, [0x4b] = KEY_LEFTARROW,
    [0x4d] = KEY_RIGHTARROW, [0x4f] = KEY_END, KEY_DOWNARROW, KEY_PGDN,
    KEY_INS, KEY_DEL,
};
static uint8_t held[2][128];
static unsigned int key_holders[256];

static void fail(const char *operation)
{
    perror(operation);
    exit(EXIT_FAILURE);
}

void DG_Init(void)
{
    display_fd = open("/dev/fb0", O_WRONLY);
    if (display_fd < 0)
        fail("doom: open /dev/fb0");
    if (ioctl(display_fd, FBIOGET_VSCREENINFO, &mode) < 0 ||
        ioctl(display_fd, FBIOGET_FSCREENINFO, &layout) < 0)
        fail("doom: framebuffer info");
    if (!mode.xres || !mode.yres || mode.bits_per_pixel != 32 ||
        mode.red.length != 8 || mode.green.length != 8 || mode.blue.length != 8 ||
        mode.red.offset > 24 || mode.green.offset > 24 || mode.blue.offset > 24 ||
        layout.line_length % 4 ||
        layout.line_length < (uint64_t)mode.xres * 4 ||
        layout.smem_len < (uint64_t)layout.line_length * mode.yres) {
        fputs("doom: unsupported framebuffer layout\n", stderr);
        exit(EXIT_FAILURE);
    }

    frame = calloc(mode.yres, layout.line_length);
    if (!frame)
        fail("doom: allocate framebuffer");
    keyboard_fd = open("/dev/kbd", O_RDONLY | O_NONBLOCK);
    if (keyboard_fd < 0)
        fail("doom: open /dev/kbd");
}

void DG_DrawFrame(void)
{
    unsigned int width = mode.xres;
    unsigned int height = mode.yres;
    if ((uint64_t)width * 3 > (uint64_t)height * 4)
        width = (uint64_t)height * 4 / 3;
    else
        height = (uint64_t)width * 3 / 4;

    for (unsigned int y = 0; y < height; ++y) {
        uint32_t *destination = (uint32_t *)(frame +
            (size_t)(y + (mode.yres - height) / 2) * layout.line_length) +
            (mode.xres - width) / 2;
        const pixel_t *source = DG_ScreenBuffer +
            (size_t)y * DOOMGENERIC_RESY / height * DOOMGENERIC_RESX;
        for (unsigned int x = 0; x < width; ++x) {
            uint32_t pixel = source[(size_t)x * DOOMGENERIC_RESX / width];
            destination[x] = (((pixel >> 16) & 255) << mode.red.offset) |
                             (((pixel >> 8) & 255) << mode.green.offset) |
                             ((pixel & 255) << mode.blue.offset);
        }
    }

    if (lseek(display_fd, 0, SEEK_SET) < 0)
        fail("doom: seek framebuffer");
    size_t size = (size_t)layout.line_length * mode.yres;
    for (size_t offset = 0; offset < size;) {
        ssize_t count = write(display_fd, frame + offset, size - offset);
        if (count < 0)
            fail("doom: write framebuffer");
        if (!count) {
            errno = EIO;
            fail("doom: write framebuffer");
        }
        offset += count;
    }
}

void DG_SleepMs(uint32_t ms)
{
    struct timespec duration = {
        .tv_sec = ms / 1000,
        .tv_nsec = (long)(ms % 1000) * 1000000,
    };
    if (nanosleep(&duration, NULL) < 0)
        fail("doom: nanosleep");
}

uint32_t DG_GetTicksMs(void)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) < 0)
        fail("doom: clock_gettime");
    return (uint64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

int DG_GetKey(int *pressed, unsigned char *key)
{
    uint8_t event[2];
    for (;;) {
        ssize_t count = read(keyboard_fd, event, sizeof(event));
        if (count < 0 && errno == EAGAIN)
            return 0;
        if (count != sizeof(event)) {
            if (count >= 0)
                errno = EIO;
            fail("doom: read keyboard");
        }
        unsigned int extended = event[1] & 1;
        unsigned int code = event[0] & 0x7f;
        unsigned char mapped = (extended ? extended_keys : set1_keys)[code];
        int down = !(event[0] & 0x80);
        if (!mapped || held[extended][code] == down)
            continue;
        held[extended][code] = down;
        if (down ? key_holders[mapped]++ == 0 : --key_holders[mapped] == 0) {
            *pressed = down;
            *key = mapped;
            return 1;
        }
    }
}

void DG_SetWindowTitle(const char *title)
{
    (void)title;
}

/* Doom writes a temporary .dsg and renames it into a menu slot. The
 * initramfs is read-only, so keep these streams for this process's lifetime. */
struct save_file {
    char *data;
    size_t size;
};

static struct save_file save_slots[10], temporary_save;

static struct save_file *save_file_for_path(const char *path)
{
    const char *name = strrchr(path, '/');
    name = name ? name + 1 : path;
    if (strcmp(name, "temp.dsg") == 0)
        return &temporary_save;
    if (strncmp(name, "doomsav", 7) == 0 && name[7] >= '0' && name[7] <= '9' &&
        strcmp(name + 8, ".dsg") == 0)
        return &save_slots[name[7] - '0'];
    return NULL;
}

FILE *__real_fopen(const char *path, const char *mode);
int __real_remove(const char *path);
int __real_rename(const char *source, const char *destination);

FILE *__wrap_fopen(const char *path, const char *mode)
{
    struct save_file *save = save_file_for_path(path);
    if (!save)
        return __real_fopen(path, mode);
    if (strcmp(mode, "wb") == 0 && save == &temporary_save) {
        free(save->data);
        *save = (struct save_file){0};
        return open_memstream(&save->data, &save->size);
    }
    if (strcmp(mode, "rb") == 0 && save->data)
        return fmemopen(save->data, save->size, "rb");
    errno = ENOENT;
    return NULL;
}

int __wrap_remove(const char *path)
{
    struct save_file *save = save_file_for_path(path);
    if (!save)
        return __real_remove(path);
    if (!save->data) {
        errno = ENOENT;
        return -1;
    }
    free(save->data);
    *save = (struct save_file){0};
    return 0;
}

int __wrap_rename(const char *source, const char *destination)
{
    struct save_file *old = save_file_for_path(source);
    struct save_file *next = save_file_for_path(destination);
    if (!old && !next)
        return __real_rename(source, destination);
    if (!old || !next || !old->data) {
        errno = ENOENT;
        return -1;
    }
    if (old != next) {
        free(next->data);
        *next = *old;
        *old = (struct save_file){0};
    }
    return 0;
}

int main(int argc, char **argv)
{
    char *boot_args[] = {argv[0], "-iwad", "/doom.wad", NULL};
    if (argc == 1) {
        argc = 3;
        argv = boot_args;
    }
    doomgeneric_Create(argc, argv);
    for (;;)
        doomgeneric_Tick();
}
