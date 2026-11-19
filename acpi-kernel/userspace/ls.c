/* Standalone Linux x86-64 ELF utility for the ACPI kernel's flat initramfs. */
#include <stddef.h>
#include <stdint.h>

enum {
    SYS_WRITE = 1,
    SYS_CLOSE = 3,
    SYS_GETDENTS64 = 217,
    SYS_OPENAT = 257,
    AT_FDCWD = -100,
    O_DIRECTORY = 0x10000,
};

static long syscall3(long number, long a, long b, long c)
{
    __asm__ volatile("syscall" : "+a"(number) : "D"(a), "S"(b), "d"(c)
                     : "rcx", "r11", "memory");
    return number;
}

static int write_all(int fd, const char *text, size_t size)
{
    while (size) {
        long written = syscall3(SYS_WRITE, fd, (long)text, (long)size);
        if (written == -4) /* EINTR */
            continue;
        if (written <= 0)
            return 1;
        text += written;
        size -= (size_t)written;
    }
    return 0;
}

static int list_directory(const char *path, int all)
{
    long fd = syscall3(SYS_OPENAT, AT_FDCWD, (long)path, O_DIRECTORY);
    if (fd < 0) {
        static const char error[] = "ls: cannot open directory\n";
        write_all(2, error, sizeof(error) - 1);
        return 1;
    }

    unsigned char entries[1024];
    int result = 0;
    for (;;) {
        long count = syscall3(SYS_GETDENTS64, fd, (long)entries, sizeof(entries));
        if (count == -4)
            continue;
        if (count <= 0) {
            if (count < 0) {
                static const char error[] = "ls: cannot read directory\n";
                write_all(2, error, sizeof(error) - 1);
                result = 1;
            }
            break;
        }
        size_t offset = 0;
        while (offset < (size_t)count) {
            const unsigned char *entry = entries + offset;
            if ((size_t)count - offset < 20) {
                result = 1;
                break;
            }
            size_t size = (size_t)entry[16] | ((size_t)entry[17] << 8);
            if (size < 20 || size > (size_t)count - offset) {
                result = 1;
                break;
            }
            const char *name = (const char *)entry + 19;
            size_t length = 0;
            while (length < size - 19 && name[length])
                ++length;
            if (length == size - 19) {
                result = 1;
                break;
            }
            if ((all || name[0] != '.') &&
                (write_all(1, name, length) || write_all(1, "\n", 1))) {
                result = 1;
                break;
            }
            offset += size;
        }
        if (result)
            break;
    }
    syscall3(SYS_CLOSE, fd, 0, 0);
    return result;
}

int ls_main(size_t argc, char **argv)
{
    size_t index = 1;
    int all = 0;
    if (index < argc && argv[index][0] == '-' &&
        argv[index][1] == 'a' && argv[index][2] == '\0') {
        all = 1;
        ++index;
    }
    if (argc - index > 1 || (index < argc && argv[index][0] == '-')) {
        static const char usage[] = "Usage: ls [-a] [directory]\n";
        write_all(2, usage, sizeof(usage) - 1);
        return 2;
    }
    return list_directory(index < argc ? argv[index] : ".", all);
}

__asm__(".text\n"
        ".global _start\n"
        ".type _start,@function\n"
        "_start:\n"
        "movq (%rsp), %rdi\n"
        "leaq 8(%rsp), %rsi\n"
        "andq $-16, %rsp\n"
        "call ls_main\n"
        "movl %eax, %edi\n"
        "movl $60, %eax\n"
        "syscall\n"
        "ud2\n"
        ".size _start, .-_start\n"
        ".section .note.GNU-stack,\"\",@progbits\n"
        ".text\n");
