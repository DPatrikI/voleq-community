// SPDX-License-Identifier: MPL-2.0

#include "VolEqRealtime.h"

#include <math.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>

_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "VolEq requires lock-free atomic counters");
_Static_assert(ATOMIC_BOOL_LOCK_FREE == 2, "VolEq requires lock-free atomic latches");

struct VolEqRealtimeContentState {
    float *samples;
    size_t capacity;
    _Atomic size_t read_index;
    _Atomic size_t write_index;
    _Atomic bool speech_authorized;
};

struct VolEqRealtimeSignalLatch {
    _Atomic uint32_t qualifying_callback_count;
    _Atomic bool malformed;
};

static const float voleq_permission_signal_threshold = 1.0e-7f;

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

VolEqRealtimeSignalLatch *voleq_realtime_signal_latch_create(void) {
    VolEqRealtimeSignalLatch *latch = malloc(sizeof(*latch));
    if (latch == NULL) {
        return NULL;
    }
    atomic_init(&latch->qualifying_callback_count, 0);
    atomic_init(&latch->malformed, false);
    return latch;
}

void voleq_realtime_signal_latch_destroy(VolEqRealtimeSignalLatch *latch) {
    free(latch);
}

void voleq_realtime_signal_latch_observe_callback(
    VolEqRealtimeSignalLatch *latch,
    const AudioBufferList *input_data
) {
    if (latch == NULL || input_data == NULL) {
        if (latch != NULL) {
            atomic_store_explicit(&latch->malformed, true, memory_order_release);
        }
        return;
    }

    bool qualifies = false;
    for (uint32_t buffer_index = 0;
         buffer_index < input_data->mNumberBuffers;
         ++buffer_index) {
        const AudioBuffer *buffer = &input_data->mBuffers[buffer_index];
        if ((buffer->mDataByteSize % sizeof(float)) != 0
            || (buffer->mDataByteSize > 0 && buffer->mData == NULL)) {
            atomic_store_explicit(&latch->malformed, true, memory_order_release);
            return;
        }

        const float *samples = (const float *)buffer->mData;
        const size_t sample_count = buffer->mDataByteSize / sizeof(float);
        for (size_t sample_index = 0; sample_index < sample_count; ++sample_index) {
            const float sample = samples[sample_index];
            if (!isfinite(sample)) {
                atomic_store_explicit(&latch->malformed, true, memory_order_release);
                return;
            }
            if (fabsf(sample) > voleq_permission_signal_threshold) {
                qualifies = true;
            }
        }
    }

    if (!qualifies) {
        return;
    }

    uint32_t current = atomic_load_explicit(
        &latch->qualifying_callback_count,
        memory_order_relaxed
    );
    while (current != UINT32_MAX
           && !atomic_compare_exchange_weak_explicit(
               &latch->qualifying_callback_count,
               &current,
               current + 1,
               memory_order_release,
               memory_order_relaxed
           )) {
    }
}

uint32_t voleq_realtime_signal_latch_qualifying_callback_count(
    const VolEqRealtimeSignalLatch *latch
) {
    if (latch == NULL) {
        return 0;
    }
    return atomic_load_explicit(
        &latch->qualifying_callback_count,
        memory_order_acquire
    );
}

bool voleq_realtime_signal_latch_is_malformed(
    const VolEqRealtimeSignalLatch *latch
) {
    if (latch == NULL) {
        return true;
    }
    return atomic_load_explicit(&latch->malformed, memory_order_acquire);
}
