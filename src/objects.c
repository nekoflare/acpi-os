#include "runtime.h"

#include <ctype.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef aml_value value;
enum { SLOT_REF = 0x100, ELEMENT_REF, BYTE_REF, FIELD, UNINITIALIZED, REGION, REGION_FIELD, DYNAMIC_SLOT, RETIRED_SLOT };
enum { NAMESPACE_OBJECT = 0x300, NAMESPACE_OBJECT_END = NAMESPACE_OBJECT + 15 };
enum { CLONE = 0x100, READ, STORE_SLOT, STORE_NAMED, STORE_REF, COPY_SLOT,
       BUFFER, PACKAGE, PACKAGE_ELEMENT, FIELD_CREATE, STRING, TYPE, EXPORT, TIMER, DELAY, NOTIFY, EVENT_CONTROL, EVENT_WAIT, MUTEX_ACQUIRE, MUTEX_RELEASE, REGION_CREATE, REGION_FIELD_CREATE, LOAD_PATHS, LOAD_TABLE, LOAD, UNLOAD, NAMESPACE_REF, OSI, INIT_NAMED, UNRESOLVED_EXTERNAL, INDEX_READ };
enum { FOLLOW_CAST = 0x200, FOLLOW_COPY };

typedef struct allocation {
    struct allocation *next;
    size_t size;
    bool marked;
    max_align_t storage[];
} allocation;

struct aml_context {
    uint64_t steps;
    allocation *allocations;
    uint64_t allocated;
    uint64_t integer_bytes;
    uint64_t slot_count;
    uint32_t sync_level;
    bool global_lock_held;
    aml_host host;
    value *held_mutex;
    value slots[];
};

/* The generated LLVM context has the same prefix and inline slot array. */
_Static_assert(sizeof(void *) == 8 && sizeof(value) == 24 &&
               offsetof(aml_context, slots) == 136, "unsupported runtime ABI");

typedef struct {
    uint8_t *bytes;
    uint64_t start, bits;
    bool force_buffer;
} bit_field;

typedef struct {
    const char *path;
    uint64_t base, length;
    uint8_t space;
} region;

typedef struct {
    uint64_t index;
    const value *local;
} field_binding;

typedef struct {
    field_binding region, selector, data;
    uint64_t bank, start, bits;
    uint8_t flags;
} region_field;

void aml_objects_collect(aml_context *ctx);

static int store(aml_context *ctx, value *dst, value src, unsigned mode, unsigned depth);

static value integer(uint64_t n)
{
    return (value){.integer_or_length = n};
}

static void *allocate(aml_context *ctx, size_t size)
{
    const uint64_t limit = ctx->host.allocation_limit ? ctx->host.allocation_limit : 64u * 1024u * 1024u;
    if (!size)
        size = 1;
    if (limit < sizeof(allocation) || size > SIZE_MAX - sizeof(allocation) ||
        size > limit - sizeof(allocation) ||
        ctx->allocated > limit - sizeof(allocation) - size)
        return NULL;
    allocation *entry = calloc(1, sizeof(*entry) + size);
    if (!entry)
        return NULL;
    entry->next = ctx->allocations;
    entry->size = sizeof(*entry) + size;
    ctx->allocated += entry->size;
    ctx->allocations = entry;
    return entry->storage;
}

void aml_context_set_host(aml_context *ctx, const aml_host *host)
{
    if (ctx)
        ctx->host = host ? *host : (aml_host){0};
}

/* Mutex slots store the sync level in the low four bits and the recursive
 * acquisition count above it. The data pointer links held mutexes. */
enum { MUTEX_LEVEL_MASK = 15, MUTEX_ACQUISITION = 16 };

static uint32_t mutex_level(const value *mutex)
{
    return mutex ? mutex->integer_or_length & MUTEX_LEVEL_MASK : 0;
}

uint32_t aml_sync_level(const aml_context *ctx)
{
    uint32_t level = mutex_level(ctx->held_mutex);
    return level > ctx->sync_level ? level : ctx->sync_level;
}

void aml_release_mutexes(aml_context *ctx)
{
    while (ctx->held_mutex) {
        value *mutex = ctx->held_mutex;
        ctx->held_mutex = (value *)mutex->data;
        *mutex = integer(mutex_level(mutex));
    }
}

static void unlink_mutex(aml_context *ctx, value *mutex)
{
    value *previous = NULL;
    for (value *held = ctx->held_mutex; held; held = (value *)held->data) {
        if (held == mutex) {
            if (previous)
                previous->data = mutex->data;
            else
                ctx->held_mutex = (value *)mutex->data;
            mutex->data = NULL;
            return;
        }
        previous = held;
    }
}

static void release_mutex(aml_context *ctx, value *mutex)
{
    uint32_t level = mutex_level(mutex);
    if (mutex->integer_or_length < MUTEX_ACQUISITION || level != aml_sync_level(ctx))
        return;
    mutex->integer_or_length -= MUTEX_ACQUISITION;
    if (mutex->integer_or_length < MUTEX_ACQUISITION)
        unlink_mutex(ctx, mutex);
}

void aml_objects_destroy(aml_context *ctx)
{
    if (!ctx)
        return;
    for (allocation *entry = ctx->allocations; entry;) {
        allocation *next = entry->next;
        free(entry);
        entry = next;
    }
    free(ctx);
}

void *aml_object_slot(aml_context *ctx)
{
    value *slot = allocate(ctx, sizeof(*slot));
    if (slot)
        slot->type = UNINITIALIZED;
    return slot;
}

void aml_retire_region(value *slot)
{
    *slot = (value){.type = RETIRED_SLOT};
}

static allocation *allocation_for(const void *data)
{
    return (allocation *)((unsigned char *)data - offsetof(allocation, storage));
}

typedef struct {
    uint64_t first, count, state;
    int32_t (*initialize)(aml_context *, value *, uint32_t);
    const uint8_t *bytes;
    uint64_t length;
    const uint64_t *dependencies;
    uint64_t dependency_count;
} dynamic_table;

extern const uint64_t aml_dynamic_count;
extern const dynamic_table aml_dynamic_tables[];

bool aml_table_active(const aml_context *ctx, uint64_t state)
{
    return ctx->slots[state].integer_or_length != 0;
}

bool aml_table_enter(aml_context *ctx, uint64_t state)
{
    if (!aml_table_active(ctx, state))
        return false;
    ++ctx->slots[state + 1].integer_or_length;
    return true;
}

void aml_table_leave(aml_context *ctx, uint64_t state)
{
    --ctx->slots[state + 1].integer_or_length;
}

void *aml_dynamic_slot(aml_context *ctx, uint64_t index)
{
    value *entry = &ctx->slots[index];
    return entry->type == DYNAMIC_SLOT ? (value *)entry->data : NULL;
}

static value *bound_slot(aml_context *ctx, uint64_t index)
{
    value *entry = &ctx->slots[index];
    if (entry->type == DYNAMIC_SLOT)
        return (value *)entry->data;
    return entry->type == RETIRED_SLOT ? NULL : entry;
}

static void retire_table(aml_context *ctx, const dynamic_table *table)
{
    for (uint64_t i = 0; i < table->count; ++i) {
        value *entry = &ctx->slots[table->first + i];
        if (entry->type == DYNAMIC_SLOT) {
            value *slot = (value *)entry->data;
            /* Unlink before clearing the slot, which may hold the next
             * mutex in the caller's acquisition list. */
            unlink_mutex(ctx, slot);
            *slot = (value){.type = RETIRED_SLOT};
        }
        *entry = (value){.type = RETIRED_SLOT};
    }
    ctx->slots[table->state] = integer(0);
}

static int32_t activate_table(aml_context *ctx, const dynamic_table *table, uint32_t depth)
{
    if (aml_table_active(ctx, table->state))
        return AML_TABLE_ALREADY_LOADED;
    for (uint64_t i = 0; i < table->dependency_count; ++i) {
        uint64_t state = aml_dynamic_tables[table->dependencies[i]].state;
        if (!aml_table_active(ctx, state))
            return AML_TABLE_NOT_LOADED;
        if (ctx->slots[state].data)
            return AML_TABLE_BUSY;
    }
    value *last_handle = &ctx->slots[ctx->slot_count - 1];
    if (last_handle->integer_or_length == UINT32_MAX || depth > 64)
        return AML_EXECUTION_LIMIT;

    for (uint64_t i = 0; i < table->count; ++i) {
        value *slot = aml_object_slot(ctx);
        if (!slot) {
            retire_table(ctx, table);
            return AML_OUT_OF_MEMORY;
        }
        ctx->slots[table->first + i] = (value){.data = slot, .type = DYNAMIC_SLOT};
    }
    ctx->slots[table->state] = integer(++last_handle->integer_or_length);
    /* Initializers can use their own bindings, but dependent activations
     * must wait until the initializer has succeeded. */
    ctx->slots[table->state].data = table;
    ctx->slots[table->state + 1] = integer(1);
    value result;
    int32_t status = table->initialize(ctx, &result, depth);
    ctx->slots[table->state].data = NULL;
    aml_table_leave(ctx, table->state);
    if (status)
        retire_table(ctx, table);
    return status;
}

int32_t aml_context_load_table(aml_context *ctx, uint64_t index)
{
    if (!ctx || index >= aml_dynamic_count)
        return AML_INVALID_ARGUMENT;
    const dynamic_table *table = &aml_dynamic_tables[index];
    if (aml_table_active(ctx, table->state))
        return AML_TABLE_ALREADY_LOADED;
    aml_objects_collect(ctx);
    ctx->steps = 100000;
    int32_t status = activate_table(ctx, table, 1);
    aml_release_mutexes(ctx);
    return status;
}

static int32_t deactivate_table(aml_context *ctx, const dynamic_table *table)
{
    if (!aml_table_active(ctx, table->state))
        return AML_TABLE_NOT_LOADED;
    if (ctx->slots[table->state + 1].integer_or_length)
        return AML_TABLE_BUSY;
    uint64_t index = table - aml_dynamic_tables;
    for (uint64_t i = 0; i < aml_dynamic_count; ++i) {
        const dynamic_table *dependent = &aml_dynamic_tables[i];
        if (aml_table_active(ctx, dependent->state))
            for (uint64_t j = 0; j < dependent->dependency_count; ++j)
                if (dependent->dependencies[j] == index)
                    return AML_TABLE_BUSY;
    }
    for (value *held = ctx->held_mutex; held; held = (value *)held->data) {
        for (uint64_t i = 0; i < table->count; ++i)
            if (held == aml_dynamic_slot(ctx, table->first + i))
                return AML_TABLE_BUSY;
    }
    retire_table(ctx, table);
    return AML_OK;
}

int32_t aml_context_unload_table(aml_context *ctx, uint64_t index)
{
    if (!ctx || index >= aml_dynamic_count)
        return AML_INVALID_ARGUMENT;
    return deactivate_table(ctx, &aml_dynamic_tables[index]);
}

static bool is_namespace_object(value v)
{
    return v.type >= NAMESPACE_OBJECT && v.type < NAMESPACE_OBJECT_END;
}

static bool namespace_object_active(value v)
{
    const value *state = v.data;
    return !state || state->integer_or_length == v.integer_or_length;
}

static bool mark(value v, unsigned depth)
{
    if (v.type == AML_VALUE_INTEGER || v.type == UNINITIALIZED || v.type == RETIRED_SLOT ||
        is_namespace_object(v) || (v.type == SLOT_REF && v.integer_or_length == 1))
        return true;
    if (!depth)
        return false;
    allocation *entry = allocation_for(v.data);
    if (entry->marked)
        return true;
    entry->marked = true;
    if (v.type == AML_VALUE_PACKAGE || v.type == ELEMENT_REF) {
        const value *elements = v.data;
        size_t count = (entry->size - sizeof(*entry)) / sizeof(*elements);
        for (size_t i = 0; i < count; ++i)
            if (!mark(elements[i], depth - 1))
                return false;
    } else if (v.type == SLOT_REF || v.type == DYNAMIC_SLOT) {
        return mark(*(const value *)v.data, depth - 1);
    } else if (v.type == REGION_FIELD) {
        const region_field *field = v.data;
        const value *locals[] = {field->region.local, field->selector.local, field->data.local};
        for (unsigned i = 0; i < 3; ++i)
            if (locals[i] && !mark((value){.type = SLOT_REF, .data = locals[i]}, depth - 1))
                return false;
    } else if (v.type == FIELD) {
        const bit_field *field = v.data;
        allocation_for(field->bytes)->marked = true;
    }
    return true;
}

void aml_objects_collect(aml_context *ctx)
{
    bool complete = true;
    for (uint64_t i = 0; complete && i < ctx->slot_count; ++i)
        complete = mark(ctx->slots[i], 64);
    allocation **link = &ctx->allocations;
    while (*link) {
        allocation *entry = *link;
        if (!entry->marked && complete) {
            *link = entry->next;
            ctx->allocated -= entry->size;
            free(entry);
        } else {
            entry->marked = false;
            link = &entry->next;
        }
    }
}

static bool is_reference(value v)
{
    return v.type == SLOT_REF || v.type == ELEMENT_REF || v.type == BYTE_REF;
}

static int bytes_value(aml_context *ctx, value *out, uint64_t type,
                       uint64_t size, const void *src, uint64_t src_size)
{
    if (size > SIZE_MAX - (type == AML_VALUE_STRING))
        return AML_OUT_OF_MEMORY;
    uint8_t *data = allocate(ctx, size + (type == AML_VALUE_STRING));
    if (!data)
        return AML_OUT_OF_MEMORY;
    if (src_size && size)
        memcpy(data, src, src_size < size ? src_size : size);
    *out = (value){.integer_or_length = size, .data = data, .type = type};
    return AML_OK;
}

static int package(aml_context *ctx, value *out, uint64_t count)
{
    if (count > SIZE_MAX / sizeof(value))
        return AML_OUT_OF_MEMORY;
    value *elements = allocate(ctx, count * sizeof(value));
    if (!elements)
        return AML_OUT_OF_MEMORY;
    for (uint64_t i = 0; i < count; ++i)
        elements[i].type = UNINITIALIZED;
    *out = (value){.integer_or_length = count, .data = elements,
                   .type = AML_VALUE_PACKAGE};
    return AML_OK;
}

static int clone_package(aml_context *ctx, value *out, value src, unsigned depth);

static inline int clone(aml_context *ctx, value *out, value src, unsigned depth)
{
    if (!depth)
        return AML_EXECUTION_LIMIT;
    if (src.type == AML_VALUE_STRING || src.type == AML_VALUE_BUFFER)
        return bytes_value(ctx, out, src.type, src.integer_or_length,
                           src.data, src.integer_or_length);
    if (src.type == AML_VALUE_PACKAGE)
        return clone_package(ctx, out, src, depth);
    *out = src;
    return AML_OK;
}

static int clone_package(aml_context *ctx, value *out, value src, unsigned depth)
{
    value result;
    int status = package(ctx, &result, src.integer_or_length);
    if (status)
        return status;
    value *dst = (value *)result.data;
    const value *elements = src.data;
    for (uint64_t i = 0; i < src.integer_or_length; ++i) {
        status = clone(ctx, &dst[i], elements[i], depth - 1);
        if (status)
            return status;
    }
    *out = result;
    return AML_OK;
}

static int storage(aml_context *ctx, value v, uint8_t scratch[8],
                   const uint8_t **bytes, uint64_t *len, bool nul)
{
    switch (v.type) {
    case AML_VALUE_INTEGER:
        *len = ctx->integer_bytes;
        for (uint64_t i = 0; i < *len; ++i)
            scratch[i] = v.integer_or_length >> (8 * i);
        *bytes = scratch;
        return AML_OK;
    case AML_VALUE_STRING:
    case AML_VALUE_BUFFER:
        *bytes = v.data;
        *len = v.integer_or_length + (nul && v.type == AML_VALUE_STRING);
        return AML_OK;
    default:
        return AML_TYPE_MISMATCH;
    }
}

static uint64_t from_bytes(const uint8_t *data, uint64_t size, uint64_t width)
{
    uint64_t result = 0;
    for (uint64_t i = 0; i < size && i < width; ++i)
        result |= (uint64_t)data[i] << (8 * i);
    return result;
}

static bool integer_whitespace(unsigned char c)
{
#if __STDC_HOSTED__
    return isspace(c);
#else
    return c == ' ' || (c >= '\t' && c <= '\r');
#endif
}

static uint64_t to_integer(aml_context *ctx, value v)
{
    if (v.type == AML_VALUE_INTEGER)
        return v.integer_or_length;
    if (v.type == AML_VALUE_BUFFER)
        return from_bytes(v.data, v.integer_or_length, ctx->integer_bytes);
    const unsigned char *text = v.data;
    size_t i = 0;
    while (i < v.integer_or_length && integer_whitespace(text[i]))
        ++i;
    bool negative = i < v.integer_or_length && text[i] == '-';
    if (i < v.integer_or_length && (text[i] == '-' || text[i] == '+'))
        ++i;
    unsigned base = 10;
    if (i < v.integer_or_length && text[i] == '0') {
        ++i;
        base = 8;
        if (i < v.integer_or_length && (text[i] == 'x' || text[i] == 'X')) {
            base = 16;
            ++i;
        }
    }
    uint64_t result = 0;
    for (; i < v.integer_or_length; ++i) {
        unsigned c = text[i];
        unsigned digit = c >= '0' && c <= '9' ? c - '0' :
                         (c | 32) >= 'a' && (c | 32) <= 'f' ? (c | 32) - 'a' + 10 : 16;
        if (digit >= base)
            break;
        if (result > (UINT64_MAX - digit) / base) {
            result = UINT64_MAX;
            break;
        }
        result = result * base + digit;
    }
    if (negative)
        result = 0 - result;
    if (ctx->integer_bytes == 4)
        result &= UINT32_MAX;
    return result;
}

static int field_read(aml_context *ctx, value *out, const bit_field *field)
{
    uint64_t count = (field->bits + 7) / 8;
    uint8_t local[8] = {0};
    uint8_t *bytes = local;
    if (field->force_buffer || count > ctx->integer_bytes) {
        int status = bytes_value(ctx, out, AML_VALUE_BUFFER, count, NULL, 0);
        if (status)
            return status;
        bytes = (uint8_t *)out->data;
    }
    for (uint64_t i = 0; i < field->bits; ++i) {
        uint64_t bit = field->start + i;
        bytes[i / 8] |= ((field->bytes[bit / 8] >> (bit % 8)) & 1u) << (i % 8);
    }
    if (bytes == local)
        *out = integer(from_bytes(local, count, ctx->integer_bytes));
    return AML_OK;
}

static int region_field_io(aml_context *ctx, const region_field *field, bool write,
                           const uint8_t *source, uint64_t length, uint8_t *destination);

static int field_write_datum(aml_context *ctx, const region_field *field, uint64_t datum)
{
    uint8_t bytes[8];
    for (unsigned i = 0; i < sizeof(bytes); ++i)
        bytes[i] = datum >> (8 * i);
    return region_field_io(ctx, field, true, bytes, sizeof(bytes), NULL);
}

static int region_field_read(aml_context *ctx, value *out, const region_field *field);

static bool field_binding_present(field_binding binding)
{
    return binding.local || binding.index != UINT64_MAX;
}

static int field_binding_get(aml_context *ctx, field_binding binding, uint64_t type,
                             const value **slot)
{
    *slot = binding.local ? binding.local : bound_slot(ctx, binding.index);
    if (!*slot || (*slot)->type == RETIRED_SLOT)
        return AML_TABLE_NOT_LOADED;
    if ((*slot)->type == UNINITIALIZED)
        return AML_UNINITIALIZED;
    return (*slot)->type == type ? AML_OK : AML_TYPE_MISMATCH;
}

static int field_transfer(aml_context *ctx, const region_field *field,
                          uint64_t offset, uint8_t width, bool write, uint64_t *datum)
{
    bool indexed = field_binding_present(field->data);
    const value *slot;
    int status;
    if (field_binding_present(field->selector)) {
        status = field_binding_get(ctx, field->selector, REGION_FIELD, &slot);
        if (status)
            return status;
        uint64_t selection = indexed ? offset : field->bank;
        const region_field *selector = slot->data;
        if (selector->bits < 64 && selection >> selector->bits)
            return AML_OUT_OF_BOUNDS;
        status = field_write_datum(ctx, selector, selection);
        if (status)
            return status;
    }
    if (indexed) {
        status = field_binding_get(ctx, field->data, REGION_FIELD, &slot);
        if (status)
            return status;
        if (write)
            return field_write_datum(ctx, slot->data, *datum);
        value result;
        status = region_field_read(ctx, &result, slot->data);
        if (status)
            return status;
        *datum = result.type == AML_VALUE_BUFFER ?
                 from_bytes(result.data, result.integer_or_length, width) :
                 result.integer_or_length;
        return AML_OK;
    }
    status = field_binding_get(ctx, field->region, REGION, &slot);
    if (status)
        return status;
    const region *reg = slot->data;
    if (offset > reg->length || width > reg->length - offset ||
        offset > UINT64_MAX - reg->base || width - 1u > UINT64_MAX - reg->base - offset)
        return AML_OUT_OF_BOUNDS;
    if (!ctx->host.region_access)
        return AML_HOST_UNAVAILABLE;
    return ctx->host.region_access(ctx->host.userdata, reg->path, reg->space,
                                  reg->base + offset, width, write, datum);
}

static int transfer_field_bits(aml_context *ctx, const region_field *field, bool write,
                           const uint8_t *source, uint64_t length, uint8_t *destination)
{
    unsigned access = field->flags & 0x0f;
    uint8_t width = access >= 2 && access <= 4 ? 1u << (access - 1) : 1;
    unsigned datum_bits = 8u * width;
    uint64_t field_end = field->start + field->bits;
    uint64_t datum_start = field->start & ~((uint64_t)datum_bits - 1);
    for (; field->bits && datum_start < field_end; datum_start += datum_bits) {
        if (!ctx->steps)
            return AML_EXECUTION_LIMIT;
        --ctx->steps;
        uint64_t start = field->start > datum_start ? field->start : datum_start;
        uint64_t end = field_end < datum_start + datum_bits ? field_end : datum_start + datum_bits;
        uint64_t datum = 0;
        int status;
        if (!write) {
            status = field_transfer(ctx, field, datum_start / 8, width, false, &datum);
            if (status)
                return status;
        } else if (end - start < datum_bits) {
            switch ((field->flags >> 5) & 3) {
            case 0:
                status = field_transfer(ctx, field, datum_start / 8, width, false, &datum);
                if (status)
                    return status;
                break;
            case 1:
                datum = width == 8 ? UINT64_MAX : (UINT64_C(1) << datum_bits) - 1;
                break;
            }
        }
        for (uint64_t bit = start; bit < end; ++bit) {
            uint64_t index = bit - field->start;
            uint64_t mask = UINT64_C(1) << (bit - datum_start);
            if (write) {
                bool set = index / 8 < length && (source[index / 8] & (1u << (index % 8)));
                datum = (datum & ~mask) | (set ? mask : 0);
            } else if (datum & mask) {
                destination[index / 8] |= 1u << (index % 8);
            }
        }
        if (write) {
            status = field_transfer(ctx, field, datum_start / 8, width, true, &datum);
            if (status)
                return status;
        }
    }
    return AML_OK;
}

static int region_field_io(aml_context *ctx, const region_field *field, bool write,
                           const uint8_t *source, uint64_t length, uint8_t *destination)
{
    if (!(field->flags & 0x10) || ctx->global_lock_held)
        return transfer_field_bits(ctx, field, write, source, length, destination);
    if (!ctx->host.acquire_global_lock || !ctx->host.release_global_lock)
        return AML_HOST_UNAVAILABLE;
    int status = ctx->host.acquire_global_lock(ctx->host.userdata);
    if (status)
        return status;
    ctx->global_lock_held = true;
    status = transfer_field_bits(ctx, field, write, source, length, destination);
    ctx->global_lock_held = false;
    ctx->host.release_global_lock(ctx->host.userdata);
    return status;
}

static int region_field_read(aml_context *ctx, value *out, const region_field *field)
{
    uint64_t length = (field->bits + 7) / 8;
    uint8_t local[8] = {0};
    uint8_t *bytes = local;
    if (length > ctx->integer_bytes) {
        int status = bytes_value(ctx, out, AML_VALUE_BUFFER, length, NULL, 0);
        if (status)
            return status;
        bytes = (uint8_t *)out->data;
    }
    int status = region_field_io(ctx, field, false, NULL, 0, bytes);
    if (!status && bytes == local)
        *out = integer(from_bytes(local, length, ctx->integer_bytes));
    return status;
}

static int read_reference(aml_context *ctx, value *out, value src, bool explicit, unsigned depth)
{
    if (explicit && !is_reference(src))
        return AML_TYPE_MISMATCH;
    for (; depth < 64; ++depth) {
        if (is_namespace_object(src))
            return namespace_object_active(src) ? AML_TYPE_MISMATCH : AML_TABLE_NOT_LOADED;
        switch (src.type) {
        case SLOT_REF:
            src = *(const value *)src.data;
            continue;
        case ELEMENT_REF:
            src = ((const value *)src.data)[src.integer_or_length];
            continue;
        case BYTE_REF:
            *out = integer(((const uint8_t *)src.data)[src.integer_or_length]);
            return AML_OK;
        case REGION_FIELD:
            return region_field_read(ctx, out, src.data);
        case FIELD:
            return field_read(ctx, out, src.data);
        case RETIRED_SLOT:
            return AML_TABLE_NOT_LOADED;
        case UNINITIALIZED:
            return AML_UNINITIALIZED;
        default:
            *out = src;
            return AML_OK;
        }
    }
    return AML_EXECUTION_LIMIT;
}

static const value *referenced_slot(value ref)
{
    if (ref.type == SLOT_REF)
        return ref.data;
    if (ref.type == ELEMENT_REF)
        return (const value *)ref.data + ref.integer_or_length;
    return NULL;
}

static int check_store_cycle(const value *dst, value src, unsigned depth)
{
    if (!depth)
        return AML_EXECUTION_LIMIT;
    const value *target = referenced_slot(src);
    if (target) {
        if (target == dst)
            return AML_INVALID_ARGUMENT;
        return check_store_cycle(dst, *target, depth - 1);
    }
    if (src.type == AML_VALUE_PACKAGE) {
        const value *elements = src.data;
        for (uint64_t i = 0; i < src.integer_or_length; ++i) {
            int status = check_store_cycle(dst, elements[i], depth - 1);
            if (status)
                return status;
        }
    }
    return AML_OK;
}

static int store(aml_context *ctx, value *dst, value src, unsigned mode, unsigned depth)
{
    if (!depth)
        return AML_EXECUTION_LIMIT;
    if (dst->type == RETIRED_SLOT)
        return AML_TABLE_NOT_LOADED;
    if (is_namespace_object(*dst))
        return namespace_object_active(*dst) ? AML_TYPE_MISMATCH : AML_TABLE_NOT_LOADED;
    if (src.type == AML_VALUE_INTEGER && dst->type == BYTE_REF) {
        ((uint8_t *)dst->data)[dst->integer_or_length] = (uint8_t)src.integer_or_length;
        return AML_OK;
    }
    if (dst->type == FIELD || dst->type == REGION_FIELD || dst->type == BYTE_REF) {
        const uint8_t *bytes;
        uint8_t scratch[8];
        uint64_t len;
        int status = storage(ctx, src, scratch, &bytes, &len, false);
        if (status)
            return status;
        if (dst->type == BYTE_REF) {
            ((uint8_t *)dst->data)[dst->integer_or_length] = len ? bytes[0] : 0;
            return AML_OK;
        }
        if (dst->type == REGION_FIELD)
            return region_field_io(ctx, dst->data, true, bytes, len, NULL);
        const bit_field *field = dst->data;
        for (uint64_t i = 0; i < field->bits; ++i) {
            uint64_t bit = field->start + i;
            unsigned mask = 1u << (bit % 8);
            bool set = i / 8 < len && (bytes[i / 8] & (1u << (i % 8)));
            uint8_t *byte = &field->bytes[bit / 8];
            *byte = (*byte & ~mask) | (set ? mask : 0);
        }
        return AML_OK;
    }
    if (mode == FOLLOW_CAST || mode == FOLLOW_COPY) {
        const value *target = referenced_slot(*dst);
        if (target)
            return store(ctx, (value *)target, src, mode, depth - 1);
        mode = mode == FOLLOW_CAST ? STORE_NAMED : COPY_SLOT;
    }
    if (mode == STORE_REF && is_reference(*dst)) {
        unsigned next = dst->type == ELEMENT_REF ? STORE_SLOT :
                        dst->integer_or_length ? STORE_NAMED : STORE_REF;
        return store(ctx, (value *)referenced_slot(*dst), src, next, depth - 1);
    }
    if (mode == STORE_NAMED && dst->type == UNINITIALIZED)
        return AML_UNINITIALIZED;
    if (mode == STORE_NAMED && is_reference(*dst))
        return store(ctx, dst, src, FOLLOW_CAST, depth - 1);
    if (mode != STORE_NAMED) {
        if (src.type == AML_VALUE_INTEGER) {
            *dst = src;
            return AML_OK;
        }
        int status = check_store_cycle(dst, src, 64);
        if (status)
            return status;
        return clone(ctx, dst, src, 64);
    }
    if (dst->type != AML_VALUE_INTEGER && dst->type != AML_VALUE_STRING && dst->type != AML_VALUE_BUFFER)
        return AML_TYPE_MISMATCH;
    if (dst->type == AML_VALUE_INTEGER && src.type == AML_VALUE_INTEGER) {
        uint64_t payload = src.integer_or_length;
        *dst = integer(ctx->integer_bytes == 4 ? (uint32_t)payload : payload);
        return AML_OK;
    }
    const uint8_t *bytes;
    uint8_t scratch[8];
    uint64_t len;
    int status = storage(ctx, src, scratch, &bytes, &len, false);
    if (status)
        return status;
    if (dst->type == AML_VALUE_INTEGER) {
        *dst = integer(from_bytes(bytes, len, ctx->integer_bytes));
        return AML_OK;
    }
    uint64_t count = len < dst->integer_or_length ? len : dst->integer_or_length;
    if (count)
        memmove((void *)dst->data, bytes, count);
    if (count < dst->integer_or_length)
        memset((uint8_t *)dst->data + count, 0, dst->integer_or_length - count);
    return AML_OK;
}

static int compare(value lhs, value rhs, int *result)
{
    if (lhs.type != rhs.type || lhs.type > AML_VALUE_BUFFER)
        return AML_TYPE_MISMATCH;
    if (lhs.type == AML_VALUE_INTEGER) {
        uint64_t right = rhs.integer_or_length;
        *result = (lhs.integer_or_length > right) - (lhs.integer_or_length < right);
        return AML_OK;
    }
    const uint8_t *left = lhs.data;
    const uint8_t *right = rhs.data;
    uint64_t left_len = lhs.integer_or_length + (lhs.type == AML_VALUE_STRING);
    uint64_t right_len = rhs.integer_or_length + (rhs.type == AML_VALUE_STRING);
    uint64_t count = left_len < right_len ? left_len : right_len;
    *result = memcmp(left, right, count);
    if (!*result)
        *result = (left_len > right_len) - (left_len < right_len);
    return AML_OK;
}

static int format_value(aml_context *ctx, value *out, value src, bool hex)
{
    if (src.type == AML_VALUE_STRING)
        return clone(ctx, out, src, 64);
    char number[32];
    if (src.type == AML_VALUE_INTEGER) {
        int len = snprintf(number, sizeof(number), hex ? "0x%llX" : "%llu",
                           (unsigned long long)src.integer_or_length);
        return bytes_value(ctx, out, AML_VALUE_STRING, len, number, len);
    }
    if (src.type != AML_VALUE_BUFFER)
        return AML_TYPE_MISMATCH;
    uint64_t count = src.integer_or_length;
    int status = bytes_value(ctx, out, AML_VALUE_STRING, count * (hex ? 5 : 4), NULL, 0);
    if (status)
        return status;
    char *cursor = (char *)out->data;
    const uint8_t *bytes = src.data;
    for (uint64_t i = 0; i < count; ++i) {
        if (i)
            *cursor++ = ',';
        cursor += sprintf(cursor, hex ? "0x%02X" : "%u", (unsigned)bytes[i]);
    }
    out->integer_or_length = cursor - (char *)out->data;
    return AML_OK;
}

static int concatenate(aml_context *ctx, value *out, value left, value right)
{
    if (left.type > AML_VALUE_BUFFER || right.type > AML_VALUE_BUFFER)
        return AML_TYPE_MISMATCH;

    char hex[17];
    if (left.type == AML_VALUE_INTEGER) {
        right = integer(to_integer(ctx, right));
    } else if (left.type == AML_VALUE_STRING && right.type == AML_VALUE_INTEGER) {
        int length = snprintf(hex, sizeof(hex), "%llx", (unsigned long long)right.integer_or_length);
        if (length < 0)
            return AML_INVALID_ARGUMENT;
        right = (value){.type = AML_VALUE_STRING, .string = hex, .integer_or_length = length};
    } else if (left.type == AML_VALUE_STRING && right.type == AML_VALUE_BUFFER) {
        int status = format_value(ctx, &right, right, true);
        if (status)
            return status;
    }

    uint8_t left_scratch[8], right_scratch[8];
    const uint8_t *left_bytes, *right_bytes;
    uint64_t left_length, right_length;
    int status = storage(ctx, left, left_scratch, &left_bytes, &left_length, false);
    if (status)
        return status;
    status = storage(ctx, right, right_scratch, &right_bytes, &right_length,
                     left.type == AML_VALUE_BUFFER);
    if (status)
        return status;
    uint64_t type = left.type == AML_VALUE_STRING ? AML_VALUE_STRING : AML_VALUE_BUFFER;
    status = bytes_value(ctx, out, type, left_length + right_length, left_bytes, left_length);
    if (status)
        return status;
    if (right_length)
        memcpy((uint8_t *)out->data + left_length, right_bytes, right_length);
    return AML_OK;
}

static int export_value(aml_context *ctx, value *out, value src, unsigned depth)
{
    if (!depth)
        return AML_EXECUTION_LIMIT;
    if (is_reference(src) || src.type == FIELD || src.type == REGION_FIELD) {
        int status = read_reference(ctx, &src, src, false, 0);
        if (status)
            return status;
        status = clone(ctx, &src, src, 64);
        if (status)
            return status;
    }
    if (src.type == AML_VALUE_PACKAGE) {
        value *elements = (value *)src.data;
        for (uint64_t i = 0; i < src.integer_or_length; ++i) {
            int status = export_value(ctx, &elements[i], elements[i], depth - 1);
            if (status)
                return status;
        }
    }
    *out = src;
    return AML_OK;
}

static int32_t load_match(aml_context *ctx, value *out,
                          const dynamic_table *table, uint32_t depth)
{
    int32_t status = activate_table(ctx, table, depth + 1);
    if (status == AML_TABLE_ALREADY_LOADED) {
        *out = integer(0);
        return AML_OK;
    }
    if (status)
        return status;
    *out = integer(ctx->slots[table->state].integer_or_length);
    return AML_OK;
}

static bool table_id_matches(const uint8_t *field, value id, size_t width)
{
    return !id.integer_or_length ||
           (memcmp(field, id.data, id.integer_or_length) == 0 &&
            (id.integer_or_length == width || field[id.integer_or_length] == 0));
}

static int32_t load_table_id(aml_context *ctx, value *out, value signature,
                             value oem, value id, uint32_t depth)
{
    if (signature.type != AML_VALUE_STRING || oem.type != AML_VALUE_STRING ||
        id.type != AML_VALUE_STRING)
        return AML_TYPE_MISMATCH;
    if (signature.integer_or_length != 4 || oem.integer_or_length > 6 ||
        id.integer_or_length > 8)
        return AML_INVALID_ARGUMENT;
    for (uint64_t i = 0; i < aml_dynamic_count; ++i) {
        const dynamic_table *table = &aml_dynamic_tables[i];
        if (memcmp(table->bytes, signature.data, 4) == 0 &&
            table_id_matches(table->bytes + 10, oem, 6) &&
            table_id_matches(table->bytes + 16, id, 8))
            return load_match(ctx, out, table, depth);
    }
    *out = integer(0);
    return AML_OK;
}

static int32_t read_load_bytes(aml_context *ctx, const region *reg,
                               uint8_t *bytes, uint64_t offset, uint64_t length)
{
    if (offset > reg->length || length > reg->length - offset ||
        offset > UINT64_MAX - reg->base ||
        (length && length - 1 > UINT64_MAX - reg->base - offset))
        return AML_OUT_OF_BOUNDS;
    if (!ctx->host.region_access)
        return AML_HOST_UNAVAILABLE;
    for (uint64_t i = 0; i < length; ++i) {
        if (!ctx->steps)
            return AML_EXECUTION_LIMIT;
        --ctx->steps;
        uint64_t datum = 0;
        int32_t status = ctx->host.region_access(ctx->host.userdata, reg->path, reg->space,
            reg->base + offset + i, 1, false, &datum);
        if (status)
            return status;
        bytes[i] = datum;
    }
    return AML_OK;
}

static int32_t load_table_bytes(aml_context *ctx, value *out, value source, uint32_t depth)
{
    const region *reg = NULL;
    uint8_t header[36];
    const uint8_t *bytes;
    uint64_t available;
    if (source.type == REGION) {
        reg = source.data;
        if (reg->space != 0)
            return AML_TYPE_MISMATCH;
        int32_t status = read_load_bytes(ctx, reg, header, 0, sizeof(header));
        if (status)
            return status;
        bytes = header;
        available = reg->length;
    } else if (source.type == AML_VALUE_BUFFER) {
        bytes = source.data;
        available = source.integer_or_length;
    } else {
        return AML_TYPE_MISMATCH;
    }
    if (available < sizeof(header))
        return AML_OUT_OF_BOUNDS;
    uint64_t length = from_bytes(bytes + 4, 4, 4);
    if (length < sizeof(header) || length > available)
        return AML_OUT_OF_BOUNDS;

    for (uint64_t i = 0; i < aml_dynamic_count; ++i) {
        const dynamic_table *table = &aml_dynamic_tables[i];
        if (table->length != length)
            continue;
        if (!reg) {
            if (memcmp(bytes, table->bytes, length) == 0)
                return load_match(ctx, out, table, depth);
            continue;
        }
        if (memcmp(header, table->bytes, sizeof(header)) != 0)
            continue;
        uint64_t offset = sizeof(header);
        while (offset < length) {
            uint8_t block[64];
            uint64_t size = length - offset < sizeof(block) ? length - offset : sizeof(block);
            int32_t status = read_load_bytes(ctx, reg, block, offset, size);
            if (status)
                return status;
            if (memcmp(block, table->bytes + offset, size) != 0)
                break;
            offset += size;
        }
        if (offset == length)
            return load_match(ctx, out, table, depth);
    }
    *out = integer(0);
    return AML_OK;
}

static bool default_osi(const char *name)
{
    static const char *const interfaces[] = {
        "Windows 2000", "Windows 2001", "Windows 2001 SP1", "Windows 2001.1",
        "Windows 2001 SP2", "Windows 2001.1 SP1", "Windows 2006", "Windows 2006.1",
        "Windows 2006 SP1", "Windows 2006 SP2", "Windows 2009", "Windows 2012",
        "Windows 2013", "Windows 2015", "Windows 2016", "Windows 2017",
        "Windows 2017.2", "Windows 2018", "Windows 2018.2", "Windows 2019",
        "Windows 2020", "Windows 2021", "Windows 2022",
        "Extended Address Space Descriptor",
    };
    for (size_t i = 0; i < sizeof(interfaces) / sizeof(*interfaces); ++i)
        if (strcmp(name, interfaces[i]) == 0)
            return true;
    return false;
}

#if !__STDC_HOSTED__
/* Let freestanding links eliminate runtime services unused by the AML code. */
__attribute__((always_inline))
#endif
int32_t aml_object_op(aml_context *ctx, value *out, uint32_t op,
                      const value *a, const value *b, const value *c,
                      uint64_t extra)
{
    value x = a ? *a : integer(0), y = b ? *b : integer(0);
    switch (op) {
    case UNRESOLVED_EXTERNAL:
        return AML_UNRESOLVED_EXTERNAL;
    case 0x73:
        return concatenate(ctx, out, x, y);
    case OSI: {
        if (x.type != AML_VALUE_STRING)
            return AML_TYPE_MISMATCH;
        bool supported = ctx->host.osi ? ctx->host.osi(ctx->host.userdata, x.string)
                                       : default_osi(x.string);
        *out = integer(supported ? (ctx->integer_bytes == 4 ? UINT32_MAX : UINT64_MAX) : 0);
        return AML_OK;
    }
    case NAMESPACE_REF: {
        value *slot = aml_object_slot(ctx);
        if (!slot)
            return AML_OUT_OF_MEMORY;
        const value *state = extra == UINT64_MAX ? NULL : &ctx->slots[extra];
        *slot = (value){
            .integer_or_length = state ? state->integer_or_length : 0,
            .data = state,
            .type = NAMESPACE_OBJECT + x.integer_or_length,
        };
        *out = (value){.data = slot, .type = SLOT_REF};
        return AML_OK;
    }
    case STRING:
        return bytes_value(ctx, out, AML_VALUE_STRING, x.integer_or_length,
                           x.data, x.integer_or_length);
    case BUFFER:
        return bytes_value(ctx, out, AML_VALUE_BUFFER,
                           x.integer_or_length > y.integer_or_length ?
                           x.integer_or_length : y.integer_or_length, y.data, y.integer_or_length);
    case PACKAGE:
        return package(ctx, out, x.integer_or_length);
    case PACKAGE_ELEMENT:
        if (extra >= x.integer_or_length)
            return AML_OK;
        return clone(ctx, (value *)x.data + extra, y, 64);
    case CLONE:
        return clone(ctx, out, x, 64);
    case INIT_NAMED:
        if (out->type != UNINITIALIZED)
            return AML_INVALID_ARGUMENT;
        *out = x;
        return AML_OK;
    case EXPORT:
        return export_value(ctx, out, x, 64);
    case LOAD_PATHS:
        if (x.type != AML_VALUE_STRING || y.type != AML_VALUE_STRING)
            return AML_TYPE_MISMATCH;
        if ((x.integer_or_length && strcmp(x.string, "\\") != 0) || y.integer_or_length)
            return AML_INVALID_ARGUMENT;
        return AML_OK;
    case LOAD_TABLE:
        return load_table_id(ctx, out, x, y, *c, (uint32_t)extra);
    case LOAD:
        return load_table_bytes(ctx, out, x, (uint32_t)extra);
    case UNLOAD:
        if (x.type != AML_VALUE_INTEGER)
            return AML_TYPE_MISMATCH;
        if (x.integer_or_length)
            for (uint64_t i = 0; i < aml_dynamic_count; ++i)
                if (ctx->slots[aml_dynamic_tables[i].state].integer_or_length == x.integer_or_length)
                    return deactivate_table(ctx, &aml_dynamic_tables[i]);
        return AML_TABLE_NOT_LOADED;
    case TIMER:
        if (!ctx->host.timer_100ns)
            return AML_HOST_UNAVAILABLE;
        *out = integer(ctx->host.timer_100ns(ctx->host.userdata));
        if (ctx->integer_bytes == 4)
            out->integer_or_length &= UINT32_MAX;
        return AML_OK;
    case DELAY: {
        if (x.type != AML_VALUE_INTEGER)
            return AML_TYPE_MISMATCH;
        if (!ctx->host.delay)
            return AML_HOST_UNAVAILABLE;
        uint64_t limit = extra ? 2000 : UINT8_MAX;
        uint64_t duration = x.integer_or_length;
        ctx->host.delay(ctx->host.userdata, extra != 0, duration > limit ? limit : duration);
        return AML_OK;
    }
    case NOTIFY:
        if (y.type != AML_VALUE_INTEGER)
            return AML_TYPE_MISMATCH;
        if (ctx->host.notify)
            ctx->host.notify(ctx->host.userdata, x.string, y.integer_or_length);
        return AML_OK;
    case MUTEX_ACQUIRE: {
        value *mutex = bound_slot(ctx, extra);
        if (!mutex)
            return AML_TABLE_NOT_LOADED;
        if (aml_sync_level(ctx) > mutex_level(mutex)) {
            *out = integer(ctx->integer_bytes == 4 ? UINT32_MAX : UINT64_MAX);
            return AML_OK;
        }
        if (mutex->integer_or_length < MUTEX_ACQUISITION) {
            mutex->data = ctx->held_mutex;
            ctx->held_mutex = mutex;
        }
        mutex->integer_or_length += MUTEX_ACQUISITION;
        *out = integer(0);
        return AML_OK;
    }
    case MUTEX_RELEASE: {
        value *mutex = bound_slot(ctx, extra);
        if (!mutex)
            return AML_TABLE_NOT_LOADED;
        release_mutex(ctx, mutex);
        return AML_OK;
    }
    case EVENT_CONTROL: {
        value *event = bound_slot(ctx, extra);
        if (!event)
            return AML_TABLE_NOT_LOADED;
        if (!x.integer_or_length)
            *event = integer(0);
        else if (event->integer_or_length != UINT64_MAX)
            ++event->integer_or_length;
        return AML_OK;
    }
    case EVENT_WAIT: {
        if (y.type != AML_VALUE_INTEGER)
            return AML_TYPE_MISMATCH;
        value *event = bound_slot(ctx, extra);
        if (!event)
            return AML_TABLE_NOT_LOADED;
        uint64_t timeout = y.integer_or_length;
        bool signaled = event->integer_or_length != 0;
        if (signaled) {
            --event->integer_or_length;
        } else if (timeout) {
            if (!ctx->host.wait_event)
                return AML_HOST_UNAVAILABLE;
            if (timeout > UINT16_MAX)
                timeout = UINT16_MAX;
            signaled = ctx->host.wait_event(ctx->host.userdata, x.string, (uint16_t)timeout);
        }
        *out = integer(signaled ? 0 : (ctx->integer_bytes == 4 ? UINT32_MAX : UINT64_MAX));
        return AML_OK;
    }
    case REGION_CREATE: {
        if (out->type != UNINITIALIZED)
            return AML_INVALID_ARGUMENT;
        if (x.type != AML_VALUE_INTEGER || y.type != AML_VALUE_INTEGER)
            return AML_TYPE_MISMATCH;
        region *reg = allocate(ctx, sizeof(*reg));
        if (!reg)
            return AML_OUT_OF_MEMORY;
        *reg = (region){c->string, x.integer_or_length, y.integer_or_length, (uint8_t)extra};
        *out = (value){.data = reg, .type = REGION};
        return AML_OK;
    }
    case REGION_FIELD_CREATE: {
        if (out->type != UNINITIALIZED)
            return AML_INVALID_ARGUMENT;
        const field_binding bindings[] = {{x.type, x.data}, {y.type, y.data}, {c->type, c->data}};
        const uint64_t types[] = {REGION, REGION_FIELD, REGION_FIELD};
        for (unsigned i = 0; i < 3; ++i) {
            if (!field_binding_present(bindings[i]))
                continue;
            const value *slot;
            int status = field_binding_get(ctx, bindings[i], types[i], &slot);
            if (status)
                return status;
        }
        if (x.integer_or_length > UINT64_MAX - 63 ||
            y.integer_or_length > UINT64_MAX - 63 - x.integer_or_length)
            return AML_OUT_OF_BOUNDS;
        region_field *field = allocate(ctx, sizeof(*field));
        if (!field)
            return AML_OUT_OF_MEMORY;
        *field = (region_field){
            .region = bindings[0], .selector = bindings[1], .data = bindings[2],
            .bank = c->integer_or_length, .start = x.integer_or_length, .bits = y.integer_or_length,
            .flags = (uint8_t)extra,
        };
        *out = (value){.data = field, .type = REGION_FIELD};
        return AML_OK;
    }
    case READ:
        if (x.type == REGION_FIELD)
            return region_field_read(ctx, out, x.data);
        if (x.type == FIELD)
            return field_read(ctx, out, x.data);
        if (x.type == UNINITIALIZED)
            return AML_UNINITIALIZED;
        *out = x;
        return AML_OK;
    case STORE_SLOT:
        return store(ctx, out, x, is_reference(*out) ?
                     (extra ? FOLLOW_COPY : FOLLOW_CAST) : STORE_SLOT, 64);
    case STORE_NAMED:
        return store(ctx, out, x, STORE_NAMED, 64);
    case COPY_SLOT:
        return store(ctx, out, x, extra && is_reference(*out) ? FOLLOW_COPY : COPY_SLOT, 64);
    case STORE_REF:
        if (!is_reference(y))
            return AML_TYPE_MISMATCH;
        return store(ctx, &y, x, op, 64);
    case FIELD_CREATE: {
        if (x.type != AML_VALUE_BUFFER)
            return AML_TYPE_MISMATCH;
        if (out->type != UNINITIALIZED)
            return AML_INVALID_ARGUMENT;
        uint64_t bits = c->integer_or_length, index = y.integer_or_length;
        if (extra == 2) {
            if (index > UINT64_MAX / 8)
                return AML_OUT_OF_BOUNDS;
            index *= 8;
        }
        if (index > x.integer_or_length * 8 || bits > x.integer_or_length * 8 - index)
            return AML_OUT_OF_BOUNDS;
        bit_field *field = allocate(ctx, sizeof(*field));
        if (!field)
            return AML_OUT_OF_MEMORY;
        *field = (bit_field){(uint8_t *)x.data, index, bits, extra == 1};
        *out = (value){.data = field, .type = FIELD};
        return AML_OK;
    }
    case 0x75: /* Increment */
    case 0x76: { /* Decrement */
        value old;
        int status = read_reference(ctx, &old, x, true, 0);
        if (status)
            return status;
        if (old.type != AML_VALUE_INTEGER)
            return AML_TYPE_MISMATCH;
        uint64_t next = op == 0x75 ? old.integer_or_length + 1 : old.integer_or_length - 1;
        if (ctx->integer_bytes == 4)
            next &= UINT32_MAX;
        value result = integer(next);
        status = store(ctx, &x, result, STORE_REF, 64);
        if (status)
            return status;
        *out = result;
        return AML_OK;
    }
    case 0x83: /* DerefOf */
        return read_reference(ctx, out, x, true, 0);
    case 0x88: /* Index */
    case INDEX_READ:
        if (x.type != AML_VALUE_BUFFER && x.type != AML_VALUE_STRING && x.type != AML_VALUE_PACKAGE)
            return AML_TYPE_MISMATCH;
        if (y.integer_or_length >= x.integer_or_length)
            return AML_OUT_OF_BOUNDS;
        if (op == INDEX_READ) {
            if (x.type == AML_VALUE_PACKAGE)
                return read_reference(ctx, out, ((const value *)x.data)[y.integer_or_length], false, 1);
            *out = integer(((const uint8_t *)x.data)[y.integer_or_length]);
            return AML_OK;
        }
        *out = x.type == AML_VALUE_PACKAGE ?
            (value){.integer_or_length = y.integer_or_length, .data = x.data, .type = ELEMENT_REF} :
            (value){.integer_or_length = y.integer_or_length, .data = x.data, .type = BYTE_REF};
        return AML_OK;
    case TYPE:
        for (unsigned depth = 0; depth < 64; ++depth) {
            if (x.type == SLOT_REF || x.type == ELEMENT_REF) {
                x = ((const value *)x.data)[x.type == ELEMENT_REF ? x.integer_or_length : 0];
                continue;
            }
            if (x.type == RETIRED_SLOT)
                return AML_TABLE_NOT_LOADED;
            if (is_namespace_object(x)) {
                if (!namespace_object_active(x))
                    return AML_TABLE_NOT_LOADED;
                *out = integer(x.type - NAMESPACE_OBJECT);
                return AML_OK;
            }
            *out = integer(x.type == UNINITIALIZED ? 0 :
                           x.type == FIELD || x.type == BYTE_REF ? 14 :
                           x.type == REGION_FIELD ? 5 :
                           x.type == REGION ? 10 :
                           x.type == AML_VALUE_INTEGER ? 1 : x.type);
            return AML_OK;
        }
        return AML_EXECUTION_LIMIT;
    case 0x87: /* SizeOf */
        if (is_reference(x)) {
            int status = read_reference(ctx, &x, x, true, 0);
            if (status)
                return status;
        }
        if (x.type != AML_VALUE_STRING && x.type != AML_VALUE_BUFFER && x.type != AML_VALUE_PACKAGE)
            return AML_TYPE_MISMATCH;
        *out = integer(x.integer_or_length);
        return AML_OK;
    case 0x90: /* LAnd */
    case 0x91: { /* LOr */
        if (x.type > AML_VALUE_BUFFER || y.type > AML_VALUE_BUFFER)
            return AML_TYPE_MISMATCH;
        bool left = x.type == AML_VALUE_BUFFER ?
                    from_bytes(x.data, x.integer_or_length, 4) != 0 : to_integer(ctx, x) != 0;
        bool right = y.type == AML_VALUE_BUFFER ?
                     from_bytes(y.data, y.integer_or_length, 4) != 0 : to_integer(ctx, y) != 0;
        bool result = op == 0x90 ? left && right : left || right;
        *out = integer(result ? (ctx->integer_bytes == 4 ? UINT32_MAX : UINT64_MAX) : 0);
        return AML_OK;
    }
    case 0x93: /* LEqual */
    case 0x94: /* LGreater */
    case 0x95: { /* LLess */
        int order, status = compare(x, y, &order);
        if (status)
            return status;
        bool result = op == 0x93 ? order == 0 : op == 0x94 ? order > 0 : order < 0;
        *out = integer(result ? (ctx->integer_bytes == 4 ? UINT32_MAX : UINT64_MAX) : 0);
        return AML_OK;
    }
    case 0x96: { /* ToBuffer */
        uint8_t scratch[8];
        const uint8_t *bytes;
        uint64_t len;
        int status = storage(ctx, x, scratch, &bytes, &len, true);
        if (status)
            return status;
        return bytes_value(ctx, out, AML_VALUE_BUFFER, len, bytes, len);
    }
    case 0x97: /* ToDecimalString */
    case 0x98: /* ToHexString */
        return format_value(ctx, out, x, op == 0x98);
    case 0x99: /* ToInteger */
        if (x.type > AML_VALUE_BUFFER)
            return AML_TYPE_MISMATCH;
        *out = integer(to_integer(ctx, x));
        return AML_OK;
    case 0x9c: { /* ToString */
        if (x.type != AML_VALUE_BUFFER)
            return AML_TYPE_MISMATCH;
        uint64_t limit = y.integer_or_length < x.integer_or_length ?
                         y.integer_or_length : x.integer_or_length;
        const uint8_t *bytes = x.data;
        uint64_t len = 0;
        while (len < limit && bytes[len])
            ++len;
        return bytes_value(ctx, out, AML_VALUE_STRING, len, bytes, len);
    }
    case 0x9e: { /* Mid */
        if (x.type != AML_VALUE_STRING && x.type != AML_VALUE_BUFFER)
            return AML_TYPE_MISMATCH;
        uint64_t index = y.integer_or_length, len = c->integer_or_length;
        if (index >= x.integer_or_length || !len)
            return bytes_value(ctx, out, x.type, 0, NULL, 0);
        uint64_t remaining = x.integer_or_length - index;
        if (len > remaining)
            len = remaining;
        return bytes_value(ctx, out, x.type, len, (const uint8_t *)x.data + index, len);
    }
    default:
        return AML_INVALID_ARGUMENT;
    }
}
