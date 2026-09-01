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

typedef struct VolEqRealtimeHeartbeat VolEqRealtimeHeartbeat;

VolEqRealtimeHeartbeat *voleq_realtime_heartbeat_create(void);
void voleq_realtime_heartbeat_destroy(VolEqRealtimeHeartbeat *heartbeat);

void voleq_realtime_heartbeat_record_callback(
    VolEqRealtimeHeartbeat *heartbeat
);

uint64_t voleq_realtime_heartbeat_callback_count(
    const VolEqRealtimeHeartbeat *heartbeat
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

typedef struct VolEqRealtimeProcessorPublication VolEqRealtimeProcessorPublication;

VolEqRealtimeProcessorPublication *voleq_realtime_processor_publication_create(void);
void voleq_realtime_processor_publication_destroy(
    VolEqRealtimeProcessorPublication *publication
);
bool voleq_realtime_processor_publish_diagnostics(
    VolEqRealtimeProcessorPublication *publication,
    uint32_t path,
    uint32_t input_frame_count,
    uint32_t output_frame_count
);
bool voleq_realtime_processor_read_diagnostics(
    const VolEqRealtimeProcessorPublication *publication,
    uint32_t *path,
    uint32_t *input_frame_count,
    uint32_t *output_frame_count
);
void voleq_realtime_processor_publish_failure(
    VolEqRealtimeProcessorPublication *publication,
    int32_t status
);
int32_t voleq_realtime_processor_take_failure(
    VolEqRealtimeProcessorPublication *publication
);

typedef struct VolEqRealtimeLivenessState VolEqRealtimeLivenessState;

enum {
    VOLEQ_LIVENESS_FLAG_ALL_ZERO = 1u << 0,
    VOLEQ_LIVENESS_FLAG_NO_CAPTURED_FRAMES = 1u << 1,
    VOLEQ_LIVENESS_FLAG_PARTIAL_DELIVERY = 1u << 2,
    VOLEQ_LIVENESS_FLAG_NONFINITE_INPUT = 1u << 3,
    VOLEQ_LIVENESS_FLAG_OUTPUT_REQUEST_ACTIVE = 1u << 4,
};

typedef struct {
    uint64_t sequence;
    uint32_t captured_frame_count;
    uint32_t requested_output_frame_count;
    float captured_peak;
    uint32_t flags;
} VolEqRealtimeLivenessRecord;

VolEqRealtimeLivenessState *voleq_realtime_liveness_state_create(
    size_t capacity
);

void voleq_realtime_liveness_state_destroy(
    VolEqRealtimeLivenessState *state
);

void voleq_realtime_liveness_state_record(
    VolEqRealtimeLivenessState *state,
    uint32_t captured_frame_count,
    uint32_t requested_output_frame_count,
    float captured_peak,
    uint32_t flags
);

size_t voleq_realtime_liveness_state_read(
    VolEqRealtimeLivenessState *state,
    VolEqRealtimeLivenessRecord *records,
    size_t maximum_record_count
);

#endif
