// SPDX-License-Identifier: MPL-2.0

#include "VolEqRealtime.h"
#include "VolEqRealtimeAtomicSupport.h"

#include <stdlib.h>

struct VolEqRealtimeHeartbeat {
    _Atomic unsigned long long callback_count;
};

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
