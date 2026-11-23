// A1: anonymous PROT_EXEC mappings, RWX and W^X transitions via mprotect.
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

static int fail(const char *what)
{
    printf("FAIL %s errno=%d\n", what, errno);
    return 1;
}

int main(void)
{
    // mov eax, 42; ret
    static const unsigned char code[] = { 0xb8, 42, 0, 0, 0, 0xc3 };
    unsigned char *rwx = mmap(NULL, 4096, PROT_READ | PROT_WRITE | PROT_EXEC,
                              MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (rwx == MAP_FAILED) { return fail("mmap RWX"); }
    memcpy(rwx, code, sizeof code);
    if (((int (*)(void))rwx)() != 42) { return fail("call RWX"); }
    rwx[1] = 7;
    if (((int (*)(void))rwx)() != 7) { return fail("patch RWX"); }
    printf("RWX ok\n");

    unsigned char *rw = mmap(NULL, 8192, PROT_READ | PROT_WRITE,
                             MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (rw == MAP_FAILED) { return fail("mmap RW"); }
    memcpy(rw + 4096, code, sizeof code);
    if (mprotect(rw, 8192, PROT_READ | PROT_EXEC)) { return fail("mprotect RX"); }
    if (((int (*)(void))(rw + 4096))() != 42) { return fail("call RX"); }
    if (mprotect(rw, 8192, PROT_READ | PROT_WRITE | PROT_EXEC)) { return fail("mprotect RWX"); }
    rw[4097] = 9;
    if (((int (*)(void))(rw + 4096))() != 9) { return fail("call after RWX"); }
    if (mprotect(rw, 8192, PROT_EXEC)) { return fail("mprotect X only"); }
    if (mprotect(rw, 8192, PROT_NONE)) { return fail("mprotect NONE"); }
    printf("mprotect transitions ok\n");

    // Pages without PROT_EXEC must still fault when called.
    if (mprotect(rw, 8192, PROT_READ | PROT_WRITE)) { return fail("mprotect RW"); }
    pid_t child = fork();
    if (child < 0) { return fail("fork"); }
    if (!child) { _exit(((int (*)(void))(rw + 4096))() == 9 ? 3 : 4); }
    int status;
    if (waitpid(child, &status, 0) != child) { return fail("waitpid"); }
    if (!WIFSIGNALED(status) || WTERMSIG(status) != SIGSEGV) {
        printf("status=%#x\n", status);
        return fail("NX not enforced");
    }
    printf("NX enforced\n");
    printf("PASS\n");
    return 0;
}
