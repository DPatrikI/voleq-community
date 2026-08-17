// SPDX-License-Identifier: MPL-2.0

#include "VolEqRealtime.h"

#include <math.h>
#include <stdatomic.h>
#include <stdint.h>
#include <limits.h>
#include <stdlib.h>

_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "VolEq requires lock-free atomic counters");
_Static_assert(ATOMIC_LONG_LOCK_FREE == 2, "VolEq requires lock-free atomic indexes");
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "VolEq requires lock-free atomic totals");
_Static_assert(ATOMIC_BOOL_LOCK_FREE == 2, "VolEq requires lock-free atomic latches");

struct VolEqRealtimeContentState {
    float *samples;
    size_t capacity;
    _Atomic size_t read_index;
    _Atomic size_t write_index;
    _Atomic bool speech_authorized;
};

struct VolEqRealtimeHeartbeat {
    _Atomic unsigned long long callback_count;
};

struct VolEqRealtimeSignalLatch {
    _Atomic uint32_t qualifying_callback_count;
    _Atomic bool malformed;
};

struct VolEqRealtimeProcessorPublication {
    _Atomic unsigned int diagnostics_state;
    uint32_t path;
    uint32_t input_frame_count;
    uint32_t output_frame_count;
    _Atomic int failure_status;
};

struct VolEqRealtimeDiagnosticState {
    VolEqRealtimeDiagnosticRecord *records;
    size_t capacity;
    _Atomic size_t read_index;
    _Atomic size_t write_index;
    _Atomic unsigned long long dropped_record_count;
    _Atomic bool fault_injection_enabled;
    unsigned long long sequence;
    uint32_t zero_run_length;
    uint32_t partial_run_length;
};

// Keep probe confirmation above sub-audible floating-point noise or dither.
// Two separate callbacks must cross this metadata-only peak threshold.
static const float voleq_signal_threshold = 1.0e-4f;
static const size_t voleq_signal_latch_max_samples_per_callback = 65536;

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

VolEqRealtimeHeartbeat *voleq_realtime_heartbeat_create(void) {
    VolEqRealtimeHeartbeat *heartbeat = malloc(sizeof(*heartbeat));
    if (heartbeat == NULL) {
        return NULL;
    }
    atomic_init(&heartbeat->callback_count, 0);
    return heartbeat;
}

void voleq_realtime_heartbeat_destroy(VolEqRealtimeHeartbeat *heartbeat) {
    free(heartbeat);
}

void voleq_realtime_heartbeat_record_callback(
    VolEqRealtimeHeartbeat *heartbeat
) {
    if (heartbeat == NULL) {
        return;
    }
    atomic_fetch_add_explicit(
        &heartbeat->callback_count,
        1,
        memory_order_relaxed
    );
}

uint64_t voleq_realtime_heartbeat_callback_count(
    const VolEqRealtimeHeartbeat *heartbeat
) {
    if (heartbeat == NULL) {
        return 0;
    }
    return (uint64_t)atomic_load_explicit(
        &heartbeat->callback_count,
        memory_order_relaxed
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
    size_t observed_sample_count = 0;
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
        if (sample_count > voleq_signal_latch_max_samples_per_callback
            || observed_sample_count
                > voleq_signal_latch_max_samples_per_callback - sample_count) {
            atomic_store_explicit(&latch->malformed, true, memory_order_release);
            return;
        }
        observed_sample_count += sample_count;
        for (size_t sample_index = 0; sample_index < sample_count; ++sample_index) {
            const float sample = samples[sample_index];
            if (!isfinite(sample)) {
                atomic_store_explicit(&latch->malformed, true, memory_order_release);
                return;
            }
            if (fabsf(sample) > voleq_signal_threshold) {
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

VolEqRealtimeDiagnosticState *voleq_realtime_diagnostic_state_create(
    size_t capacity
) {
    if (capacity < 2) {
        return NULL;
    }
    VolEqRealtimeDiagnosticState *state = calloc(1, sizeof(*state));
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
    atomic_init(&state->dropped_record_count, 0);
    atomic_init(&state->fault_injection_enabled, false);
    return state;
}

void voleq_realtime_diagnostic_state_destroy(
    VolEqRealtimeDiagnosticState *state
) {
    if (state == NULL) {
        return;
    }
    free(state->records);
    free(state);
}

void voleq_realtime_diagnostic_state_record(
    VolEqRealtimeDiagnosticState *state,
    uint64_t callback_host_time,
    uint32_t captured_frame_count,
    uint32_t requested_output_frame_count,
    float captured_peak,
    uint32_t flags,
    uint32_t processing_path,
    uint32_t processing_outcome,
    int32_t processing_status
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
    if ((flags & VOLEQ_DIAGNOSTIC_FLAG_ALL_ZERO) != 0) {
        if (state->zero_run_length != UINT32_MAX) {
            state->zero_run_length += 1;
        }
    } else {
        state->zero_run_length = 0;
    }
    if ((flags & VOLEQ_DIAGNOSTIC_FLAG_PARTIAL_DELIVERY) != 0) {
        if (state->partial_run_length != UINT32_MAX) {
            state->partial_run_length += 1;
        }
    } else {
        state->partial_run_length = 0;
    }
    if (write_index - read_index >= state->capacity) {
        atomic_fetch_add_explicit(
            &state->dropped_record_count,
            1,
            memory_order_relaxed
        );
        return;
    }

    VolEqRealtimeDiagnosticRecord record = {
        .sequence = (uint64_t)state->sequence,
        .callback_host_time = callback_host_time,
        .captured_frame_count = captured_frame_count,
        .requested_output_frame_count = requested_output_frame_count,
        .captured_peak = captured_peak,
        .flags = flags,
        .zero_run_length = state->zero_run_length,
        .partial_run_length = state->partial_run_length,
        .processing_path = processing_path,
        .processing_outcome = processing_outcome,
        .processing_status = processing_status,
    };
    state->records[write_index % state->capacity] = record;
    atomic_store_explicit(
        &state->write_index,
        write_index + 1,
        memory_order_release
    );
}

size_t voleq_realtime_diagnostic_state_read(
    VolEqRealtimeDiagnosticState *state,
    VolEqRealtimeDiagnosticRecord *records,
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

uint64_t voleq_realtime_diagnostic_state_dropped_record_count(
    const VolEqRealtimeDiagnosticState *state
) {
    if (state == NULL) {
        return 0;
    }
    return (uint64_t)atomic_load_explicit(
        &state->dropped_record_count,
        memory_order_relaxed
    );
}

void voleq_realtime_diagnostic_state_set_fault_injection_enabled(
    VolEqRealtimeDiagnosticState *state,
    bool enabled
) {
    if (state == NULL) {
        return;
    }
    atomic_store_explicit(
        &state->fault_injection_enabled,
        enabled,
        memory_order_release
    );
}

bool voleq_realtime_diagnostic_state_fault_injection_enabled(
    const VolEqRealtimeDiagnosticState *state
) {
    if (state == NULL) {
        return false;
    }
    return atomic_load_explicit(
        &state->fault_injection_enabled,
        memory_order_acquire
    );
}
