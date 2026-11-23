// C3: private file mappings the way ld.so maps a library: reserve the whole
// span from the file, map later segments over it with MAP_FIXED, map BSS
// anonymously over the tail and run code from the file mapping.
#define _GNU_SOURCE
#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <link.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/auxv.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static int fail(const char *what)
{
    printf("FAIL %s errno=%d\n", what, errno);
    return 1;
}

// Position independent and free of relocations, so a copy anywhere runs.
__attribute__((noinline, aligned(64))) long mix(long a, long b)
{
    return a * 31 + b;
}

static char file_copy[64 * 1024];

int main(void)
{
    int fd = open("/bin/mmap-file.elf", O_RDONLY | O_CLOEXEC);
    struct stat st;
    if (fd < 0 || fstat(fd, &st)) { return fail("open"); }
    ssize_t got = pread(fd, file_copy, sizeof file_copy, 0);
    if (got < 4096) { return fail("pread"); }

    // Find mix() in the file through the executable PT_LOAD that holds it.
    const ElfW(Phdr) *phdr = (const void *)getauxval(AT_PHDR);
    off_t mix_offset = -1;
    for (unsigned long i = 0; i < getauxval(AT_PHNUM); i++) {
        uintptr_t start = phdr[i].p_vaddr, address = (uintptr_t)mix;
        if (phdr[i].p_type == PT_LOAD && (phdr[i].p_flags & PF_X) && address >= start &&
            address < start + phdr[i].p_filesz) {
            mix_offset = phdr[i].p_offset + (address - start);
        }
    }
    if (mix_offset < 0) { return fail("mix offset"); }

    // 1. Reserve 16 pages from the start of the file, read-only.
    size_t span = 16 * 4096;
    unsigned char *map = mmap(NULL, span, PROT_READ, MAP_PRIVATE, fd, 0);
    if (map == MAP_FAILED) { return fail("mmap span"); }
    if (memcmp(map, file_copy, 4096)) { return fail("span contents"); }

    // 2. MAP_FIXED the page holding mix() executable at page 4 of the span.
    off_t page = mix_offset & ~4095L;
    unsigned char *text = mmap(map + 4 * 4096, 4096, PROT_READ | PROT_EXEC,
                               MAP_PRIVATE | MAP_FIXED, fd, page);
    if (text != map + 4 * 4096) { return fail("MAP_FIXED text"); }
    long (*copy)(long, long) = (long (*)(long, long))(text + (mix_offset - page));
    if (copy(3, 4) != 97) { return fail("call mapped code"); }

    // 3. A writable private segment: writes stay private to the mapping.
    unsigned char *data = mmap(map + 6 * 4096, 2 * 4096, PROT_READ | PROT_WRITE,
                               MAP_PRIVATE | MAP_FIXED, fd, 4096);
    if (data != map + 6 * 4096 || memcmp(data, file_copy + 4096, 4096)) {
        return fail("MAP_FIXED data");
    }
    data[0] ^= 0xFF;
    if (pread(fd, file_copy, 1, 4096) != 1 || (unsigned char)file_copy[0] == data[0]) {
        return fail("private write");
    }

    // 4. BSS: anonymous zero pages over the rest of the span.
    unsigned char *bss = mmap(map + 8 * 4096, 8 * 4096, PROT_READ | PROT_WRITE,
                              MAP_PRIVATE | MAP_FIXED | MAP_ANONYMOUS, -1, 0);
    if (bss != map + 8 * 4096) { return fail("MAP_FIXED bss"); }
    for (int i = 0; i < 8 * 4096; i++) {
        if (bss[i]) { return fail("bss not zero"); }
    }
    bss[100] = 1;

    // 5. RELRO-style mprotect over a file-backed page, then the whole span
    // becomes read-write-execute as for DT_TEXTREL.
    if (mprotect(data, 4096, PROT_READ)) { return fail("mprotect file page"); }
    if (mprotect(map, span, PROT_READ | PROT_WRITE | PROT_EXEC)) { return fail("mprotect span"); }
    if (copy(1, 1) != 32) { return fail("call after mprotect"); }
    data[0] = 1;

    // 6. Mapping past the end of the file reads zero.
    off_t last = (st.st_size - 1) & ~4095L;
    unsigned char *tail = mmap(NULL, 2 * 4096, PROT_READ, MAP_PRIVATE, fd, last);
    if (tail == MAP_FAILED) { return fail("mmap tail"); }
    size_t in_file = st.st_size - last;
    for (size_t i = in_file; i < 2 * 4096; i++) {
        if (tail[i]) { return fail("bytes past EOF"); }
    }

    // 7. A shared read-only mapping of the file also works.
    unsigned char *shared = mmap(NULL, 4096, PROT_READ, MAP_SHARED, fd, 0);
    if (shared == MAP_FAILED || memcmp(shared, map, 4)) { return fail("MAP_SHARED read-only"); }

    if (munmap(map, span) || munmap(tail, 2 * 4096) || munmap(shared, 4096)) {
        return fail("munmap");
    }
    close(fd);
    printf("PASS\n");
    return 0;
}
