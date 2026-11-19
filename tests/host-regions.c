#include "../src/runtime.h"

#include <assert.h>
#include <string.h>

int32_t aml_MAIN(aml_context *ctx, uint64_t *result);
int32_t aml_LKIO(aml_context *ctx, uint64_t *result);

struct simulated_memory {
    uint8_t bytes[16];
    unsigned reads, writes, lock_count;
    bool locked, fail_lock_io;
};

static int32_t access_region(void *userdata, const char *path, uint8_t space,
                             uint64_t address, uint8_t width, bool write,
                             uint64_t *value)
{
    struct simulated_memory *memory = userdata;
    assert(strcmp(path, "\\MEM0") == 0 && space == 0);
    assert(address >= 0x2000 && address + width <= 0x2010);
    unsigned offset = address - 0x2000;
    assert(memory->locked == (offset == 10));
    if (offset == 10 && memory->fail_lock_io)
        return AML_OUT_OF_BOUNDS;
    assert(width == (offset < 4 ? 2 : 1));
    if (write) {
        ++memory->writes;
        for (unsigned i = 0; i < width; ++i)
            memory->bytes[offset + i] = *value >> (8 * i);
    } else {
        ++memory->reads;
        *value = 0;
        for (unsigned i = 0; i < width; ++i)
            *value |= (uint64_t)memory->bytes[offset + i] << (8 * i);
    }
    return AML_OK;
}

static int32_t acquire_global_lock(void *userdata)
{
    struct simulated_memory *memory = userdata;
    assert(!memory->locked);
    memory->locked = true;
    ++memory->lock_count;
    return AML_OK;
}

static void release_global_lock(void *userdata)
{
    struct simulated_memory *memory = userdata;
    assert(memory->locked);
    memory->locked = false;
}

int main(void)
{
    aml_context *ctx = aml_context_create();
    assert(ctx);
    uint64_t result = 99;
    assert(aml_MAIN(ctx, &result) == AML_HOST_UNAVAILABLE);
    assert(result == 99);

    struct simulated_memory memory = {0};
    const aml_host host = {
        .userdata = &memory,
        .region_access = access_region,
        .acquire_global_lock = acquire_global_lock,
        .release_global_lock = release_global_lock,
    };
    aml_context_set_host(ctx, &host);
    assert(aml_MAIN(ctx, &result) == AML_OK);
    assert(result == 42);
    const uint8_t expected[] = {0xD4, 0xBC, 0x7A, 0x56, 0xF6, 0xB0, 7, 3, 0x99, 0x88};
    assert(memcmp(memory.bytes, expected, sizeof(expected)) == 0);
    assert(memory.reads == 12 && memory.writes == 12);
    memory.fail_lock_io = true;
    assert(aml_LKIO(ctx, &result) == AML_OUT_OF_BOUNDS);
    assert(!memory.locked && memory.lock_count == 1 && result == 42);
    memory.fail_lock_io = false;
    assert(aml_LKIO(ctx, &result) == AML_OK);
    assert(!memory.locked && memory.lock_count == 3 && result == 0x66);
    aml_context_destroy(ctx);
}
