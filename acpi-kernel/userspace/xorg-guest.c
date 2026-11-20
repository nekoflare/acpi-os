/* Framebuffer and PS/2 device hooks for the upstream Xvfb backend. */
#include <dix-config.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#include "X11/X.h"
#include "inputstr.h"
#include "inpututils.h"
#include "os.h"
#include "pixmapstr.h"
#include "scrnintstr.h"
#include "damage.h"

static int fb_fd = -1;
static struct fb_fix_screeninfo fb_layout;
static uint8_t *published;
static Bool force_refresh;
static Bool page_flip;
static Bool partial_flip;
static DamagePtr screen_damage;
static Bool damage_attempted;
static BoxRec pending_damage[2];
static unsigned next_page;

enum {
    GUEST_FB_PRESENT = 0x46F0,
    GUEST_FB_PRESENT_RECT = 0x46F1,
};

struct guest_fb_present_rect {
    uint64_t pixels;
    uint16_t x1, y1, x2, y2;
};

_Static_assert(sizeof(struct guest_fb_present_rect) == 16,
               "guest framebuffer ioctl layout");
static ScreenBlockHandlerProcPtr screen_block_handler;
static int mouse_fd = -1, keyboard_fd = -1;
static uint8_t buttons;

void amlaot_xorg_geometry(int *width, int *height);
void amlaot_xorg_screen(ScreenPtr screen);
void amlaot_xorg_close_screen(void);
void amlaot_xorg_input(DeviceIntPtr mouse, DeviceIntPtr keyboard);
void amlaot_xorg_close_input(void);

void
amlaot_xorg_geometry(int *width, int *height)
{
    struct fb_var_screeninfo mode;
    fb_fd = open("/dev/fb0", O_WRONLY | O_CLOEXEC);
    if (fb_fd < 0)
        return;
    if (ioctl(fb_fd, FBIOGET_VSCREENINFO, &mode) ||
        ioctl(fb_fd, FBIOGET_FSCREENINFO, &fb_layout) ||
        mode.bits_per_pixel != 32 || mode.red.offset != 16 ||
        mode.green.offset != 8 || mode.blue.offset != 0 ||
        mode.red.length != 8 || mode.green.length != 8 || mode.blue.length != 8 ||
        !mode.xres || !mode.yres || mode.xres > INT16_MAX || mode.yres > INT16_MAX ||
        fb_layout.line_length < mode.xres * 4 ||
        fb_layout.smem_len < (uint64_t)fb_layout.line_length * mode.yres) {
        LogMessage(X_WARNING, "Unsupported guest framebuffer mode\n");
        amlaot_xorg_close_screen();
        return;
    }

    published = malloc((size_t)mode.xres * 4 * mode.yres);
    if (!published) {
        amlaot_xorg_close_screen();
        return;
    }
    *width = mode.xres;
    *height = mode.yres;
    force_refresh = TRUE;
    page_flip = fb_layout.line_length == mode.xres * 4;
    partial_flip = page_flip;
    next_page = 0;
    damage_attempted = FALSE;
    pending_damage[0] = pending_damage[1] = (BoxRec){ 0, 0, *width, *height };
}

static Bool
publish_row(const uint8_t *data, size_t bytes, off_t offset)
{
    if (lseek(fb_fd, offset, SEEK_SET) != offset)
        return FALSE;
    while (bytes) {
        ssize_t count = write(fb_fd, data, bytes);
        if (count < 0 && errno == EINTR)
            continue;
        if (count <= 0)
            return FALSE;
        data += count;
        bytes -= count;
    }
    return TRUE;
}

static void
clear_screen_damage(DamagePtr damage, void *data)
{
    (void)damage;
    (void)data;
    screen_damage = NULL;
}

static void
collect_damage(BoxRec *pending, const BoxRec *changed)
{
    if (pending->x1 == pending->x2) {
        *pending = *changed;
        return;
    }
    pending->x1 = min(pending->x1, changed->x1);
    pending->y1 = min(pending->y1, changed->y1);
    pending->x2 = max(pending->x2, changed->x2);
    pending->y2 = max(pending->y2, changed->y2);
}

static int
present_page(const uint8_t *pixels, const BoxRec *box, int width, int height)
{
    // Prefer the contiguous copy when damage covers most of the screen.
    size_t area = (size_t)(box->x2 - box->x1) * (box->y2 - box->y1);
    if (partial_flip && screen_damage && area < (size_t)width * height * 3 / 4) {
        struct guest_fb_present_rect request = {
            (uintptr_t)pixels, box->x1, box->y1, box->x2, box->y2
        };
        if (!ioctl(fb_fd, GUEST_FB_PRESENT_RECT, &request))
            return 0;
        if (errno != ENOTTY)
            return -1;
        partial_flip = FALSE;
    }
    return ioctl(fb_fd, GUEST_FB_PRESENT, pixels);
}

static void
guest_block_handler(ScreenPtr screen, void *timeout)
{
    screen->BlockHandler = screen_block_handler;
    screen->BlockHandler(screen, timeout);
    screen_block_handler = screen->BlockHandler;
    screen->BlockHandler = guest_block_handler;

    if (fb_fd < 0)
        return;
    PixmapPtr pixmap = screen->GetScreenPixmap(screen);
    const uint8_t *pixels = pixmap->devPrivate.ptr;
    size_t row_bytes = screen->width * 4;
    if (!damage_attempted) {
        damage_attempted = TRUE;
        if (DamageSetup(screen)) {
            screen_damage = DamageCreate(NULL, clear_screen_damage,
                                         DamageReportNone, TRUE, screen, NULL);
            if (screen_damage)
                DamageRegister(&pixmap->drawable, screen_damage);
        }
    }

    BoxRec changed = { 0, 0, screen->width, screen->height };
    if (screen_damage && !force_refresh) {
        RegionPtr damage = DamageRegion(screen_damage);
        if (!RegionNotEmpty(damage))
            return;
        changed = *RegionExtents(damage);
    }
    if (screen_damage)
        DamageEmpty(screen_damage);

    if (page_flip && pixmap->devKind == row_bytes) {
        size_t bytes = row_bytes * screen->height;
        if (!screen_damage && !force_refresh && !memcmp(pixels, published, bytes))
            return;
        // Both pages are missing this update until they are independently presented.
        collect_damage(&pending_damage[0], &changed);
        collect_damage(&pending_damage[1], &changed);
        if (!present_page(pixels, &pending_damage[next_page], screen->width, screen->height)) {
            if (force_refresh)
                LogMessageVerb(X_INFO, 0, "Guest framebuffer page flipping enabled\n");
            if (!screen_damage)
                memcpy(published, pixels, bytes);
            pending_damage[next_page] = (BoxRec){ 0 };
            next_page ^= 1;
            force_refresh = FALSE;
            return;
        }
        if (errno != ENOTTY) {
            LogMessage(X_WARNING, "Cannot present guest framebuffer: %s\n", strerror(errno));
            amlaot_xorg_close_screen();
            return;
        }
        page_flip = FALSE;
        force_refresh = TRUE;
        changed = (BoxRec){ 0, 0, screen->width, screen->height };
    }
    for (int y = changed.y1; y < changed.y2; ++y) {
        const uint8_t *row = pixels + y * pixmap->devKind;
        uint8_t *previous = published + y * row_bytes;
        if (!force_refresh && !memcmp(row, previous, row_bytes))
            continue;
        if (!publish_row(row, row_bytes, (off_t)y * fb_layout.line_length)) {
            LogMessage(X_WARNING, "Cannot update guest framebuffer: %s\n", strerror(errno));
            amlaot_xorg_close_screen();
            return;
        }
        memcpy(previous, row, row_bytes);
    }
    force_refresh = FALSE;
}

void
amlaot_xorg_screen(ScreenPtr screen)
{
    if (fb_fd < 0)
        return;
    screen_block_handler = screen->BlockHandler;
    screen->BlockHandler = guest_block_handler;
}

void
amlaot_xorg_close_screen(void)
{
    if (screen_damage)
        DamageDestroy(screen_damage);
    if (fb_fd >= 0)
        close(fb_fd);
    fb_fd = -1;
    free(published);
    published = NULL;
}

static void
mouse_ready(int fd, int ready, void *data)
{
    if (!(ready & X_NOTIFY_READ))
        return;
    DeviceIntPtr mouse = data;
    static const int button_map[] = {1, 3, 2};
    for (unsigned i = 0; i < 32; ++i) {
        uint8_t packet[8];
        if (read(fd, packet, sizeof(packet)) != sizeof(packet))
            break;
        int dx = (int16_t)(packet[0] | packet[1] << 8);
        int dy = (int16_t)(packet[2] | packet[3] << 8);
        if (dx || dy) {
            ValuatorMask mask;
            valuator_mask_zero(&mask);
            valuator_mask_set(&mask, 0, dx);
            valuator_mask_set(&mask, 1, dy);
            QueuePointerEvents(mouse, MotionNotify, 0, POINTER_RELATIVE, &mask);
        }
        for (unsigned bit = 0; bit < 3; ++bit) {
            unsigned mask = 1U << bit;
            if ((buttons ^ packet[4]) & mask)
                QueuePointerEvents(mouse, packet[4] & mask ? ButtonPress : ButtonRelease,
                                   button_map[bit], 0, NULL);
        }
        buttons = packet[4];
    }
}

static void
keyboard_ready(int fd, int ready, void *data)
{
    if (!(ready & X_NOTIFY_READ))
        return;
    DeviceIntPtr keyboard = data;
    static const uint8_t extended[128] = {
        [0x1c] = 96, [0x1d] = 97, [0x35] = 98, [0x37] = 99, [0x38] = 100,
        [0x47] = 102, [0x48] = 103, [0x49] = 104, [0x4b] = 105,
        [0x4d] = 106, [0x4f] = 107, [0x50] = 108, [0x51] = 109,
        [0x52] = 110, [0x53] = 111, [0x5b] = 125, [0x5c] = 126, [0x5d] = 127,
    };
    for (unsigned i = 0; i < 32; ++i) {
        uint8_t packet[2];
        if (read(fd, packet, sizeof(packet)) != sizeof(packet))
            break;
        unsigned key = packet[0] & 0x7f;
        if (packet[1])
            key = extended[key];
        if (key)
            QueueKeyboardEvents(keyboard, packet[0] & 0x80 ? KeyRelease : KeyPress,
                                key + 8);
    }
}

static int
open_input(const char *path, DeviceIntPtr device, NotifyFdProcPtr callback)
{
    int fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd >= 0 && !SetNotifyFd(fd, callback, X_NOTIFY_READ, device)) {
        close(fd);
        return -1;
    }
    return fd;
}

void
amlaot_xorg_input(DeviceIntPtr mouse, DeviceIntPtr keyboard)
{
    buttons = 0;
    if (mouse)
        mouse_fd = open_input("/dev/mouse", mouse, mouse_ready);
    if (keyboard)
        keyboard_fd = open_input("/dev/kbd", keyboard, keyboard_ready);
}

void
amlaot_xorg_close_input(void)
{
    if (mouse_fd >= 0) {
        RemoveNotifyFd(mouse_fd);
        close(mouse_fd);
        mouse_fd = -1;
    }
    if (keyboard_fd >= 0) {
        RemoveNotifyFd(keyboard_fd);
        close(keyboard_fd);
        keyboard_fd = -1;
    }
}
