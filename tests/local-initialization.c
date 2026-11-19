#include "../src/runtime.h"

#include <assert.h>

int32_t aml_MAIN(aml_context *, uint64_t *);
int32_t aml_PICK(aml_context *, uint64_t *, uint64_t);
int32_t aml_BUMP(aml_context *, uint64_t *, uint64_t);

int main(void)
{
    aml_context *ctx = aml_context_create();
    assert(ctx);
    uint64_t result;
    assert(aml_MAIN(ctx, &result) == AML_OK && result == 42);
    assert(aml_PICK(ctx, &result, 0) == AML_UNINITIALIZED && result == 42);
    assert(aml_BUMP(ctx, &result, 0) == AML_UNINITIALIZED && result == 42);
    assert(aml_BUMP(ctx, &result, 1) == AML_OK && result == 42);
    aml_context_destroy(ctx);
}
