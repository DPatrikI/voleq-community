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

typedef struct VolEqRealtimeDiagnosticState VolEqRealtimeDiagnosticState;

enum {
    VOLEQ_DIAGNOSTIC_FLAG_ALL_ZERO = 1u << 0,
    VOLEQ_DIAGNOSTIC_FLAG_NO_CAPTURED_FRAMES = 1u << 1,
    VOLEQ_DIAGNOSTIC_FLAG_PARTIAL_DELIVERY = 1u << 2,
    VOLEQ_DIAGNOSTIC_FLAG_NONFINITE_INPUT = 1u << 3,
    VOLEQ_DIAGNOSTIC_FLAG_OUTPUT_REQUEST_ACTIVE = 1u << 4,
};

typedef struct {
    uint64_t sequence;
    uint64_t callback_host_time;
    uint32_t captured_frame_count;
    uint32_t requested_output_frame_count;
    float captured_peak;
    uint32_t flags;
    uint32_t zero_run_length;
    uint32_t partial_run_length;
    uint32_t processing_path;
    uint32_t processing_outcome;
    int32_t processing_status;
} VolEqRealtimeDiagnosticRecord;

VolEqRealtimeDiagnosticState *voleq_realtime_diagnostic_state_create(
    size_t capacity
);

void voleq_realtime_diagnostic_state_destroy(
    VolEqRealtimeDiagnosticState *state
);

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
);

size_t voleq_realtime_diagnostic_state_read(
    VolEqRealtimeDiagnosticState *state,
    VolEqRealtimeDiagnosticRecord *records,
    size_t maximum_record_count
);

uint64_t voleq_realtime_diagnostic_state_dropped_record_count(
    const VolEqRealtimeDiagnosticState *state
);

void voleq_realtime_diagnostic_state_set_fault_injection_enabled(
    VolEqRealtimeDiagnosticState *state,
    bool enabled
);

bool voleq_realtime_diagnostic_state_fault_injection_enabled(
    const VolEqRealtimeDiagnosticState *state
);

#endif
