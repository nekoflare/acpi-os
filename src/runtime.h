#ifndef AMLAOT_RUNTIME_H
#define AMLAOT_RUNTIME_H

#include <stdbool.h>
#include <stdint.h>

typedef struct aml_context aml_context;

enum aml_status {
    AML_OK = 0,
    AML_DIVISION_BY_ZERO = 1,
    AML_EXECUTION_LIMIT = 2,
    AML_INVALID_ARGUMENT = 3,
    AML_TYPE_MISMATCH = 4,
    AML_OUT_OF_BOUNDS = 5,
    AML_OUT_OF_MEMORY = 6,
    AML_UNINITIALIZED = 7,
    AML_SYNC_LEVEL_TOO_HIGH = 8,
    AML_HOST_UNAVAILABLE = 9,
    AML_TABLE_NOT_LOADED = 10,
    AML_TABLE_ALREADY_LOADED = 11,
    AML_TABLE_BUSY = 12,
    AML_UNRESOLVED_EXTERNAL = 13,
    AML_NO_RETURN = 14,
};

enum aml_value_type {
    AML_VALUE_INTEGER = 0,
    AML_VALUE_STRING = 2,
    AML_VALUE_BUFFER = 3,
    AML_VALUE_PACKAGE = 4,
    AML_VALUE_UNINITIALIZED = 260,
    AML_VALUE_NO_RETURN = 0x110,
};

/* Strings and buffers expose bytes, and packages expose an array of aml_value.
 * Data returned by an entry point belongs to its context. Treat it as read-only.
 * The length of a string excludes its terminating NUL.
 */
typedef struct aml_value {
    uint64_t integer_or_length;
    union {
        const void *data;
        const char *string;
    };
    uint64_t type;
} aml_value;

typedef struct aml_host {
    void *userdata;
    uint64_t (*timer_100ns)(void *userdata);
    void (*delay)(void *userdata, bool sleep, uint64_t duration);
    void (*notify)(void *userdata, const char *path, uint64_t value);
    bool (*wait_event)(void *userdata, const char *path, uint16_t timeout_ms);
    int32_t (*region_access)(void *userdata, const char *path, uint8_t space,
                             uint64_t address, uint8_t width_bytes, bool write,
                             uint64_t *value);
    int32_t (*acquire_global_lock)(void *userdata);
    void (*release_global_lock)(void *userdata);
    /* Receives a NUL-terminated name valid for the duration of the call. */
    bool (*osi)(void *userdata, const char *interface_name);
    /* Maximum runtime allocation bytes per context. Zero selects 64 MiB. */
    uint64_t allocation_limit;
} aml_host;

/* Copies the callbacks into ctx. Pass NULL to clear them. The caller owns
 * userdata and must hold exclusive access to ctx. Callbacks run synchronously
 * and must not reenter the same context. Delay uses milliseconds for Sleep and
 * microseconds for Stall. Notify supplies the target's absolute AML path.
 * Timer and delays require their callback. Notify without a callback is ignored.
 * Wait first consumes a queued AML signal, then polls immediately if the
 * timeout is zero. Otherwise wait_event returns true for a host signal and
 * false for timeout. A timeout of UINT16_MAX requests an indefinite wait.
 * A nonzero wait with no queued signal requires the wait_event callback.
 * Region accesses use absolute addresses and little-endian scalar values.
 * On read, region_access writes the value. On write, it consumes the value.
 * Return AML_OK on success or an aml_status on failure. Fields declared
 * Lock require both global lock callbacks, and release follows any successful
 * acquisition even when an access fails.
 */
void aml_context_set_host(aml_context *ctx, const aml_host *host);

aml_context *aml_context_create(void);
/* Installs host callbacks before executing module-level AML. The _OSI callback
 * overrides the default policy, which recognizes the Windows interface names
 * through Windows 2022 and "Extended Address Space Descriptor". */
aml_context *aml_context_create_with_host(const aml_host *host);
void aml_context_destroy(aml_context *ctx);

/* Dynamic SSDT indices are zero-based in --dynamic-ssdt option order.
 * Each context starts with all dynamic tables unloaded. Load initializes the
 * table's objects and unload invalidates them and references to them.
 * Loading a dependent table during its prerequisite's initialization reports
 * AML_TABLE_BUSY.
 * The caller must hold exclusive access to the context. A successful load
 * attempt invalidates the previous host result snapshot.
 */
int32_t aml_context_load_table(aml_context *ctx, uint64_t index);
int32_t aml_context_unload_table(aml_context *ctx, uint64_t index);

/* Each aml_<path> returns int32_t and takes (aml_context *, uint64_t *,
 * followed by one uint64_t per AML argument). Other result types produce
 * AML_TYPE_MISMATCH after method execution. A method that reaches its end
 * without a Return reports AML_NO_RETURN and leaves the integer result intact.
 *
 * Each aml_value_<path> takes an aml_value * result and the same integer
 * arguments. It reports successful fallthrough as AML_OK with a result tagged
 * AML_VALUE_NO_RETURN. An AML expression that requires a missing return value
 * fails with AML_NO_RETURN. Both entry points write the result only on success.
 * References in host results are resolved to snapshots of the referenced values.
 * The result's data remains valid until the next method invocation on the
 * same context or until context destruction, whichever comes first.
 */
#endif
