#include "../src/runtime.h"

#include <assert.h>

int32_t aml_MAIN(aml_context *, uint64_t *);
int32_t aml_CALL(aml_context *, uint64_t *, uint64_t);
int32_t aml_SEEN(aml_context *, uint64_t *);
#ifndef EXPECTED_RESULT
#define EXPECTED_RESULT 42
#endif

int main(void)
{
    aml_context *ctx = aml_context_create();
    assert(ctx);
    uint64_t result;
    assert(aml_MAIN(ctx, &result) == AML_OK && result == EXPECTED_RESULT);
    assert(aml_CALL(ctx, &result, 0) == AML_OK && result == 42);
    if (EXPECTED_RESULT == 42) {
        assert(aml_CALL(ctx, &result, 1) == AML_UNRESOLVED_EXTERNAL && result == 42);
    } else {
        assert(aml_CALL(ctx, &result, 1) == AML_OK && result == 2);
    }
    assert(aml_SEEN(ctx, &result) == AML_OK && result == 1);
    aml_context_destroy(ctx);
}
