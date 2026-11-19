#include "../src/runtime.h"

#include <assert.h>
#include <string.h>

int32_t aml_MAIN(aml_context *, uint64_t *);
int32_t aml_SAVE(aml_context *, uint64_t *);
int32_t aml_READ(aml_context *, uint64_t *);

static int32_t access_region(void *userdata, const char *path, uint8_t space,
                             uint64_t address, uint8_t width, bool write,
                             uint64_t *value)
{
    uint8_t (*memory)[4] = userdata;
    assert(strcmp(path, "\\WORK.MEM0") == 0 && space == 0 && width == 1);
    assert((address >= 0x2000 && address < 0x2004) ||
           (address >= 0x2100 && address < 0x2104));
    uint8_t *byte = &memory[(address - 0x2000) >> 8][address & 3];
    if (write)
        *byte = *value;
    else
        *value = *byte;
    return AML_OK;
}

int main(void)
{
    uint8_t memory[2][4] = {{0}};
    const aml_host host = {.userdata = memory, .region_access = access_region};
    aml_context *ctx = aml_context_create_with_host(&host);
    uint64_t result;
    assert(ctx);
    assert(aml_MAIN(ctx, &result) == AML_OK && result == 42);
    const uint8_t expected[2][4] = {{0x24, 7, 2, 0xB2}, {0x44, 7, 2, 0xB2}};
    assert(memcmp(memory, expected, sizeof(memory)) == 0);
    assert(aml_SAVE(ctx, &result) == AML_OK && result == 0);
    assert(aml_READ(ctx, &result) == AML_TABLE_NOT_LOADED && result == 0);
    aml_context_destroy(ctx);
}
