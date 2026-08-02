// SPDX-License-Identifier: MPL-2.0

#ifndef VOLEQ_ALLOCATION_TEST_SUPPORT_H
#define VOLEQ_ALLOCATION_TEST_SUPPORT_H

#include <stddef.h>

void voleq_test_allocation_tracking_begin(void);
size_t voleq_test_allocation_tracking_end(void);

#endif
