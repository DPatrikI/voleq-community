// SPDX-License-Identifier: MPL-2.0

#include "VolEqRealtime.h"
#include "VolEqRealtimeAtomicSupport.h"

#include <stdlib.h>

struct VolEqRealtimeProcessorPublication {
    _Atomic unsigned int diagnostics_state;
    uint32_t path;
    uint32_t input_frame_count;
    uint32_t output_frame_count;
    _Atomic int failure_status;
};

VolEqRealtimeProcessorPublication *voleq_realtime_processor_publication_create(
    void
) {
    VolEqRealtimeProcessorPublication *publication = calloc(
        1,
        sizeof(*publication)
    );
    if (publication == NULL) {
        return NULL;
    }
    atomic_init(&publication->diagnostics_state, 0);
    atomic_init(&publication->failure_status, 0);
    return publication;
}

void voleq_realtime_processor_publication_destroy(
    VolEqRealtimeProcessorPublication *publication
) {
    free(publication);
}

bool voleq_realtime_processor_publish_diagnostics(
    VolEqRealtimeProcessorPublication *publication,
    uint32_t path,
    uint32_t input_frame_count,
    uint32_t output_frame_count
) {
    if (publication == NULL) {
        return false;
    }
    unsigned int expected = 0;
    if (!atomic_compare_exchange_strong_explicit(
        &publication->diagnostics_state,
        &expected,
        1,
        memory_order_relaxed,
        memory_order_relaxed
    )) {
        return false;
    }
    publication->path = path;
    publication->input_frame_count = input_frame_count;
    publication->output_frame_count = output_frame_count;
    atomic_store_explicit(
        &publication->diagnostics_state,
        2,
        memory_order_release
    );
    return true;
}

bool voleq_realtime_processor_read_diagnostics(
    const VolEqRealtimeProcessorPublication *publication,
    uint32_t *path,
    uint32_t *input_frame_count,
    uint32_t *output_frame_count
) {
    if (publication == NULL
        || path == NULL
        || input_frame_count == NULL
        || output_frame_count == NULL
        || atomic_load_explicit(
            &publication->diagnostics_state,
            memory_order_acquire
        ) != 2) {
        return false;
    }
    *path = publication->path;
    *input_frame_count = publication->input_frame_count;
    *output_frame_count = publication->output_frame_count;
    return true;
}

void voleq_realtime_processor_publish_failure(
    VolEqRealtimeProcessorPublication *publication,
    int32_t status
) {
    if (publication == NULL || status == 0) {
        return;
    }
    int expected = 0;
    atomic_compare_exchange_strong_explicit(
        &publication->failure_status,
        &expected,
        (int)status,
        memory_order_release,
        memory_order_relaxed
    );
}

int32_t voleq_realtime_processor_take_failure(
    VolEqRealtimeProcessorPublication *publication
) {
    if (publication == NULL) {
        return 0;
    }
    return (int32_t)atomic_exchange_explicit(
        &publication->failure_status,
        0,
        memory_order_acq_rel
    );
}
