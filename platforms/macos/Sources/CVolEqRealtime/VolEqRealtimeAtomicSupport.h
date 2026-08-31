// SPDX-License-Identifier: MPL-2.0

#ifndef VOLEQ_REALTIME_ATOMIC_SUPPORT_H
#define VOLEQ_REALTIME_ATOMIC_SUPPORT_H

#include <stdatomic.h>

_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "VolEq requires lock-free atomic counters");
_Static_assert(ATOMIC_LONG_LOCK_FREE == 2, "VolEq requires lock-free atomic indexes");
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "VolEq requires lock-free atomic totals");
_Static_assert(ATOMIC_BOOL_LOCK_FREE == 2, "VolEq requires lock-free atomic latches");

#endif
