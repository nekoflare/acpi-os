#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <poll.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

enum {
    ROOT_WINDOW = 0x100,
    ROOT_COLORMAP = 0x101,
    ROOT_VISUAL = 0x102,
    CLIENT_ID_BASE = 0x200000,
    CLIENT_ID_MASK = 0x1FFFFF,
    CREATE_WINDOW = 1,
    CHANGE_WINDOW_ATTRIBUTES = 2,
    GET_WINDOW_ATTRIBUTES = 3,
    MAP_WINDOW = 8,
    MAP_SUBWINDOWS = 9,
    CONFIGURE_WINDOW = 12,
    BACKGROUND_PIXMAP = 1,
    BACKGROUND_PIXEL = 1 << 1,
    BORDER_PIXEL = 1 << 3,
    BIT_GRAVITY_ATTRIBUTE = 1 << 4,
    COLORMAP_ATTRIBUTE = 1 << 13,
    OVERRIDE_REDIRECT_ATTRIBUTE = 1 << 9,
    CURSOR_ATTRIBUTE = 1 << 14,
    EXPOSURE_MASK = 1 << 15,
    EVENT_MASK_ATTRIBUTE = 1 << 11,
    SUBSTRUCTURE_NOTIFY = 1 << 19,
    SUBSTRUCTURE_REDIRECT = 1 << 20,
    ALL_EVENT_BITS = (1 << 25) - 1,
    EXPOSE_EVENT = 12,
    CREATE_NOTIFY = 16,
    MAP_NOTIFY = 19,
    WINDOW_X = 96,
    WINDOW_Y = 192,
    WINDOW_WIDTH = 208,
    WINDOW_HEIGHT = 112,
    WINDOW_PIXEL = 0x2BA6A2,
    ROOT_DEPTH = 24,
    GET_GEOMETRY = 14,
    QUERY_TREE = 15,
    INTERN_ATOM = 16,
    GET_ATOM_NAME = 17,
    CHANGE_PROPERTY = 18,
    DELETE_PROPERTY = 19,
    GET_PROPERTY = 20,
    MAX_PROPERTIES = 16,
    MAX_PROPERTY_BYTES = 256,
    GRAB_KEY = 33,
    UNGRAB_KEY = 34,
    QUERY_POINTER = 38,
    SET_INPUT_FOCUS = 42,
    GET_KEYBOARD_MAPPING = 101,
    GET_MODIFIER_MAPPING = 119,
    GET_INPUT_FOCUS = 43,
    OPEN_FONT = 45,
    CLOSE_FONT = 46,
    ALLOC_COLOR = 84,
    CREATE_GLYPH_CURSOR = 94,
    FREE_CURSOR = 95,
    CURSOR_FONT_GLYPHS = 154,
    MAX_CURSOR_RESOURCES = 16,
    CREATE_PIXMAP = 53,
    FREE_PIXMAP = 54,
    MAX_PIXMAPS = 16,
    MAX_WINDOWS = 8,
    CREATE_GC = 55,
    CHANGE_GC = 56,
    CLEAR_AREA = 61,
    COPY_AREA = 62,
    POLY_FILL_RECTANGLE = 70,
    POLY_FILL_ARC = 71,
    PUT_IMAGE = 72,
    GET_IMAGE = 73,
    NO_EXPOSURE = 14,
    FREE_GC = 60,
    LAST_PREDEFINED_ATOM = 68,
    MAX_DYNAMIC_ATOMS = 64,
    MAX_ATOM_NAME = 255,
    QUERY_EXTENSION = 98,
    LIST_EXTENSIONS = 99,
    NO_OPERATION = 127,
    BAD_REQUEST = 1,
    BAD_VALUE = 2,
    BAD_WINDOW = 3,
    BAD_PIXMAP = 4,
    BAD_ATOM = 5,
    BAD_CURSOR = 6,
    BAD_FONT = 7,
    BAD_MATCH = 8,
    BAD_DRAWABLE = 9,
    BAD_ACCESS = 10,
    BAD_ALLOC = 11,
    BAD_COLORMAP = 12,
    BAD_GC = 13,
    BAD_ID_CHOICE = 14,
    BAD_NAME = 15,
    BAD_LENGTH = 16,
    MAX_REQUEST_WORDS = 4096,
};

struct framebuffer {
    int fd;
    struct fb_var_screeninfo mode;
    struct fb_fix_screeninfo layout;
};

struct window {
    uint32_t id, parent;
    int x, y;
    uint16_t width, height;
    uint32_t background, border, events, cursor;
    uint8_t bit_gravity;
    bool has_background;
    bool mapped, override_redirect;
};

static struct window *find_window(struct window windows[MAX_WINDOWS], uint32_t id)
{
    for (size_t i = 0; i < MAX_WINDOWS; ++i)
        if (windows[i].id == id)
            return &windows[i];
    return NULL;
}

struct window_area {
    int x, y, left, top, right, bottom;
};

static bool window_view(struct window windows[MAX_WINDOWS], const struct window *window,
                        struct window_area *area)
{
    *area = (struct window_area){
        .right = window->width, .bottom = window->height,
    };
    const struct window *current = window;
    for (;;) {
        if (!current->mapped)
            return false;
        area->x += current->x;
        area->y += current->y;
        area->left += current->x;
        area->right += current->x;
        area->top += current->y;
        area->bottom += current->y;
        if (current->parent == ROOT_WINDOW)
            return true;
        current = find_window(windows, current->parent);
        if (!current)
            return false;
        if (area->left < 0) area->left = 0;
        if (area->top < 0) area->top = 0;
        if (area->right > current->width) area->right = current->width;
        if (area->bottom > current->height) area->bottom = current->height;
    }
}

static int open_framebuffer(struct framebuffer *fb)
{
    fb->fd = open("/dev/fb0", O_WRONLY);
    if (fb->fd < 0)
        return -1;
    if (ioctl(fb->fd, FBIOGET_VSCREENINFO, &fb->mode) ||
        ioctl(fb->fd, FBIOGET_FSCREENINFO, &fb->layout) ||
        fb->mode.xres < WINDOW_X + WINDOW_WIDTH || fb->mode.xres > UINT16_MAX ||
        fb->mode.yres < WINDOW_Y + WINDOW_HEIGHT || fb->mode.yres > UINT16_MAX ||
        fb->mode.bits_per_pixel != 32 ||
        fb->mode.red.length != 8 || fb->mode.green.length != 8 ||
        fb->mode.blue.length != 8 || fb->mode.red.offset > 24 ||
        fb->mode.green.offset > 24 || fb->mode.blue.offset > 24 ||
        fb->layout.line_length < (uint64_t)fb->mode.xres * sizeof(uint32_t) ||
        fb->layout.smem_len < (uint64_t)fb->layout.line_length * fb->mode.yres) {
        close(fb->fd);
        return -1;
    }
    return 0;
}

static int read_exact(int fd, void *data, size_t size)
{
    uint8_t *bytes = data;
    size_t received = 0;
    while (received < size) {
        ssize_t count = read(fd, bytes + received, size - received);
        if (count < 0 && errno == EINTR)
            continue;
        if (count < 0 || (!count && received))
            return -1;
        if (!count)
            return 0;
        received += (size_t)count;
    }
    return 1;
}

static int write_exact(int fd, const void *data, size_t size)
{
    const uint8_t *bytes = data;
    while (size) {
        ssize_t count = write(fd, bytes, size);
        if (count < 0 && errno == EINTR)
            continue;
        if (count <= 0)
            return -1;
        bytes += count;
        size -= (size_t)count;
    }
    return 0;
}

static uint32_t framebuffer_pixel(const struct framebuffer *fb, uint32_t rgb)
{
    return (((rgb >> 16) & 255) << fb->mode.red.offset) |
           (((rgb >> 8) & 255) << fb->mode.green.offset) |
           ((rgb & 255) << fb->mode.blue.offset);
}

static int write_framebuffer_row(const struct framebuffer *fb, int x, int y,
                                 const uint32_t *row, size_t count)
{
    off_t offset = (off_t)y * fb->layout.line_length + (off_t)x * sizeof(*row);
    if (lseek(fb->fd, offset, SEEK_SET) != offset)
        return -1;
    return write_exact(fb->fd, row, count * sizeof(*row));
}

static int paint_window(const struct framebuffer *fb, const struct window *window)
{
    if (!window->has_background)
        return 0;

    int left = window->x;
    int top = window->y;
    int right = left + window->width;
    int bottom = top + window->height;
    if (left < 0)
        left = 0;
    if (top < 0)
        top = 0;
    if (right > (int)fb->mode.xres)
        right = (int)fb->mode.xres;
    if (bottom > (int)fb->mode.yres)
        bottom = (int)fb->mode.yres;
    if (left >= right || top >= bottom)
        return 0;

    size_t count = (size_t)(right - left);
    uint32_t *row = malloc(count * sizeof(*row));
    if (!row)
        return -1;
    uint32_t packed = framebuffer_pixel(fb, window->background);
    for (size_t i = 0; i < count; ++i)
        row[i] = packed;

    int result = 0;
    for (int y = top; y < bottom; ++y) {
        if (write_framebuffer_row(fb, left, y, row, count)) {
            result = -1;
            break;
        }
    }
    free(row);
    return result;
}

static uint32_t get_field(const uint8_t *bytes, size_t size, bool little_endian)
{
    uint32_t value = 0;
    for (size_t i = 0; i < size; ++i)
        value = (value << 8) | bytes[little_endian ? size - 1 - i : i];
    return value;
}

static void put_field(uint8_t *bytes, size_t size, uint32_t value, bool little_endian)
{
    for (size_t i = 0; i < size; ++i) {
        bytes[little_endian ? i : size - 1 - i] = (uint8_t)value;
        value >>= 8;
    }
}

static int send_setup(int fd, bool little_endian, const struct framebuffer *fb, uint32_t base)
{
    const char vendor[] = "AMLAOT";
    uint8_t packet[144] = {1};
    put_field(packet + 2, 2, 11, little_endian);
    put_field(packet + 6, 2, (sizeof(packet) - 8) / 4, little_endian);

    uint8_t *setup = packet + 8;
    put_field(setup, 4, 1, little_endian); // Server release
    put_field(setup + 4, 4, base, little_endian); // Client resource ID base
    put_field(setup + 8, 4, CLIENT_ID_MASK, little_endian);
    put_field(setup + 16, 2, sizeof(vendor) - 1, little_endian);
    put_field(setup + 18, 2, MAX_REQUEST_WORDS, little_endian);
    setup[20] = 1; // Screens
    setup[21] = 2; // Pixmap formats
    setup[24] = 32; // Bitmap scanline unit
    setup[25] = 32; // Bitmap scanline padding
    setup[26] = 8; // Minimum keycode
    setup[27] = 255;
    memcpy(setup + 32, vendor, sizeof(vendor) - 1);

    uint8_t *format = setup + 40;
    format[0] = ROOT_DEPTH;
    format[1] = 32; // Bits per pixel
    format[2] = 32; // Scanline padding

    format[8] = 1;
    format[9] = 1;
    format[10] = 32;
    uint8_t *screen = format + 16;
    put_field(screen, 4, ROOT_WINDOW, little_endian);
    put_field(screen + 4, 4, ROOT_COLORMAP, little_endian);
    put_field(screen + 8, 4, 0xFFFFFF, little_endian);
    put_field(screen + 20, 2, fb->mode.xres, little_endian);
    put_field(screen + 22, 2, fb->mode.yres, little_endian);
    put_field(screen + 24, 2, fb->mode.xres * 254 / 960, little_endian); // Assume 96 DPI
    put_field(screen + 26, 2, fb->mode.yres * 254 / 960, little_endian);
    put_field(screen + 28, 2, 1, little_endian); // Minimum installed colormaps
    put_field(screen + 30, 2, 1, little_endian);
    put_field(screen + 32, 4, ROOT_VISUAL, little_endian);
    screen[38] = ROOT_DEPTH;
    screen[39] = 2; // Allowed depths

    uint8_t *depth = screen + 40;
    depth[0] = ROOT_DEPTH;
    put_field(depth + 2, 2, 1, little_endian); // Visuals at this depth

    uint8_t *visual = depth + 8;
    put_field(visual, 4, ROOT_VISUAL, little_endian);
    visual[4] = 4; // TrueColor
    visual[5] = 8; // Bits per RGB component
    put_field(visual + 6, 2, 256, little_endian);
    put_field(visual + 8, 4, 0xFF0000, little_endian);
    put_field(visual + 12, 4, 0x00FF00, little_endian);
    put_field(visual + 16, 4, 0x0000FF, little_endian);
    visual[24] = 1; // One-bit pixmap depth has no visuals.
    return write_exact(fd, packet, sizeof(packet));
}

static int discard_bytes(int fd, size_t size)
{
    uint8_t scratch[128];
    while (size) {
        size_t count = size < sizeof(scratch) ? size : sizeof(scratch);
        if (read_exact(fd, scratch, count) != 1)
            return -1;
        size -= count;
    }
    return 0;
}

static uint8_t create_window(struct window *window, struct window windows[MAX_WINDOWS],
                             const uint8_t *request,
                             size_t size, bool little_endian, uint32_t base, uint32_t *bad_value)
{
    if (size < 32)
        return BAD_LENGTH;
    uint32_t mask = get_field(request + 28, 4, little_endian);
    if (size != 32 + (size_t)__builtin_popcount(mask) * 4)
        return BAD_LENGTH;
    uint32_t parent = get_field(request + 8, 4, little_endian);
    if (parent != ROOT_WINDOW && (!parent || !find_window(windows, parent))) {
        *bad_value = parent;
        return BAD_WINDOW;
    }
    uint32_t id = get_field(request + 4, 4, little_endian);
    if ((id & ~CLIENT_ID_MASK) != base || id == window->id) {
        *bad_value = id;
        return BAD_ID_CHOICE;
    }
    uint32_t class = get_field(request + 22, 2, little_endian);
    uint32_t visual = get_field(request + 24, 4, little_endian);
    if ((request[1] && request[1] != ROOT_DEPTH) || class > 1 ||
        (visual && visual != ROOT_VISUAL) || get_field(request + 20, 2, little_endian))
        return BAD_MATCH;

    uint16_t width = get_field(request + 16, 2, little_endian);
    uint16_t height = get_field(request + 18, 2, little_endian);
    if (!width || !height)
        return BAD_VALUE;
    if (window->id)
        return BAD_ALLOC;
    *window = (struct window){
        .id = id,
        .parent = parent,
        .x = (int16_t)get_field(request + 12, 2, little_endian),
        .y = (int16_t)get_field(request + 14, 2, little_endian),
        .width = width,
        .height = height,
    };
    return 0;
}

struct graphics_context {
    uint32_t id, foreground, background, planes;
    uint8_t depth;
    bool graphics_exposures;
};

struct pixmap {
    uint32_t id;
    uint16_t width, height;
    uint8_t depth;
    uint32_t *pixels;
};

static struct pixmap *find_pixmap(struct pixmap pixmaps[MAX_PIXMAPS], uint32_t id)
{
    for (size_t i = 0; i < MAX_PIXMAPS; ++i) {
        if (pixmaps[i].id == id)
            return &pixmaps[i];
    }
    return NULL;
}

static struct graphics_context *find_context(struct graphics_context contexts[16], uint32_t id)
{
    for (size_t i = 0; i < 16; ++i) {
        if (contexts[i].id == id)
            return &contexts[i];
    }
    return NULL;
}

static uint8_t handle_pixmap(struct pixmap pixmaps[MAX_PIXMAPS], struct window windows[MAX_WINDOWS],
                             struct graphics_context contexts[16], const uint8_t *request,
                             bool little_endian, uint32_t base, uint32_t *bad_value)
{
    uint32_t id = get_field(request + 4, 4, little_endian);
    struct pixmap *existing = id ? find_pixmap(pixmaps, id) : NULL;
    if (request[0] == FREE_PIXMAP) {
        if (!existing) {
            *bad_value = id;
            return BAD_PIXMAP;
        }
        free(existing->pixels);
        *existing = (struct pixmap){0};
        return 0;
    }

    if ((id & ~CLIENT_ID_MASK) != base || find_window(windows, id) ||
        existing || find_context(contexts, id)) {
        *bad_value = id;
        return BAD_ID_CHOICE;
    }
    uint32_t drawable = get_field(request + 8, 4, little_endian);
    if (drawable != ROOT_WINDOW && (!drawable || !find_window(windows, drawable)) &&
        (!drawable || !find_pixmap(pixmaps, drawable))) {
        *bad_value = drawable;
        return BAD_DRAWABLE;
    }
    uint16_t width = get_field(request + 12, 2, little_endian);
    uint16_t height = get_field(request + 14, 2, little_endian);
    if (!width || !height)
        return BAD_VALUE;
    if (request[1] != 1 && request[1] != ROOT_DEPTH) {
        *bad_value = request[1];
        return BAD_VALUE;
    }
    struct pixmap *slot = find_pixmap(pixmaps, 0);
    if (!slot)
        return BAD_ALLOC;
    // Pixel storage can be allocated when the pixmap is first drawn to.
    if ((uint64_t)width * height > 4 * 1024 * 1024)
        return BAD_ALLOC;
    *slot = (struct pixmap){.id = id, .width = width, .height = height, .depth = request[1]};
    return 0;
}

static uint8_t update_gc(struct graphics_context *context, uint32_t mask,
                         const uint8_t *values, bool little_endian, uint32_t *bad_value)
{
    const uint32_t supported = 0xFF | (1U << 16);
    if (mask & ~supported) {
        *bad_value = mask;
        return BAD_VALUE;
    }
    struct graphics_context updated = *context;
    const uint32_t max_line_values[] = {UINT16_MAX, 2, 3, 2};
    for (unsigned bit = 0; mask; ++bit) {
        uint32_t flag = 1U << bit;
        if (!(mask & flag))
            continue;
        uint32_t value = get_field(values, 4, little_endian);
        values += 4;
        mask &= ~flag;
        if ((bit == 0 && value != 3) || (bit == 16 && value > 1) ||
            (bit >= 4 && bit <= 7 && value > max_line_values[bit - 4])) {
            *bad_value = value;
            return BAD_VALUE;
        }
        if (bit == 1)
            updated.planes = value;
        if (bit == 2)
            updated.foreground = value;
        if (bit == 3)
            updated.background = value;
        if (bit == 16)
            updated.graphics_exposures = value;
    }
    *context = updated;
    return 0;
}

static uint8_t handle_gc(struct graphics_context contexts[16], struct window windows[MAX_WINDOWS],
                         struct pixmap pixmaps[MAX_PIXMAPS], const uint8_t *request,
                         size_t bytes, bool little_endian, uint32_t base, uint32_t *bad_value)
{
    uint32_t id = get_field(request + 4, 4, little_endian);
    struct graphics_context *existing = id ? find_context(contexts, id) : NULL;
    if (request[0] != CREATE_GC) {
        if (!existing) {
            *bad_value = id;
            return BAD_GC;
        }
        if (request[0] == FREE_GC) {
            existing->id = 0;
            return 0;
        }
        uint32_t mask = get_field(request + 8, 4, little_endian);
        if (bytes != 12 + (size_t)__builtin_popcount(mask) * 4)
            return BAD_LENGTH;
        return update_gc(existing, mask, request + 12, little_endian, bad_value);
    }
    uint32_t mask = get_field(request + 12, 4, little_endian);
    if (bytes != 16 + (size_t)__builtin_popcount(mask) * 4)
        return BAD_LENGTH;
    uint32_t drawable = get_field(request + 8, 4, little_endian);
    struct pixmap *pixmap = drawable ? find_pixmap(pixmaps, drawable) : NULL;
    if (drawable != ROOT_WINDOW && (!drawable || !find_window(windows, drawable)) && !pixmap) {
        *bad_value = drawable;
        return BAD_DRAWABLE;
    }
    if ((id & ~CLIENT_ID_MASK) != base || find_window(windows, id) || existing || find_pixmap(pixmaps, id)) {
        *bad_value = id;
        return BAD_ID_CHOICE;
    }
    struct graphics_context *slot = find_context(contexts, 0);
    if (!slot)
        return BAD_ALLOC;
    struct graphics_context gc = {
        .id = id, .background = 1, .planes = UINT32_MAX,
        .depth = pixmap ? pixmap->depth : ROOT_DEPTH, .graphics_exposures = true,
    };
    uint8_t error = update_gc(&gc, mask, request + 16, little_endian, bad_value);
    if (!error)
        *slot = gc;
    return error;
}

static uint8_t ensure_pixels(struct pixmap *pixmap)
{
    if (!pixmap->pixels)
        pixmap->pixels = calloc((size_t)pixmap->width * pixmap->height, sizeof(*pixmap->pixels));
    return pixmap->pixels ? 0 : BAD_ALLOC;
}

static uint8_t fill_pixmap(struct pixmap *pixmap, const struct graphics_context *gc,
                          const uint8_t *rectangles, size_t bytes, bool little_endian)
{
    uint8_t error = ensure_pixels(pixmap);
    if (error)
        return error;
    uint32_t planes = gc->planes & (pixmap->depth == 1 ? 1 : 0xFFFFFF);
    for (size_t offset = 0; offset < bytes; offset += 8) {
        const uint8_t *rect = rectangles + offset;
        int x = (int16_t)get_field(rect, 2, little_endian);
        int y = (int16_t)get_field(rect + 2, 2, little_endian);
        int right = x + (int)get_field(rect + 4, 2, little_endian);
        int bottom = y + (int)get_field(rect + 6, 2, little_endian);
        if (right > pixmap->width)
            right = pixmap->width;
        if (bottom > pixmap->height)
            bottom = pixmap->height;
        for (int row = y < 0 ? 0 : y; row < bottom; ++row) {
            for (int col = x < 0 ? 0 : x; col < right; ++col) {
                uint32_t *pixel = &pixmap->pixels[(size_t)row * pixmap->width + col];
                *pixel = (*pixel & ~planes) | (gc->foreground & planes);
            }
        }
    }
    return 0;
}

static uint32_t pixmap_pixel(const struct pixmap *pixmap, int x, int y)
{
    return pixmap->pixels ? pixmap->pixels[(size_t)y * pixmap->width + x] : 0;
}

static void put_pixmap_pixel(struct pixmap *pixmap, int x, int y, uint32_t value, uint32_t mask)
{
    uint32_t *pixel = &pixmap->pixels[(size_t)y * pixmap->width + x];
    *pixel = (*pixel & ~mask) | (value & mask);
}

static uint8_t copy_pixmap(struct pixmap *dst, struct pixmap *src, const struct graphics_context *gc,
                          const uint8_t *request, bool little_endian)
{
    if (dst->depth != src->depth)
        return BAD_MATCH;
    int sx = (int16_t)get_field(request + 16, 2, little_endian);
    int sy = (int16_t)get_field(request + 18, 2, little_endian);
    int dx = (int16_t)get_field(request + 20, 2, little_endian);
    int dy = (int16_t)get_field(request + 22, 2, little_endian);
    int width = get_field(request + 24, 2, little_endian);
    int height = get_field(request + 26, 2, little_endian);
    int left = 0, top = 0, right = width, bottom = height;
    if (left < -sx) left = -sx;
    if (left < -dx) left = -dx;
    if (top < -sy) top = -sy;
    if (top < -dy) top = -dy;
    if (right > src->width - sx) right = src->width - sx;
    if (right > dst->width - dx) right = dst->width - dx;
    if (bottom > src->height - sy) bottom = src->height - sy;
    if (bottom > dst->height - dy) bottom = dst->height - dy;
    if (left >= right || top >= bottom)
        return 0;
    uint8_t error = ensure_pixels(dst);
    if (error)
        return error;
    uint32_t mask = gc->planes & (dst->depth == 1 ? 1 : 0xFFFFFF);
    // Reverse traversal on overlapping copies where the destination follows the source.
    bool reverse_y = src == dst && dy > sy;
    bool reverse_x = src == dst && dy == sy && dx > sx;
    for (int row = 0; row < bottom - top; ++row) {
        int y = reverse_y ? bottom - 1 - row : top + row;
        for (int col = 0; col < right - left; ++col) {
            int x = reverse_x ? right - 1 - col : left + col;
            put_pixmap_pixel(dst, dx + x, dy + y, pixmap_pixel(src, sx + x, sy + y), mask);
        }
    }
    return 0;
}

static uint8_t put_image(struct pixmap *pixmap, const struct graphics_context *gc,
                         const uint8_t *request, size_t bytes, bool little_endian)
{
    bool bitmap = request[1] == 0 && request[21] == 1;
    bool monochrome = bitmap || (request[1] <= 2 && request[1] != 0 &&
                                 request[21] == 1 && pixmap->depth == 1);
    if ((!monochrome && (request[1] != 2 || request[20] ||
                     request[21] != ROOT_DEPTH || pixmap->depth != ROOT_DEPTH)) ||
        (monochrome && (request[20] >= 32 || (request[1] == 2 && request[20]))))
        return BAD_MATCH;
    int width = get_field(request + 12, 2, little_endian);
    int height = get_field(request + 14, 2, little_endian);
    size_t stride = monochrome ? ((size_t)width + request[20] + 31) / 32 * 4 : (size_t)width * 4;
    if (bytes != 24 + (uint64_t)stride * height)
        return BAD_LENGTH;
    int x = (int16_t)get_field(request + 16, 2, little_endian);
    int y = (int16_t)get_field(request + 18, 2, little_endian);
    uint8_t error = ensure_pixels(pixmap);
    if (error)
        return error;
    for (int row = 0; row < height; ++row) {
        for (int col = 0; col < width; ++col) {
            if (x + col < 0 || x + col >= pixmap->width || y + row < 0 || y + row >= pixmap->height)
                continue;
            const uint8_t *scanline = request + 24 + (size_t)row * stride;
            uint32_t pixel;
            if (monochrome) {
                unsigned bit = (unsigned)col + request[20];
                bool set = scanline[bit / 8] & (1U << (bit % 8));
                pixel = bitmap ? (set ? gc->foreground : gc->background) : set;
            } else {
                pixel = get_field(scanline + (size_t)col * 4, 4, true);
            }
            uint32_t depth_mask = pixmap->depth == 1 ? 1 : 0xFFFFFF;
            put_pixmap_pixel(pixmap, x + col, y + row, pixel, gc->planes & depth_mask);
        }
    }
    return 0;
}

static int send_pixmap_image(int fd, const struct pixmap *pixmap, const uint8_t *request,
                             uint16_t sequence, bool little_endian)
{
    int x = (int16_t)get_field(request + 8, 2, little_endian);
    int y = (int16_t)get_field(request + 10, 2, little_endian);
    int width = get_field(request + 12, 2, little_endian);
    int height = get_field(request + 14, 2, little_endian);
    if (request[1] != 2 || pixmap->depth != ROOT_DEPTH || x < 0 || y < 0 ||
        x + width > pixmap->width || y + height > pixmap->height)
        return BAD_MATCH;
    uint32_t mask = get_field(request + 16, 4, little_endian) & 0xFFFFFF;
    uint8_t reply[32] = {1, ROOT_DEPTH};
    put_field(reply + 2, 2, sequence, little_endian);
    put_field(reply + 4, 4, (uint32_t)width * height, little_endian);
    if (write_exact(fd, reply, sizeof(reply)))
        return -1;
    uint8_t buffer[512];
    for (int row = 0; row < height; ++row) {
        for (int col = 0; col < width;) {
            int count = width - col;
            if (count > (int)sizeof(buffer) / 4)
                count = sizeof(buffer) / 4;
            for (int i = 0; i < count; ++i)
                put_field(buffer + i * 4, 4, pixmap_pixel(pixmap, x + col + i, y + row) & mask, true);
            if (write_exact(fd, buffer, (size_t)count * 4))
                return -1;
            col += count;
        }
    }
    return 0;
}

static int copy_pixmap_to_window(const struct framebuffer *fb, const struct pixmap *pixmap,
                                 struct window windows[MAX_WINDOWS], const struct window *window,
                                 const uint8_t *request, bool little_endian)
{
    struct window_area area;
    if (!window_view(windows, window, &area))
        return 0;
    int source_x = (int16_t)get_field(request + 16, 2, little_endian);
    int source_y = (int16_t)get_field(request + 18, 2, little_endian);
    int dest_x = (int16_t)get_field(request + 20, 2, little_endian);
    int dest_y = (int16_t)get_field(request + 22, 2, little_endian);
    int width = get_field(request + 24, 2, little_endian);
    int height = get_field(request + 26, 2, little_endian);
    if (!width || !height)
        return 0;
    uint32_t *row = malloc((size_t)width * sizeof(*row));
    if (!row)
        return -1;
    int result = 0;
    for (int y = 0; y < height; ++y) {
        int sy = source_y + y, dy = dest_y + y, fy = area.y + dy;
        if (sy < 0 || sy >= pixmap->height || dy < 0 || dy >= window->height ||
            fy < area.top || fy >= area.bottom || fy < 0 || fy >= (int)fb->mode.yres)
            continue;
        int start = 0, count = 0;
        for (int x = 0; x < width; ++x) {
            int sx = source_x + x, dx = dest_x + x, fx = area.x + dx;
            if (sx < 0 || sx >= pixmap->width || dx < 0 || dx >= window->width ||
                fx < area.left || fx >= area.right || fx < 0 || fx >= (int)fb->mode.xres)
                continue;
            if (!count)
                start = fx;
            uint32_t rgb = pixmap->pixels ? pixmap->pixels[(size_t)sy * pixmap->width + sx] : 0;
            row[count++] = framebuffer_pixel(fb, rgb);
        }
        if (count && write_framebuffer_row(fb, start, fy, row, count)) {
            result = -1;
            break;
        }
    }
    free(row);
    return result;
}

static const char *const predefined_atoms[] = {
    "PRIMARY", "SECONDARY", "ARC", "ATOM",
    "BITMAP", "CARDINAL", "COLORMAP", "CURSOR",
    "CUT_BUFFER0", "CUT_BUFFER1", "CUT_BUFFER2", "CUT_BUFFER3",
    "CUT_BUFFER4", "CUT_BUFFER5", "CUT_BUFFER6", "CUT_BUFFER7",
    "DRAWABLE", "FONT", "INTEGER", "PIXMAP",
    "POINT", "RECTANGLE", "RESOURCE_MANAGER", "RGB_COLOR_MAP",
    "RGB_BEST_MAP", "RGB_BLUE_MAP", "RGB_DEFAULT_MAP", "RGB_GRAY_MAP",
    "RGB_GREEN_MAP", "RGB_RED_MAP", "STRING", "VISUALID",
    "WINDOW", "WM_COMMAND", "WM_HINTS", "WM_CLIENT_MACHINE",
    "WM_ICON_NAME", "WM_ICON_SIZE", "WM_NAME", "WM_NORMAL_HINTS",
    "WM_SIZE_HINTS", "WM_ZOOM_HINTS", "MIN_SPACE", "NORM_SPACE",
    "MAX_SPACE", "END_SPACE", "SUPERSCRIPT_X", "SUPERSCRIPT_Y",
    "SUBSCRIPT_X", "SUBSCRIPT_Y", "UNDERLINE_POSITION", "UNDERLINE_THICKNESS",
    "STRIKEOUT_ASCENT", "STRIKEOUT_DESCENT", "ITALIC_ANGLE", "X_HEIGHT",
    "QUAD_WIDTH", "WEIGHT", "POINT_SIZE", "RESOLUTION",
    "COPYRIGHT", "NOTICE", "FONT_NAME", "FAMILY_NAME",
    "FULL_NAME", "CAP_HEIGHT", "WM_CLASS", "WM_TRANSIENT_FOR",
};
_Static_assert(sizeof(predefined_atoms) / sizeof(*predefined_atoms) == LAST_PREDEFINED_ATOM,
               "Predefined X11 atom count");

struct atom_table {
    size_t count;
    struct {
        uint8_t length;
        uint8_t name[MAX_ATOM_NAME];
    } names[MAX_DYNAMIC_ATOMS];
};

static bool atom_valid(const struct atom_table *atoms, uint32_t id)
{
    return id && id <= LAST_PREDEFINED_ATOM + atoms->count;
}

static const void *atom_name(const struct atom_table *atoms, uint32_t id, size_t *length)
{
    if (id <= LAST_PREDEFINED_ATOM) {
        const char *name = predefined_atoms[id - 1];
        *length = strlen(name);
        return name;
    }
    size_t index = id - LAST_PREDEFINED_ATOM - 1;
    *length = atoms->names[index].length;
    return atoms->names[index].name;
}

static uint32_t intern_atom(struct atom_table *atoms, const uint8_t *name,
                            size_t length, bool only_if_exists)
{
    for (uint32_t id = 1; atom_valid(atoms, id); ++id) {
        size_t existing_length;
        const void *existing = atom_name(atoms, id, &existing_length);
        if (length == existing_length && !memcmp(name, existing, length))
            return id;
    }
    if (only_if_exists || atoms->count == MAX_DYNAMIC_ATOMS)
        return 0;

    size_t index = atoms->count++;
    atoms->names[index].length = (uint8_t)length;
    memcpy(atoms->names[index].name, name, length);
    return LAST_PREDEFINED_ATOM + 1 + (uint32_t)index;
}

static uint8_t check_get_property(const struct atom_table *atoms, const uint8_t *request,
                                  bool little_endian, uint32_t *bad_value)
{
    if (request[1] > 1) {
        *bad_value = request[1];
        return BAD_VALUE;
    }
    uint32_t atom = get_field(request + 8, 4, little_endian);
    if (!atom_valid(atoms, atom)) {
        *bad_value = atom;
        return BAD_ATOM;
    }
    uint32_t type = get_field(request + 12, 4, little_endian);
    if (type && !atom_valid(atoms, type)) {
        *bad_value = type;
        return BAD_ATOM;
    }
    return 0;
}

struct property {
    uint32_t window, atom, type;
    uint16_t length;
    uint8_t format, data[MAX_PROPERTY_BYTES];
};

static struct property *find_property(struct property properties[MAX_PROPERTIES], uint32_t window, uint32_t atom)
{
    for (size_t i = 0; i < MAX_PROPERTIES; ++i) {
        if (properties[i].window == window && properties[i].atom == atom)
            return &properties[i];
    }
    return NULL;
}

static uint8_t change_property(struct property properties[MAX_PROPERTIES],
                               const struct atom_table *atoms, const uint8_t *request,
                               size_t bytes, bool little_endian, uint32_t *bad_value)
{
    uint32_t id = get_field(request + 4, 4, little_endian);
    uint32_t atom = get_field(request + 8, 4, little_endian);
    uint32_t type = get_field(request + 12, 4, little_endian);
    uint8_t format = request[16];
    uint8_t mode = request[1];
    if (!atom_valid(atoms, atom) || !atom_valid(atoms, type)) {
        *bad_value = atom_valid(atoms, atom) ? type : atom;
        return BAD_ATOM;
    }
    if (mode > 2 || (format != 8 && format != 16 && format != 32)) {
        *bad_value = mode > 2 ? mode : format;
        return BAD_VALUE;
    }
    uint64_t length = (uint64_t)get_field(request + 20, 4, little_endian) * (format / 8);
    if (bytes != 24 + ((length + 3) & ~(uint64_t)3))
        return BAD_LENGTH;

    struct property *property = find_property(properties, id, atom);
    size_t retained = 0;
    if (mode && property) {
        if (property->type != type || property->format != format)
            return BAD_MATCH;
        retained = property->length;
    }
    if (length + retained > MAX_PROPERTY_BYTES)
        return BAD_ALLOC;
    if (!property)
        property = find_property(properties, 0, 0);
    if (!property)
        return BAD_ALLOC;
    if (mode == 1)
        memmove(property->data + length, property->data, retained);
    memcpy(property->data + (mode == 2 ? retained : 0), request + 24, length);
    property->window = id;
    property->atom = atom;
    property->type = type;
    property->format = format;
    property->length = retained + length;
    return 0;
}

static int send_window_notice(int fd, uint8_t type, uint16_t sequence,
                              const struct window *window, bool little_endian)
{
    uint8_t event[32] = {type};
    put_field(event + 2, 2, sequence, little_endian);
    put_field(event + 4, 4, window->parent, little_endian);
    put_field(event + 8, 4, window->id, little_endian);
    if (type == CREATE_NOTIFY) {
        put_field(event + 12, 2, (uint16_t)window->x, little_endian);
        put_field(event + 14, 2, (uint16_t)window->y, little_endian);
        put_field(event + 16, 2, window->width, little_endian);
        put_field(event + 18, 2, window->height, little_endian);
        event[22] = window->override_redirect;
    } else {
        event[12] = window->override_redirect;
    }
    return write_exact(fd, event, sizeof(event));
}

enum cursor_resource_type { CURSOR_FONT, GLYPH_CURSOR };

struct cursor_resource {
    uint32_t id;
    enum cursor_resource_type type;
    uint16_t source_glyph, mask_glyph;
    bool has_mask;
    uint16_t foreground[3], background[3];
};

static struct cursor_resource *find_cursor_resource(
    struct cursor_resource resources[MAX_CURSOR_RESOURCES], uint32_t id)
{
    for (size_t i = 0; i < MAX_CURSOR_RESOURCES; ++i) {
        if (resources[i].id == id)
            return &resources[i];
    }
    return NULL;
}

static uint8_t handle_cursor_resource(struct cursor_resource resources[MAX_CURSOR_RESOURCES],
                                      uint8_t opcode, const uint8_t *request, size_t bytes,
                                      bool little_endian, uint32_t base, uint32_t *bad_value)
{
    uint32_t id = get_field(request + 4, 4, little_endian);
    struct cursor_resource *existing = id ? find_cursor_resource(resources, id) : NULL;
    if (opcode == CLOSE_FONT || opcode == FREE_CURSOR) {
        if (existing && existing->type == (opcode == CLOSE_FONT ? CURSOR_FONT : GLYPH_CURSOR)) {
            existing->id = 0;
            return 0;
        }
        *bad_value = id;
        return opcode == CLOSE_FONT ? BAD_FONT : BAD_CURSOR;
    }

    if (existing || (id & ~CLIENT_ID_MASK) != base) {
        *bad_value = id;
        return BAD_ID_CHOICE;
    }
    struct cursor_resource resource = {.id = id, .type = CURSOR_FONT};
    if (opcode == OPEN_FONT) {
        const char name[] = "cursor";
        size_t length = get_field(request + 8, 2, little_endian);
        if (bytes != 12 + ((length + 3) & ~(size_t)3))
            return BAD_LENGTH;
        if (length != sizeof(name) - 1)
            return BAD_NAME;
        for (size_t i = 0; i < length; ++i) {
            uint8_t ch = request[12 + i];
            if (ch >= 'A' && ch <= 'Z')
                ch += 'a' - 'A';
            if (ch != (uint8_t)name[i])
                return BAD_NAME;
        }
    } else {
        uint32_t source_id = get_field(request + 8, 4, little_endian);
        uint32_t mask_id = get_field(request + 12, 4, little_endian);
        struct cursor_resource *source = source_id ? find_cursor_resource(resources, source_id) : NULL;
        struct cursor_resource *mask = mask_id ? find_cursor_resource(resources, mask_id) : NULL;
        if (!source || source->type != CURSOR_FONT) {
            *bad_value = source_id;
            return BAD_FONT;
        }
        if (mask_id && (!mask || mask->type != CURSOR_FONT)) {
            *bad_value = mask_id;
            return BAD_FONT;
        }
        resource.type = GLYPH_CURSOR;
        resource.has_mask = mask_id != 0;
        resource.source_glyph = get_field(request + 16, 2, little_endian);
        resource.mask_glyph = get_field(request + 18, 2, little_endian);
        if (resource.source_glyph >= CURSOR_FONT_GLYPHS ||
            (resource.has_mask && resource.mask_glyph >= CURSOR_FONT_GLYPHS)) {
            *bad_value = resource.source_glyph >= CURSOR_FONT_GLYPHS
                ? resource.source_glyph : resource.mask_glyph;
            return BAD_VALUE;
        }
        for (size_t i = 0; i < 3; ++i) {
            resource.foreground[i] = get_field(request + 20 + i * 2, 2, little_endian);
            resource.background[i] = get_field(request + 26 + i * 2, 2, little_endian);
        }
    }

    struct cursor_resource *slot = find_cursor_resource(resources, 0);
    if (!slot)
        return BAD_ALLOC;
    *slot = resource;
    return 0;
}

static uint8_t apply_window_attributes(struct window *window, uint32_t attributes,
                                       const uint8_t *values, bool little_endian,
                                       struct cursor_resource cursors[MAX_CURSOR_RESOURCES],
                                       uint32_t *bad_value)
{
    const uint32_t supported = BACKGROUND_PIXMAP | BACKGROUND_PIXEL | BORDER_PIXEL |
        OVERRIDE_REDIRECT_ATTRIBUTE | EVENT_MASK_ATTRIBUTE | CURSOR_ATTRIBUTE |
        BIT_GRAVITY_ATTRIBUTE | COLORMAP_ATTRIBUTE;
    if (attributes & ~supported) {
        *bad_value = attributes;
        return BAD_VALUE;
    }

    struct window updated = *window;
    for (uint32_t bit = 1; attributes; bit <<= 1) {
        if (!(attributes & bit))
            continue;
        uint32_t value = get_field(values, 4, little_endian);
        values += 4;
        attributes &= ~bit;
        switch (bit) {
        case BACKGROUND_PIXMAP:
            // None and ParentRelative are supported. The root has no background pixmap.
            if (value > 1) {
                *bad_value = value;
                return BAD_PIXMAP;
            }
            updated.has_background = false;
            break;
        case BACKGROUND_PIXEL:
            updated.background = value & 0xFFFFFF;
            updated.has_background = true;
            break;
        case BORDER_PIXEL:
            updated.border = value & 0xFFFFFF;
            break;
        case BIT_GRAVITY_ATTRIBUTE:
            if (value > 10) {
                *bad_value = value;
                return BAD_VALUE;
            }
            updated.bit_gravity = value;
            break;
        case COLORMAP_ATTRIBUTE:
            if (value && value != ROOT_COLORMAP) {
                *bad_value = value;
                return BAD_COLORMAP;
            }
            break;
        case OVERRIDE_REDIRECT_ATTRIBUTE:
            if (value > 1) {
                *bad_value = value;
                return BAD_VALUE;
            }
            updated.override_redirect = value;
            break;
        case EVENT_MASK_ATTRIBUTE:
            if (value & ~ALL_EVENT_BITS) {
                *bad_value = value;
                return BAD_VALUE;
            }
            updated.events = value;
            break;
        case CURSOR_ATTRIBUTE:
            if (value) {
                struct cursor_resource *cursor = find_cursor_resource(cursors, value);
                if (!cursor || cursor->type != GLYPH_CURSOR) {
                    *bad_value = value;
                    return BAD_CURSOR;
                }
            }
            updated.cursor = value;
            break;
        }
    }
    *window = updated;
    return 0;
}

static int send_expose(int fd, uint16_t sequence, const struct window *window, bool little_endian)
{
    uint8_t event[32] = {EXPOSE_EVENT};
    put_field(event + 2, 2, sequence, little_endian);
    put_field(event + 4, 4, window->id, little_endian);
    put_field(event + 12, 2, window->width, little_endian);
    put_field(event + 14, 2, window->height, little_endian);
    return write_exact(fd, event, sizeof(event));
}

static int show_window_tree(int fd, const struct framebuffer *fb, struct window windows[MAX_WINDOWS],
                            struct window *window, uint16_t sequence, bool little_endian)
{
    struct window_area area;
    if (!window_view(windows, window, &area))
        return 0;
    if (area.left < area.right && area.top < area.bottom) {
        struct window visible = *window;
        visible.x = area.left;
        visible.y = area.top;
        visible.width = area.right - area.left;
        visible.height = area.bottom - area.top;
        if (paint_window(fb, &visible))
            return -1;
        if ((window->events & EXPOSURE_MASK) && send_expose(fd, sequence, window, little_endian))
            return -1;
    }
    for (size_t i = 0; i < MAX_WINDOWS; ++i)
        if (windows[i].id && windows[i].parent == window->id &&
            show_window_tree(fd, fb, windows, &windows[i], sequence, little_endian))
            return -1;
    return 0;
}

static int fill_window_area(const struct framebuffer *fb, const struct window_area *area,
                            int x, int y, int width, int height, uint32_t color)
{
    int left = area->x + x, top = area->y + y;
    int right = left + width, bottom = top + height;
    if (left < area->left) left = area->left;
    if (top < area->top) top = area->top;
    if (right > area->right) right = area->right;
    if (bottom > area->bottom) bottom = area->bottom;
    if (left >= right || top >= bottom)
        return 0;
    const struct window region = {
        .x = left, .y = top, .width = right - left, .height = bottom - top,
        .background = color, .has_background = true,
    };
    return paint_window(fb, &region);
}

static int fill_window_shapes(const struct framebuffer *fb, const struct window_area *area,
                              const struct graphics_context *gc, const uint8_t *data,
                              size_t length, bool arc, bool little_endian)
{
    size_t stride = arc ? 12 : 8;
    for (size_t i = 0; i < length; i += stride) {
        const uint8_t *shape = data + i;
        int x = (int16_t)get_field(shape, 2, little_endian);
        int y = (int16_t)get_field(shape + 2, 2, little_endian);
        int width = get_field(shape + 4, 2, little_endian);
        int height = get_field(shape + 6, 2, little_endian);
        if (!width || !height)
            continue;
        if (!arc) {
            if (fill_window_area(fb, area, x, y, width, height, gc->foreground))
                return -1;
            continue;
        }
        int angle = (int16_t)get_field(shape + 10, 2, little_endian);
        if (angle > -360 * 64 && angle < 360 * 64)
            return BAD_MATCH;
        int first = area->top - area->y - y;
        int last = area->bottom - area->y - y;
        if (first < 0) first = 0;
        if (last > height) last = height;
        for (int row = first; row < last; ++row) {
            double v = (2.0 * row + 1 - height) / height;
            int lo = 0, hi = (width + 1) / 2;
            while (lo < hi) {
                int mid = (lo + hi) / 2;
                double u = (2.0 * mid + 1 - width) / width;
                if (u * u + v * v <= 1)
                    hi = mid;
                else
                    lo = mid + 1;
            }
            if (fill_window_area(fb, area, x + lo, y + row, width - 2 * lo, 1, gc->foreground))
                return -1;
        }
    }
    return 0;
}

static int map_window(int fd, const struct framebuffer *fb, struct window windows[MAX_WINDOWS],
                      struct window *window, uint32_t root_events, uint16_t sequence, bool little_endian)
{
    if (window->mapped)
        return 0;
    window->mapped = true;
    const struct window *parent = window->parent == ROOT_WINDOW ? NULL : find_window(windows, window->parent);
    uint32_t parent_events = parent ? parent->events : root_events;
    if ((parent_events & SUBSTRUCTURE_NOTIFY) &&
        send_window_notice(fd, MAP_NOTIFY, sequence, window, little_endian))
        return -1;
    return show_window_tree(fd, fb, windows, window, sequence, little_endian);
}

static uint32_t keycode_symbol(unsigned keycode)
{
    static const uint32_t table[] = {
        [1] = 0xFF1B, [2] = '1', [3] = '2', [4] = '3', [5] = '4',
        [6] = '5', [7] = '6', [8] = '7', [9] = '8', [10] = '9', [11] = '0',
        [16] = 'q', [17] = 'w', [18] = 'e', [19] = 'r', [20] = 't', [21] = 'y',
        [22] = 'u', [23] = 'i', [24] = 'o', [25] = 'p', [28] = 0xFF0D,
        [29] = 0xFFE3, [30] = 'a', [31] = 's', [32] = 'd', [33] = 'f', [34] = 'g',
        [35] = 'h', [36] = 'j', [37] = 'k', [38] = 'l', [42] = 0xFFE1,
        [44] = 'z', [45] = 'x', [46] = 'c', [47] = 'v', [48] = 'b', [49] = 'n',
        [50] = 'm', [54] = 0xFFE2, [56] = 0xFFE9, [57] = ' ', [58] = 0xFFE5,
        [69] = 0xFF7F,
    };
    unsigned scan = keycode - 8;
    return scan < sizeof(table) / sizeof(*table) ? table[scan] : 0;
}

struct x11_client {
    int fd;
    bool little_endian;
    uint16_t sequence;
    uint32_t base, root_events;
};

static int start_x11_client(struct x11_client *client, const struct framebuffer *fb)
{
    int fd = client->fd;
    uint8_t prefix[12];
    if (read_exact(fd, prefix, sizeof(prefix)) != 1 ||
        (prefix[0] != 'l' && prefix[0] != 'B'))
        return -1;
    bool little_endian = prefix[0] == 'l';
    size_t auth_name = get_field(prefix + 6, 2, little_endian);
    size_t auth_data = get_field(prefix + 8, 2, little_endian);
    if (get_field(prefix + 2, 2, little_endian) != 11 ||
        get_field(prefix + 4, 2, little_endian) != 0 || auth_name || auth_data)
        return -1;
    client->little_endian = little_endian;
    return send_setup(fd, little_endian, fb, client->base);
}

static int wait_for_x11_input(const struct x11_client clients[2], int keyboard, int listener)
{
    struct pollfd descriptors[] = {
        {.fd = clients[0].fd, .events = POLLIN},
        {.fd = clients[1].fd, .events = POLLIN},
        {.fd = keyboard, .events = POLLIN},
        {.fd = listener, .events = POLLIN},
    };
    for (;;) {
        if (poll(descriptors, 4, -1) < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        if (descriptors[2].revents & POLLIN) {
            uint8_t event[2];
            if (read(keyboard, event, sizeof(event)) == sizeof(event) &&
                event[0] == 1 && event[1] == 0)
                return 2;
        }
        if (descriptors[3].revents & POLLIN)
            return 3;
        for (int i = 0; i < 2; ++i) {
            if (descriptors[i].revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL))
                return i;
        }
        if (descriptors[2].revents & (POLLERR | POLLHUP | POLLNVAL))
            return -1;
    }
}

static int serve_x11(int primary, const struct framebuffer *fb, int keyboard, int listener)
{
    struct x11_client clients[] = {
        {.fd = primary, .base = CLIENT_ID_BASE},
        {.fd = -1, .base = 2 * CLIENT_ID_BASE},
    };
    if (start_x11_client(&clients[0], fb))
        return -1;

    struct window windows[MAX_WINDOWS] = {0};
    struct graphics_context contexts[16] = {0};
    struct pixmap pixmaps[MAX_PIXMAPS] = {0};
    struct atom_table atoms = {0};
    struct property properties[MAX_PROPERTIES] = {0};
    struct cursor_resource cursors[MAX_CURSOR_RESOURCES] = {0};
    struct window root = {.id = ROOT_WINDOW, .width = fb->mode.xres, .height = fb->mode.yres};
    uint32_t focus = 1; // PointerRoot
    uint8_t revert_focus = 0;
    uint8_t request[MAX_REQUEST_WORDS * 4];
    int status;
    bool cleared_console = false;
    bool secondary_accepted = false;
    int result = -1;
    for (;;) {
        int slot = 0;
        if (keyboard >= 0) {
            slot = wait_for_x11_input(clients, keyboard,
                                     cleared_console && !secondary_accepted ? listener : -1);
            if (slot == 3) {
                clients[1].fd = accept(listener, NULL, NULL);
                if (clients[1].fd >= 0) {
                    secondary_accepted = true;
                    if (start_x11_client(&clients[1], fb)) {
                        close(clients[1].fd);
                        clients[1].fd = -1;
                    }
                }
                continue;
            }
            if (slot == 2 || slot < 0) {
                result = slot == 2 ? 1 : -1;
                break;
            }
        }
        struct x11_client *client = &clients[slot];
        int fd = client->fd;
        bool little_endian = client->little_endian;
        uint32_t base = client->base;
        status = read_exact(fd, request, 4);
        if (status != 1) {
            if (slot == 1) {
                close(fd);
                client->fd = -1;
                continue;
            }
            result = status;
            break;
        }
        uint16_t sequence = ++client->sequence;
        root.events = client->root_events;
        size_t words = get_field(request + 2, 2, little_endian);
        if (!words)
            goto cleanup;
        size_t bytes = words * 4;
        uint8_t opcode = request[0];
        uint8_t error = 0;
        uint32_t bad_value = 0;
        bool window_request = opcode == GET_GEOMETRY || opcode == MAP_WINDOW || opcode == MAP_SUBWINDOWS ||
                              opcode == QUERY_TREE || opcode == GET_WINDOW_ATTRIBUTES || opcode == QUERY_POINTER;
        bool gc_request = opcode == CREATE_GC || opcode == FREE_GC || opcode == CHANGE_GC;
        bool draw_request = opcode == POLY_FILL_RECTANGLE || opcode == POLY_FILL_ARC ||
                            opcode == COPY_AREA || opcode == GET_IMAGE || opcode == PUT_IMAGE;
        bool pixmap_request = opcode == CREATE_PIXMAP || opcode == FREE_PIXMAP;
        bool cursor_request = opcode == OPEN_FONT || opcode == CLOSE_FONT ||
                              opcode == CREATE_GLYPH_CURSOR || opcode == FREE_CURSOR;
        if (words > MAX_REQUEST_WORDS ||
            (opcode == OPEN_FONT && (bytes < 12 || bytes > sizeof(request))) ||
            ((opcode == CLOSE_FONT || opcode == FREE_CURSOR) && words != 2) ||
            (opcode == CREATE_GLYPH_CURSOR && words != 8) ||
            (opcode == INTERN_ATOM && (bytes < 8 || bytes > sizeof(request))) ||
            (opcode == GET_ATOM_NAME && words != 2) ||
            ((window_request || opcode == FREE_GC || opcode == FREE_PIXMAP) && words != 2) ||
            ((opcode == CREATE_PIXMAP || opcode == ALLOC_COLOR) && words != 4) ||
            (opcode == CREATE_GC && (bytes < 16 || bytes > 108)) ||
            (opcode == CHANGE_GC && (bytes < 12 || bytes > 104)) ||
            (opcode == POLY_FILL_RECTANGLE && (words < 3 || !(words & 1))) ||
            (opcode == COPY_AREA && words != 7) ||
            (opcode == CLEAR_AREA && words != 4) ||
            (opcode == POLY_FILL_ARC && (words < 3 || words % 3)) ||
            (opcode == GET_IMAGE && words != 5) ||
            (opcode == PUT_IMAGE && words < 6) ||
            (opcode == GET_PROPERTY && words != 6) ||
            (opcode == DELETE_PROPERTY && words != 3) ||
            (opcode == CHANGE_PROPERTY && (bytes < 24 || bytes > 24 + MAX_PROPERTY_BYTES)) ||
            ((opcode == CHANGE_WINDOW_ATTRIBUTES || opcode == CONFIGURE_WINDOW) &&
             (bytes < 12 || bytes > 72)) ||
            ((opcode == GET_INPUT_FOCUS || opcode == GET_MODIFIER_MAPPING) && words != 1) ||
            (opcode == GET_KEYBOARD_MAPPING && words != 2) ||
            ((opcode == SET_INPUT_FOCUS || opcode == UNGRAB_KEY) && words != 3) ||
            (opcode == GRAB_KEY && words != 4) ||
            (opcode == CREATE_WINDOW && (bytes < 32 || bytes > 92)) ||
            (opcode == QUERY_EXTENSION && words < 2) ||
            (opcode == LIST_EXTENSIONS && words != 1)) {
            if (discard_bytes(fd, bytes - 4))
                goto cleanup;
            error = BAD_LENGTH;
        } else if (opcode == QUERY_EXTENSION) {
            if (read_exact(fd, request + 4, 4) != 1 || discard_bytes(fd, bytes - 8))
                goto cleanup;
            size_t name_length = get_field(request + 4, 2, little_endian);
            if (bytes != 8 + ((name_length + 3) & ~(size_t)3))
                error = BAD_LENGTH;
        } else if (opcode == CREATE_WINDOW || window_request || gc_request || pixmap_request || cursor_request || draw_request ||
                   opcode == CLEAR_AREA || opcode == GET_PROPERTY || opcode == CHANGE_PROPERTY || opcode == DELETE_PROPERTY ||
                   opcode == CHANGE_WINDOW_ATTRIBUTES || opcode == CONFIGURE_WINDOW ||
                   opcode == INTERN_ATOM || opcode == GET_ATOM_NAME || opcode == ALLOC_COLOR ||
                   opcode == GET_KEYBOARD_MAPPING || opcode == SET_INPUT_FOCUS ||
                   opcode == GRAB_KEY || opcode == UNGRAB_KEY) {
            if (read_exact(fd, request + 4, bytes - 4) != 1)
                goto cleanup;
        } else {
            if (discard_bytes(fd, bytes - 4))
                goto cleanup;
            if (opcode == NO_OPERATION)
                continue;
            if (opcode != LIST_EXTENSIONS && opcode != GET_INPUT_FOCUS && opcode != GET_MODIFIER_MAPPING)
                error = BAD_REQUEST;
        }

        uint32_t atom = 0;
        bool atom_query = opcode == INTERN_ATOM || opcode == GET_ATOM_NAME;
        bool extension_query = opcode == QUERY_EXTENSION || opcode == LIST_EXTENSIONS;
        const struct window *geometry = NULL;
        struct window pixmap_geometry;
        uint8_t drawable_depth = ROOT_DEPTH;
        if (!error && (opcode == CREATE_WINDOW || opcode == CREATE_GC || opcode == CREATE_PIXMAP ||
                       opcode == OPEN_FONT || opcode == CREATE_GLYPH_CURSOR)) {
            uint32_t id = get_field(request + 4, 4, little_endian);
            bool font_or_cursor = opcode == OPEN_FONT || opcode == CREATE_GLYPH_CURSOR;
            if (id && ((!font_or_cursor && find_cursor_resource(cursors, id)) ||
                       (font_or_cursor && (find_window(windows, id) || find_context(contexts, id) ||
                                          find_pixmap(pixmaps, id))))) {
                error = BAD_ID_CHOICE;
                bad_value = id;
            }
        }
        if (!error && opcode == CREATE_WINDOW) {
            uint32_t id = get_field(request + 4, 4, little_endian);
            if (id && (find_context(contexts, id) || find_pixmap(pixmaps, id))) {
                error = BAD_ID_CHOICE;
                bad_value = id;
            }
            struct window *slot = find_window(windows, 0);
            struct window candidate = {0};
            if (!error && id && find_window(windows, id)) {
                error = BAD_ID_CHOICE;
                bad_value = id;
            }
            if (!error && !slot)
                error = BAD_ALLOC;
            if (!error)
                error = create_window(&candidate, windows, request, bytes, little_endian, base, &bad_value);
            if (!error)
                error = apply_window_attributes(&candidate, get_field(request + 28, 4, little_endian),
                                                request + 32, little_endian, cursors, &bad_value);
            if (!error) {
                *slot = candidate;
                const struct window *parent = candidate.parent == ROOT_WINDOW
                    ? &root : find_window(windows, candidate.parent);
                if ((parent->events & SUBSTRUCTURE_NOTIFY) &&
                    send_window_notice(fd, CREATE_NOTIFY, sequence, slot, little_endian))
                    goto cleanup;
            }
        } else if (!error && (opcode == CHANGE_WINDOW_ATTRIBUTES || opcode == CONFIGURE_WINDOW)) {
            uint32_t id = get_field(request + 4, 4, little_endian);
            struct window *target = id == ROOT_WINDOW ? &root : id ? find_window(windows, id) : NULL;
            uint32_t mask = get_field(request + 8, opcode == CONFIGURE_WINDOW ? 2 : 4, little_endian);
            if (!target) {
                error = BAD_WINDOW;
                bad_value = id;
            } else if (bytes != 12 + (size_t)__builtin_popcount(mask) * 4) {
                error = BAD_LENGTH;
            } else if (opcode == CHANGE_WINDOW_ATTRIBUTES) {
                error = apply_window_attributes(target, mask, request + 12, little_endian, cursors, &bad_value);
                if (!error && target == &root)
                    client->root_events = root.events;
            } else if (mask && (mask != (1 << 6) || get_field(request + 12, 4, little_endian) > 4)) {
                // The sole child already occupies the top of the stacking order.
                error = BAD_VALUE;
                bad_value = mask;
            }
        } else if (!error && opcode == GET_KEYBOARD_MAPPING) {
            if (request[4] < 8 || !request[5] || (unsigned)request[4] + request[5] > 256) {
                error = BAD_VALUE;
                bad_value = request[4];
            }
        } else if (!error && opcode == SET_INPUT_FOCUS) {
            uint32_t id = get_field(request + 4, 4, little_endian);
            struct window *child = id > 1 && id != ROOT_WINDOW ? find_window(windows, id) : NULL;
            if (request[1] > 2) {
                error = BAD_VALUE;
                bad_value = request[1];
            } else if (id > 1 && id != ROOT_WINDOW && !child) {
                error = BAD_WINDOW;
                bad_value = id;
            } else if (child && !child->mapped) {
                error = BAD_MATCH;
            } else {
                focus = id;
                revert_focus = request[1];
            }
        } else if (!error && (opcode == GRAB_KEY || opcode == UNGRAB_KEY)) {
            uint32_t id = get_field(request + 4, 4, little_endian);
            if (id != ROOT_WINDOW && (!id || !find_window(windows, id))) {
                error = BAD_WINDOW;
                bad_value = id;
            } else if (opcode == GRAB_KEY) {
                // Passive key grabs require keyboard event delivery.
                error = BAD_ACCESS;
            }
        } else if (!error && cursor_request) {
            error = handle_cursor_resource(cursors, opcode, request, bytes, little_endian, base, &bad_value);
        } else if (!error && gc_request) {
            error = handle_gc(contexts, windows, pixmaps, request, bytes, little_endian, base, &bad_value);
        } else if (!error && opcode == CLEAR_AREA) {
            uint32_t id = get_field(request + 4, 4, little_endian);
            const struct window *window = id == ROOT_WINDOW ? &root : id ? find_window(windows, id) : NULL;
            struct window_area area;
            if (!window) {
                error = BAD_WINDOW;
                bad_value = id;
            } else if (request[1] > 1) {
                error = BAD_VALUE;
                bad_value = request[1];
            } else if (window != &root && window_view(windows, window, &area)) {
                int x = (int16_t)get_field(request + 8, 2, little_endian);
                int y = (int16_t)get_field(request + 10, 2, little_endian);
                int width = get_field(request + 12, 2, little_endian);
                int height = get_field(request + 14, 2, little_endian);
                if (!width) width = window->width - x;
                if (!height) height = window->height - y;
                if (window->has_background && fill_window_area(fb, &area, x, y, width, height, window->background))
                    goto cleanup;
                if (request[1] && (window->events & EXPOSURE_MASK) && send_expose(fd, sequence, window, little_endian))
                    goto cleanup;
            }
        } else if (!error && draw_request) {
            uint32_t source = get_field(request + 4, 4, little_endian);
            uint32_t gc_id = get_field(request + (opcode == COPY_AREA ? 12 : 8), 4, little_endian);
            struct pixmap *pixmap = source ? find_pixmap(pixmaps, source) : NULL;
            struct graphics_context *gc = gc_id ? find_context(contexts, gc_id) : NULL;
            struct window *draw_window = (opcode == POLY_FILL_RECTANGLE || opcode == POLY_FILL_ARC) && source
                ? find_window(windows, source) : NULL;
            if (draw_window && gc) {
                struct window_area area;
                if (gc->depth != ROOT_DEPTH || (gc->planes & 0xFFFFFF) != 0xFFFFFF) {
                    error = BAD_MATCH;
                } else if (window_view(windows, draw_window, &area)) {
                    int draw_result = fill_window_shapes(fb, &area, gc, request + 12, bytes - 12,
                                                         opcode == POLY_FILL_ARC, little_endian);
                    if (draw_result < 0)
                        goto cleanup;
                    error = draw_result;
                }
            } else if (draw_window) {
                error = BAD_GC;
                bad_value = gc_id;
            } else if (!pixmap) {
                error = BAD_DRAWABLE;
                bad_value = source;
            } else if (opcode == GET_IMAGE) {
                int result = send_pixmap_image(fd, pixmap, request, sequence, little_endian);
                if (result < 0)
                    goto cleanup;
                error = result;
            } else if (!gc) {
                error = BAD_GC;
                bad_value = gc_id;
            } else if (pixmap->depth != gc->depth) {
                error = BAD_MATCH;
            } else if (opcode == POLY_FILL_RECTANGLE) {
                error = fill_pixmap(pixmap, gc, request + 12, bytes - 12, little_endian);
            } else if (opcode == POLY_FILL_ARC) {
                error = BAD_MATCH;
            } else if (opcode == PUT_IMAGE) {
                error = put_image(pixmap, gc, request, bytes, little_endian);
            } else {
                uint32_t destination = get_field(request + 8, 4, little_endian);
                struct pixmap *target = destination ? find_pixmap(pixmaps, destination) : NULL;
                struct window *destination_window = destination ? find_window(windows, destination) : NULL;
                if (target) {
                    error = copy_pixmap(target, pixmap, gc, request, little_endian);
                } else if (!destination_window) {
                    error = BAD_DRAWABLE;
                    bad_value = destination;
                } else if (pixmap->depth != ROOT_DEPTH || (gc->planes & 0xFFFFFF) != 0xFFFFFF) {
                    error = BAD_MATCH;
                } else {
                    if (keyboard >= 0 && !cleared_console && destination_window->mapped) {
                        const struct window clear = {
                            .width = fb->mode.xres, .height = fb->mode.yres, .has_background = true,
                        };
                        if (paint_window(fb, &clear))
                            goto cleanup;
                        cleared_console = true;
                    }
                    if (copy_pixmap_to_window(fb, pixmap, windows, destination_window, request, little_endian))
                        goto cleanup;
                }
                if (!error && gc->graphics_exposures) {
                    uint8_t event[32] = {NO_EXPOSURE};
                    put_field(event + 2, 2, sequence, little_endian);
                    put_field(event + 4, 4, destination, little_endian);
                    event[10] = COPY_AREA;
                    if (write_exact(fd, event, sizeof(event)))
                        goto cleanup;
                }
            }
        } else if (!error && pixmap_request) {
            error = handle_pixmap(pixmaps, windows, contexts, request, little_endian, base, &bad_value);
        } else if (!error && opcode == INTERN_ATOM) {
            size_t length = get_field(request + 4, 2, little_endian);
            if (bytes != 8 + ((length + 3) & ~(size_t)3)) {
                error = BAD_LENGTH;
            } else if (request[1] > 1) {
                error = BAD_VALUE;
                bad_value = request[1];
            } else if (length > MAX_ATOM_NAME) {
                error = BAD_ALLOC;
            } else {
                atom = intern_atom(&atoms, request + 8, length, request[1]);
                if (!atom && !request[1])
                    error = BAD_ALLOC;
            }
        } else if (!error && opcode == GET_ATOM_NAME) {
            atom = get_field(request + 4, 4, little_endian);
            if (!atom_valid(&atoms, atom)) {
                error = BAD_ATOM;
                bad_value = atom;
            }
        } else if (!error && opcode == ALLOC_COLOR) {
            uint32_t colormap = get_field(request + 4, 4, little_endian);
            if (colormap != ROOT_COLORMAP) {
                error = BAD_COLORMAP;
                bad_value = colormap;
            }
        } else if (!error && (opcode == GET_PROPERTY || opcode == CHANGE_PROPERTY || opcode == DELETE_PROPERTY)) {
            uint32_t id = get_field(request + 4, 4, little_endian);
            uint32_t property_atom = get_field(request + 8, 4, little_endian);
            if (id != ROOT_WINDOW && (!id || !find_window(windows, id))) {
                error = BAD_WINDOW;
                bad_value = id;
            } else if (opcode == CHANGE_PROPERTY) {
                error = change_property(properties, &atoms, request, bytes, little_endian, &bad_value);
            } else if (opcode == DELETE_PROPERTY) {
                if (!atom_valid(&atoms, property_atom)) {
                    error = BAD_ATOM;
                    bad_value = property_atom;
                } else {
                    struct property *property = find_property(properties, id, property_atom);
                    if (property)
                        *property = (struct property){0};
                }
            } else {
                error = check_get_property(&atoms, request, little_endian, &bad_value);
                struct property *property = find_property(properties, id, property_atom);
                uint32_t type = get_field(request + 12, 4, little_endian);
                if (!error && property && (!type || type == property->type) &&
                    (uint64_t)get_field(request + 16, 4, little_endian) * 4 > property->length) {
                    error = BAD_VALUE;
                    bad_value = get_field(request + 16, 4, little_endian);
                }
            }
        } else if (!error && window_request) {
            uint32_t id = get_field(request + 4, 4, little_endian);
            struct window *child = id ? find_window(windows, id) : NULL;
            if (opcode == MAP_WINDOW || opcode == MAP_SUBWINDOWS) {
                if (!child && id != ROOT_WINDOW) {
                    error = BAD_WINDOW;
                    bad_value = id;
                } else if (opcode == MAP_WINDOW) {
                    if (child && map_window(fd, fb, windows, child, root.events, sequence, little_endian))
                        goto cleanup;
                } else {
                    for (size_t i = 0; i < MAX_WINDOWS; ++i)
                        if (windows[i].id && windows[i].parent == id &&
                            map_window(fd, fb, windows, &windows[i], root.events, sequence, little_endian))
                            goto cleanup;
                }
            } else if (id == ROOT_WINDOW) {
                geometry = &root;
            } else if (child) {
                geometry = child;
            } else {
                struct pixmap *pixmap = opcode == GET_GEOMETRY && id ? find_pixmap(pixmaps, id) : NULL;
                if (pixmap) {
                    pixmap_geometry = (struct window){.width = pixmap->width, .height = pixmap->height};
                    geometry = &pixmap_geometry;
                    drawable_depth = pixmap->depth;
                } else {
                    error = opcode == GET_GEOMETRY ? BAD_DRAWABLE : BAD_WINDOW;
                    bad_value = id;
                }
            }
        }
        if (!error && !geometry && !extension_query && !atom_query &&
            opcode != GET_PROPERTY && opcode != GET_INPUT_FOCUS && opcode != ALLOC_COLOR &&
            opcode != GET_KEYBOARD_MAPPING && opcode != GET_MODIFIER_MAPPING)
            continue;

        uint8_t reply[32 + 248 * 4] = {0};
        size_t reply_size = 32;
        put_field(reply + 2, 2, sequence, little_endian);
        if (error) {
            reply[1] = error;
            put_field(reply + 4, 4, bad_value, little_endian);
            reply[10] = opcode;
        } else if (extension_query) {
            reply[0] = 1;
        } else if (opcode == GET_PROPERTY) {
            reply[0] = 1;
            struct property *property = find_property(properties, get_field(request + 4, 4, little_endian),
                                                     get_field(request + 8, 4, little_endian));
            if (property) {
                uint32_t requested_type = get_field(request + 12, 4, little_endian);
                reply[1] = property->format;
                put_field(reply + 8, 4, property->type, little_endian);
                if (requested_type && requested_type != property->type) {
                    put_field(reply + 12, 4, property->length, little_endian);
                } else {
                    size_t offset = get_field(request + 16, 4, little_endian) * (uint64_t)4;
                    uint64_t limit = get_field(request + 20, 4, little_endian) * (uint64_t)4;
                    size_t length = property->length - offset;
                    if (length > limit)
                        length = limit;
                    size_t after = property->length - offset - length;
                    size_t padded = (length + 3) & ~(size_t)3;
                    put_field(reply + 4, 4, padded / 4, little_endian);
                    put_field(reply + 12, 4, after, little_endian);
                    put_field(reply + 16, 4, length / (property->format / 8), little_endian);
                    memcpy(reply + 32, property->data + offset, length);
                    reply_size += padded;
                    if (request[1] && !after)
                        *property = (struct property){0};
                }
            }
        } else if (opcode == INTERN_ATOM) {
            reply[0] = 1;
            put_field(reply + 8, 4, atom, little_endian);
        } else if (opcode == GET_ATOM_NAME) {
            size_t length;
            const void *name = atom_name(&atoms, atom, &length);
            size_t padded = (length + 3) & ~(size_t)3;
            reply[0] = 1;
            put_field(reply + 4, 4, padded / 4, little_endian);
            put_field(reply + 8, 2, length, little_endian);
            memcpy(reply + 32, name, length);
            reply_size += padded;
        } else if (opcode == ALLOC_COLOR) {
            uint32_t pixel = 0;
            reply[0] = 1;
            // Quantize the requested intensities to the root visual's 8-bit channels.
            for (size_t channel = 0; channel < 3; ++channel) {
                uint32_t intensity = get_field(request + 8 + channel * 2, 2, little_endian) >> 8;
                put_field(reply + 8 + channel * 2, 2, intensity * 257, little_endian);
                pixel = (pixel << 8) | intensity;
            }
            put_field(reply + 16, 4, pixel, little_endian);
        } else if (opcode == QUERY_POINTER) {
            // The guest has no pointer input yet. Start with a stationary pointer at the root origin.
            reply[0] = 1;
            reply[1] = 1; // Same screen
            put_field(reply + 8, 4, ROOT_WINDOW, little_endian);
            int x = 0, y = 0;
            const struct window *ancestor = geometry;
            while (ancestor && ancestor != &root) {
                x += ancestor->x;
                y += ancestor->y;
                ancestor = find_window(windows, ancestor->parent);
            }
            for (size_t i = MAX_WINDOWS; i > 0; --i) {
                const struct window *child = &windows[i - 1];
                struct window_area area;
                if (child->id && child->parent == geometry->id &&
                    window_view(windows, child, &area) && area.left <= 0 && area.top <= 0 &&
                    area.right > 0 && area.bottom > 0) {
                    put_field(reply + 12, 4, child->id, little_endian);
                    break;
                }
            }
            put_field(reply + 20, 2, (uint16_t)-x, little_endian);
            put_field(reply + 22, 2, (uint16_t)-y, little_endian);
        } else if (opcode == GET_INPUT_FOCUS) {
            reply[0] = 1;
            reply[1] = revert_focus;
            put_field(reply + 8, 4, focus, little_endian);
        } else if (opcode == GET_KEYBOARD_MAPPING) {
            reply[0] = 1;
            reply[1] = 1; // One keysym per keycode
            put_field(reply + 4, 4, request[5], little_endian);
            for (unsigned i = 0; i < request[5]; ++i)
                put_field(reply + 32 + i * 4, 4, keycode_symbol(request[4] + i), little_endian);
            reply_size += (size_t)request[5] * 4;
        } else if (opcode == GET_MODIFIER_MAPPING) {
            const uint8_t modifiers[16] = {50, 62, 66, 0, 37, 0, 64, 0, 77, 0};
            reply[0] = 1;
            reply[1] = 2;
            put_field(reply + 4, 4, sizeof(modifiers) / 4, little_endian);
            memcpy(reply + 32, modifiers, sizeof(modifiers));
            reply_size += sizeof(modifiers);
        } else if (opcode == GET_WINDOW_ATTRIBUTES) {
            uint32_t events = geometry->events;
            reply[0] = 1;
            put_field(reply + 4, 4, 3, little_endian);
            put_field(reply + 8, 4, ROOT_VISUAL, little_endian);
            put_field(reply + 12, 2, 1, little_endian); // InputOutput
            reply[14] = geometry->bit_gravity;
            reply[15] = 1; // NorthWest window gravity
            put_field(reply + 16, 4, UINT32_MAX, little_endian);
            reply[25] = 1; // Colormap installed
            struct window_area area;
            reply[26] = geometry == &root || window_view(windows, geometry, &area)
                ? 2 : geometry->mapped ? 1 : 0;
            reply[27] = geometry->override_redirect;
            put_field(reply + 28, 4, ROOT_COLORMAP, little_endian);
            put_field(reply + 32, 4, events, little_endian);
            put_field(reply + 36, 4, events, little_endian);
            reply_size = 44;
        } else if (opcode == QUERY_TREE) {
            reply[0] = 1;
            put_field(reply + 8, 4, ROOT_WINDOW, little_endian);
            put_field(reply + 12, 4, geometry->parent, little_endian);
            size_t count = 0;
            for (size_t i = 0; i < MAX_WINDOWS; ++i) {
                if (windows[i].id && windows[i].parent == geometry->id)
                    put_field(reply + 32 + count++ * 4, 4, windows[i].id, little_endian);
            }
            put_field(reply + 4, 4, count, little_endian);
            put_field(reply + 16, 2, count, little_endian);
            reply_size += count * 4;
        } else {
            reply[0] = 1;
            reply[1] = drawable_depth;
            put_field(reply + 8, 4, ROOT_WINDOW, little_endian);
            put_field(reply + 12, 2, (uint16_t)geometry->x, little_endian);
            put_field(reply + 14, 2, (uint16_t)geometry->y, little_endian);
            put_field(reply + 16, 2, geometry->width, little_endian);
            put_field(reply + 18, 2, geometry->height, little_endian);
        }
        if (write_exact(fd, reply, reply_size))
            goto cleanup;
    }
cleanup:
    if (clients[1].fd >= 0)
        close(clients[1].fd);
    for (size_t i = 0; i < MAX_PIXMAPS; ++i)
        free(pixmaps[i].pixels);
    return result;
}

static int probe_x11(int fd, bool little_endian, const struct framebuffer *fb)
{
    uint8_t prefix[12] = {little_endian ? 'l' : 'B'};
    put_field(prefix + 2, 2, 11, little_endian);
    if (write_exact(fd, prefix, sizeof(prefix)) ||
        read_exact(fd, prefix, 8) != 1 || prefix[0] != 1 ||
        get_field(prefix + 2, 2, little_endian) != 11 ||
        get_field(prefix + 4, 2, little_endian) != 0)
        return -1;

    uint8_t setup[256];
    size_t size = get_field(prefix + 6, 2, little_endian) * 4;
    if (size < 32 || size > sizeof(setup) || read_exact(fd, setup, size) != 1 ||
        setup[20] != 1 || setup[21] != 2)
        return -1;
    size_t vendor_size = get_field(setup + 16, 2, little_endian);
    size_t screen_offset = 32 + ((vendor_size + 3) & ~(size_t)3) + setup[21] * 8;
    if (screen_offset + 40 > size)
        return -1;
    const uint8_t *screen = setup + screen_offset;
    uint32_t root = get_field(screen, 4, little_endian);
    if (!root || get_field(screen + 20, 2, little_endian) != fb->mode.xres ||
        get_field(screen + 22, 2, little_endian) != fb->mode.yres || screen[38] != 24)
        return -1;

    // A padded NoOperation, an invalid drawable query, then the root query.
    uint8_t requests[24] = {127};
    put_field(requests + 2, 2, 2, little_endian);
    requests[8] = 14;
    put_field(requests + 10, 2, 2, little_endian);
    requests[16] = 14;
    put_field(requests + 18, 2, 2, little_endian);
    put_field(requests + 20, 4, root, little_endian);
    uint8_t reply[32];
    if (write_exact(fd, requests, sizeof(requests)) ||
        read_exact(fd, reply, sizeof(reply)) != 1 || reply[0] != 0 ||
        reply[1] != 9 || get_field(reply + 2, 2, little_endian) != 2 ||
        reply[10] != 14)
        return -1;
    if (read_exact(fd, reply, sizeof(reply)) != 1 || reply[0] != 1 ||
        reply[1] != 24 || get_field(reply + 2, 2, little_endian) != 3 ||
        get_field(reply + 4, 4, little_endian) ||
        get_field(reply + 8, 4, little_endian) != root ||
        get_field(reply + 16, 2, little_endian) != fb->mode.xres ||
        get_field(reply + 18, 2, little_endian) != fb->mode.yres)
        return -1;
    uint32_t event_mask = SUBSTRUCTURE_NOTIFY | SUBSTRUCTURE_REDIRECT;
    uint8_t select[16] = {CHANGE_WINDOW_ATTRIBUTES};
    put_field(select + 2, 2, sizeof(select) / 4, little_endian);
    put_field(select + 4, 4, root, little_endian);
    put_field(select + 8, 4, EVENT_MASK_ATTRIBUTE, little_endian);
    put_field(select + 12, 4, event_mask, little_endian);
    uint8_t focus[4] = {GET_INPUT_FOCUS};
    put_field(focus + 2, 2, 1, little_endian);
    if (write_exact(fd, select, sizeof(select)) || write_exact(fd, focus, sizeof(focus)) ||
        read_exact(fd, reply, sizeof(reply)) != 1 || reply[0] != 1 ||
        get_field(reply + 2, 2, little_endian) != 5 ||
        get_field(reply + 8, 4, little_endian) != 1)
        return -1;

    uint32_t id = get_field(setup + 4, 4, little_endian) | 1;
    uint8_t create[48] = {1};
    put_field(create + 2, 2, sizeof(create) / 4, little_endian);
    put_field(create + 4, 4, id, little_endian);
    put_field(create + 8, 4, root, little_endian);
    put_field(create + 12, 2, WINDOW_X, little_endian);
    put_field(create + 14, 2, WINDOW_Y, little_endian);
    put_field(create + 16, 2, WINDOW_WIDTH, little_endian);
    put_field(create + 18, 2, WINDOW_HEIGHT, little_endian);
    put_field(create + 22, 2, 1, little_endian); // InputOutput
    put_field(create + 28, 4, BACKGROUND_PIXMAP | BACKGROUND_PIXEL |
              OVERRIDE_REDIRECT_ATTRIBUTE | EVENT_MASK_ATTRIBUTE, little_endian);
    put_field(create + 32, 4, 1, little_endian); // ParentRelative
    put_field(create + 36, 4, 0x31485D, little_endian);
    put_field(create + 40, 4, 1, little_endian);
    put_field(create + 44, 4, EXPOSURE_MASK, little_endian);
    uint8_t map[8] = {8};
    put_field(map + 2, 2, sizeof(map) / 4, little_endian);
    put_field(map + 4, 4, id, little_endian);
    uint8_t query[8] = {14};
    put_field(query + 2, 2, sizeof(query) / 4, little_endian);
    put_field(query + 4, 4, id, little_endian);
    if (write_exact(fd, create, sizeof(create)) || write_exact(fd, map, sizeof(map)) ||
        write_exact(fd, query, sizeof(query)))
        return -1;
    for (uint8_t type = CREATE_NOTIFY; type <= MAP_NOTIFY; type += MAP_NOTIFY - CREATE_NOTIFY) {
        if (read_exact(fd, reply, sizeof(reply)) != 1 || reply[0] != type ||
            get_field(reply + 8, 4, little_endian) != id)
            return -1;
    }
    if (read_exact(fd, reply, sizeof(reply)) != 1 || reply[0] != EXPOSE_EVENT ||
        get_field(reply + 2, 2, little_endian) != 7 ||
        get_field(reply + 4, 4, little_endian) != id ||
        get_field(reply + 12, 2, little_endian) != WINDOW_WIDTH ||
        get_field(reply + 14, 2, little_endian) != WINDOW_HEIGHT)
        return -1;
    if (read_exact(fd, reply, sizeof(reply)) != 1 ||
        reply[0] != 1 || get_field(reply + 2, 2, little_endian) != 8 ||
        get_field(reply + 8, 4, little_endian) != root ||
        get_field(reply + 12, 2, little_endian) != WINDOW_X ||
        get_field(reply + 14, 2, little_endian) != WINDOW_Y ||
        get_field(reply + 16, 2, little_endian) != WINDOW_WIDTH ||
        get_field(reply + 18, 2, little_endian) != WINDOW_HEIGHT)
        return -1;
    uint8_t tree[8] = {QUERY_TREE};
    put_field(tree + 2, 2, 2, little_endian);
    put_field(tree + 4, 4, root, little_endian);
    uint8_t child[4];
    if (write_exact(fd, tree, sizeof(tree)) || read_exact(fd, reply, sizeof(reply)) != 1 ||
        reply[0] != 1 || get_field(reply + 2, 2, little_endian) != 9 ||
        get_field(reply + 4, 4, little_endian) != 1 ||
        get_field(reply + 8, 4, little_endian) != root ||
        get_field(reply + 12, 4, little_endian) ||
        get_field(reply + 16, 2, little_endian) != 1 ||
        read_exact(fd, child, sizeof(child)) != 1 || get_field(child, 4, little_endian) != id)
        return -1;

    uint8_t extension[16] = {QUERY_EXTENSION};
    put_field(extension + 2, 2, 4, little_endian);
    put_field(extension + 4, 2, 6, little_endian);
    memcpy(extension + 8, "RENDER", 6);
    if (write_exact(fd, extension, sizeof(extension)) ||
        read_exact(fd, reply, sizeof(reply)) != 1 || reply[0] != 1 ||
        get_field(reply + 2, 2, little_endian) != 10 || reply[8])
        return -1;
    uint32_t gc = id + 1;
    uint8_t create_gc[20] = {CREATE_GC};
    put_field(create_gc + 2, 2, 5, little_endian);
    put_field(create_gc + 4, 4, gc, little_endian);
    put_field(create_gc + 8, 4, root, little_endian);
    put_field(create_gc + 12, 4, 1U << 3, little_endian);
    put_field(create_gc + 16, 4, 0xFFFFFF, little_endian);
    uint8_t free_gc[8] = {FREE_GC};
    put_field(free_gc + 2, 2, 2, little_endian);
    put_field(free_gc + 4, 4, gc, little_endian);
    if (write_exact(fd, create_gc, sizeof(create_gc)) ||
        write_exact(fd, free_gc, sizeof(free_gc)) ||
        write_exact(fd, free_gc, sizeof(free_gc)) ||
        read_exact(fd, reply, sizeof(reply)) != 1 || reply[0] != 0 || reply[1] != BAD_GC ||
        get_field(reply + 2, 2, little_endian) != 13 ||
        get_field(reply + 4, 4, little_endian) != gc)
        return -1;

    uint8_t property[24] = {GET_PROPERTY};
    put_field(property + 2, 2, 6, little_endian);
    put_field(property + 4, 4, root, little_endian);
    put_field(property + 8, 4, 23, little_endian); // RESOURCE_MANAGER
    put_field(property + 20, 4, 64, little_endian);
    if (write_exact(fd, property, sizeof(property)) ||
        read_exact(fd, reply, sizeof(reply)) != 1 || reply[0] != 1 || reply[1] ||
        get_field(reply + 2, 2, little_endian) != 14 ||
        get_field(reply + 4, 4, little_endian) || get_field(reply + 8, 4, little_endian))
        return -1;
    uint8_t attributes[8] = {GET_WINDOW_ATTRIBUTES};
    put_field(attributes + 2, 2, 2, little_endian);
    put_field(attributes + 4, 4, root, little_endian);
    uint8_t attrs_reply[44];
    if (write_exact(fd, attributes, sizeof(attributes)) ||
        read_exact(fd, attrs_reply, sizeof(attrs_reply)) != 1 || attrs_reply[0] != 1 ||
        get_field(attrs_reply + 2, 2, little_endian) != 15 ||
        get_field(attrs_reply + 4, 4, little_endian) != 3 || attrs_reply[26] != 2 ||
        get_field(attrs_reply + 32, 4, little_endian) != event_mask ||
        get_field(attrs_reply + 36, 4, little_endian) != event_mask)
        return -1;
    uint8_t pointer[8] = {QUERY_POINTER};
    put_field(pointer + 2, 2, 2, little_endian);
    put_field(pointer + 4, 4, id, little_endian);
    if (write_exact(fd, pointer, sizeof(pointer)) || read_exact(fd, reply, sizeof(reply)) != 1 ||
        reply[0] != 1 || reply[1] != 1 || get_field(reply + 2, 2, little_endian) != 16 ||
        get_field(reply + 8, 4, little_endian) != root ||
        get_field(reply + 12, 4, little_endian) || get_field(reply + 16, 4, little_endian) ||
        get_field(reply + 20, 2, little_endian) != (uint16_t)-WINDOW_X ||
        get_field(reply + 22, 2, little_endian) != (uint16_t)-WINDOW_Y)
        return -1;

    uint8_t pixmap[16] = {CREATE_PIXMAP, 1};
    put_field(pixmap + 2, 2, 4, little_endian);
    put_field(pixmap + 4, 4, gc, little_endian); // Reuse the released graphics-context ID.
    put_field(pixmap + 8, 4, root, little_endian);
    put_field(pixmap + 12, 2, 13, little_endian);
    put_field(pixmap + 14, 2, 7, little_endian);
    put_field(query + 4, 4, gc, little_endian);
    if (write_exact(fd, pixmap, sizeof(pixmap)) || write_exact(fd, query, sizeof(query)) ||
        read_exact(fd, reply, sizeof(reply)) != 1 || reply[0] != 1 || reply[1] != 1 ||
        get_field(reply + 2, 2, little_endian) != 18 ||
        get_field(reply + 8, 4, little_endian) != root ||
        get_field(reply + 16, 2, little_endian) != 13 || get_field(reply + 18, 2, little_endian) != 7)
        return -1;
    uint8_t free_pixmap[8] = {FREE_PIXMAP};
    put_field(free_pixmap + 2, 2, 2, little_endian);
    put_field(free_pixmap + 4, 4, gc, little_endian);
    if (write_exact(fd, free_pixmap, sizeof(free_pixmap)) || write_exact(fd, query, sizeof(query)) ||
        read_exact(fd, reply, sizeof(reply)) != 1 || reply[0] || reply[1] != BAD_DRAWABLE ||
        get_field(reply + 2, 2, little_endian) != 20 ||
        get_field(reply + 4, 4, little_endian) != gc)
        return -1;
    uint8_t intern[20] = {INTERN_ATOM, 1};
    put_field(intern + 2, 2, 5, little_endian);
    put_field(intern + 4, 2, 12, little_endian);
    memcpy(intern + 8, "WM_PROTOCOLS", 12);
    for (uint16_t sequence = 21; sequence <= 23; ++sequence) {
        if (sequence == 22)
            intern[1] = 0;
        else
            intern[1] = 1;
        if (write_exact(fd, intern, sizeof(intern)) ||
            read_exact(fd, reply, sizeof(reply)) != 1 || reply[0] != 1 ||
            get_field(reply + 2, 2, little_endian) != sequence ||
            get_field(reply + 8, 4, little_endian) != (sequence == 21 ? 0 : 69))
            return -1;
    }
    uint8_t atom_query[8] = {GET_ATOM_NAME};
    put_field(atom_query + 2, 2, 2, little_endian);
    put_field(atom_query + 4, 4, 69, little_endian);
    uint8_t name[12];
    if (write_exact(fd, atom_query, sizeof(atom_query)) ||
        read_exact(fd, reply, sizeof(reply)) != 1 || reply[0] != 1 ||
        get_field(reply + 2, 2, little_endian) != 24 ||
        get_field(reply + 4, 4, little_endian) != 3 ||
        get_field(reply + 8, 2, little_endian) != sizeof(name) ||
        read_exact(fd, name, sizeof(name)) != 1 || memcmp(name, "WM_PROTOCOLS", sizeof(name)))
        return -1;
    uint8_t open_font[20] = {OPEN_FONT};
    put_field(open_font + 2, 2, 5, little_endian);
    put_field(open_font + 4, 4, gc, little_endian);
    put_field(open_font + 8, 2, 6, little_endian);
    memcpy(open_font + 12, "cursor", 6);
    uint32_t cursor_id = gc + 1;
    uint8_t cursor[32] = {CREATE_GLYPH_CURSOR};
    put_field(cursor + 2, 2, 8, little_endian);
    put_field(cursor + 4, 4, cursor_id, little_endian);
    put_field(cursor + 8, 4, gc, little_endian);
    put_field(cursor + 12, 4, gc, little_endian);
    put_field(cursor + 16, 2, 68, little_endian); // left_ptr
    put_field(cursor + 18, 2, 69, little_endian);
    uint8_t close_font[8] = {CLOSE_FONT};
    put_field(close_font + 2, 2, 2, little_endian);
    put_field(close_font + 4, 4, gc, little_endian);
    uint8_t free_cursor[8] = {FREE_CURSOR};
    put_field(free_cursor + 2, 2, 2, little_endian);
    put_field(free_cursor + 4, 4, cursor_id, little_endian);
    if (write_exact(fd, open_font, sizeof(open_font)) || write_exact(fd, cursor, sizeof(cursor)) ||
        write_exact(fd, close_font, sizeof(close_font)) || write_exact(fd, free_cursor, sizeof(free_cursor)) ||
        write_exact(fd, free_cursor, sizeof(free_cursor)) ||
        read_exact(fd, reply, sizeof(reply)) != 1 || reply[0] || reply[1] != BAD_CURSOR ||
        get_field(reply + 2, 2, little_endian) != 29 ||
        get_field(reply + 4, 4, little_endian) != cursor_id)
        return -1;
    uint8_t color[16] = {ALLOC_COLOR};
    put_field(color + 2, 2, 4, little_endian);
    put_field(color + 4, 4, get_field(screen + 4, 4, little_endian), little_endian);
    put_field(color + 8, 2, 0x1234, little_endian);
    put_field(color + 10, 2, 0x5678, little_endian);
    put_field(color + 12, 2, 0x9ABC, little_endian);
    if (write_exact(fd, color, sizeof(color)) || read_exact(fd, reply, sizeof(reply)) != 1 ||
        reply[0] != 1 || get_field(reply + 2, 2, little_endian) != 30 ||
        get_field(reply + 8, 2, little_endian) != 0x1212 ||
        get_field(reply + 10, 2, little_endian) != 0x5656 ||
        get_field(reply + 12, 2, little_endian) != 0x9A9A ||
        get_field(reply + 16, 4, little_endian) != 0x12569A)
        return -1;
    put_field(color + 4, 4, 0, little_endian);
    if (write_exact(fd, color, sizeof(color)) || read_exact(fd, reply, sizeof(reply)) != 1 ||
        reply[0] || reply[1] != BAD_COLORMAP ||
        get_field(reply + 2, 2, little_endian) != 31 || reply[10] != ALLOC_COLOR)
        return -1;
    uint8_t change[32] = {CHANGE_PROPERTY};
    put_field(change + 2, 2, 8, little_endian);
    put_field(change + 4, 4, id, little_endian);
    put_field(change + 8, 4, 67, little_endian); // WM_CLASS
    put_field(change + 12, 4, 31, little_endian); // STRING
    change[16] = 8;
    put_field(change + 20, 4, 8, little_endian);
    memcpy(change + 24, "dwm\0dwm", 8);
    put_field(property + 4, 4, id, little_endian);
    put_field(property + 8, 4, 67, little_endian);
    put_field(property + 12, 4, 31, little_endian);
    property[1] = 1; // Delete after the final matching read.
    uint8_t class_hint[8];
    if (write_exact(fd, change, sizeof(change)) || write_exact(fd, property, sizeof(property)) ||
        read_exact(fd, reply, sizeof(reply)) != 1 || reply[0] != 1 || reply[1] != 8 ||
        get_field(reply + 2, 2, little_endian) != 33 ||
        get_field(reply + 4, 4, little_endian) != 2 || get_field(reply + 8, 4, little_endian) != 31 ||
        get_field(reply + 16, 4, little_endian) != 8 ||
        read_exact(fd, class_hint, sizeof(class_hint)) != 1 ||
        memcmp(class_hint, "dwm\0dwm", sizeof(class_hint)))
        return -1;
    if (write_exact(fd, property, sizeof(property)) || read_exact(fd, reply, sizeof(reply)) != 1 ||
        reply[0] != 1 || reply[1] || get_field(reply + 2, 2, little_endian) != 34 ||
        get_field(reply + 8, 4, little_endian))
        return -1;
    // Paint the final window color through the same offscreen path used by dwm.
    uint32_t backing = id + 3;
    uint32_t drawing_gc = id + 4;
    pixmap[1] = ROOT_DEPTH;
    put_field(pixmap + 4, 4, backing, little_endian);
    put_field(pixmap + 12, 2, WINDOW_WIDTH, little_endian);
    put_field(pixmap + 14, 2, WINDOW_HEIGHT, little_endian);
    put_field(create_gc + 4, 4, drawing_gc, little_endian);
    put_field(create_gc + 8, 4, backing, little_endian);
    uint8_t change_gc[16] = {CHANGE_GC};
    put_field(change_gc + 2, 2, 4, little_endian);
    put_field(change_gc + 4, 4, drawing_gc, little_endian);
    put_field(change_gc + 8, 4, 1U << 2, little_endian);
    put_field(change_gc + 12, 4, WINDOW_PIXEL, little_endian);
    uint8_t fill[20] = {POLY_FILL_RECTANGLE};
    put_field(fill + 2, 2, 5, little_endian);
    put_field(fill + 4, 4, backing, little_endian);
    put_field(fill + 8, 4, drawing_gc, little_endian);
    put_field(fill + 16, 2, WINDOW_WIDTH, little_endian);
    put_field(fill + 18, 2, WINDOW_HEIGHT, little_endian);
    uint8_t copy[28] = {COPY_AREA};
    put_field(copy + 2, 2, 7, little_endian);
    put_field(copy + 4, 4, backing, little_endian);
    put_field(copy + 8, 4, id, little_endian);
    put_field(copy + 12, 4, drawing_gc, little_endian);
    put_field(copy + 24, 2, WINDOW_WIDTH, little_endian);
    put_field(copy + 26, 2, WINDOW_HEIGHT, little_endian);
    if (write_exact(fd, pixmap, sizeof(pixmap)) || write_exact(fd, create_gc, sizeof(create_gc)) ||
        write_exact(fd, change_gc, sizeof(change_gc)) || write_exact(fd, fill, sizeof(fill)) ||
        write_exact(fd, copy, sizeof(copy)) || read_exact(fd, reply, sizeof(reply)) != 1 ||
        reply[0] != NO_EXPOSURE || get_field(reply + 2, 2, little_endian) != 39)
        return -1;
    uint32_t nested = id + 5;
    uint8_t child_request[32] = {CREATE_WINDOW};
    put_field(child_request + 2, 2, 8, little_endian);
    put_field(child_request + 4, 4, nested, little_endian);
    put_field(child_request + 8, 4, id, little_endian);
    put_field(child_request + 12, 2, 12, little_endian);
    put_field(child_request + 14, 2, 8, little_endian);
    put_field(child_request + 16, 2, 32, little_endian);
    put_field(child_request + 18, 2, 16, little_endian);
    map[0] = MAP_SUBWINDOWS;
    put_field(map + 4, 4, id, little_endian);
    put_field(tree + 4, 4, nested, little_endian);
    if (write_exact(fd, child_request, sizeof(child_request)) ||
        write_exact(fd, map, sizeof(map)) || write_exact(fd, tree, sizeof(tree)) ||
        read_exact(fd, reply, sizeof(reply)) != 1 || reply[0] != 1 ||
        get_field(reply + 2, 2, little_endian) != 42 ||
        get_field(reply + 4, 4, little_endian) ||
        get_field(reply + 8, 4, little_endian) != root ||
        get_field(reply + 12, 4, little_endian) != id)
        return -1;
    put_field(attributes + 4, 4, nested, little_endian);
    if (write_exact(fd, attributes, sizeof(attributes)) ||
        read_exact(fd, attrs_reply, sizeof(attrs_reply)) != 1 || attrs_reply[0] != 1 ||
        get_field(attrs_reply + 2, 2, little_endian) != 43 || attrs_reply[26] != 2)
        return -1;
    return 0;
}

static int paint_desktop(const struct framebuffer *fb, bool active)
{
    const struct window background = {
        .width = fb->mode.xres, .height = fb->mode.yres,
        .background = active ? 0x1C293E : 0, .has_background = true,
    };
    int result = paint_window(fb, &background);
    if (result || !active)
        return result;

    const struct window frame = {
        .x = WINDOW_X - 2, .y = WINDOW_Y - 22,
        .width = WINDOW_WIDTH + 4, .height = WINDOW_HEIGHT + 24,
        .background = 0x61738B, .has_background = true,
    };
    return paint_window(fb, &frame);
}

static int wait_for_desktop_exit(int connection, int keyboard)
{
    struct pollfd descriptors[] = {
        {.fd = keyboard, .events = POLLIN},
        {.fd = connection, .events = POLLIN},
    };
    for (;;) {
        if (poll(descriptors, 2, -1) < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        if (descriptors[1].revents || !(descriptors[0].revents & POLLIN))
            return -1;
        uint8_t event[2];
        ssize_t size = read(keyboard, event, sizeof(event));
        if (size < 0 && (errno == EINTR || errno == EAGAIN))
            continue;
        if (size != sizeof(event))
            return -1;
        if (event[0] == 1 && event[1] == 0) // Set-1 Escape press
            return 0;
    }
}

static int check_connection(int listener, const struct sockaddr_un *address,
                            socklen_t size, bool little_endian, const struct framebuffer *fb,
                            int keyboard)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0)
        return -1;
    if (connect(fd, (const struct sockaddr *)address, size)) {
        close(fd);
        return -1;
    }

    pid_t child = fork();
    if (child == 0) {
        close(fd);
        int connection = accept(listener, NULL, NULL);
        if (connection < 0)
            _exit(1);
        _exit(serve_x11(connection, fb, -1, -1) != 0);
    }
    if (child < 0) {
        close(fd);
        return -1;
    }

    int result = probe_x11(fd, little_endian, fb);
    if (!result && keyboard >= 0)
        result = wait_for_desktop_exit(fd, keyboard);
    close(fd);
    int status;
    if (waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status))
        return -1;
    return result;
}

static const struct sockaddr_un display_address = {
    .sun_family = AF_UNIX,
    .sun_path = "/tmp/.X11-unix/X0",
};
#define DISPLAY_ADDRESS_SIZE (offsetof(struct sockaddr_un, sun_path) + sizeof("/tmp/.X11-unix/X0"))

static int open_display_socket(void)
{
    int listener = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (listener < 0)
        return -1;
    if (bind(listener, (const struct sockaddr *)&display_address, DISPLAY_ADDRESS_SIZE) ||
        listen(listener, 2)) {
        close(listener);
        return -1;
    }
    return listener;
}

int run_guest_dwm(void)
{
    int listener = open_display_socket();
    if (listener < 0) {
        perror("dwm session: display socket");
        return -1;
    }

    struct framebuffer fb = {0};
    if (open_framebuffer(&fb)) {
        fputs("dwm session: framebuffer unavailable\n", stderr);
        close(listener);
        return -1;
    }
    int keyboard = open("/dev/kbd", O_RDONLY | O_NONBLOCK);
    if (keyboard < 0) {
        perror("dwm session: keyboard");
        close(fb.fd);
        close(listener);
        return -1;
    }
    pid_t child = fork();
    if (child == 0) {
        close(listener);
        close(fb.fd);
        close(keyboard);
        char *const args[] = {"dwm", NULL};
        char *const environment[] = {
            "PATH=/", "DISPLAY=:0", "XAUTHORITY=/dev/null",
            "FONTCONFIG_FILE=/dwm-fonts.conf", NULL,
        };
        execve("/dwm", args, environment);
        perror("dwm session: exec /dwm");
        _exit(127);
    }

    int result = -1;
    if (child < 0) {
        perror("dwm session: fork");
    } else {
        struct pollfd ready = {.fd = listener, .events = POLLIN};
        int status;
        int pending;
        do {
            pending = poll(&ready, 1, 100);
            if (pending == 0 && waitpid(child, &status, WNOHANG) != 0) {
                fputs("dwm session: client exited before connecting\n", stderr);
                goto done;
            }
        } while (pending == 0 || (pending < 0 && errno == EINTR));

        if (ready.revents & POLLIN) {
            int fd = accept(listener, NULL, NULL);
            if (fd >= 0) {
                pid_t eyes = fork();
                if (eyes == 0) {
                    close(fd);
                    close(listener);
                    close(keyboard);
                    close(fb.fd);
                    char geometry[32];
                    snprintf(geometry, sizeof(geometry), "220x144+%u+%u",
                             (fb.mode.xres - 220) / 2, (fb.mode.yres - 144) / 2);
                    char *const args[] = {"xeyes", "+shape", "-bw", "0", "-geometry", geometry, NULL};
                    char *const environment[] = {"PATH=/", "DISPLAY=:0", "XAUTHORITY=/dev/null", NULL};
                    execve("/xeyes", args, environment);
                    perror("dwm session: exec /xeyes");
                    _exit(127);
                }
                if (eyes > 0)
                    result = serve_x11(fd, &fb, keyboard, listener);
                close(fd);
                close(listener);
                listener = -1;
                if (eyes > 0)
                    waitpid(eyes, NULL, 0);
            }
        }
        if (listener >= 0) {
            close(listener);
            listener = -1;
        }
        bool escape = result == 1;
        if (waitpid(child, &status, 0) != child || !WIFEXITED(status) || WEXITSTATUS(status))
            result = -1;
        if (escape)
            result = paint_desktop(&fb, false);
    }
done:
    close(keyboard);
    close(fb.fd);
    if (listener >= 0)
        close(listener);
    return result;
}

static int run_x11(bool desktop)
{
    int listener = open_display_socket();
    if (listener < 0)
        return -1;

    struct framebuffer fb = {0};
    if (open_framebuffer(&fb)) {
        close(listener);
        return -1;
    }
    int keyboard = -1;
    int result = 0;
    if (desktop) {
        keyboard = open("/dev/kbd", O_RDONLY | O_NONBLOCK);
        if (keyboard < 0 || paint_desktop(&fb, true))
            result = -1;
    }
    if (!result)
        result = check_connection(listener, &display_address, DISPLAY_ADDRESS_SIZE, true, &fb, keyboard);
    if (!result && !desktop)
        result = check_connection(listener, &display_address, DISPLAY_ADDRESS_SIZE, false, &fb, -1);
    if (keyboard >= 0) {
        if (paint_desktop(&fb, false))
            result = -1;
        close(keyboard);
    }
    close(fb.fd);
    close(listener);
    return result;
}


int check_x11(void)
{
    return run_x11(false);
}

int run_x11_desktop(void)
{
    return run_x11(true);
}
