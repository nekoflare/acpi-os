// C2: the dynamically linked curl and libcurl against a host HTTP and HTTPS
// server (scripts/http-test-server.py). Checks the guest clock (certificates
// need it), plain HTTP, HTTPS with the test certificate, that HTTPS without it
// fails verification, a 1 MiB download, gzip decoding through zlib, an upload,
// and the libcurl API through curl/curl-probe.c.
// net
// http-server
// disk: musl-runtime zlib zlib-shared openssl ca-certificates curl
// disk-dynamic: usr/bin/curl-probe=curl/curl-probe.c
// disk-libs: -lcurl
// timeout: 120
// expect: libcurl/8.23.0 OpenSSL/3.5.9 zlib/1.3.1
// expect: plain http ok
// expect: https ok
// expect: unverified https refused (60)
// expect: 1 MiB over https ok
// expect: gzip ok
// expect: upload ok
// expect: curl-probe result=0 status=200
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static char output[2 << 20];
static size_t output_length;

// Runs a program with the given standard input (length bytes) and collects
// its standard output in output. Returns the exit status.
static int run(char *const arguments[], const char *input, size_t length)
{
    int in[2], out[2];
    if (pipe(in) || pipe(out)) { return -1; }
    fflush(stdout);
    pid_t child = fork();
    if (child == 0) {
        dup2(in[0], 0);
        dup2(out[1], 1);
        close(in[0]);
        close(in[1]);
        close(out[0]);
        close(out[1]);
        char *const environment[] = {"HOME=/tmp", "PATH=/usr/bin:/bin", NULL};
        execve(arguments[0], arguments, environment);
        dprintf(2, "FAIL exec %s errno=%d\n", arguments[0], errno);
        _exit(127);
    }
    close(in[0]);
    close(out[1]);
    // A separate writer, so a large upload cannot block against the output.
    pid_t writer = fork();
    if (writer == 0) {
        close(out[0]);
        while (length) {
            ssize_t n = write(in[1], input, length);
            if (n <= 0) { _exit(1); }
            input += n;
            length -= (size_t)n;
        }
        _exit(0);
    }
    close(in[1]);
    output_length = 0;
    for (;;) {
        ssize_t n = read(out[0], output + output_length, sizeof output - 1 - output_length);
        if (n <= 0) { break; }
        output_length += (size_t)n;
    }
    output[output_length] = 0;
    close(out[0]);
    int status;
    waitpid(writer, &status, 0);
    if (waitpid(child, &status, 0) != child) { return -1; }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

static unsigned char pattern(size_t i) { return (unsigned char)(i * 7 + (i >> 8)); }

static unsigned crc32(const unsigned char *data, size_t length)
{
    unsigned crc = 0xffffffff;
    for (size_t i = 0; i < length; ++i) {
        crc ^= data[i];
        for (int bit = 0; bit < 8; ++bit) { crc = (crc >> 1) ^ (0xedb88320 & -(crc & 1)); }
    }
    return ~crc;
}

int main(void)
{
    time_t now = time(NULL);
    struct tm utc;
    gmtime_r(&now, &utc);
    printf("guest clock %04d-%02d-%02d %02d:%02d:%02d UTC\n", utc.tm_year + 1900, utc.tm_mon + 1,
           utc.tm_mday, utc.tm_hour, utc.tm_min, utc.tm_sec);
    if (utc.tm_year + 1900 < 2026) { printf("FAIL guest clock is not set\n"); return 1; }

    FILE *ports = fopen("/etc/http-ports", "r");
    int http_port, https_port;
    if (!ports || fscanf(ports, "%d %d", &http_port, &https_port) != 2) {
        printf("FAIL /etc/http-ports\n");
        return 1;
    }
    fclose(ports);
    char url[128];

    char *const version[] = {"/usr/bin/curl", "--version", NULL};
    if (run(version, NULL, 0)) { printf("FAIL curl --version\n"); return 1; }
    fputs(output, stdout);

    snprintf(url, sizeof url, "http://10.0.2.2:%d/hello", http_port);
    char *const plain[] = {"/usr/bin/curl", "-sS", url, NULL};
    int status = run(plain, NULL, 0);
    if (status || strcmp(output, "hello from the host\n")) {
        printf("FAIL plain http status=%d output=%s\n", status, output);
        return 1;
    }
    printf("plain http ok\n");

    snprintf(url, sizeof url, "https://10.0.2.2:%d/hello", https_port);
    char *const secure[] = {"/usr/bin/curl", "-sS", "--cacert", "/etc/http-ca.pem", url, NULL};
    status = run(secure, NULL, 0);
    if (status || strcmp(output, "hello from the host\n")) {
        printf("FAIL https status=%d output=%s\n", status, output);
        return 1;
    }
    printf("https ok\n");

    // The system bundle does not hold the test certificate: CURLE_PEER_FAILED_VERIFICATION.
    char *const unverified[] = {"/usr/bin/curl", "-sS", url, NULL};
    status = run(unverified, NULL, 0);
    if (status != 60) { printf("FAIL unverified https status=%d\n", status); return 1; }
    printf("unverified https refused (60)\n");

    snprintf(url, sizeof url, "https://10.0.2.2:%d/big", https_port);
    char *const big[] = {"/usr/bin/curl", "-sS", "--cacert", "/etc/http-ca.pem", url, NULL};
    status = run(big, NULL, 0);
    if (status || output_length != 1 << 20) {
        printf("FAIL big status=%d length=%zu\n", status, output_length);
        return 1;
    }
    for (size_t i = 0; i < output_length; ++i) {
        if ((unsigned char)output[i] != pattern(i)) { printf("FAIL big byte %zu\n", i); return 1; }
    }
    printf("1 MiB over https ok\n");

    snprintf(url, sizeof url, "https://10.0.2.2:%d/gzip", https_port);
    char *const compressed[] = {"/usr/bin/curl", "-sS", "--compressed",
                                "--cacert", "/etc/http-ca.pem", url, NULL};
    status = run(compressed, NULL, 0);
    const char *last = "line 1999 of the compressible page\n";
    if (status || strncmp(output, "line 0 of the compressible page\n", 32) ||
        output_length < strlen(last) || strcmp(output + output_length - strlen(last), last)) {
        printf("FAIL gzip status=%d length=%zu\n", status, output_length);
        return 1;
    }
    printf("gzip ok (%zu bytes decoded)\n", output_length);

    static unsigned char upload[200000];
    for (size_t i = 0; i < sizeof upload; ++i) { upload[i] = pattern(i); }
    char expected[64];
    snprintf(expected, sizeof expected, "%zu %08x\n", sizeof upload, crc32(upload, sizeof upload));
    snprintf(url, sizeof url, "https://10.0.2.2:%d/echo", https_port);
    char *const post[] = {"/usr/bin/curl", "-sS", "--cacert", "/etc/http-ca.pem",
                          "--data-binary", "@-", url, NULL};
    status = run(post, (const char *)upload, sizeof upload);
    if (status || strcmp(output, expected)) {
        printf("FAIL upload status=%d output=%s expected=%s\n", status, output, expected);
        return 1;
    }
    printf("upload ok\n");

    snprintf(url, sizeof url, "https://10.0.2.2:%d/hello", https_port);
    char *const probe[] = {"/usr/bin/curl-probe", url, "/etc/http-ca.pem", NULL};
    status = run(probe, NULL, 0);
    fputs(output, stdout);
    if (status) { printf("FAIL curl-probe status=%d\n", status); return 1; }

    printf("PASS\n");
    return 0;
}
