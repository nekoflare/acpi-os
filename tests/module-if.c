#include "../src/runtime.h"
#include <assert.h>
int32_t aml_MAIN(aml_context *, uint64_t *);
int main(void)
{
    aml_context *ctx = aml_context_create();
    assert(ctx);
    uint64_t result;
    assert(aml_MAIN(ctx, &result) == AML_OK && result == 42);
    aml_context_destroy(ctx);
}
