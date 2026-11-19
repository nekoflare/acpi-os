#include "../src/runtime.h"

#include <assert.h>

int32_t aml_MAIN(aml_context *, uint64_t *);
int32_t aml_BAD0(aml_context *, uint64_t *, uint64_t);

int main(void)
{
    aml_context *ctx = aml_context_create();
    assert(ctx);
    uint64_t result;
    assert(aml_MAIN(ctx, &result) == AML_OK && result == 42);
    assert(aml_BAD0(ctx, &result, 1) == AML_TYPE_MISMATCH && result == 42);
    aml_context_destroy(ctx);
}
