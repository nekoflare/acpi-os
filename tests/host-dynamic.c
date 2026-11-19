#include "../src/runtime.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

int32_t aml_MAIN(aml_context *, uint64_t *);
int32_t aml_DINC(aml_context *, uint64_t *);
int32_t aml_SAVA(aml_context *, uint64_t *);
int32_t aml_SAVE(aml_context *, uint64_t *);
int32_t aml_READ(aml_context *, uint64_t *);
int32_t aml_PRES(aml_context *, uint64_t *);
int32_t aml_MTYP(aml_context *, uint64_t *);

int32_t aml_LDTB(aml_context *, uint64_t *);
int32_t aml_LDOP(aml_context *, uint64_t *);
int32_t aml_ULDT(aml_context *, uint64_t *);

struct table_image {
    uint8_t bytes[1024];
    size_t size;
};

static int32_t read_table(void *userdata, const char *path, uint8_t space,
                          uint64_t address, uint8_t width, bool write, uint64_t *value)
{
    const struct table_image *image = userdata;
    assert(strcmp(path, "\\TBLE") == 0 && space == 0 && width == 1 && !write);
    assert(address >= 0x3000 && address - 0x3000 < image->size);
    *value = image->bytes[address - 0x3000];
    return AML_OK;
}

int main(int argc, char **argv)
{
    aml_context *ctx = aml_context_create();
    aml_context *other = aml_context_create();
    assert(ctx && other);
    uint64_t result = 99;

    assert(aml_MAIN(ctx, &result) == AML_TABLE_NOT_LOADED && result == 99);
    assert(aml_DINC(ctx, &result) == AML_TABLE_NOT_LOADED && result == 99);
    assert(aml_SAVE(ctx, &result) == AML_TABLE_NOT_LOADED && result == 99);
    assert(aml_PRES(ctx, &result) == AML_OK && result == 0);
    assert(aml_context_load_table(ctx, 1) == AML_INVALID_ARGUMENT);
    assert(aml_context_load_table(ctx, 0) == AML_OK);
    assert(aml_context_load_table(ctx, 0) == AML_TABLE_ALREADY_LOADED);
    assert(aml_MAIN(ctx, &result) == AML_OK && result == 42);
    assert(aml_MAIN(other, &result) == AML_TABLE_NOT_LOADED && result == 42);
    assert(aml_SAVE(ctx, &result) == AML_OK);
    assert(aml_READ(ctx, &result) == AML_OK && result == 42);
    assert(aml_PRES(ctx, &result) == AML_OK && result == 87);
    assert(aml_MTYP(ctx, &result) == AML_OK && result == 8);
    result = 42;

    assert(aml_context_unload_table(ctx, 0) == AML_OK);
    assert(aml_context_unload_table(ctx, 0) == AML_TABLE_NOT_LOADED);
    assert(aml_MAIN(ctx, &result) == AML_TABLE_NOT_LOADED && result == 42);
    assert(aml_READ(ctx, &result) == AML_TABLE_NOT_LOADED && result == 42);
    assert(aml_PRES(ctx, &result) == AML_OK && result == 0);
    assert(aml_MTYP(ctx, &result) == AML_TABLE_NOT_LOADED && result == 0);
    assert(aml_context_load_table(ctx, 0) == AML_OK);
    assert(aml_MTYP(ctx, &result) == AML_TABLE_NOT_LOADED && result == 0);
    assert(aml_DINC(ctx, &result) == AML_OK && result == 42);
    assert(aml_READ(ctx, &result) == AML_TABLE_NOT_LOADED && result == 42);
    assert(aml_SAVE(ctx, &result) == AML_OK);
    assert(aml_READ(ctx, &result) == AML_OK && result == 42);

    assert(aml_SAVA(ctx, &result) == AML_OK && result == 87);
    assert(aml_READ(ctx, &result) == AML_OK && result == 87);
    assert(aml_context_unload_table(ctx, 0) == AML_OK);
    assert(aml_SAVA(ctx, &result) == AML_TABLE_NOT_LOADED && result == 87);
    assert(aml_READ(ctx, &result) == AML_TABLE_NOT_LOADED && result == 87);
    assert(aml_LDTB(ctx, &result) == AML_OK && result != 0);
    uint64_t old_handle = result;
    assert(aml_READ(ctx, &result) == AML_TABLE_NOT_LOADED && result == old_handle);
    assert(aml_DINC(ctx, &result) == AML_OK && result == 42);
    assert(aml_ULDT(ctx, &result) == AML_OK && result == 0);
    assert(aml_DINC(ctx, &result) == AML_TABLE_NOT_LOADED);
    assert(aml_ULDT(ctx, &result) == AML_TABLE_NOT_LOADED);

    assert(argc == 2);
    FILE *stream = fopen(argv[1], "rb");
    assert(stream);
    struct table_image image;
    image.size = fread(image.bytes, 1, sizeof(image.bytes), stream);
    assert(feof(stream) && fclose(stream) == 0);
    const aml_host host = {.userdata = &image, .region_access = read_table};
    aml_context_set_host(ctx, &host);
    image.bytes[image.size - 1] ^= 1;
    assert(aml_LDOP(ctx, &result) == AML_OK && result == 0);
    assert(aml_MAIN(ctx, &result) == AML_TABLE_NOT_LOADED);
    image.bytes[image.size - 1] ^= 1;
    assert(aml_LDOP(ctx, &result) == AML_OK && result > old_handle);
    assert(aml_MAIN(ctx, &result) == AML_OK && result == 42);
    assert(aml_ULDT(ctx, &result) == AML_OK);

    aml_context_destroy(ctx);
    aml_context_destroy(other);
}
