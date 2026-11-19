#include "../src/runtime.h"

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static aml_context *ctx;

int32_t aml_READ(aml_context *, uint64_t *);
static uint64_t run_aml_READ(void)
{
    uint64_t result;
    if (aml_READ(ctx, &result) != AML_OK) {
        fprintf(stderr, "aml_READ failed\n");
        exit(EXIT_FAILURE);
    }
    return result;
}
int32_t aml_BUMP(aml_context *, uint64_t *);
static uint64_t run_aml_BUMP(void)
{
    uint64_t result;
    if (aml_BUMP(ctx, &result) != AML_OK) {
        fprintf(stderr, "aml_BUMP failed\n");
        exit(EXIT_FAILURE);
    }
    return result;
}
int32_t aml_OBSV(aml_context *, uint64_t *);
static uint64_t run_aml_OBSV(void)
{
    uint64_t result;
    if (aml_OBSV(ctx, &result) != AML_OK) {
        fprintf(stderr, "aml_OBSV failed\n");
        exit(EXIT_FAILURE);
    }
    return result;
}

static int expect(const char *call, uint64_t actual, uint64_t expected)
{
    if (actual != expected) {
        fprintf(stderr, "%s returned %" PRIu64 ", expected %" PRIu64 "\n",
                call, actual, expected);
        return 1;
    }
    printf("%s = %" PRIu64 "\n", call, actual);
    return 0;
}

static int run(void)
{
    return expect("READ()", run_aml_READ(), 41)
        || expect("BUMP()", run_aml_BUMP(), 42)
        || expect("READ()", run_aml_READ(), 42)
        || expect("OBSV()", run_aml_OBSV(), 86)
        || expect("READ()", run_aml_READ(), 43);
}

int main(void)
{
    ctx = aml_context_create();
    if (!ctx)
        return EXIT_FAILURE;
    int status = run();
    aml_context_destroy(ctx);
    return status;
}
