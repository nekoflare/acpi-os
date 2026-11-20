#include "../../src/runtime.h"
#include <stddef.h>

#define REQUEST(section_name) __attribute__((used, section(section_name)))
#define LIMINE_ID(a, b) {0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, a, b}

/* Limine Boot Protocol request markers and base revision tag. */
REQUEST(".limine_requests_start")
static volatile uint64_t requests_start[] = {
    0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf, 0x785c6ed015d3e316, 0x181e920a7852b9d9
};
REQUEST(".limine_requests")
static volatile uint64_t base_revision[] = {
    0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, 6
};

struct rsdp_response {
    uint64_t revision;
    const void *address;
};

struct hhdm_response {
    uint64_t revision, offset;
};

struct memory_map_entry {
    uint64_t base, length, type;
};

struct memory_map_response {
    uint64_t revision, count;
    const struct memory_map_entry *const *entries;
};

REQUEST(".limine_requests")
static volatile struct {
    uint64_t id[4], revision;
    const struct rsdp_response *response;
} rsdp_request = { .id = LIMINE_ID(0xc5e77b6b397e7b43, 0x27637845accdcf3c) };

REQUEST(".limine_requests")
static volatile struct {
    uint64_t id[4], revision;
    const struct hhdm_response *response;
} hhdm_request = { .id = LIMINE_ID(0x48dcf1cb8ad2b852, 0x63984e959a98244b) };

REQUEST(".limine_requests")
static volatile struct {
    uint64_t id[4], revision;
    const struct memory_map_response *response;
} memory_map_request = { .id = LIMINE_ID(0x67cf3d9d378a806f, 0xe304acdfc50c3c62) };

struct framebuffer {
    void *address;
    uint64_t width, height, pitch;
    uint16_t bpp;
    uint8_t memory_model;
    uint8_t red_size, red_shift, green_size, green_shift, blue_size, blue_shift;
};

struct framebuffer_response {
    uint64_t revision, count;
    const struct framebuffer *const *buffers;
};

REQUEST(".limine_requests")
static volatile struct {
    uint64_t id[4], revision;
    const struct framebuffer_response *response;
} framebuffer_request = { .id = LIMINE_ID(0x9d5827dcd881dd75, 0xa3148604f6fab11b) };

struct module_file {
    uint64_t revision;
    const uint8_t *address;
    uint64_t size;
    const char *path;
    const char *command;
};

struct module_response {
    uint64_t revision, count;
    const struct module_file *const *files;
};

REQUEST(".limine_requests")
static volatile struct {
    uint64_t id[4], revision;
    const struct module_response *response;
} module_request = { .id = LIMINE_ID(0x3e7e279702be32af, 0xca1c4f3bd1280cee) };

REQUEST(".limine_requests_end")
static volatile uint64_t requests_end[] = {
    0xadc0e0531bb10d03, 0x9572709f31764c62
};

extern const uint8_t acpi_initramfs_start[], acpi_initramfs_end[];
int32_t aml_KERN(aml_context *, uint64_t *, uint64_t rsdp,
                 uint64_t initramfs, uint64_t initramfs_size,
                 uint64_t module_name, uint64_t module_command,
                 uint64_t boot_addresses);

enum {
    USABLE = 0,
    ACPI_RECLAIMABLE = 2,
    ACPI_NVS = 3,
    RESERVED_MAPPED = 8,
};

#define PAGE_SIZE UINT64_C(4096)

static const struct memory_map_response *boot_memory_map;
static uint64_t direct_map_offset;

static const struct framebuffer *console_framebuffer;
static uint32_t console_white;
static uint64_t framebuffer_shadow;
static uint64_t shadow_range = UINT64_MAX;
static uint64_t shadow_base;

uint64_t acpi_page_range(uint64_t index, uint64_t field);

static void reserve_framebuffer_shadow(uint64_t bytes)
{
    if (!direct_map_offset || !boot_memory_map || bytes > UINT64_MAX - (PAGE_SIZE - 1))
        return;

    uint64_t size = (bytes + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
    for (uint64_t i = 0; i < boot_memory_map->count; ++i) {
        uint64_t first = acpi_page_range(i, 0);
        uint64_t limit = acpi_page_range(i, 1);
        if (first && size <= limit - first) {
            // Carve cached RAM from the top of this range before ASL allocates pages.
            shadow_base = limit - size;
            shadow_range = i;
            framebuffer_shadow = direct_map_offset + shadow_base;
            return;
        }
    }
}

static uint32_t framebuffer_mask(unsigned size, unsigned shift, unsigned bpp)
{
    if (!size || shift >= bpp || size > bpp - shift)
        return 0;
    return (uint32_t)(((UINT64_C(1) << size) - 1) << shift);
}

static void select_framebuffer(void)
{
    const struct framebuffer_response *response = framebuffer_request.response;
    if (!response)
        return;

    for (uint64_t i = 0; i < response->count; ++i) {
        const struct framebuffer *fb = response->buffers[i];
        if (!fb || !fb->address || fb->memory_model != 1 ||
            (fb->bpp != 24 && fb->bpp != 32) || fb->width < 8 || fb->height < 16)
            continue;

        uint64_t bytes = fb->bpp / 8;
        if (fb->width > fb->pitch / bytes ||
            fb->height > (UINT64_MAX - (uintptr_t)fb->address) / fb->pitch)
            continue;

        uint32_t red = framebuffer_mask(fb->red_size, fb->red_shift, fb->bpp);
        uint32_t green = framebuffer_mask(fb->green_size, fb->green_shift, fb->bpp);
        uint32_t blue = framebuffer_mask(fb->blue_size, fb->blue_shift, fb->bpp);
        if (!red || !green || !blue || (red & green) || (red & blue) || (green & blue))
            continue;

        console_framebuffer = fb;
        console_white = red | green | blue;
        reserve_framebuffer_shadow(fb->pitch * fb->height);
        return;
    }
}

/* Return the validated geometry and packed foreground color to ASL. */
uint64_t acpi_framebuffer_info(uint64_t field)
{
    const struct framebuffer *fb = console_framebuffer;
    if (!fb)
        return 0;

    switch (field) {
    case 0: return (uintptr_t)fb->address;
    case 1: return fb->width;
    case 2: return fb->height;
    case 3: return fb->pitch;
    case 4: return fb->bpp / 8;
    case 5: return console_white;
    case 6: return fb->red_shift;
    case 7: return fb->green_shift;
    case 8: return fb->blue_shift;
    case 9: return fb->red_size;
    case 10: return fb->green_size;
    case 11: return fb->blue_size;
    default: return 0;
    }
}

/* Copy forward for scrolling, or clear when source is zero. */
static void framebuffer_transfer(uint64_t destination, uint64_t source, uint64_t bytes)
{
    if (!((destination | source) & 3)) {
        uint64_t words = bytes / 4;
        if (source) {
            __asm__ volatile("rep movsl" : "+D"(destination), "+S"(source), "+c"(words)
                             : : "memory");
        } else {
            __asm__ volatile("rep stosl" : "+D"(destination), "+c"(words) : "a"(0) : "memory");
        }
        bytes %= 4;
    }

    if (source) {
        __asm__ volatile("rep movsb" : "+D"(destination), "+S"(source), "+c"(bytes)
                         : : "memory");
    } else {
        __asm__ volatile("rep stosb" : "+D"(destination), "+c"(bytes) : "a"(0) : "memory");
    }
}

static uint64_t shadow_address(uint64_t address)
{
    return framebuffer_shadow + (address - (uintptr_t)console_framebuffer->address);
}

/* Draw eight pixels from an LSB-first glyph row, with ink in the low word. */
uint64_t acpi_pixel_row(uint64_t address, uint64_t bits, uint64_t colors, uint64_t bytes)
{
    uint32_t ink = (uint32_t)colors;
    uint32_t paper = (uint32_t)(colors >> 32);
    uint64_t target = framebuffer_shadow ? shadow_address(address) : address;
    if (bytes == 4 && !(target & 3)) {
        volatile uint32_t *pixels = (volatile uint32_t *)target;
        for (unsigned i = 0; i < 8; ++i)
            pixels[i] = (bits & (1u << i)) ? ink : paper;
    } else {
        volatile uint8_t *pixels = (volatile uint8_t *)target;
        for (unsigned i = 0; i < 8; ++i) {
            uint64_t color = (bits & (1u << i)) ? ink : paper;
            for (uint64_t byte = 0; byte < bytes; ++byte)
                *pixels++ = (uint8_t)(color >> (8 * byte));
        }
    }
    if (framebuffer_shadow)
        framebuffer_transfer(address, target, 8 * bytes);
    return 0;
}

uint64_t acpi_framebuffer_blit(uint64_t destination, uint64_t source, uint64_t bytes)
{
    if (!console_framebuffer)
        return 0;
    const uint64_t framebuffer_start = (uintptr_t)console_framebuffer->address;
    const uint64_t framebuffer_size = console_framebuffer->pitch * console_framebuffer->height;
    const uint64_t framebuffer_end = framebuffer_start + framebuffer_size;
    if (destination < framebuffer_start || destination > framebuffer_end ||
        bytes > framebuffer_end - destination) {
        if (source >= framebuffer_start && source <= framebuffer_end &&
            bytes <= framebuffer_end - source)
            framebuffer_transfer(destination, framebuffer_shadow ? shadow_address(source) : source,
                                 bytes);
        return 0;
    }

    if (framebuffer_shadow) {
        uint64_t target = shadow_address(destination);
        if (source >= framebuffer_start && source <= framebuffer_end &&
            bytes <= framebuffer_end - source)
            source = shadow_address(source);
        else if (source) {
            framebuffer_transfer(target, source, bytes);
            source = target;
        }
        framebuffer_transfer(target, source, bytes);
        source = source ? target : 0;
    }
    framebuffer_transfer(destination, source, bytes);
    return 0;
}

/* Select an allocator boundary (0–1) or a raw Limine field (2–4). */
uint64_t acpi_page_range(uint64_t index, uint64_t field)
{
    if (!boot_memory_map || index >= boot_memory_map->count)
        return UINT64_MAX;

    const struct memory_map_entry *entry = boot_memory_map->entries[index];
    switch (field) {
    case 2: return entry->base;
    case 3: return entry->length;
    case 4: return entry->type;
    }

    if (entry->type != USABLE || entry->length > UINT64_MAX - entry->base ||
        entry->base > UINT64_MAX - (PAGE_SIZE - 1))
        return 0;

    uint64_t first = (entry->base + PAGE_SIZE - 1) & ~(PAGE_SIZE - 1);
    uint64_t limit = (entry->base + entry->length) & ~(PAGE_SIZE - 1);
    if (index == shadow_range)
        limit = shadow_base;
    if (!first)
        first = PAGE_SIZE;
    if (first >= limit || limit - 1 > UINT64_MAX - direct_map_offset)
        return 0;

    return field ? limit : first;
}

uint64_t acpi_page_root(void)
{
    uint64_t cr4, cr3;
    __asm__ volatile("mov %%cr4, %0" : "=r"(cr4));
    if (!boot_memory_map || (cr4 & (UINT64_C(1) << 12))) /* LA57 */
        return 0;

    __asm__ volatile("mov %%cr3, %0" : "=r"(cr3) : : "memory");
    return cr3 & UINT64_C(0x000ffffffffff000);
}

uint64_t acpi_clear_page(uint64_t address)
{
    uint64_t *page = (uint64_t *)address;
    for (uint64_t i = 0; i < PAGE_SIZE / sizeof(*page); ++i)
        page[i] = 0;
    return 0;
}

/* Copy between disjoint, already mapped kernel addresses. */
uint64_t acpi_copy_memory(uint64_t destination, uint64_t source, uint64_t length)
{
    __asm__ volatile("rep movsb" : "+D"(destination), "+S"(source), "+c"(length) : : "memory");
    return 0;
}

uint64_t acpi_invalidate_page(uint64_t address)
{
    __asm__ volatile("invlpg (%0)" : : "r"(address) : "memory");
    return 0;
}

static bool acpi_byte_mapped(uint64_t address)
{
    for (uint64_t i = 0; i < boot_memory_map->count; ++i) {
        const struct memory_map_entry *entry = boot_memory_map->entries[i];
        if (address < entry->base)
            break;
        if ((entry->type == ACPI_RECLAIMABLE || entry->type == ACPI_NVS ||
             entry->type == RESERVED_MAPPED) && address - entry->base < entry->length)
            return true;
    }
    return false;
}

/* Read little-endian firmware bytes through Limine's direct map. */
uint64_t acpi_read_memory(uint64_t address, uint64_t width)
{
    if (!boot_memory_map || !address || (width != 1 && width != 4 && width != 8) ||
        address > UINT64_MAX - direct_map_offset ||
        width - 1 > UINT64_MAX - direct_map_offset - address)
        return UINT64_MAX;

    uint64_t value = 0;
    for (uint64_t i = 0; i < width; ++i) {
        if (!acpi_byte_mapped(address + i))
            return UINT64_MAX;
        const uint8_t *byte = (const uint8_t *)(direct_map_offset + address + i);
        value |= (uint64_t)*byte << (i * 8);
    }
    return value;
}

extern const unsigned char acpi_vector_entries[];
volatile uint8_t acpi_irq_pending;

static const struct module_file *boot_module(void)
{
    const struct module_response *response = module_request.response;
    return response && response->count ? response->files[0] : NULL;
}

static const char *boot_module_name(const struct module_file *file)
{
    if (!file || !file->path)
        return "";
    const char *name = file->path;
    for (const char *cursor = name; *cursor; ++cursor)
        if (*cursor == '/')
            name = cursor + 1;
    return name;
}

uint64_t acpi_image_word(uint64_t offset, uint64_t width)
{
    const struct module_file *file = boot_module();
    if (!file)
        return UINT64_MAX;
    if (!width)
        return file->size;
    if ((width != 1 && width != 2 && width != 4 && width != 8) ||
        offset > file->size || width > file->size - offset)
        return UINT64_MAX;

    uint64_t value = 0;
    for (uint64_t i = 0; i < width; ++i)
        value |= (uint64_t)file->address[offset + i] << (i * 8);
    return value;
}

uint64_t acpi_image_copy(uint64_t address, uint64_t offset, uint64_t length)
{
    const struct module_file *file = boot_module();
    if (!file || offset > file->size || length > file->size - offset)
        return 0;
    uint8_t *out = (uint8_t *)address;
    for (uint64_t i = 0; i < length; ++i)
        out[i] = file->address[offset + i];
    return 1;
}

uint64_t acpi_virtual_byte(uint64_t address)
{
    return *(const volatile uint8_t *)address;
}

uint64_t acpi_store_byte(uint64_t address, uint64_t value)
{
    *(volatile uint8_t *)address = (uint8_t)value;
    return 0;
}

uint64_t acpi_load_tr(uint64_t selector)
{
    __asm__ volatile("ltr %0" : : "r"((uint16_t)selector) : "memory");
    return 0;
}

extern void acpi_syscall_entry(void);

extern void acpi_task_exit(void);
extern void acpi_task_test(uint64_t *);

uint64_t acpi_port_io(uint64_t address, uint64_t width, uint64_t value)
{
    uint16_t port = (uint16_t)address;
    uint32_t word;
    if (value == UINT64_MAX) {
        switch (width) {
        case 1: {
            uint8_t byte;
            __asm__ volatile("inb %1, %0" : "=a"(byte) : "Nd"(port) : "memory");
            return byte;
        }
        case 2: {
            uint16_t half;
            __asm__ volatile("inw %1, %0" : "=a"(half) : "Nd"(port) : "memory");
            return half;
        }
        case 4:
            __asm__ volatile("inl %1, %0" : "=a"(word) : "Nd"(port) : "memory");
            return word;
        }
    } else {
        switch (width) {
        case 1:
            __asm__ volatile("outb %0, %1" : : "a"((uint8_t)value), "Nd"(port) : "memory");
            break;
        case 2:
            __asm__ volatile("outw %0, %1" : : "a"((uint16_t)value), "Nd"(port) : "memory");
            break;
        case 4:
            __asm__ volatile("outl %0, %1" : : "a"((uint32_t)value), "Nd"(port) : "memory");
            break;
        }
    }
    return 0;
}

uint64_t acpi_mmio_dword(uint64_t address, uint64_t value)
{
    volatile uint32_t *word = (volatile uint32_t *)address;
    if (value == UINT64_MAX)
        return *word;
    *word = (uint32_t)value;
    return 0;
}

uint64_t acpi_has_apic(void)
{
    uint32_t eax = 1, ebx, ecx, edx;
    __asm__ volatile("cpuid" : "+a"(eax), "=b"(ebx), "=c"(ecx), "=d"(edx));
    return (edx >> 9) & 1;
}

uint64_t acpi_apic_msr(uint64_t index, uint64_t value)
{
    uint32_t low, high;
    if (value == UINT64_MAX) {
        __asm__ volatile("rdmsr" : "=a"(low), "=d"(high) : "c"((uint32_t)index) : "memory");
        return low | ((uint64_t)high << 32);
    }
    low = (uint32_t)value;
    high = (uint32_t)(value >> 32);
    __asm__ volatile("wrmsr" : : "a"(low), "d"(high), "c"((uint32_t)index) : "memory");
    return 0;
}

static uint64_t read_tsc(void)
{
    uint32_t low, high;
    __asm__ volatile("rdtsc" : "=a"(low), "=d"(high));
    return low | ((uint64_t)high << 32);
}

/* Wait for an interrupt when no task is currently running. */
uint64_t acpi_wait_irq(uint64_t cycles)
{
    acpi_irq_pending = 0;
    if (cycles) {
        uint64_t start = read_tsc();
        __asm__ volatile("sti" : : : "memory");
        while (!acpi_irq_pending && read_tsc() - start < cycles)
            __asm__ volatile("pause");
        __asm__ volatile("cli" : : : "memory");
    } else {
        __asm__ volatile("sti; hlt; cli" : : : "memory");
    }
    return acpi_irq_pending;
}

static int32_t region_access(void *userdata, const char *path, uint8_t space,
                           uint64_t address, uint8_t width, bool write, uint64_t *value)
{
    (void)userdata;
    (void)path;
    if (space == 0 && width == 8 && !(address & 7)) {
        volatile uint64_t *word = (volatile uint64_t *)address;
        if (write)
            *word = *value;
        else
            *value = *word;
        return AML_OK;
    }
    if (space == 1 && width == 2 && (address == 0x1CE || address == 0x1CF)) {
        uint16_t word;
        if (write) {
            if (address == 0x1CF)
                __asm__ volatile("sfence" : : : "memory");
            __asm__ volatile("outw %0, %1" : : "a"((uint16_t)*value), "Nd"((uint16_t)address) : "memory");
        } else {
            __asm__ volatile("inw %1, %0" : "=a"(word) : "Nd"((uint16_t)address));
            *value = word;
        }
        return AML_OK;
    }
    if (space == 1 && width == 4 && (address == 0xCF8 || address == 0xCFC)) {
        uint32_t word;
        if (write)
            __asm__ volatile("outl %0, %1" : : "a"((uint32_t)*value), "Nd"((uint16_t)address));
        else {
            __asm__ volatile("inl %1, %0" : "=a"(word) : "Nd"((uint16_t)address));
            *value = word;
        }
        return AML_OK;
    }
    if (space != 1 || width != 1 ||
        !((address >= 0x3F8 && address <= 0x3FF) ||
          address == 0x40 || address == 0x43 ||
          address == 0x60 || address == 0x64 ||
          address == 0x21 || address == 0xA1))
        return AML_INVALID_ARGUMENT;

    uint16_t port = (uint16_t)address;
    uint8_t byte;
    if (write) {
        byte = (uint8_t)*value;
        __asm__ volatile("outb %0, %1" : : "a"(byte), "Nd"(port));
    } else {
        __asm__ volatile("inb %1, %0" : "=a"(byte) : "Nd"(port));
        *value = byte;
    }
    return AML_OK;
}

_Noreturn void _start(void)
{
    if (base_revision[2] == 0) {
        const struct rsdp_response *rsdp = rsdp_request.response;
        const struct hhdm_response *hhdm = hhdm_request.response;
        uint64_t rsdp_physical = 0;
        if (hhdm) {
            direct_map_offset = hhdm->offset;
            boot_memory_map = memory_map_request.response;
            if (rsdp && (uintptr_t)rsdp->address > direct_map_offset)
                rsdp_physical = (uintptr_t)rsdp->address - direct_map_offset;
        }
        select_framebuffer();
        const aml_host host = {.region_access = region_access};
        aml_context *ctx = aml_context_create_with_host(&host);
        uint64_t result;
        if (ctx) {
            const struct module_file *module = boot_module();
            /* Keep this order in sync with the ASL KERN boot handoff. */
            const uint64_t boot_addresses[] = {
                direct_map_offset,
                (uintptr_t)acpi_vector_entries,
                (uintptr_t)acpi_syscall_entry,
                (uintptr_t)acpi_task_exit,
                (uintptr_t)acpi_task_test,
            };
            aml_KERN(ctx, &result, rsdp_physical, (uintptr_t)acpi_initramfs_start,
                     (uintptr_t)acpi_initramfs_end - (uintptr_t)acpi_initramfs_start,
                     (uintptr_t)boot_module_name(module),
                     module ? (uintptr_t)module->command : 0,
                     (uintptr_t)boot_addresses);
        }
    }
    for (;;)
        __asm__ volatile("cli; hlt");
}
