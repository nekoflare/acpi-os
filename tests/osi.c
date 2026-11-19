#include "../src/runtime.h"

#include <assert.h>
#include <string.h>

int32_t aml_MAIN(aml_context *, uint64_t *);
int32_t aml_READ(aml_context *, uint64_t *);
int32_t aml_BAD0(aml_context *, uint64_t *, uint64_t);
int32_t aml_value_OSNM(aml_context *, aml_value *);
int32_t aml_OSWR(aml_context *, uint64_t *);

static bool query(void *userdata, const char *interface_name)
{
    unsigned *calls = userdata;
    const char *expected = (*calls)++ == 0 ? "Windows 2015" : "AMLAOT Test";
    assert(strcmp(interface_name, expected) == 0);
    return strcmp(interface_name, "AMLAOT Test") == 0;
}

int main(void)
{
    unsigned calls = 0;
    const aml_host host = {.userdata = &calls, .osi = query};
    aml_context *custom = aml_context_create_with_host(&host);
    aml_context *standard = aml_context_create();
    uint64_t result;

    assert(custom && standard);
    assert(calls == 2);
    assert(aml_READ(custom, &result) == AML_OK && result == 7);
    assert(aml_MAIN(standard, &result) == AML_OK && result == 42);
    assert(aml_BAD0(standard, &result, 1) == AML_TYPE_MISMATCH && result == 42);
    assert(aml_OSWR(custom, &result) == AML_OK);
    aml_value os;
    assert(aml_value_OSNM(custom, &os) == AML_OK && os.type == AML_VALUE_STRING);
    assert(strcmp(os.string, "AMLAOT Test") == 0);
    assert(aml_value_OSNM(standard, &os) == AML_OK && os.type == AML_VALUE_STRING);
    assert(strcmp(os.string, "Microsoft Windows NT") == 0);
    aml_context_destroy(standard);
    aml_context_destroy(custom);
}
