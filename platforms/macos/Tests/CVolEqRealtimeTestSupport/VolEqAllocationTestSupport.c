// SPDX-License-Identifier: MPL-2.0

#include "VolEqAllocationTestSupport.h"

#include <dlfcn.h>
#include <malloc/malloc.h>
#include <stdbool.h>
#include <stdlib.h>

static _Thread_local bool tracking_allocations;
static _Thread_local size_t allocation_count;

static void *(*original_malloc)(size_t);
static void *(*original_calloc)(size_t, size_t);
static void *(*original_realloc)(void *, size_t);
static int (*original_posix_memalign)(void **, size_t, size_t);
static void *(*original_aligned_alloc)(size_t, size_t);
static void *(*original_malloc_zone_malloc)(malloc_zone_t *, size_t);
static void *(*original_malloc_zone_calloc)(malloc_zone_t *, size_t, size_t);
static void *(*original_malloc_zone_realloc)(malloc_zone_t *, void *, size_t);

__attribute__((constructor))
static void voleq_prepare_allocation_interposers(void) {
    original_malloc = dlsym(RTLD_NEXT, "malloc");
    original_calloc = dlsym(RTLD_NEXT, "calloc");
    original_realloc = dlsym(RTLD_NEXT, "realloc");
    original_posix_memalign = dlsym(RTLD_NEXT, "posix_memalign");
    original_aligned_alloc = dlsym(RTLD_NEXT, "aligned_alloc");
    original_malloc_zone_malloc = dlsym(RTLD_NEXT, "malloc_zone_malloc");
    original_malloc_zone_calloc = dlsym(RTLD_NEXT, "malloc_zone_calloc");
    original_malloc_zone_realloc = dlsym(RTLD_NEXT, "malloc_zone_realloc");
}

static void *voleq_tracked_malloc(size_t size) {
    if (tracking_allocations) allocation_count++;
    return original_malloc(size);
}

static void *voleq_tracked_calloc(size_t count, size_t size) {
    if (tracking_allocations) allocation_count++;
    return original_calloc(count, size);
}

static void *voleq_tracked_realloc(void *pointer, size_t size) {
    if (tracking_allocations) allocation_count++;
    return original_realloc(pointer, size);
}

static int voleq_tracked_posix_memalign(void **pointer, size_t alignment, size_t size) {
    if (tracking_allocations) allocation_count++;
    return original_posix_memalign(pointer, alignment, size);
}

static void *voleq_tracked_aligned_alloc(size_t alignment, size_t size) {
    if (tracking_allocations) allocation_count++;
    return original_aligned_alloc(alignment, size);
}

static void *voleq_tracked_malloc_zone_malloc(malloc_zone_t *zone, size_t size) {
    if (tracking_allocations) allocation_count++;
    return original_malloc_zone_malloc(zone, size);
}

static void *voleq_tracked_malloc_zone_calloc(
    malloc_zone_t *zone,
    size_t count,
    size_t size
) {
    if (tracking_allocations) allocation_count++;
    return original_malloc_zone_calloc(zone, count, size);
}

static void *voleq_tracked_malloc_zone_realloc(
    malloc_zone_t *zone,
    void *pointer,
    size_t size
) {
    if (tracking_allocations) allocation_count++;
    return original_malloc_zone_realloc(zone, pointer, size);
}

#define VOLEQ_INTERPOSE(replacement, replacee)                                  \
    __attribute__((used)) static const struct {                                \
        const void *replacement;                                                \
        const void *original;                                                   \
    } _voleq_interpose_##replacee __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(unsigned long)&replacement,                              \
        (const void *)(unsigned long)&replacee                                  \
    }

VOLEQ_INTERPOSE(voleq_tracked_malloc, malloc);
VOLEQ_INTERPOSE(voleq_tracked_calloc, calloc);
VOLEQ_INTERPOSE(voleq_tracked_realloc, realloc);
VOLEQ_INTERPOSE(voleq_tracked_posix_memalign, posix_memalign);
VOLEQ_INTERPOSE(voleq_tracked_aligned_alloc, aligned_alloc);
VOLEQ_INTERPOSE(voleq_tracked_malloc_zone_malloc, malloc_zone_malloc);
VOLEQ_INTERPOSE(voleq_tracked_malloc_zone_calloc, malloc_zone_calloc);
VOLEQ_INTERPOSE(voleq_tracked_malloc_zone_realloc, malloc_zone_realloc);

void voleq_test_allocation_tracking_begin(void) {
    allocation_count = 0;
    tracking_allocations = true;
}

size_t voleq_test_allocation_tracking_end(void) {
    tracking_allocations = false;
    return allocation_count;
}
