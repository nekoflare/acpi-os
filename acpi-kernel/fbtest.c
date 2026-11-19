#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <unistd.h>

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
    return 0;
}
