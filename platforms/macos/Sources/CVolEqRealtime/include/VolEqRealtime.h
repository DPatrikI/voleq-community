// SPDX-License-Identifier: MPL-2.0

#ifndef VOLEQ_REALTIME_H
#define VOLEQ_REALTIME_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include <CoreAudio/CoreAudioTypes.h>

typedef struct VolEqRealtimeContentState VolEqRealtimeContentState;

VolEqRealtimeContentState *voleq_realtime_content_state_create(size_t capacity);
void voleq_realtime_content_state_destroy(VolEqRealtimeContentState *state);

size_t voleq_realtime_content_state_write(
    VolEqRealtimeContentState *state,
    const float *samples,
    size_t count
);

size_t voleq_realtime_content_state_read(
    VolEqRealtimeContentState *state,
    float *samples,
    size_t count
);

void voleq_realtime_content_state_set_speech_authorized(
    VolEqRealtimeContentState *state,
    bool authorized
);

bool voleq_realtime_content_state_is_speech_authorized(
    const VolEqRealtimeContentState *state
);

typedef struct VolEqRealtimeSignalLatch VolEqRealtimeSignalLatch;

VolEqRealtimeSignalLatch *voleq_realtime_signal_latch_create(void);
void voleq_realtime_signal_latch_destroy(VolEqRealtimeSignalLatch *latch);

void voleq_realtime_signal_latch_observe_callback(
    VolEqRealtimeSignalLatch *latch,
    const AudioBufferList *input_data
);

uint32_t voleq_realtime_signal_latch_qualifying_callback_count(
    const VolEqRealtimeSignalLatch *latch
);

bool voleq_realtime_signal_latch_is_malformed(
    const VolEqRealtimeSignalLatch *latch
);

#endif
