// C1: the shared OpenSSL, zlib and CA bundle packages. Runs crypto/crypto-probe.c
// (dynamically linked against libcrypto, libssl and libz), then the openssl
// command line tool. The disk's /etc (ssl/) merges with the initramfs /etc
// (fstab, hosts, resolv.conf) when the disk mounts over /.
// disk: musl-runtime zlib zlib-shared openssl ca-certificates
// disk-dynamic: usr/bin/crypto-probe=crypto/crypto-probe.c
// disk-libs: -lssl -lcrypto -lz
// timeout: 120
// expect: sha256(abc)=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
// expect: crypto-probe ok
// expect: OpenSSL 3.5.9
// expect: SHA2-256(stdin)= ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

// Runs a program with the given standard input and returns its exit status.
static int run(char *const arguments[], const char *input)
{
    int pipes[2];
    if (pipe(pipes)) { return -1; }
    fflush(stdout);
    pid_t child = fork();
    if (child == 0) {
        dup2(pipes[0], 0);
        close(pipes[0]);
        close(pipes[1]);
        char *const environment[] = {"HOME=/tmp", "PATH=/usr/bin:/bin", NULL};
        execve(arguments[0], arguments, environment);
        printf("FAIL exec %s errno=%d\n", arguments[0], errno);
        _exit(127);
    }
    close(pipes[0]);
    if (input && write(pipes[1], input, strlen(input)) < 0) { return -1; }
    close(pipes[1]);
    int status;
    if (waitpid(child, &status, 0) != child) { return -1; }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

int main(void)
{
    const char *const files[] = {
        "/etc/fstab", "/etc/hosts", "/etc/resolv.conf", "/etc/ssl/openssl.cnf",
        "/etc/ssl/certs/ca-certificates.crt", "/etc/ssl/cert.pem",
    };
    for (unsigned i = 0; i < sizeof files / sizeof *files; ++i) {
        if (access(files[i], R_OK)) { printf("FAIL %s errno=%d\n", files[i], errno); return 1; }
    }
    printf("/etc merged\n");

    char *const probe[] = {"/usr/bin/crypto-probe", NULL};
    int status = run(probe, NULL);
    if (status) { printf("FAIL crypto-probe status=%d\n", status); return 1; }

    char *const version[] = {"/usr/bin/openssl", "version", "-a", NULL};
    status = run(version, NULL);
    if (status) { printf("FAIL openssl version status=%d\n", status); return 1; }

    char *const digest[] = {"/usr/bin/openssl", "dgst", "-sha256", NULL};
    status = run(digest, "abc");
    if (status) { printf("FAIL openssl dgst status=%d\n", status); return 1; }

    char *const key[] = {"/usr/bin/openssl", "genpkey", "-algorithm", "ed25519", NULL};
    status = run(key, NULL);
    if (status) { printf("FAIL openssl genpkey status=%d\n", status); return 1; }

    printf("PASS\n");
    return 0;
}
