// A dynamically linked PIE: the kernel starts /lib/ld-musl-x86_64.so.1,
// which loads this program, resolves its libc symbols and calls main.
#include <dlfcn.h>
#include <stdio.h>
#include <sys/auxv.h>

int main(void)
{
    Dl_info info;
    dladdr((void *)printf, &info);
    printf("Hello from a dynamically linked program.\n");
    printf("printf comes from %s, ld.so is at %#lx\n", info.dli_fname, getauxval(AT_BASE));
    return 0;
}
