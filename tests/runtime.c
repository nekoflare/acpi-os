#include "../src/runtime.h"

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

int32_t aml_MAIN(aml_context *, uint64_t *);
int32_t aml_DELG(aml_context *, uint64_t *, uint64_t);
int32_t aml_FAIL(aml_context *, uint64_t *, uint64_t);
int32_t aml_LOOP(aml_context *, uint64_t *, uint64_t);
int32_t aml_RECU(aml_context *, uint64_t *, uint64_t);

#define CHECK(condition) do { \
    if (!(condition)) { \
        fprintf(stderr, "Line %d failed: %s\n", __LINE__, #condition); \
        return false; \
    } \
} while (0)

static bool verify(aml_context *first, aml_context *second)
{
    uint64_t result = 0;
    CHECK(first && second);
    CHECK(aml_MAIN(first, &result) == AML_OK && result == 4242);
    CHECK(aml_DELG(first, &result, UINT64_C(0x100000002)) == AML_OK && result == 44);
    CHECK(aml_MAIN(second, &result) == AML_OK && result == 4242);
    CHECK(aml_MAIN(first, &result) == AML_OK && result == 4545);
    CHECK(aml_FAIL(first, &result, 0) == AML_DIVISION_BY_ZERO && result == 4545);
    CHECK(aml_LOOP(first, &result, 1) == AML_EXECUTION_LIMIT && result == 4545);
    CHECK(aml_RECU(first, &result, 1) == AML_EXECUTION_LIMIT && result == 4545);
    CHECK(aml_MAIN(NULL, &result) == AML_INVALID_ARGUMENT && result == 4545);
    CHECK(aml_MAIN(first, NULL) == AML_INVALID_ARGUMENT);
    CHECK(aml_MAIN(first, &result) == AML_OK && result == 4646);
    return true;
}

int main(void)
{
    aml_context *first = aml_context_create();
    aml_context *second = aml_context_create();
    const bool passed = verify(first, second);
    aml_context_destroy(second);
    aml_context_destroy(first);
    return passed ? EXIT_SUCCESS : EXIT_FAILURE;
}
