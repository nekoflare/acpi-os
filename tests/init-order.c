#include "../src/runtime.h"

#include <assert.h>
#include <stddef.h>

int main(void)
{
    assert(aml_context_create() == NULL);
    return 0;
}
