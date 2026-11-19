#include "../src/runtime.h"

#include <assert.h>

int32_t aml_PROB(aml_context *, uint64_t *);
int32_t aml_NSET(aml_context *, uint64_t *);
int32_t aml_GETC(aml_context *, uint64_t *);

static uint64_t timer(void *userdata)
{
    (void)userdata;
    return 0x3000;
}

int main(void)
{
    aml_context *ctx = aml_context_create();
    assert(ctx);
    uint64_t result;

    assert(aml_context_load_table(ctx, 0) == AML_HOST_UNAVAILABLE);
    assert(aml_PROB(ctx, &result) == AML_OK && result == 0);
    assert(aml_context_load_table(ctx, 1) == AML_TABLE_NOT_LOADED);

    aml_context_set_host(ctx, &(aml_host){.timer_100ns = timer});
    assert(aml_context_load_table(ctx, 0) == AML_OK);
    assert(aml_context_load_table(ctx, 1) == AML_OK);
    assert(aml_GETC(ctx, &result) == AML_OK && result == 42);
    assert(aml_context_unload_table(ctx, 0) == AML_TABLE_BUSY);
    assert(aml_context_unload_table(ctx, 1) == AML_OK);
    assert(aml_context_unload_table(ctx, 0) == AML_OK);

    assert(aml_NSET(ctx, &result) == AML_OK);
    assert(aml_context_load_table(ctx, 0) == AML_TABLE_BUSY);
    assert(aml_PROB(ctx, &result) == AML_OK && result == 0);
    assert(aml_context_unload_table(ctx, 0) == AML_TABLE_NOT_LOADED);
    assert(aml_context_unload_table(ctx, 1) == AML_TABLE_NOT_LOADED);
    assert(aml_GETC(ctx, &result) == AML_TABLE_NOT_LOADED);

    aml_context_destroy(ctx);
}
