// SPDX-License-Identifier: MPL-2.0

#include "VolEqRealtime.h"
#include "VolEqRealtimeAtomicSupport.h"

#include <limits.h>
#include <math.h>
#include <stdlib.h>

struct VolEqRealtimeSignalLatch {
    _Atomic uint32_t qualifying_callback_count;
    _Atomic bool malformed;
};

// Keep probe confirmation above sub-audible floating-point noise or dither.
// Two separate callbacks must cross this metadata-only peak threshold.
static const float voleq_signal_threshold = 1.0e-4f;
static const size_t voleq_signal_latch_max_samples_per_callback = 65536;

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
