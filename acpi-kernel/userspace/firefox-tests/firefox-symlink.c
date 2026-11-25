// Firefox locks its profile with a symlink named "lock" whose target is
// "<ip>:+<pid>". The kernel wrote such short (fast) symlinks with the
// extents flag still set, and e2fsck rejected the desktop's volume. Make
// short and long symlinks, remove one of each, and let the runner's e2fsck
// check the volume.
// disk: busybox
// disk-rw
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int failures;

#define CHECK(cond, ...) do { \
    if (!(cond)) { printf("FAIL line %d: ", __LINE__); printf(__VA_ARGS__); \
        printf(" (errno=%d)\n", errno); failures++; } } while (0)

static void make_link(const char *target, const char *path)
{
    char buf[256];
    struct stat st;
    CHECK(symlink(target, path) == 0, "symlink %s", path);
    ssize_t n = readlink(path, buf, sizeof buf);
    CHECK(n == (ssize_t)strlen(target) && !memcmp(buf, target, n), "readlink %s", path);
    CHECK(lstat(path, &st) == 0 && S_ISLNK(st.st_mode) && st.st_size == (off_t)strlen(target),
        "lstat %s", path);
}

int main(void)
{
    const char *longer = "/a/target/path/that/is/longer/than/the/sixty/bytes/an/inode/holds";
    CHECK(mkdir("/tmp/profile", 0700) == 0, "mkdir");
    make_link("127.0.0.1:+1234", "/tmp/profile/lock");
    make_link(longer, "/tmp/profile/long");
    make_link("127.0.0.1:+5678", "/tmp/profile/gone");
    make_link(longer, "/tmp/profile/gone-long");
    CHECK(unlink("/tmp/profile/gone") == 0, "unlink short");
    CHECK(unlink("/tmp/profile/gone-long") == 0, "unlink long");
    CHECK(symlink("x", "/tmp/profile/lock") == -1 && errno == EEXIST, "EEXIST");
    sync();

    if (failures) {
        printf("%d failures\n", failures);
        return 1;
    }
    printf("PASS\n");
    return 0;
}
