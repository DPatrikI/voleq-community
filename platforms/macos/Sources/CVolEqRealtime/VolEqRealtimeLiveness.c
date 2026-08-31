// SPDX-License-Identifier: MPL-2.0

#include "VolEqRealtime.h"
#include "VolEqRealtimeAtomicSupport.h"

#include <limits.h>
#include <stdlib.h>

struct VolEqRealtimeLivenessState {
    VolEqRealtimeLivenessRecord *records;
    size_t capacity;
    _Atomic size_t read_index;
    _Atomic size_t write_index;
    unsigned long long sequence;
};

VolEqRealtimeLivenessState *voleq_realtime_liveness_state_create(
    size_t capacity
) {
    if (capacity < 2) {
        return NULL;
    }
    VolEqRealtimeLivenessState *state = calloc(1, sizeof(*state));
    if (state == NULL) {
        return NULL;
    }
    state->records = calloc(capacity, sizeof(*state->records));
    if (state->records == NULL) {
        free(state);
        return NULL;
    }
    state->capacity = capacity;
    atomic_init(&state->read_index, 0);
    atomic_init(&state->write_index, 0);
    return state;
}

void voleq_realtime_liveness_state_destroy(
    VolEqRealtimeLivenessState *state
) {
    if (state == NULL) {
        return;
    }
    free(state->records);
    free(state);
}

void voleq_realtime_liveness_state_record(
    VolEqRealtimeLivenessState *state,
    uint32_t captured_frame_count,
    uint32_t requested_output_frame_count,
    float captured_peak,
    uint32_t flags
) {
    if (state == NULL) {
        return;
    }
    const size_t write_index = atomic_load_explicit(
        &state->write_index,
        memory_order_relaxed
    );
    const size_t read_index = atomic_load_explicit(
        &state->read_index,
        memory_order_acquire
    );
    if (state->sequence != ULLONG_MAX) {
        state->sequence += 1;
    }
    if (write_index - read_index >= state->capacity) {
        return;
    }

    VolEqRealtimeLivenessRecord record = {
        .sequence = (uint64_t)state->sequence,
        .captured_frame_count = captured_frame_count,
        .requested_output_frame_count = requested_output_frame_count,
        .captured_peak = captured_peak,
        .flags = flags,
    };
    state->records[write_index % state->capacity] = record;
    atomic_store_explicit(
        &state->write_index,
        write_index + 1,
        memory_order_release
    );
}

size_t voleq_realtime_liveness_state_read(
    VolEqRealtimeLivenessState *state,
    VolEqRealtimeLivenessRecord *records,
    size_t maximum_record_count
) {
    if (state == NULL || records == NULL || maximum_record_count == 0) {
        return 0;
    }
    const size_t read_index = atomic_load_explicit(
        &state->read_index,
        memory_order_relaxed
    );
    const size_t write_index = atomic_load_explicit(
        &state->write_index,
        memory_order_acquire
    );
    const size_t stored = write_index - read_index;
    const size_t read_count = stored < maximum_record_count
        ? stored
        : maximum_record_count;
    for (size_t index = 0; index < read_count; ++index) {
        records[index] = state->records[(read_index + index) % state->capacity];
    }
    atomic_store_explicit(
        &state->read_index,
        read_index + read_count,
        memory_order_release
    );
    return read_count;
}
