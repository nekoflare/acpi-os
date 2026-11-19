#include "../src/runtime.h"

#include <assert.h>

int32_t aml_MAIN(aml_context *, uint64_t *);
int32_t aml_SETV(aml_context *, uint64_t *, uint64_t);
int32_t aml_value_SETV(aml_context *, aml_value *, uint64_t);
int32_t aml_value_NEED(aml_context *, aml_value *, uint64_t);

int main(void)
{
    aml_context *ctx = aml_context_create();
    assert(ctx);
    uint64_t result = 99;
    assert(aml_SETV(ctx, &result, 7) == AML_NO_RETURN && result == 99);
    aml_value value;
    assert(aml_value_SETV(ctx, &value, 8) == AML_OK && value.type == AML_VALUE_NO_RETURN);
    assert(aml_MAIN(ctx, &result) == AML_OK && result == 42);
    assert(aml_value_NEED(ctx, &value, 1) == AML_OK);
    assert(value.type == AML_VALUE_INTEGER && value.integer_or_length == 20);
    assert(aml_value_NEED(ctx, &value, 2) == AML_NO_RETURN);
    assert(value.type == AML_VALUE_INTEGER && value.integer_or_length == 20);
    aml_context_destroy(ctx);
}
