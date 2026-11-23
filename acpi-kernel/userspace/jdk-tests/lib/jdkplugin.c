// Shared library for the dlopen test: a constructor, exported data and
// functions, dynamic TLS, a large BSS and calls back into libc.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int plugin_constructed;
const char *plugin_name = "jdkplugin"; // Needs a relocation: lands in RELRO.
static char big_bss[3 * 4096 + 123];
static __thread long tls_counter = 5;

__attribute__((constructor)) static void construct(void)
{
    plugin_constructed = 1;
}

long plugin_add(long a, long b)
{
    return a + b;
}

long plugin_tls_bump(void)
{
    return ++tls_counter;
}

int plugin_bss_zero(void)
{
    for (size_t i = 0; i < sizeof big_bss; i++) {
        if (big_bss[i]) { return 0; }
    }
    big_bss[sizeof big_bss - 1] = 1;
    return 1;
}

char *plugin_format(int value)
{
    char *text = malloc(32);
    if (text) { snprintf(text, 32, "%s:%d", plugin_name, value); }
    return text;
}
