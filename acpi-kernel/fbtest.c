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
    if (!var.xres || !var.yres || var.bits_per_pixel != 32 ||
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

    const uint32_t colors[] = {0xFF0000, 0x00FF00, 0x0000FF, 0xFFFFFF};
    for (uint32_t x = 0; x < var.xres; ++x) {
        uint32_t rgb = colors[(uint64_t)x * 4 / var.xres];
        row[x] = ((rgb >> 16 & 0xFF) << var.red.offset) |
                 ((rgb >> 8 & 0xFF) << var.green.offset) |
                 ((rgb & 0xFF) << var.blue.offset);
    }
    if (lseek(fd, (off_t)(var.yres / 2) * fix.line_length, SEEK_SET) < 0) {
        perror("fbtest: seek to test row");
        free(row);
        close(fd);
        return 1;
    }
    if (write_all(fd, row, (size_t)var.xres * sizeof(*row)) < 0) {
        perror("fbtest: write framebuffer pixels");
        free(row);
        close(fd);
        return 1;
    }

    free(row);
    if (close(fd) < 0) {
        perror("fbtest: close framebuffer");
        return 1;
    }
    printf("fbdev test pattern displayed (%ux%u XRGB8888)\n",
           var.xres, var.yres);
    hold_pattern();
    return 0;
}
