// Interface configuration (NETPLAN S4): SIOCGIF* ioctls for lo and eth0,
// /proc/net/dev and /proc/net/route, and busybox ifconfig and route reading
// them.
// net
// disk: busybox
#include <arpa/inet.h>
#include <errno.h>
#include <net/if.h>
#include <net/if_arp.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/wait.h>
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

static struct ifreq req(const char *name) {
    struct ifreq r;
    memset(&r, 0, sizeof r);
    strncpy(r.ifr_name, name, IFNAMSIZ - 1);
    return r;
}

static const char *addr(struct sockaddr *sa) {
    return inet_ntoa(((struct sockaddr_in *)sa)->sin_addr);
}

static void check_addr(int s, unsigned long op, const char *name, const char *want) {
    struct ifreq r = req(name);
    int rc = ioctl(s, op, &r);
    CHECK(rc == 0, "ioctl %#lx %s: %s", op, name, strerror(errno));
    if (rc == 0) {
        CHECK(r.ifr_addr.sa_family == AF_INET, "family %d", r.ifr_addr.sa_family);
        CHECK(!strcmp(addr(&r.ifr_addr), want), "%#lx %s: %s, want %s", op, name,
              addr(&r.ifr_addr), want);
    }
}

static void check_int(int s, unsigned long op, const char *name, int want) {
    struct ifreq r = req(name);
    int rc = ioctl(s, op, &r);
    CHECK(rc == 0, "ioctl %#lx %s: %s", op, name, strerror(errno));
    if (rc == 0) CHECK(r.ifr_ifindex == want, "%#lx %s: %d, want %d", op, name, r.ifr_ifindex, want);
}

// Read a whole file into a static buffer.
static char *slurp(const char *path) {
    static char buf[8192];
    FILE *f = fopen(path, "r");
    if (!f) {
        CHECK(0, "open %s: %s", path, strerror(errno));
        return "";
    }
    size_t n = fread(buf, 1, sizeof buf - 1, f);
    buf[n] = 0;
    fclose(f);
    return buf;
}

// Run busybox with the given applet, return its output.
static char *run(char *const argv[]) {
    static char out[8192];
    int p[2];
    pipe(p);
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
    int st;
    waitpid(pid, &st, 0);
    CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 0, "busybox %s status %#x", argv[1], st);
    printf("--- busybox %s %s\n%s---\n", argv[1], argv[2] ? argv[2] : "", out);
    return out;
}

int main(void) {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    CHECK(s >= 0, "socket: %s", strerror(errno));

    // SIOCGIFCONF: length query, then the two entries.
    struct ifconf ic = {0};
    CHECK(ioctl(s, SIOCGIFCONF, &ic) == 0, "SIOCGIFCONF null: %s", strerror(errno));
    CHECK(ic.ifc_len == 2 * (int)sizeof(struct ifreq), "ifc_len %d", ic.ifc_len);
    struct ifreq list[4];
    ic.ifc_len = sizeof list;
    ic.ifc_req = list;
    CHECK(ioctl(s, SIOCGIFCONF, &ic) == 0, "SIOCGIFCONF: %s", strerror(errno));
    CHECK(ic.ifc_len == 2 * (int)sizeof(struct ifreq), "ifc_len %d", ic.ifc_len);
    CHECK(!strcmp(list[0].ifr_name, "lo") && !strcmp(addr(&list[0].ifr_addr), "127.0.0.1"),
          "entry 0 %s %s", list[0].ifr_name, addr(&list[0].ifr_addr));
    CHECK(!strcmp(list[1].ifr_name, "eth0") && !strcmp(addr(&list[1].ifr_addr), "10.0.2.15"),
          "entry 1 %s %s", list[1].ifr_name, addr(&list[1].ifr_addr));
    // A buffer with room for one entry gets one.
    ic.ifc_len = sizeof(struct ifreq) + 10;
    CHECK(ioctl(s, SIOCGIFCONF, &ic) == 0 && ic.ifc_len == (int)sizeof(struct ifreq),
          "short SIOCGIFCONF len %d", ic.ifc_len);

    check_addr(s, SIOCGIFADDR, "eth0", "10.0.2.15");
    check_addr(s, SIOCGIFNETMASK, "eth0", "255.255.255.0");
    check_addr(s, SIOCGIFBRDADDR, "eth0", "10.0.2.255");
    check_addr(s, SIOCGIFADDR, "lo", "127.0.0.1");
    check_addr(s, SIOCGIFNETMASK, "lo", "255.0.0.0");
    check_int(s, SIOCGIFINDEX, "lo", 1);
    check_int(s, SIOCGIFINDEX, "eth0", 2);
    check_int(s, SIOCGIFMTU, "eth0", 1500);
    check_int(s, SIOCGIFMTU, "lo", 65536);
    check_int(s, SIOCGIFMETRIC, "eth0", 0);
    check_int(s, SIOCGIFTXQLEN, "eth0", 1000);

    struct ifreq r = req("eth0");
    CHECK(ioctl(s, SIOCGIFFLAGS, &r) == 0, "SIOCGIFFLAGS: %s", strerror(errno));
    CHECK(r.ifr_flags == (IFF_UP | IFF_BROADCAST | IFF_RUNNING | IFF_MULTICAST), "eth0 flags %#x",
          r.ifr_flags);
    r = req("lo");
    CHECK(ioctl(s, SIOCGIFFLAGS, &r) == 0, "SIOCGIFFLAGS lo: %s", strerror(errno));
    CHECK(r.ifr_flags == (IFF_UP | IFF_LOOPBACK | IFF_RUNNING), "lo flags %#x", r.ifr_flags);

    r = req("eth0");
    CHECK(ioctl(s, SIOCGIFHWADDR, &r) == 0, "SIOCGIFHWADDR: %s", strerror(errno));
    unsigned char *mac = (unsigned char *)r.ifr_hwaddr.sa_data;
    CHECK(r.ifr_hwaddr.sa_family == ARPHRD_ETHER, "hw family %d", r.ifr_hwaddr.sa_family);
    // QEMU's default station address.
    CHECK(mac[0] == 0x52 && mac[1] == 0x54 && mac[2] == 0 && mac[3] == 0x12 && mac[4] == 0x34 &&
              mac[5] == 0x56,
          "mac %02x:%02x:%02x:%02x:%02x:%02x", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    r = req("lo");
    CHECK(ioctl(s, SIOCGIFHWADDR, &r) == 0 && r.ifr_hwaddr.sa_family == ARPHRD_LOOPBACK,
          "lo hw family %d", r.ifr_hwaddr.sa_family);

    // Index to name, and the libc wrappers built on these ioctls.
    r = req("");
    r.ifr_ifindex = 2;
    CHECK(ioctl(s, SIOCGIFNAME, &r) == 0 && !strcmp(r.ifr_name, "eth0"), "SIOCGIFNAME %s",
          r.ifr_name);
    r.ifr_ifindex = 7;
    CHECK(ioctl(s, SIOCGIFNAME, &r) < 0 && errno == ENODEV, "SIOCGIFNAME 7: %s", strerror(errno));
    // musl's if_nametoindex opens an AF_UNIX SOCK_DGRAM socket, which the
    // kernel does not offer yet, so it is not checked here.

    // Errors: unknown interface, setters, a bad pointer, and a non-socket.
    r = req("eth1");
    CHECK(ioctl(s, SIOCGIFADDR, &r) < 0 && errno == ENODEV, "eth1: %s", strerror(errno));
    r = req("eth0");
    CHECK(ioctl(s, SIOCSIFADDR, &r) < 0 && errno == EOPNOTSUPP, "SIOCSIFADDR: %s",
          strerror(errno));
    r.ifr_flags = IFF_UP | IFF_BROADCAST | IFF_RUNNING | IFF_MULTICAST;
    CHECK(ioctl(s, SIOCSIFFLAGS, &r) == 0, "SIOCSIFFLAGS up: %s", strerror(errno));
    CHECK(ioctl(s, SIOCGIFADDR, (void *)8) < 0 && errno == EFAULT, "fault: %s", strerror(errno));
    CHECK(ioctl(0, SIOCGIFADDR, &r) < 0 && errno == ENOTTY, "console: %s", strerror(errno));
    // Interface ioctls also answer on AF_UNIX sockets.
    int u = socket(AF_UNIX, SOCK_STREAM, 0);
    r = req("eth0");
    CHECK(u >= 0 && ioctl(u, SIOCGIFINDEX, &r) == 0 && r.ifr_ifindex == 2, "AF_UNIX SIOCGIFINDEX: %s",
          strerror(errno));
    close(u);

    // Traffic shows up in /proc/net/dev: send a datagram first.
    struct sockaddr_in to = {.sin_family = AF_INET, .sin_port = htons(9)};
    inet_pton(AF_INET, "10.0.2.2", &to.sin_addr);
    CHECK(sendto(s, "x", 1, 0, (struct sockaddr *)&to, sizeof to) == 1, "sendto: %s",
          strerror(errno));

    char *dev = slurp("/proc/net/dev");
    printf("--- /proc/net/dev\n%s---\n", dev);
    CHECK(!strncmp(dev, "Inter-|   Receive", 17), "dev header");
    CHECK(strstr(dev, "\n    lo:       0       0    0    0    0     0          0         0 "),
          "lo row");
    char *eth = strstr(dev, "\n  eth0:");
    CHECK(eth != NULL, "eth0 row");
    if (eth) {
        unsigned long long v[16];
        int n = sscanf(eth + 8, "%llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu %llu",
                       &v[0], &v[1], &v[2], &v[3], &v[4], &v[5], &v[6], &v[7], &v[8], &v[9], &v[10],
                       &v[11], &v[12], &v[13], &v[14], &v[15]);
        CHECK(n == 16, "eth0 fields %d", n);
        CHECK(v[1] > 0 && v[0] >= v[1] * 42, "rx %llu bytes %llu packets", v[0], v[1]);
        CHECK(v[9] > 0 && v[8] >= v[9] * 42, "tx %llu bytes %llu packets", v[8], v[9]);
    }

    char *route = slurp("/proc/net/route");
    printf("--- /proc/net/route\n%s---\n", route);
    char *lines[4];
    int nl = 0;
    for (char *p = route; *p && nl < 4; nl++) {
        lines[nl] = p;
        char *e = strchr(p, '\n');
        CHECK(e && e - p == 127, "route line %d length %ld", nl, e ? (long)(e - p) : -1L);
        if (!e) break;
        p = e + 1;
    }
    CHECK(nl == 3, "route lines %d", nl);
    CHECK(!strncmp(lines[0], "Iface\tDestination\tGateway \tFlags", 32), "route header");
    if (nl == 3) {
        CHECK(!strncmp(lines[1], "eth0\t00000000\t0202000A\t0003\t0\t0\t0\t00000000\t0\t0\t0 ", 46),
              "default route");
        CHECK(!strncmp(lines[2], "eth0\t0002000A\t00000000\t0001\t0\t0\t0\t00FFFFFF\t0\t0\t0 ", 46),
              "subnet route");
    }

    char *out = run((char *[]){"busybox", "ifconfig", "-a", NULL});
    CHECK(strstr(out, "eth0      Link encap:Ethernet  HWaddr 52:54:00:12:34:56"), "ifconfig eth0");
    CHECK(strstr(out, "inet addr:10.0.2.15  Bcast:10.0.2.255  Mask:255.255.255.0"),
          "ifconfig eth0 inet");
    CHECK(strstr(out, "UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1"), "ifconfig flags");
    CHECK(strstr(out, "lo        Link encap:Local Loopback"), "ifconfig lo");
    CHECK(strstr(out, "inet addr:127.0.0.1  Mask:255.0.0.0"), "ifconfig lo inet");
    out = run((char *[]){"busybox", "route", "-n", NULL});
    CHECK(strstr(out, "0.0.0.0         10.0.2.2        0.0.0.0         UG    0      0        0 eth0"),
          "route default");
    CHECK(strstr(out, "10.0.2.0        0.0.0.0         255.255.255.0   U     0      0        0 eth0"),
          "route subnet");

    close(s);
    if (failures) {
        printf("%d failures\n", failures);
        return 1;
    }
    printf("PASS\n");
    return 0;
}
