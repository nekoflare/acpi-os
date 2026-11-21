#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

enum { SYS_SCHED_GETAFFINITY_X86_64 = 204 };

static void usage(FILE *stream)
{
    fputs("Usage: nproc [OPTION]...\n"
          "Print the number of processing units available to this process.\n"
          "  --all          print the number of online processors\n"
          "  --ignore=N     exclude N processing units, but return at least 1\n"
          "  --help         display this help and exit\n"
          "  --version      output version information and exit\n", stream);
}

static int parse_count(const char *text, unsigned long *count)
{
    char *end = NULL;
    unsigned long parsed;

    if (!text || !*text || *text == '-')
        return -1;
    errno = 0;
    parsed = strtoul(text, &end, 10);
    if (errno || !end || *end)
        return -1;
    *count = parsed;
    return 0;
}

static unsigned long affinity_count(void)
{
    uint64_t mask = 0;
    long result = syscall(SYS_SCHED_GETAFFINITY_X86_64, 0UL,
                          (unsigned long)sizeof(mask), (unsigned long)&mask);
    unsigned long count = 0;

    if (result < 0) {
        perror("nproc: sched_getaffinity");
        return 0;
    }
    while (mask) {
        count += (unsigned long)(mask & 1U);
        mask >>= 1;
    }
    return count;
}

static unsigned long env_count(const char *name, unsigned long fallback)
{
    const char *value = getenv(name);
    unsigned long parsed;

    if (value && parse_count(value, &parsed) == 0 && parsed)
        return parsed;
    return fallback;
}

int main(int argc, char **argv)
{
    unsigned long ignore = 0;
    unsigned long count;
    int all = 0;

    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--all")) {
            all = 1;
        } else if (!strcmp(argv[i], "--help")) {
            usage(stdout);
            return 0;
        } else if (!strcmp(argv[i], "--version")) {
            puts("nproc (acpi-os) 1.0");
            return 0;
        } else if (!strncmp(argv[i], "--ignore=", 9)) {
            if (parse_count(argv[i] + 9, &ignore) < 0) {
                fprintf(stderr, "nproc: invalid number: %s\n", argv[i] + 9);
                return 1;
            }
        } else if (!strcmp(argv[i], "--ignore") && i + 1 < argc) {
            if (parse_count(argv[++i], &ignore) < 0) {
                fprintf(stderr, "nproc: invalid number: %s\n", argv[i]);
                return 1;
            }
        } else {
            fprintf(stderr, "nproc: unrecognized option: %s\n", argv[i]);
            usage(stderr);
            return 1;
        }
    }

    count = affinity_count();
    if (!count)
        return 1;

    if (!all) {
        unsigned long minimum = env_count("OMP_NUM_THREADS", 1);
        unsigned long maximum = env_count("OMP_THREAD_LIMIT", count);
        if (count < minimum)
            count = minimum;
        if (count > maximum)
            count = maximum;
    }

    count = ignore < count ? count - ignore : 1;
    printf("%lu\n", count);
    return 0;
}
