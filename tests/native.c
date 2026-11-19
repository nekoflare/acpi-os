#include "../src/runtime.h"

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static aml_context *ctx;

int32_t aml_STEP(aml_context *, uint64_t *, uint64_t input);
static uint64_t run_aml_STEP(uint64_t input)
{
    uint64_t result;
    if (aml_STEP(ctx, &result, input) != AML_OK) {
        fprintf(stderr, "aml_STEP failed\n");
        exit(EXIT_FAILURE);
    }
    return result;
}
int32_t aml_TEST(aml_context *, uint64_t *, uint64_t input);
static uint64_t run_aml_TEST(uint64_t input)
{
    uint64_t result;
    if (aml_TEST(ctx, &result, input) != AML_OK) {
        fprintf(stderr, "aml_TEST failed\n");
        exit(EXIT_FAILURE);
    }
    return result;
}

static int run(void)
{
    const struct {
        const char *name;
        uint64_t (*method)(uint64_t);
        uint64_t input;
        uint64_t expected;
    } cases[] = {
        { "STEP", run_aml_STEP, 2, 1 },
        { "STEP", run_aml_STEP, 3, 9 },
        { "STEP", run_aml_STEP, UINT64_C(1) << 63, UINT64_C(1) << 62 },
        { "STEP", run_aml_STEP, UINT64_MAX, UINT64_MAX - 2 },
        { "TEST", run_aml_TEST, 0, 0 },
        { "TEST", run_aml_TEST, 4, 13 },
        { "TEST", run_aml_TEST, 8, 54 },
    };

    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; ++i) {
        uint64_t actual = cases[i].method(cases[i].input);
        if (actual != cases[i].expected) {
            fprintf(stderr, "%s(%" PRIu64 ") returned %" PRIu64 ", expected %" PRIu64 "\n",
                    cases[i].name, cases[i].input, actual, cases[i].expected);
            return 1;
        }
        printf("%s(%" PRIu64 ") = %" PRIu64 "\n", cases[i].name, cases[i].input, actual);
    }
    return 0;
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
