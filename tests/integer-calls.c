#include "../src/runtime.h"

#include <assert.h>

int32_t aml_NEED(aml_context *, uint64_t *, uint64_t);
int32_t aml_STMT(aml_context *, uint64_t *, uint64_t);
int32_t aml_IGNR(aml_context *, uint64_t *);
int32_t aml_MAYB(aml_context *, uint64_t *, uint64_t);
int32_t aml_value_MAYB(aml_context *, aml_value *, uint64_t);
int32_t aml_SIXA(aml_context *, uint64_t *, uint64_t, uint64_t, uint64_t,
                 uint64_t, uint64_t, uint64_t);
int32_t aml_CSIX(aml_context *, uint64_t *);
int32_t aml_CMIX(aml_context *, uint64_t *);
int32_t aml_CSER(aml_context *, uint64_t *);
int32_t aml_DEEP(aml_context *, uint64_t *, uint64_t);
int32_t aml_CALW(aml_context *, uint64_t *);
int32_t aml_CWRP(aml_context *, uint64_t *);

int main(void)
{
    aml_context *ctx = aml_context_create();
    assert(ctx);
    uint64_t result = 0;
    aml_value value;
    assert(aml_NEED(ctx, &result, 4) == AML_OK && result == 10);
    assert(aml_NEED(ctx, &result, 0) == AML_NO_RETURN);
    assert(aml_STMT(ctx, &result, 3) == AML_OK && result == 77);
    assert(aml_STMT(ctx, &result, 0) == AML_NO_RETURN);
    assert(aml_IGNR(ctx, &result) == AML_OK && result == 5);
    result = 1234;
    assert(aml_MAYB(ctx, &result, 0) == AML_NO_RETURN && result == 1234);
    assert(aml_value_MAYB(ctx, &value, 0) == AML_OK && value.type == AML_VALUE_NO_RETURN);
    assert(aml_value_MAYB(ctx, &value, 8) == AML_OK);
    assert(value.type == AML_VALUE_INTEGER && value.integer_or_length == 9);
    assert(aml_SIXA(ctx, &result, 1, 1, 0, 1, 0, 1) == AML_OK && result == 53);
    assert(aml_CSIX(ctx, &result) == AML_OK && result == 45);
    assert(aml_CMIX(ctx, &result) == AML_OK && result == 18);
    assert(aml_CSER(ctx, &result) == AML_OK && result == 42);
    assert(aml_DEEP(ctx, &result, 0) == AML_EXECUTION_LIMIT);
    assert(aml_CALW(ctx, &result) == AML_OK && result == 21);
    assert(aml_CWRP(ctx, &result) == AML_OK && result == 0);
    aml_context_destroy(ctx);
    return 0;
}
