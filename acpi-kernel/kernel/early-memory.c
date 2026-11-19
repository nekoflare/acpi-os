#include <stddef.h>
#include <stdint.h>

static _Alignas(max_align_t) unsigned char arena[64 * 1024];
static size_t used;

void *memset(void *destination, int byte, size_t count)
{
    unsigned char *out = destination;
    for (size_t i = 0; i < count; ++i)
        out[i] = (unsigned char)byte;
    return destination;
}

void *memcpy(void *restrict destination, const void *restrict source, size_t count)
{
    unsigned char *out = destination;
    const unsigned char *in = source;
    for (size_t i = 0; i < count; ++i)
        out[i] = in[i];
    return destination;
}

int memcmp(const void *left, const void *right, size_t count)
{
    const unsigned char *a = left;
    const unsigned char *b = right;
    for (size_t i = 0; i < count; ++i) {
        if (a[i] != b[i])
            return (int)a[i] - (int)b[i];
    }
    return 0;
}

void *memmove(void *destination, const void *source, size_t count)
{
    unsigned char *out = destination;
    const unsigned char *in = source;
    if ((uintptr_t)out < (uintptr_t)in) {
        for (size_t i = 0; i < count; ++i)
            out[i] = in[i];
    } else {
        while (count) {
            --count;
            out[count] = in[count];
        }
    }
    return destination;
}

void *calloc(size_t count, size_t size)
{
    const size_t alignment = _Alignof(max_align_t);
    size_t start = (used + alignment - 1) & ~(alignment - 1);
    if (count && size > SIZE_MAX / count)
        return NULL;
    size_t bytes = count * size;
    if (!bytes)
        bytes = 1;
    if (start > sizeof(arena) || bytes > sizeof(arena) - start)
        return NULL;
    used = start + bytes;
    return memset(arena + start, 0, bytes);
}

void free(void *allocation)
{
    /* The early arena is reserved for the lifetime of this boot milestone. */
    (void)allocation;
}

/* Scalar region methods take a checkpoint and discard their temporary objects. */
size_t acpi_arena_mark(void)
{
    return used;
}

void acpi_arena_reset(size_t mark)
{
    used = mark;
}
