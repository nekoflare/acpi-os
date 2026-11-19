#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/types.h>
#include <unistd.h>

static void cpuid(uint32_t leaf, uint32_t *a, uint32_t *b,
                  uint32_t *c, uint32_t *d)
{
    __asm__ volatile("cpuid" : "=a"(*a), "=b"(*b), "=c"(*c), "=d"(*d)
                     : "a"(leaf), "c"(0));
}

static uint64_t read_tsc(void)
{
    uint32_t low, high;
    __asm__ volatile("rdtsc" : "=a"(low), "=d"(high));
    return ((uint64_t)high << 32) | low;
}

static uint64_t tsc_frequency(void)
{
    uint32_t max_leaf, b, c, d;
    cpuid(0, &max_leaf, &b, &c, &d);
    if (max_leaf >= 0x15) {
        uint32_t denominator, numerator, crystal_hz;
        cpuid(0x15, &denominator, &numerator, &crystal_hz, &d);
        if (denominator && numerator && crystal_hz)
            return (uint64_t)crystal_hz * numerator / denominator;
    }
    if (max_leaf >= 0x16) {
        uint32_t base_mhz;
        cpuid(0x16, &base_mhz, &b, &c, &d);
        if (base_mhz)
            return (uint64_t)base_mhz * 1000000;
    }
    return 10000000000ULL;
}

static void hold_pattern(void)
{
    uint64_t deadline = read_tsc() + tsc_frequency() * 5;
    while (read_tsc() < deadline)
        __asm__ volatile("pause");
}

static uint32_t hsv_pixel(uint32_t hue, uint32_t saturation,
                          uint32_t red_shift, uint32_t green_shift,
                          uint32_t blue_shift)
{
    uint32_t sector = hue >> 8;
    uint32_t fraction = hue & 255;
    uint32_t p = (255 * (255 - saturation)) / 255;
    uint32_t q = (255 * (255 - saturation * fraction / 255)) / 255;
    uint32_t t = (255 * (255 - saturation * (255 - fraction) / 255)) / 255;
    uint32_t red, green, blue;

    switch (sector) {
    case 0: red = 255; green = t; blue = p; break;
    case 1: red = q; green = 255; blue = p; break;
    case 2: red = p; green = 255; blue = t; break;
    case 3: red = p; green = q; blue = 255; break;
    case 4: red = t; green = p; blue = 255; break;
    default: red = 255; green = p; blue = q; break;
    }
    return (red << red_shift) | (green << green_shift) | (blue << blue_shift);
}

static int write_all(int fd, const void *data, size_t size)
{
    const unsigned char *bytes = data;
    while (size) {
        ssize_t written = write(fd, bytes, size);
        if (written < 0 && errno == EINTR)
            continue;
        if (written <= 0)
            return -1;
        bytes += (size_t)written;
        size -= (size_t)written;
    }
    return 0;
}

int main(void)
{
    int fd = open("/dev/fb0", O_WRONLY);
    if (fd < 0) {
        perror("fbtest: open /dev/fb0");
        return 1;
    }

    struct fb_var_screeninfo var = {0};
    struct fb_fix_screeninfo fix = {0};
    if (ioctl(fd, FBIOGET_VSCREENINFO, &var) < 0 ||
        ioctl(fd, FBIOGET_FSCREENINFO, &fix) < 0) {
        perror("fbtest: framebuffer info ioctl");
        close(fd);
        return 1;
    }
    if (var.xres < 2 || var.yres < 2 || var.bits_per_pixel != 32 ||
        var.red.offset != 16 || var.red.length != 8 ||
        var.green.offset != 8 || var.green.length != 8 ||
        var.blue.offset != 0 || var.blue.length != 8 ||
        fix.line_length < var.xres * sizeof(uint32_t) ||
        fix.smem_len < fix.line_length * var.yres) {
        fprintf(stderr, "fbtest: unsupported framebuffer mode\n");
        close(fd);
        return 1;
    }

    uint32_t *row = malloc((size_t)var.xres * sizeof(*row));
    if (!row) {
        perror("fbtest: allocate scanline");
        close(fd);
        return 1;
    }

    uint32_t draw_width = var.xres < 320 ? var.xres : 320;
    uint32_t draw_height = var.yres < 200 ? var.yres : 200;
    uint32_t origin_x = (var.xres - draw_width) / 2;
    uint32_t origin_y = (var.yres - draw_height) / 2;
    for (uint32_t y = 0; y < draw_height; ++y) {
        uint32_t saturation = (uint64_t)(draw_height - 1 - y) * 255 / (draw_height - 1);
        for (uint32_t x = 0; x < draw_width; ++x) {
            uint32_t hue = (uint64_t)x * 1535 / (draw_width - 1);
            row[x] = hsv_pixel(hue, saturation, var.red.offset,
                               var.green.offset, var.blue.offset);
        }
        off_t offset = (off_t)(origin_y + y) * fix.line_length +
                       (off_t)origin_x * sizeof(*row);
        if (lseek(fd, offset, SEEK_SET) < 0 ||
            write_all(fd, row, (size_t)draw_width * sizeof(*row)) < 0) {
            perror("fbtest: write color space");
            free(row);
            close(fd);
            return 1;
        }
    }

    free(row);
    if (close(fd) < 0) {
        perror("fbtest: close framebuffer");
        return 1;
    }
    printf("HSV color space displayed (%ux%u XRGB8888)\n",
           draw_width, draw_height);
    hold_pattern();
    return 0;
}
