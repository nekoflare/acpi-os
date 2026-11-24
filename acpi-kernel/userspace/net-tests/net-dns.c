// Name resolution (NETPLAN S5): musl's resolver reads /etc/resolv.conf and
// asks slirp's DNS forwarder at 10.0.2.3 over UDP; busybox nslookup does the
// same with its own resolver.
// net
// disk: busybox
// timeout: 90
#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int failures;

#define CHECK(cond, ...)                                                       \
    do {                                                                       \
        if (!(cond)) {                                                         \
            printf("FAIL %s:%d: ", __FILE__, __LINE__);                        \
            printf(__VA_ARGS__);                                               \
            printf("\n");                                                      \
            failures++;                                                        \
        }                                                                      \
    } while (0)

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000LL + ts.tv_nsec / 1000000;
}

// Resolve name for family; print each address and return how many there
// were, or the negative getaddrinfo error.
static int resolve(const char *name, int family, const char *service) {
    struct addrinfo hints = {.ai_family = family, .ai_socktype = SOCK_STREAM}, *result;
    long long start = now_ms();
    int rc = getaddrinfo(name, service, &hints, &result);
    long long took = now_ms() - start;
    if (rc) {
        printf("getaddrinfo %s family %d: %s (%lld ms)\n", name, family, gai_strerror(rc), took);
        return rc < 0 ? rc : -rc;
    }
    int n = 0;
    for (struct addrinfo *ai = result; ai; ai = ai->ai_next) {
        char text[INET6_ADDRSTRLEN];
        int port;
        if (ai->ai_family == AF_INET) {
            struct sockaddr_in *in = (struct sockaddr_in *)ai->ai_addr;
            inet_ntop(AF_INET, &in->sin_addr, text, sizeof text);
            port = ntohs(in->sin_port);
        } else {
            struct sockaddr_in6 *in6 = (struct sockaddr_in6 *)ai->ai_addr;
            inet_ntop(AF_INET6, &in6->sin6_addr, text, sizeof text);
            port = ntohs(in6->sin6_port);
        }
        printf("  %s %s port %d\n", ai->ai_family == AF_INET ? "A   " : "AAAA", text, port);
        if (service) CHECK(port == atoi(service), "port %d", port);
        if (family != AF_UNSPEC) CHECK(ai->ai_family == family, "family %d", ai->ai_family);
        n++;
    }
    freeaddrinfo(result);
    printf("getaddrinfo %s family %d: %d addresses in %lld ms\n", name, family, n, took);
    return n;
}

// Run busybox with the given arguments and return its output and status.
static char *run(char *const argv[], int *status) {
    static char out[8192];
    int p[2];
    if (pipe(p)) return strcpy(out, "pipe failed");
    pid_t pid = fork();
    if (!pid) {
        dup2(p[1], 1);
        dup2(p[1], 2);
        close(p[0]);
        execv("/usr/bin/busybox", argv);
        _exit(127);
    }
    close(p[1]);
    size_t n = 0;
    ssize_t r;
    while (n < sizeof out - 1 && (r = read(p[0], out + n, sizeof out - 1 - n)) > 0) n += r;
    out[n] = 0;
    close(p[0]);
    waitpid(pid, status, 0);
    printf("--- busybox %s %s (status %#x)\n%s---\n", argv[1], argv[2], *status, out);
    return out;
}

int main(void) {
    FILE *f = fopen("/etc/resolv.conf", "r");
    char line[128] = "";
    CHECK(f && fgets(line, sizeof line, f), "/etc/resolv.conf: %s", strerror(errno));
    CHECK(!strcmp(line, "nameserver 10.0.2.3\n"), "resolv.conf says %s", line);
    if (f) fclose(f);

    // A records only, then both families; the slirp forwarder passes AAAA
    // answers through even though the guest has no IPv6.
    CHECK(resolve("example.com", AF_INET, "443") > 0, "example.com A");
    CHECK(resolve("example.com", AF_UNSPEC, "80") > 0, "example.com any");
    // A trailing dot and a name with several labels.
    CHECK(resolve("www.example.com.", AF_INET, NULL) > 0, "www.example.com.");
    // /etc/hosts still answers first.
    CHECK(resolve("localhost", AF_INET, NULL) == 1, "localhost");
    // NXDOMAIN comes back as an answer, not a timeout.
    long long start = now_ms();
    int rc = resolve("does-not-exist.invalid", AF_INET, NULL);
    CHECK(rc == -(EAI_NONAME < 0 ? -EAI_NONAME : EAI_NONAME), "invalid name gave %d", rc);
    CHECK(now_ms() - start < 4000, "NXDOMAIN took %lld ms", now_ms() - start);

    // The old interface over the same resolver.
    struct hostent *he = gethostbyname("example.com");
    CHECK(he && he->h_addrtype == AF_INET && he->h_addr_list[0], "gethostbyname: %d", h_errno);
    if (he && he->h_addr_list[0])
        printf("gethostbyname example.com: %s\n", inet_ntoa(*(struct in_addr *)he->h_addr_list[0]));

    // Reverse lookup through the forwarder.
    struct sockaddr_in sin = {.sin_family = AF_INET};
    inet_pton(AF_INET, "10.0.2.2", &sin.sin_addr);
    char host[NI_MAXHOST];
    rc = getnameinfo((struct sockaddr *)&sin, sizeof sin, host, sizeof host, NULL, 0, NI_NUMERICHOST);
    CHECK(rc == 0 && !strcmp(host, "10.0.2.2"), "getnameinfo numeric: %s", gai_strerror(rc));

    int status;
    char *out = run((char *[]){"busybox", "nslookup", "example.com", NULL}, &status);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0, "nslookup status %#x", status);
    CHECK(strstr(out, "Server:\t\t10.0.2.3"), "nslookup server");
    CHECK(strstr(out, "Name:\texample.com\nAddress: "), "nslookup answer");
    out = run((char *[]){"busybox", "nslookup", "-type=a", "does-not-exist.invalid", NULL}, &status);
    CHECK(strstr(out, "NXDOMAIN"), "nslookup NXDOMAIN");

    if (failures) {
        printf("%d failures\n", failures);
        return 1;
    }
    printf("PASS\n");
    return 0;
}
