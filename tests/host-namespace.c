#include "../src/runtime.h"

#include <assert.h>
#include <string.h>

int32_t aml_MAIN(aml_context *ctx, uint64_t *result);
int32_t aml_TZ00_FAIL(aml_context *ctx, uint64_t *result) __asm__("aml_TZ00.FAIL");

int32_t aml_EVWT(aml_context *ctx, uint64_t *result, uint64_t timeout);
int32_t aml_HOST(aml_context *ctx, uint64_t *result);

static void delay(void *userdata, bool sleep, uint64_t duration)
{
    unsigned *step = userdata;
    if ((*step)++ == 0)
        assert(sleep && duration == 5);
    else
        assert(!sleep && duration == 11);
}

static void notify(void *userdata, const char *path, uint64_t value)
{
    unsigned *step = userdata;
    assert((*step)++ == 2);
    assert(strcmp(path, "\\TZ00") == 0 && value == 0x81);
}

static uint64_t timer(void *userdata)
{
    unsigned *step = userdata;
    assert((*step)++ == 3);
    return 1234;
}

static bool wait_event(void *userdata, const char *path, uint16_t timeout)
{
    unsigned *step = userdata;
    assert(strcmp(path, "\\EVT0") == 0);
    if ((*step)++ == 4) {
        assert(timeout == 5);
        return false;
    }
    assert(timeout == UINT16_MAX);
    return true;
}

int main(void)
{
    aml_context *ctx = aml_context_create();
    assert(ctx);
    uint64_t result = 99;
    assert(aml_TZ00_FAIL(ctx, &result) == AML_SYNC_LEVEL_TOO_HIGH);
    assert(result == 99);
    assert(aml_HOST(ctx, &result) == AML_HOST_UNAVAILABLE);
    assert(result == 99);

    unsigned step = 0;
    aml_host host = {.userdata = &step, .delay = delay, .notify = notify, .timer_100ns = timer,
                     .wait_event = wait_event};
    aml_context_set_host(ctx, &host);
    assert(aml_MAIN(ctx, &result) == AML_OK);
    assert(result == 42 && step == 5);
    assert(aml_EVWT(ctx, &result, 0x10000) == AML_OK);
    assert(result == 0 && step == 6);
    step = 0;
    assert(aml_HOST(ctx, &result) == AML_OK);
    assert(result == 1234 && step == 4);
    aml_context_destroy(ctx);
}
