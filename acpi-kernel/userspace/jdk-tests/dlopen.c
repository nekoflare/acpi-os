// link: dynamic
// shared-lib: lib/jdkplugin.c
// C4: dlopen, dlsym, dladdr and dynamic TLS in a library loaded at run time,
// as the JVM loads libjvm.so and its native libraries.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fail(const char *what)
{
    printf("FAIL %s errno=%d\n", what, errno);
    return 1;
}

static long (*tls_bump)(void);
static pthread_barrier_t loaded;

// Started before dlopen; uses the library's TLS once it is loaded.
static void *early_thread(void *arg)
{
    (void)arg;
    pthread_barrier_wait(&loaded);
    long first = tls_bump(), second = tls_bump();
    return (void *)(first == 6 && second == 7 ? 1L : 0L);
}

static void *thread_main(void *arg)
{
    (void)arg;
    // A new thread starts from the library's TLS initial value.
    long first = tls_bump(), second = tls_bump();
    return (void *)(first == 6 && second == 7 ? 1L : 0L);
}

int main(void)
{
    if (dlopen("libmissing.so", RTLD_NOW) || !dlerror()) { return fail("missing library"); }

    pthread_t early;
    pthread_barrier_init(&loaded, NULL, 2);
    if (pthread_create(&early, NULL, early_thread, NULL)) { return fail("early thread"); }
    void *handle = dlopen("libjdkplugin.so", RTLD_NOW | RTLD_LOCAL);
    if (!handle) { printf("%s\n", dlerror()); return fail("dlopen"); }
    int *constructed = dlsym(handle, "plugin_constructed");
    long (*add)(long, long) = (long (*)(long, long))dlsym(handle, "plugin_add");
    int (*bss_zero)(void) = (int (*)(void))dlsym(handle, "plugin_bss_zero");
    char *(*format)(int) = (char *(*)(int))dlsym(handle, "plugin_format");
    tls_bump = (long (*)(void))dlsym(handle, "plugin_tls_bump");
    if (!constructed || !add || !bss_zero || !format || !tls_bump) { return fail("dlsym"); }
    if (!*constructed) { return fail("constructor"); }
    if (add(40, 2) != 42 || !bss_zero()) { return fail("calls"); }
    char *text = format(7);
    if (!text || strcmp(text, "jdkplugin:7")) { return fail("libc from library"); }
    free(text);
    if (dlsym(handle, "no_such_symbol")) { return fail("missing symbol"); }

    Dl_info info;
    if (!dladdr((void *)add, &info) || !info.dli_fname || !strstr(info.dli_fname, "libjdkplugin.so") ||
        !info.dli_sname || strcmp(info.dli_sname, "plugin_add")) {
        return fail("dladdr");
    }
    printf("loaded %s at %p\n", info.dli_fname, info.dli_fbase);

    if (tls_bump() != 6 || tls_bump() != 7) { return fail("main thread TLS"); }
    pthread_barrier_wait(&loaded);
    void *early_result;
    if (pthread_join(early, &early_result) || !early_result) { return fail("early thread TLS"); }
    pthread_t threads[4];
    for (int i = 0; i < 4; i++) {
        if (pthread_create(&threads[i], NULL, thread_main, NULL)) { return fail("pthread_create"); }
    }
    for (int i = 0; i < 4; i++) {
        void *result;
        if (pthread_join(threads[i], &result) || !result) { return fail("thread TLS"); }
    }

    // Loading it again returns the same object; RTLD_DEFAULT does not see a
    // RTLD_LOCAL library.
    if (dlopen("/lib/libjdkplugin.so", RTLD_NOW) != handle) { return fail("dlopen by path"); }
    if (dlsym(RTLD_DEFAULT, "plugin_add")) { return fail("RTLD_LOCAL leaked"); }
    if (!dlsym(RTLD_DEFAULT, "printf")) { return fail("RTLD_DEFAULT libc"); }
    if (dlclose(handle)) { return fail("dlclose"); }
    printf("PASS\n");
    return 0;
}
