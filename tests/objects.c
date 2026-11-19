#include "../src/runtime.h"

#include <assert.h>
#include <string.h>

int32_t aml_MAIN(aml_context *, uint64_t *);
int32_t aml_SAVE(aml_context *, uint64_t *);
int32_t aml_BUMP(aml_context *, uint64_t *);
int32_t aml_INVD(aml_context *, uint64_t *);
int32_t aml_value_SBUF(aml_context *, aml_value *, uint64_t);
int32_t aml_value_SPKG(aml_context *, aml_value *, uint64_t);
int32_t aml_value_CSTR(aml_context *, aml_value *);

int main(void)
{
    aml_context *ctx = aml_context_create();
    assert(ctx);

    uint64_t integer = 0;
    assert(aml_MAIN(ctx, &integer) == AML_OK && integer == 49);
    aml_context *second = aml_context_create();
    assert(second);
    assert(aml_SAVE(second, &integer) == AML_OK && integer == 0);
    assert(aml_BUMP(second, &integer) == AML_OK && integer == 0xB3);
    aml_context_destroy(second);
    assert(aml_BUMP(ctx, &integer) == AML_OK && integer == 0xB4);
    assert(aml_INVD(ctx, &integer) == AML_OUT_OF_BOUNDS && integer == 0xB4);

    aml_value value;
    assert(aml_value_SBUF(ctx, &value, 4) == AML_OK);
    const uint8_t buffer[] = {0xAA, 1, 0, 0};
    assert(value.type == AML_VALUE_BUFFER && value.integer_or_length == sizeof(buffer));
    assert(memcmp(value.data, buffer, sizeof(buffer)) == 0);

    assert(aml_value_SBUF(ctx, &value, 0) == AML_OK);
    assert(value.type == AML_VALUE_BUFFER && value.integer_or_length == 2);
    assert(memcmp(value.data, buffer, 2) == 0);

    assert(aml_value_SPKG(ctx, &value, 3) == AML_OK);
    assert(value.type == AML_VALUE_PACKAGE && value.integer_or_length == 3);
    const aml_value *elements = value.data;
    assert(elements[0].type == AML_VALUE_INTEGER && elements[0].integer_or_length == 9);
    assert(elements[1].type == AML_VALUE_STRING && strcmp(elements[1].string, "hi") == 0);
    assert(elements[2].type == AML_VALUE_UNINITIALIZED);

    assert(aml_value_CSTR(ctx, &value) == AML_OK);
    assert(value.type == AML_VALUE_STRING && value.integer_or_length == 4);
    assert(memcmp(value.string, "xy\0\0", 5) == 0);

    for (int i = 0; i < 200; ++i)
        assert(aml_value_SBUF(ctx, &value, 512 * 1024) == AML_OK);
    assert(aml_MAIN(ctx, &integer) == AML_OK && integer == 49);
    aml_context_destroy(ctx);
}
