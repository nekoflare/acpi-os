/* Framebuffer and PS/2 device hooks for the upstream Xvfb backend. */
#include <dix-config.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/fb.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
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
static uint32_t *scanout_shadow[2];
static Bool scanout_valid[2];
static Bool force_refresh;
static Bool page_flip;
static Bool partial_flip;
static Bool front_updates;
static DamagePtr screen_damage;
static Bool damage_attempted;
static RegionRec pending_damage[2];
static Bool pending_damage_ready;
static unsigned next_page;

enum {
    GUEST_FB_PRESENT = 0x46F0,
    GUEST_FB_PRESENT_RECT = 0x46F1,
    GUEST_FB_PRESENT_RECTS = 0x46F2,
    GUEST_FB_UPDATE_RECTS = 0x46F3,
    MAX_PRESENT_RECTS = 64,
};

struct guest_fb_present_rect {
    uint64_t pixels;
    uint16_t x1, y1, x2, y2;
};

struct guest_fb_present_rects {
    uint64_t pixels, count;
    BoxRec boxes[MAX_PRESENT_RECTS];
};

_Static_assert(sizeof(BoxRec) == 8 &&
               offsetof(struct guest_fb_present_rects, boxes) == 16,
               "guest framebuffer rectangle list ioctl layout");
_Static_assert(sizeof(struct guest_fb_present_rect) == 16,
               "guest framebuffer ioctl layout");
static ScreenBlockHandlerProcPtr screen_block_handler;
static int mouse_fd = -1, keyboard_fd = -1;
static uint8_t buttons;

enum present_path { PRESENT_RECT, PRESENT_FULL, PRESENT_ROWS, PRESENT_PATHS };
static enum present_path present_path;
static uint64_t present_bytes, last_motion_us, report_start_us;
static struct {
    unsigned frames[PRESENT_PATHS];
    unsigned mouse_packets, motion_packets, mouse_budget_hits;
    unsigned motion_frames;
    uint64_t bytes, present_us, max_present_us, max_motion_age_us;
} timing;

static uint64_t
monotonic_us(void)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now))
        return 0;
    return (uint64_t)now.tv_sec * 1000000 + now.tv_nsec / 1000;
}

static void
record_present(uint64_t start, enum present_path path, uint64_t bytes)
{
    uint64_t end = monotonic_us();
    if (!start || end < start)
        return;
    if (!report_start_us)
        report_start_us = start;
    uint64_t elapsed = end - start;
    ++timing.frames[path];
    timing.bytes += bytes;
    timing.present_us += elapsed;
    timing.max_present_us = max(timing.max_present_us, elapsed);
    if (last_motion_us && last_motion_us <= end) {
        ++timing.motion_frames;
        timing.max_motion_age_us = max(timing.max_motion_age_us, end - last_motion_us);
        last_motion_us = 0;
    }
    if (end - report_start_us < 1000000)
        return;
    LogMessageVerb(X_INFO, 0,
        "AMLDRAG t_us=%" PRIu64 " interval_us=%" PRIu64
        " rect=%u full=%u rows=%u bytes=%" PRIu64
        " present_total_us=%" PRIu64 " present_max_us=%" PRIu64
        " mouse_packets=%u motion_packets=%u mouse_budget_hits=%u"
        " motion_frames=%u latest_motion_to_present_max_us=%" PRIu64 "\n",
        end, end - report_start_us, timing.frames[PRESENT_RECT],
        timing.frames[PRESENT_FULL], timing.frames[PRESENT_ROWS], timing.bytes,
        timing.present_us, timing.max_present_us, timing.mouse_packets,
        timing.motion_packets, timing.mouse_budget_hits, timing.motion_frames,
        timing.max_motion_age_us);
    memset(&timing, 0, sizeof(timing));
    report_start_us = end;
}

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
    front_updates = TRUE;
    if (page_flip) {
        size_t bytes = (size_t)*width * *height * 4;
        for (unsigned page = 0; page < 2; ++page)
            scanout_shadow[page] = malloc(bytes);
    }
    next_page = 0;
    damage_attempted = FALSE;
    BoxRec full = { 0, 0, *width, *height };
    RegionInit(&pending_damage[0], &full, 1);
    RegionInit(&pending_damage[1], &full, 1);
    pending_damage_ready = TRUE;
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

/* Clip conservative X damage to the pixels that differ on this back page. */
static void
refine_damage(RegionPtr refined, RegionPtr damage, const uint32_t *pixels,
              const uint32_t *previous, int width)
{
    BoxRec boxes[MAX_PRESENT_RECTS];
    int count = 0;
    const BoxRec *rects = RegionRects(damage);
    for (int i = 0; i < RegionNumRects(damage); ++i) {
        const BoxRec *box = &rects[i];
        BoxRec changed = { box->x2, box->y2, box->x1, box->y1 };
        size_t bytes = (box->x2 - box->x1) * sizeof(*pixels);
        for (int y = box->y1; y < box->y2; ++y) {
            size_t row = (size_t)y * width;
            const uint32_t *current = pixels + row;
            const uint32_t *old = previous + row;
            if (!memcmp(current + box->x1, old + box->x1, bytes))
                continue;
            int left = box->x1;
            int right = box->x2;
            while (left < changed.x1 && current[left] == old[left])
                ++left;
            while (right > changed.x2 && current[right - 1] == old[right - 1])
                --right;
            changed.x1 = min(changed.x1, left);
            changed.x2 = max(changed.x2, right);
            changed.y1 = min(changed.y1, y);
            changed.y2 = y + 1;
        }
        if (changed.y1 < changed.y2)
            boxes[count++] = changed;
    }
    /* The back page may already match while the visible page is stale. */
    if (!count)
        boxes[count++] = (BoxRec){ 0, 0, 1, 1 };
    RegionInitBoxes(refined, boxes, count);
}

static void
remember_scanout(uint32_t *shadow, const uint8_t *pixels, RegionPtr damage, int width)
{
    const BoxRec *boxes = RegionRects(damage);
    for (int i = 0; i < RegionNumRects(damage); ++i) {
        const BoxRec *box = &boxes[i];
        size_t bytes = (box->x2 - box->x1) * sizeof(*shadow);
        for (int y = box->y1; y < box->y2; ++y) {
            size_t offset = (size_t)y * width + box->x1;
            memcpy(shadow + offset, pixels + offset * sizeof(*shadow), bytes);
        }
    }
}

static int
present_page(const uint8_t *pixels, RegionPtr damage, int width, int height)
{
    const BoxRec *box = RegionExtents(damage);
    size_t threshold = (size_t)width * height * 3 / 4;
    int count = RegionNumRects(damage);
    if (partial_flip && count > 1 && count <= MAX_PRESENT_RECTS) {
        size_t area = 0;
        const BoxRec *boxes = RegionRects(damage);
        for (int i = 0; i < count; ++i)
            area += (size_t)(boxes[i].x2 - boxes[i].x1) *
                    (boxes[i].y2 - boxes[i].y1);
        if (area < threshold) {
            struct guest_fb_present_rects request = {
                .pixels = (uintptr_t)pixels, .count = count
            };
            memcpy(request.boxes, boxes, count * sizeof(*boxes));
            if (!ioctl(fb_fd, GUEST_FB_PRESENT_RECTS, &request)) {
                present_path = PRESENT_RECT;
                present_bytes = area * 4;
                return 0;
            }
            if (errno != ENOTTY)
                return -1;
        }
    }
    size_t area = (size_t)(box->x2 - box->x1) * (box->y2 - box->y1);
    if (partial_flip && screen_damage && area < threshold) {
        struct guest_fb_present_rect request = {
            (uintptr_t)pixels, box->x1, box->y1, box->x2, box->y2
        };
        if (!ioctl(fb_fd, GUEST_FB_PRESENT_RECT, &request)) {
            present_path = PRESENT_RECT;
            present_bytes = area * 4;
            return 0;
        }
        if (errno != ENOTTY)
            return -1;
        partial_flip = FALSE;
    }
    present_path = PRESENT_FULL;
    present_bytes = (uint64_t)width * height * 4;
    return ioctl(fb_fd, GUEST_FB_PRESENT, pixels);
}

static int
update_scanout(const uint8_t *pixels, RegionPtr damage)
{
    int count = RegionNumRects(damage);
    const BoxRec *boxes = RegionRects(damage);
    struct guest_fb_present_rects request = {
        .pixels = (uintptr_t)pixels, .count = count
    };
    memcpy(request.boxes, boxes, count * sizeof(*boxes));
    if (ioctl(fb_fd, GUEST_FB_UPDATE_RECTS, &request))
        return -1;

    present_path = PRESENT_RECT;
    present_bytes = 0;
    for (int i = 0; i < count; ++i)
        present_bytes += (uint64_t)(boxes[i].x2 - boxes[i].x1) *
                         (boxes[i].y2 - boxes[i].y1) * 4;
    return 0;
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
    uint64_t start = monotonic_us();
    if (page_flip && pixmap->devKind == row_bytes) {
        size_t bytes = row_bytes * screen->height;
        if (!screen_damage && !force_refresh && !memcmp(pixels, published, bytes))
            return;
        Bool update_front = front_updates && screen_damage && !force_refresh;
        unsigned page = next_page ^ update_front;
        BoxRec full = { 0, 0, screen->width, screen->height };
        for (unsigned i = 0; i < 2; ++i) {
            RegionPtr pending = &pending_damage[i];
            if (force_refresh || !screen_damage || (update_front && i != page) ||
                !RegionUnion(pending, pending, DamageRegion(screen_damage))) {
                RegionReset(pending, &full);
            } else if (RegionNumRects(pending) > MAX_PRESENT_RECTS) {
                BoxRec extents = *RegionExtents(pending);
                RegionReset(pending, &extents);
            }
        }
        if (screen_damage)
            DamageEmpty(screen_damage);
        RegionPtr pending = &pending_damage[page];
        uint32_t *shadow = scanout_shadow[page];
        Bool compare = shadow && scanout_valid[page];
        RegionRec refined;
        RegionPtr update = pending;
        if (compare) {
            refine_damage(&refined, pending, (const uint32_t *)pixels, shadow, screen->width);
            if (RegionNotEmpty(&refined) && RegionNumRects(&refined) <= MAX_PRESENT_RECTS)
                update = &refined;
        }
        int result = update_front ? update_scanout(pixels, update)
                                  : present_page(pixels, update, screen->width, screen->height);
        int present_error = errno;
        if (compare)
            RegionUninit(&refined);
        errno = present_error;
        if (update_front && result && errno == ENOTTY) {
            front_updates = FALSE;
            page = next_page;
            pending = &pending_damage[page];
            shadow = scanout_shadow[page];
            result = present_page(pixels, pending, screen->width, screen->height);
            update_front = FALSE;
        }
        if (!result) {
            if (shadow) {
                remember_scanout(shadow, pixels, pending, screen->width);
                scanout_valid[page] = TRUE;
            }
            if (force_refresh)
                LogMessageVerb(X_INFO, 0, "Guest framebuffer scanout initialized\n");
            if (!screen_damage)
                memcpy(published, pixels, bytes);
            RegionEmpty(pending);
            if (!update_front)
                next_page ^= 1;
            force_refresh = FALSE;
            record_present(start, present_path, present_bytes);
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
    if (screen_damage)
        DamageEmpty(screen_damage);
    uint64_t written = 0;
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
        written += row_bytes;
    }
    force_refresh = FALSE;
    if (written)
        record_present(start, PRESENT_ROWS, written);
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
    if (pending_damage_ready) {
        RegionUninit(&pending_damage[0]);
        RegionUninit(&pending_damage[1]);
        pending_damage_ready = FALSE;
    }
    for (unsigned page = 0; page < 2; ++page) {
        free(scanout_shadow[page]);
        scanout_shadow[page] = NULL;
        scanout_valid[page] = FALSE;
    }
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
    unsigned i;
    Bool motion = FALSE;
    for (i = 0; i < 32; ++i) {
        uint8_t packet[8];
        if (read(fd, packet, sizeof(packet)) != sizeof(packet))
            break;
        int dx = (int16_t)(packet[0] | packet[1] << 8);
        int dy = (int16_t)(packet[2] | packet[3] << 8);
        if (dx || dy) {
            motion = TRUE;
            ++timing.motion_packets;
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
    timing.mouse_packets += i;
    if (i == 32)
        ++timing.mouse_budget_hits;
    if (motion)
        last_motion_us = monotonic_us();
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
