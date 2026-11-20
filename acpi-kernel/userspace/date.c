#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int usage(void)
{
    fputs("usage: date [-u] [+FORMAT]\n", stderr);
    return 2;
}

int main(int argc, char **argv)
{
    int utc = 0;
    const char *format = "%a %b %e %H:%M:%S %Z %Y";
    int have_format = 0;

    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "-u") || !strcmp(argv[i], "--utc")) {
            utc = 1;
        } else if (argv[i][0] == '+' && !have_format) {
            format = argv[i] + 1;
            have_format = 1;
        } else {
            return usage();
        }
    }

    time_t now = time(NULL);
    if (now == (time_t)-1) {
        perror("date: time");
        return 1;
    }

    struct tm broken_down;
    if (!(utc ? gmtime_r(&now, &broken_down) : localtime_r(&now, &broken_down))) {
        perror("date: conversion");
        return 1;
    }

    char output[4096];
    size_t length = strftime(output, sizeof(output), format, &broken_down);
    if (!length && *format) {
        fputs("date: format is too long or invalid\n", stderr);
        return 1;
    }
    if (puts(output) == EOF) {
        perror("date: write");
        return 1;
    }
    return 0;
}
