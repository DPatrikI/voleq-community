// SPDX-License-Identifier: MPL-2.0

#include "VolEqRealtime.h"
#include "VolEqRealtimeAtomicSupport.h"

#include <stdlib.h>

struct VolEqRealtimeContentState {
    float *samples;
    size_t capacity;
    _Atomic size_t read_index;
    _Atomic size_t write_index;
    _Atomic bool speech_authorized;
};

VolEqRealtimeContentState *voleq_realtime_content_state_create(size_t capacity) {
    if (capacity < 2) {
        return NULL;
    }

    VolEqRealtimeContentState *state = calloc(1, sizeof(*state));
    if (state == NULL) {
        return NULL;
    }
    state->samples = calloc(capacity, sizeof(*state->samples));
    if (state->samples == NULL) {
        free(state);
        return NULL;
    }
    state->capacity = capacity;
    atomic_init(&state->read_index, 0);
    atomic_init(&state->write_index, 0);
    atomic_init(&state->speech_authorized, false);
    return state;
}

void voleq_realtime_content_state_destroy(VolEqRealtimeContentState *state) {
    if (state == NULL) {
        return;
    }
    free(state->samples);
    free(state);
}

size_t voleq_realtime_content_state_write(
    VolEqRealtimeContentState *state,
    const float *samples,
    size_t count
) {
    if (state == NULL || samples == NULL || count == 0) {
        return 0;
    }

    const size_t write_index = atomic_load_explicit(
        &state->write_index,
        memory_order_relaxed
    );
    const size_t read_index = atomic_load_explicit(
        &state->read_index,
        memory_order_acquire
    );
    const size_t available = state->capacity - (write_index - read_index);
    const size_t write_count = count < available ? count : available;

    for (size_t index = 0; index < write_count; ++index) {
        state->samples[(write_index + index) % state->capacity] = samples[index];
    }
    atomic_store_explicit(
        &state->write_index,
        write_index + write_count,
        memory_order_release
    );
    if (write_count != count) {
        atomic_store_explicit(
            &state->speech_authorized,
            false,
            memory_order_release
        );
    }
    return write_count;
}

size_t voleq_realtime_content_state_read(
    VolEqRealtimeContentState *state,
    float *samples,
    size_t count
) {
    if (state == NULL || samples == NULL || count == 0) {
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
    const size_t read_count = count < stored ? count : stored;

    for (size_t index = 0; index < read_count; ++index) {
        samples[index] = state->samples[(read_index + index) % state->capacity];
    }
    atomic_store_explicit(
        &state->read_index,
        read_index + read_count,
        memory_order_release
    );
    return read_count;
}

void voleq_realtime_content_state_set_speech_authorized(
    VolEqRealtimeContentState *state,
    bool authorized
) {
    if (state == NULL) {
        return;
    }
    atomic_store_explicit(
        &state->speech_authorized,
        authorized,
        memory_order_release
    );
}

bool voleq_realtime_content_state_is_speech_authorized(
    const VolEqRealtimeContentState *state
) {
    if (state == NULL) {
        return false;
    }
    return atomic_load_explicit(
        &state->speech_authorized,
        memory_order_acquire
    );
}
