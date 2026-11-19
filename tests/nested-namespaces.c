#include "../src/runtime.h"

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static aml_context *ctx;

int32_t aml_MAIN(aml_context *, uint64_t *);
static uint64_t run_aml_MAIN(void)
{
    uint64_t result;
    if (aml_MAIN(ctx, &result) != AML_OK) {
        fprintf(stderr, "aml_MAIN failed\n");
        exit(EXIT_FAILURE);
    }
    return result;
}
int32_t aml_STEP(aml_context *, uint64_t *);
static uint64_t run_aml_STEP(void)
{
    uint64_t result;
    if (aml_STEP(ctx, &result) != AML_OK) {
        fprintf(stderr, "aml_STEP failed\n");
        exit(EXIT_FAILURE);
    }
    return result;
}
int32_t left_step(aml_context *, uint64_t *, uint64_t value) __asm__("aml__SB_.LFT0.STEP");
static uint64_t run_left_step(uint64_t value)
{
    uint64_t result;
    if (left_step(ctx, &result, value) != AML_OK) {
        fprintf(stderr, "left_step failed\n");
        exit(EXIT_FAILURE);
    }
    return result;
}
int32_t right_step(aml_context *, uint64_t *, uint64_t value, uint64_t factor) __asm__("aml__SB_.RGT0.STEP");
static uint64_t run_right_step(uint64_t value, uint64_t factor)
{
    uint64_t result;
    if (right_step(ctx, &result, value, factor) != AML_OK) {
        fprintf(stderr, "right_step failed\n");
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
    return expect("MAIN()", run_aml_MAIN(), 15041122)
        || expect("LFT0.STEP(0)", run_left_step(0), 17)
        || expect("RGT0.STEP(0, 0)", run_right_step(0, 0), 26)
        || expect("STEP()", run_aml_STEP(), 110);
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
